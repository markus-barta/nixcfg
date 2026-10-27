import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";
import { StageStore, prepareLock, RECEIPT_CHECKPOINT, STATE_DIR, SOCKET_PATH } from "./v2-stage-worker.mjs";
import { startCycle, cycleReceipt } from "./v1-cycle.mjs";

const instant = "2026-10-27T12:00:00.000Z";
const json = file => JSON.parse(fs.readFileSync(file));
const worker = fileURLToPath(new URL("./v2-stage-worker.mjs", import.meta.url));
const baselineRevision = "c58a7e41389ce705d455e6c740a1835ea0595390"; // Supplied main; scratch origin/main is older.

async function fixture(t, count = 15) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), "joed102-recovery-"));
  fs.chmodSync(base, 0o700);
  t.after(() => spawnSync("trash", [base]));
  const root = path.join(base, "v2"), checkpointRoot = path.join(base, "ipc");
  for (const dir of [root, checkpointRoot]) fs.mkdirSync(dir, { mode: 0o700 });
  const options = { root, checkpointRoot, uid: process.getuid(), gid: process.getgid() };
  prepareLock(root, options.uid, options.gid);
  const store = new StageStore(options); store.enroll(); await store.open();
  for (let seq = 1; seq <= count; seq++) assert.equal(store.stage(instant, () => instant).status, 200);
  return { base, root, options, store, log: path.join(root, "receipts.jsonl"),
    checkpoint: path.join(checkpointRoot, "receipts-checkpoint.json") };
}

function coldStart(options) {
  // A fresh process includes module imports, contract verification, pair recovery
  // and checkpoint persistence. No broker, socket, Docker or network is involved.
  const result = spawnSync(process.execPath, ["--input-type=module", "-e", `
    const started = performance.now(), cpu = process.cpuUsage();
    const { StageStore } = await import(process.argv[1]);
    const store = await new StageStore(JSON.parse(process.argv[2])).open();
    const used = process.cpuUsage(cpu);
    console.log(JSON.stringify({ ...store.recovery, wallMs: performance.now() - started,
      cpuMs: (used.user + used.system) / 1000, seq: store.lastReceiptSeq }));
  `, pathToFileURL(worker).href, JSON.stringify(options)], { encoding: "utf8", timeout: 60_000 });
  assert.equal(result.status, 0, result.stderr || result.error?.message);
  return JSON.parse(result.stdout);
}

function syntheticLog(f, minBytes) {
  const binding = cycleReceipt(startCycle('{"synthetic":true}')(200, instant), true);
  const template = { format: "ops392.v2-sequence-receipt.v1", outcome: "committed", generatedAt: instant,
    stagedReceivedAt: instant, recordedAt: instant, pairSha256: "a".repeat(64), ...binding };
  const fd = fs.openSync(f.log, "w");
  let size = 0, seq = 0, chunk = "";
  try {
    while (size < minBytes) {
      const row = JSON.stringify({ ...template, seq: ++seq,
        observationId: `ops392.v1-cycle.00000000-0000-4000-8000-${seq.toString(16).padStart(12, "0")}` }) + "\n";
      size += Buffer.byteLength(row); chunk += row;
      if (chunk.length >= 65536) { fs.writeFileSync(fd, chunk); chunk = ""; }
    }
    if (chunk) fs.writeFileSync(fd, chunk);
    fs.fsyncSync(fd);
  } finally { fs.closeSync(fd); }
  const stateFile = path.join(f.root, "sequence-state.json");
  const state = json(stateFile);
  fs.writeFileSync(stateFile, JSON.stringify({ ...state, lastReservedSeq: seq, lastGeneratedAt: instant,
    lastObservationId: JSON.stringify(["ops392.switch-set.v2", instant]) }));
  fs.writeFileSync(f.checkpoint, "{"); // Force a full, validated first scan.
  return { size, rows: seq };
}

for (const mib of [11, 40]) test(`${mib} MiB real-shape receipt log: cold start validates only the bounded tail`, async t => {
  const f = await fixture(t, 0);
  const { size, rows } = syntheticLog(f, mib * 1024 * 1024);
  const full = coldStart(f.options);
  assert.equal(full.scanMode, "full"); assert.equal(full.rowsScanned, rows);
  const store = await new StageStore(f.options).open();
  // Real staged pairs carry the same binding fields as production receipts.
  for (let n = 0; n < 12; n++) {
    const observation = { bookTs: instant, v1Cycle: startCycle('{"synthetic":true}')(200, instant) };
    const reservation = store.reserve(observation, instant);
    assert.equal(store.stage(observation, () => instant, reservation, true).status, 200);
  }
  const before = fs.readFileSync(f.log);
  const tail = coldStart(f.options);
  assert.equal(tail.scanMode, "tail"); assert.equal(tail.rowsScanned, 12); // 11 tail + boundary row.
  assert.equal(tail.seq, rows + 12);
  assert.ok(tail.wallMs < 5000, JSON.stringify(tail));
  assert.deepEqual(fs.readFileSync(f.log), before);
  assert.equal(fs.readdirSync(f.root).filter(name => name.startsWith("pair-")).length, 10);
  t.diagnostic(JSON.stringify({ bytes: size, rows, full, tail }));
});

for (const fault of ["missing", "corrupt", "extra-key", "offset-beyond-size", "mid-line", "seq", "hash", "prefix-tamper", "retained-before"]) {
  test(`checkpoint ${fault} falls back to full validation`, async t => {
    const f = await fixture(t);
    const value = json(f.checkpoint);
    assert.ok(value.offset > 0);
    if (fault === "missing") fs.renameSync(f.checkpoint, `${f.checkpoint}.held`);
    else if (fault === "corrupt") fs.writeFileSync(f.checkpoint, "{");
    else if (fault === "prefix-tamper") {
      const bytes = fs.readFileSync(f.log);
      // A valid historical change must trigger revalidation, even without pairs.
      fs.writeFileSync(f.log, bytes.toString().replace('"outcome":"committed"', '"outcome":"rejected "'));
      // Equal length, valid JSON, invalid outcome: full scan must reject it.
      await assert.rejects(new StageStore(f.options).open());
      assert.equal(fs.readFileSync(f.log, "utf8").includes('"rejected "'), true);
      return;
    } else {
      if (fault === "extra-key") value.unknown = true;
      if (fault === "offset-beyond-size") value.offset = fs.statSync(f.log).size + 1;
      if (fault === "mid-line") value.offset--;
      if (fault === "seq") value.lastReceiptSeq--;
      if (fault === "hash") value.prefixSha256 = "0".repeat(64);
      if (fault === "retained-before") {
        // A correctly hashed checkpoint after retained receipts is unusable.
        value.offset = fs.statSync(f.log).size;
        value.lastReceiptSeq = 15;
        const { createHash } = await import("node:crypto");
        value.prefixSha256 = createHash("sha256").update(fs.readFileSync(f.log)).digest("hex");
      }
      fs.writeFileSync(f.checkpoint, JSON.stringify(value));
    }
    const before = fs.readFileSync(f.log);
    const store = await new StageStore(f.options).open();
    assert.deepEqual(store.recovery, { scanMode: "full", rowsScanned: 15 });
    assert.deepEqual(fs.readFileSync(f.log), before);
    assert.equal((await new StageStore(f.options).open()).recovery.scanMode, "tail");
  });
}

test("valid prefix tamper triggers a full scan instead of trusting its cached validation", async t => {
  const f = await fixture(t);
  const original = fs.readFileSync(f.log, "utf8");
  const lines = original.trimEnd().split("\n");
  const first = JSON.parse(lines[0]); first.recordedAt = instant;
  lines[0] = JSON.stringify(first);
  fs.writeFileSync(f.log, lines.join("\n") + "\n");
  assert.deepEqual((await new StageStore(f.options).open()).recovery, { scanMode: "full", rowsScanned: 15 });
});

for (const fault of ["duplicate-seq", "ahead-seq", "extra-key", "bad-time", "bad-binding", "wrong-pair", "torn"]) {
  test(`tail ${fault} fails closed and preserves receipt evidence`, async t => {
    const f = await fixture(t);
    const lines = fs.readFileSync(f.log, "utf8").trimEnd().split("\n");
    const row = JSON.parse(lines.at(-1));
    if (fault === "duplicate-seq") row.seq--;
    if (fault === "ahead-seq") row.seq++;
    if (fault === "extra-key") row.unknown = true;
    if (fault === "bad-time") row.recordedAt = "2026-02-30T00:00:00.000Z";
    if (fault === "bad-binding") row.v1Sha256 = "a".repeat(64);
    if (fault === "wrong-pair") row.pairSha256 = "b".repeat(64);
    lines[lines.length - 1] = JSON.stringify(row);
    fs.writeFileSync(f.log, lines.join("\n") + (fault === "torn" ? "\n{" : "\n"));
    const before = fs.readFileSync(f.log), checkpoint = fs.readFileSync(f.checkpoint);
    await assert.rejects(new StageStore(f.options).open());
    assert.deepEqual(fs.readFileSync(f.log), before);
    assert.deepEqual(fs.readFileSync(f.checkpoint), checkpoint);
  });
}

for (const fault of ["symlink", "hardlink", "mode", "owner", "directory", "parent-mode", "parent-symlink"]) {
  test(`unsafe checkpoint ${fault} is never trusted or replaced`, async t => {
    const f = await fixture(t);
    if (["symlink", "hardlink", "directory"].includes(fault)) fs.renameSync(f.checkpoint, `${f.checkpoint}.held`);
    if (fault === "symlink") fs.symlinkSync(`${f.checkpoint}.held`, f.checkpoint);
    if (fault === "hardlink") fs.linkSync(`${f.checkpoint}.held`, f.checkpoint);
    if (fault === "directory") fs.mkdirSync(f.checkpoint, { mode: 0o700 });
    if (fault === "mode") fs.chmodSync(f.checkpoint, 0o644);
    if (fault === "parent-mode") fs.chmodSync(f.options.checkpointRoot, 0o750);
    if (fault === "parent-symlink") {
      fs.renameSync(f.options.checkpointRoot, `${f.options.checkpointRoot}.held`);
      fs.symlinkSync(`${f.options.checkpointRoot}.held`, f.options.checkpointRoot);
    }
    const inode = fs.lstatSync(f.checkpoint).ino;
    let options = f.options;
    if (fault === "owner") options = { ...options, io: new Proxy(fs, { get(target, key) {
      if (key === "lstatSync") return file => {
        const stat = target.lstatSync(file);
        if (file === f.checkpoint) stat.uid++;
        return stat;
      };
      return target[key];
    } }) };
    const store = await new StageStore(options).open();
    assert.equal(store.recovery.scanMode, "full");
    assert.equal(fs.lstatSync(f.checkpoint).ino, inode);
    assert.equal(store.stage(instant, () => instant).status, 200);
  });
}

for (const point of ["checkpoint_write", "checkpoint_fsync", "checkpoint_rename", "checkpoint_dir_fsync"]) {
  test(`process death at ${point} leaves rollback-compatible state and a recoverable cache`, async t => {
    const f = await fixture(t);
    const result = spawnSync(process.execPath, ["--input-type=module", "-e", `
      const { StageStore } = await import(process.argv[1]);
      const store = await new StageStore(JSON.parse(process.argv[2])).open();
      store.boundary = name => { if (name === process.argv[3]) process.kill(process.pid, 'SIGKILL'); };
      store.stage('${instant}', () => '${instant}');
    `, pathToFileURL(worker).href, JSON.stringify(f.options), point], { encoding: "utf8" });
    assert.equal(result.signal, "SIGKILL", result.stderr);
    const state = json(path.join(f.root, "sequence-state.json"));
    const reopened = await new StageStore(f.options).open();
    assert.equal(reopened.lastReceiptSeq, state.lastReservedSeq);
    assert.equal(reopened.stage(instant, () => instant).seq, state.lastReservedSeq + 1);
    assert.equal(fs.existsSync(path.join(f.options.checkpointRoot, ".receipts-checkpoint.tmp")), false);
  });
}

test("checkpoint is outside the state tree; actual previous-main and r15 recovery ignore it", async t => {
  assert.equal(path.dirname(RECEIPT_CHECKPOINT), path.dirname(SOCKET_PATH));
  assert.equal(RECEIPT_CHECKPOINT.startsWith(STATE_DIR + path.sep), false);
  const f = await fixture(t);
  assert.throws(() => new StageStore({ ...f.options, checkpointRoot: f.root }));
  assert.throws(() => new StageStore({ ...f.options, checkpointRoot: path.join(f.root, "cache") }));
  const runtime = path.join(f.base, "baseline");
  const tree = "hosts/hsb0/docker/joe-board-pusher";
  const files = execFileSync("git", ["ls-tree", "--full-tree", "-r", "--name-only", `${baselineRevision}:${tree}`], { encoding: "utf8" }).trim().split("\n");
  for (const name of files.filter(name => (/^[^/]+\.mjs$/.test(name) && !name.endsWith(".test.mjs"))
    || name === "contracts.lock.json" || name.startsWith("contracts/"))) {
    const destination = path.join(runtime, name);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.writeFileSync(destination, execFileSync("git", ["show", `${baselineRevision}:${tree}/${name}`]));
  }
  const { StageStore: PreviousStore } = await import(pathToFileURL(path.join(runtime, "v2-stage-worker.mjs")));
  const before = fs.readFileSync(f.log), checkpoint = fs.readFileSync(f.checkpoint);
  const old = await new PreviousStore(f.options).open();
  assert.equal(old.previous.value.seq, 15);
  assert.equal(old.stage(instant, () => instant).seq, 16);
  const next = await new StageStore(f.options).open();
  assert.equal(next.recovery.scanMode, "tail"); assert.equal(next.lastReceiptSeq, 16);
  assert.ok(fs.readFileSync(f.log).subarray(0, before.length).equals(before));
  assert.equal(fs.statSync(f.checkpoint).mode & 0o7777, 0o600);
  assert.equal(fs.statSync(f.checkpoint).nlink, 1);
  assert.ok(checkpoint.length > 0);
  // These same-instant revision-9 projections are also r15-compatible. Its
  // separate source-time migration rules remain covered by v2-rollback tests.
  const { StageStore: R15Store } = await import("./fixtures/r15/v2-stage-worker.mjs");
  const r15 = await new R15Store(f.options).open();
  assert.equal(r15.previous.value.seq, 16);
  assert.equal(r15.stage(instant, () => instant).seq, 17);
  assert.equal((await new StageStore(f.options).open()).lastReceiptSeq, 17);
  assert.equal(fs.readdirSync(f.root).some(name => name.includes("checkpoint")), false);
});
