import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";
import { StageStore, prepareLock, STATE_DIR, SOCKET_PATH } from "./v2-stage-worker.mjs";
import { startCycle, cycleReceipt } from "./v1-cycle.mjs";

const instant = "2026-10-27T12:00:00.000Z";
const json = file => JSON.parse(fs.readFileSync(file));
const worker = fileURLToPath(new URL("./v2-stage-worker.mjs", import.meta.url));
const baselineRevision = "c58a7e41389ce705d455e6c740a1835ea0595390"; // Pinned pre-checkpoint worker for rollback compatibility.

async function fixture(t, count = 15) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), "joed102-recovery-"));
  fs.chmodSync(base, 0o700);
  t.after(() => spawnSync("trash", [base]));
  const root = path.join(base, "pusher", "v2"), checkpointRoot = path.join(base, "checkpoint");
  for (const dir of [root, checkpointRoot]) fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const options = { root, env: { JOE_V2_STAGE_CHECKPOINT_DIR: checkpointRoot }, uid: process.getuid(), gid: process.getgid() };
  prepareLock(root, options.uid, options.gid);
  const store = new StageStore(options); store.enroll(); await store.open();
  for (let seq = 1; seq <= count; seq++) assert.equal(store.stage(instant, () => instant).status, 200);
  return { base, root, checkpointRoot, options, store, log: path.join(root, "receipts.jsonl"),
    checkpoint: path.join(checkpointRoot, "receipts-checkpoint.json") };
}

function coldStart(options, validationBudgetBytes = null) {
  // A fresh process includes module imports, contract verification, pair recovery
  // and checkpoint persistence. No broker, socket, Docker or network is involved.
  const result = spawnSync(process.execPath, ["--input-type=module", "-e", `
    const started = performance.now(), cpu = process.cpuUsage();
    const { StageStore } = await import(process.argv[1]);
    const budget = JSON.parse(process.argv[3]);
    let validatedBytes = 0;
    const remember = StageStore.prototype.rememberReceipt;
    StageStore.prototype.rememberReceipt = function(row, bytes) {
      remember.call(this, row, bytes);
      validatedBytes += bytes.length;
      // Deterministic startup deadline: terminate the real process once its
      // validation work budget is exhausted, between checkpoint writes.
      if (budget !== null && validatedBytes >= budget) process.kill(process.pid, "SIGKILL");
    };
    const store = await new StageStore(JSON.parse(process.argv[2])).open();
    const used = process.cpuUsage(cpu);
    console.log(JSON.stringify({ ...store.recovery, wallMs: performance.now() - started,
      cpuMs: (used.user + used.system) / 1000, seq: store.lastReceiptSeq }));
  `, pathToFileURL(worker).href, JSON.stringify(options), JSON.stringify(validationBudgetBytes)], { encoding: "utf8", timeout: 60_000 });
  if (result.signal === "SIGKILL") {
    assert.notEqual(validationBudgetBytes, null, result.error?.message);
    return { killed: true };
  }
  assert.equal(result.status, 0, result.stderr || result.error?.message);
  return JSON.parse(result.stdout);
}

function logSha(file) {
  const hash = createHash("sha256"), buffer = Buffer.alloc(65536);
  const fd = fs.openSync(file, "r");
  try {
    let count;
    while ((count = fs.readSync(fd, buffer))) hash.update(buffer.subarray(0, count));
    return hash.digest("hex");
  } finally { fs.closeSync(fd); }
}

function syntheticLog(f, minBytes, { outcome = "committed", append = false } = {}) {
  const binding = cycleReceipt(startCycle('{"synthetic":true}')(200, instant), true);
  const template = { format: "ops392.v2-sequence-receipt.v1", outcome, generatedAt: instant,
    stagedReceivedAt: instant, recordedAt: instant, pairSha256: "a".repeat(64), ...binding };
  const stateFile = path.join(f.root, "sequence-state.json");
  const state = json(stateFile);
  const fd = fs.openSync(f.log, append ? "a" : "w");
  let size = 0, seq = append ? state.lastReservedSeq : 0, chunk = "";
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
  fs.writeFileSync(stateFile, JSON.stringify({ ...state, lastReservedSeq: seq, lastGeneratedAt: instant,
    lastObservationId: JSON.stringify(["ops392.switch-set.v2", instant]) }));
  fs.writeFileSync(f.checkpoint, "{"); // Force a full, validated first scan.
  return { size, rows: seq };
}

for (const setting of [undefined, ""]) test(`checkpoint env ${setting === undefined ? "unset" : "empty"} performs no checkpoint IO`, async t => {
  const f = await fixture(t);
  const before = fs.readFileSync(f.checkpoint), accesses = [], warnings = [];
  const io = new Proxy(fs, { get(target, key) {
    if (typeof target[key] !== "function") return target[key];
    return (...args) => {
      if (typeof args[0] === "string" && (args[0].startsWith(f.checkpointRoot)
        || args[0].startsWith(path.dirname(SOCKET_PATH)))) accesses.push([key, args[0]]);
      return target[key](...args);
    };
  } });
  const store = await new StageStore({ ...f.options, io,
    env: setting === undefined ? {} : { JOE_V2_STAGE_CHECKPOINT_DIR: setting },
    onCheckpointDisabled: () => warnings.push(true) }).open();
  assert.deepEqual(store.recovery, { scanMode: "full", rowsScanned: 15 });
  assert.equal(store.stage(instant, () => instant).seq, 16);
  assert.deepEqual(accesses, []);
  assert.deepEqual(warnings, []);
  assert.deepEqual(fs.readFileSync(f.checkpoint), before);
});

for (const location of ["relative", "legacy-ipc", "legacy-child", "production-state", "production-parent", "state", "state-child", "state-parent", "state-parent-child", "ancestor", "socket", "socket-child", "pusher-read-only", "alias-to-shared"]) {
  test(`checkpoint directory ${location} is refused before checkpoint IO`, async t => {
    const f = await fixture(t), warnings = [], accesses = [];
    const shared = path.join(f.base, "ipc"); fs.mkdirSync(shared, { mode: 0o700 });
    const socketPath = path.join(shared, "stage.sock");
    const directories = {
      relative: "checkpoint", "legacy-ipc": path.dirname(SOCKET_PATH),
      "legacy-child": path.join(path.dirname(SOCKET_PATH), "private"),
      "production-state": STATE_DIR, "production-parent": path.dirname(STATE_DIR),
      state: f.root, "state-child": path.join(f.root, "cache"),
      "state-parent": path.dirname(f.root), "state-parent-child": path.join(path.dirname(f.root), "cache"),
      ancestor: f.base, socket: shared, "socket-child": path.join(shared, "cache"),
      "pusher-read-only": "/var/lib/paper-desk-executor/cache",
    };
    if (location === "alias-to-shared") {
      const alias = path.join(f.base, "alias"); fs.symlinkSync(shared, alias);
      fs.mkdirSync(path.join(shared, "cache"), { mode: 0o700 });
      directories[location] = path.join(alias, "cache");
    }
    const io = new Proxy(fs, { get(target, key) {
      if (typeof target[key] !== "function") return target[key];
      return (...args) => {
        if (typeof args[0] === "string" && /receipts-checkpoint|\.receipts-checkpoint/.test(args[0])) accesses.push(key);
        return target[key](...args);
      };
    } });
    const store = await new StageStore({ ...f.options, io, socketPath,
      env: { JOE_V2_STAGE_CHECKPOINT_DIR: directories[location] },
      onCheckpointDisabled: () => warnings.push(true) }).open();
    assert.deepEqual(store.recovery, { scanMode: "full", rowsScanned: 15 });
    assert.equal(store.checkpointRoot, null);
    assert.equal(store.stage(instant, () => instant).seq, 16);
    assert.deepEqual(warnings, [true]);
    assert.deepEqual(accesses, []);
  });
}

for (const fault of ["missing", "file", "symlink", "mode", "uid", "gid"]) {
  test(`unusable stager-only directory ${fault} disables checkpoints once`, async t => {
    const f = await fixture(t), warnings = [];
    if (["missing", "file", "symlink"].includes(fault)) fs.renameSync(f.checkpointRoot, `${f.checkpointRoot}.held`);
    if (fault === "file") fs.writeFileSync(f.checkpointRoot, "", { mode: 0o600 });
    if (fault === "symlink") fs.symlinkSync(`${f.checkpointRoot}.held`, f.checkpointRoot);
    if (fault === "mode") fs.chmodSync(f.checkpointRoot, 0o750);
    const io = new Proxy(fs, { get(target, key) {
      if (key === "lstatSync" && ["uid", "gid"].includes(fault)) return file => {
        const stat = target.lstatSync(file);
        if (file === f.checkpointRoot) stat[fault]++;
        return stat;
      };
      return target[key];
    } });
    const store = await new StageStore({ ...f.options, io, onCheckpointDisabled: () => warnings.push(true) }).open();
    assert.deepEqual(store.recovery, { scanMode: "full", rowsScanned: 15 });
    assert.equal(store.stage(instant, () => instant).seq, 16);
    assert.equal(store.checkpointRoot, null);
    assert.deepEqual(warnings, [true]);
    if (fault === "missing") assert.equal(fs.existsSync(f.checkpointRoot), false);
  });
}

for (const corruption of ["malformed-history", "decreasing-seq", "hidden-retained-receipt"]) {
  for (const location of ["legacy-ipc-unset", "socket", "pusher-parent"]) {
    test(`forged ${corruption} checkpoint in ${location} cannot conceal receipt corruption`, async t => {
      const f = await fixture(t, corruption === "malformed-history" ? 15 : 99);
      const lines = fs.readFileSync(f.log, "utf8").trimEnd().split("\n");
      let prefix, tail = "", lastReceiptSeq;
      if (corruption === "malformed-history") {
        lines[0] = "{";
        prefix = lines.slice(0, 5).join("\n") + "\n";
        tail = lines.slice(5).join("\n") + "\n";
        lastReceiptSeq = 5; // Valid boundary and tail; historical JSON is invalid.
      } else {
        const retained = JSON.parse(lines.at(-1));
        if (corruption === "hidden-retained-receipt") retained.pairSha256 = "0".repeat(64);
        prefix = JSON.stringify(retained) + "\n" + lines[1] + "\n";
        lastReceiptSeq = 2; // A forged low boundary used to hide retained pair 99.
      }
      fs.writeFileSync(f.log, prefix + tail);
      const forged = Buffer.from(JSON.stringify({ format: "joed102.v2-receipts-checkpoint.v1",
        offset: Buffer.byteLength(prefix), lastReceiptSeq,
        prefixSha256: createHash("sha256").update(prefix).digest("hex") }));
      const shared = location === "pusher-parent" ? path.dirname(f.root) : path.join(f.base, "legacy-ipc");
      fs.mkdirSync(shared, { recursive: true, mode: 0o700 });
      const checkpoint = path.join(shared, "receipts-checkpoint.json");
      fs.writeFileSync(checkpoint, forged, { mode: 0o600 });
      const before = fs.readFileSync(f.log), names = fs.readdirSync(f.root).sort();
      const warnings = [];
      const store = new StageStore({ ...f.options,
        socketPath: location === "pusher-parent" ? SOCKET_PATH : path.join(shared, "stage.sock"),
        env: location === "legacy-ipc-unset" ? {} : { JOE_V2_STAGE_CHECKPOINT_DIR: shared },
        onCheckpointDisabled: () => warnings.push(true) });
      await assert.rejects(store.open(), /stage_storage_invalid|JSON/);
      assert.equal(store.recovery.scanMode, "full");
      assert.deepEqual(warnings, location === "legacy-ipc-unset" ? [] : [true]);
      assert.deepEqual(fs.readFileSync(f.log), before); // No second receipt 99.
      assert.deepEqual(fs.readdirSync(f.root).sort(), names);
      assert.deepEqual(fs.readFileSync(checkpoint), forged);
    });
  }
}

test("a stager-only checkpoint survives a fresh worker and missing-mount rollback safely falls back", async t => {
  const f = await fixture(t), before = fs.readFileSync(f.log);
  assert.equal(coldStart(f.options).scanMode, "tail");
  fs.renameSync(f.checkpointRoot, `${f.checkpointRoot}.held`);
  const warnings = [];
  const store = await new StageStore({ ...f.options, onCheckpointDisabled: () => warnings.push(true) }).open();
  assert.deepEqual(store.recovery, { scanMode: "full", rowsScanned: 15 });
  assert.deepEqual(warnings, [true]);
  assert.equal(fs.existsSync(f.checkpointRoot), false);
  assert.deepEqual(fs.readFileSync(f.log), before);
});

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

for (const outcome of ["committed", "rejected"]) test(`a full scan of ${outcome} history killed at a simulated startup deadline resumes and completes`, async t => {
  const f = await fixture(t, 0);
  const { rows } = syntheticLog(f, 11 * 1024 * 1024, { outcome });
  const before = logSha(f.log);
  assert.deepEqual(coldStart(f.options, 6 * 1024 * 1024), { killed: true });
  const progress = json(f.checkpoint);
  assert.ok(progress.offset >= 4 * 1024 * 1024 && progress.offset < 6 * 1024 * 1024);
  assert.ok(progress.lastReceiptSeq > 0 && progress.lastReceiptSeq < rows);
  assert.equal(fs.readFileSync(f.log).at(progress.offset - 1), 10);
  const resumed = coldStart(f.options);
  assert.equal(resumed.scanMode, "tail");
  assert.equal(resumed.rowsScanned, rows - progress.lastReceiptSeq + 1);
  assert.equal(resumed.seq, rows);
  assert.equal(logSha(f.log), before);
  t.diagnostic(JSON.stringify({ checkpointBytes: progress.offset, resumed }));
});

test("scan checkpoints never advance past an old retained pair into a long rejected tail", async t => {
  const f = await fixture(t);
  const oldestRetained = Math.min(...f.store.retainedSeqs());
  const { rows } = syntheticLog(f, 6 * 1024 * 1024, { outcome: "rejected", append: true });
  const before = logSha(f.log), checkpoint = fs.readFileSync(f.checkpoint);
  assert.deepEqual(coldStart(f.options, 5 * 1024 * 1024), { killed: true });
  // Even a deadline does not justify checkpointing beyond an unbound pair.
  assert.deepEqual(fs.readFileSync(f.checkpoint), checkpoint);
  const full = coldStart(f.options);
  assert.equal(full.scanMode, "full");
  assert.equal(full.rowsScanned, rows);
  assert.equal(full.seq, rows);
  assert.ok(json(f.checkpoint).lastReceiptSeq < oldestRetained);
  assert.equal(logSha(f.log), before);
});

for (const invalid of [false, true]) test(`prefix tamper after a killed full scan ${invalid ? "fails closed" : "forces full validation"}`, async t => {
  const f = await fixture(t, 0);
  const { rows } = syntheticLog(f, 6 * 1024 * 1024);
  assert.deepEqual(coldStart(f.options, 5 * 1024 * 1024), { killed: true });
  const checkpoint = fs.readFileSync(f.checkpoint);
  const original = fs.readFileSync(f.log, "utf8");
  // Keep offsets stable; JSON permits whitespace after the closing quote.
  const tampered = original.replace('"outcome":"committed"', invalid ? '"outcome":"rejected "' : '"outcome":"staged"   ');
  assert.equal(Buffer.byteLength(tampered), Buffer.byteLength(original));
  fs.writeFileSync(f.log, tampered);
  if (invalid) {
    await assert.rejects(new StageStore(f.options).open());
    assert.deepEqual(fs.readFileSync(f.checkpoint), checkpoint);
  } else {
    const recovered = await new StageStore(f.options).open();
    assert.deepEqual(recovered.recovery, { scanMode: "full", rowsScanned: rows });
  }
  assert.equal(fs.readFileSync(f.log, "utf8"), tampered);
});

test("110 MiB log with retained pairs completes across bounded simulated startup restarts", async t => {
  const f = await fixture(t, 0);
  const { rows } = syntheticLog(f, 110 * 1024 * 1024);
  // Preparation creates real retained pairs after the synthetic history.
  const store = await new StageStore(f.options).open();
  for (let n = 0; n < 12; n++) assert.equal(store.stage(instant, () => instant).status, 200);
  const oldestRetained = Math.min(...store.retainedSeqs());
  fs.writeFileSync(f.checkpoint, "{");
  const before = logSha(f.log), started = performance.now();
  const validationBudgetBytes = 24 * 1024 * 1024, maxRestarts = 6;
  let previousOffset = 0, restarts = 0, complete;
  const offsets = [];
  for (let attempt = 0; attempt <= maxRestarts; attempt++) {
    const result = coldStart(f.options, validationBudgetBytes);
    const progress = json(f.checkpoint);
    assert.ok(progress.offset > previousOffset);
    assert.ok(progress.lastReceiptSeq < oldestRetained);
    previousOffset = progress.offset; offsets.push(progress.offset);
    if (!result.killed) { complete = result; break; }
    restarts++;
  }
  assert.ok(complete, `recovery exceeded ${maxRestarts} restarts`);
  assert.ok(restarts > 0 && restarts <= maxRestarts);
  assert.equal(complete.scanMode, "tail");
  assert.equal(complete.seq, rows + 12);
  assert.equal(logSha(f.log), before);
  assert.equal((await new StageStore(f.options).open()).recovery.rowsScanned, 12);
  t.diagnostic(JSON.stringify({ bytes: fs.statSync(f.log).size, validationBudgetBytes, maxRestarts,
    restarts, wallMs: performance.now() - started, offsets, complete }));
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
        // Read the log once: offset and hash come from the same bytes (no stat-then-read race).
        const logBytes = fs.readFileSync(f.log);
        value.offset = logBytes.length;
        value.lastReceiptSeq = 15;
        const { createHash } = await import("node:crypto");
        value.prefixSha256 = createHash("sha256").update(logBytes).digest("hex");
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
    if (fault === "parent-mode") fs.chmodSync(f.checkpointRoot, 0o750);
    if (fault === "parent-symlink") {
      fs.renameSync(f.checkpointRoot, `${f.checkpointRoot}.held`);
      fs.symlinkSync(`${f.checkpointRoot}.held`, f.checkpointRoot);
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
    assert.equal(fs.existsSync(path.join(f.checkpointRoot, ".receipts-checkpoint.tmp")), false);
  });
}

test("checkpoint is outside the state tree; actual previous-main and r15 recovery ignore it", async t => {
  const f = await fixture(t);
  assert.equal(f.checkpoint.startsWith(f.root + path.sep), false);
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
