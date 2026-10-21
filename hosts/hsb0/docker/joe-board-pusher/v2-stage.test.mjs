import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";
import { EventEmitter } from "node:events";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { StageStore, buildCandidate, normalizeBookTs, acceptStage, prepareLock, launchLocked, serveWorker } from "./v2-stage-worker.mjs";
import { FRAME_FORMAT, MAX_FRAME_BYTES } from "./v2-stage-handoff.mjs";
import { createStageSupervisor } from "./v2-stage-supervisor.mjs";
import { validateContract } from "./contracts/index.mjs";
import { acceptSnapshot } from "./contracts/accept.mjs";

const instant = "2026-10-19T07:00:00.000Z";
const later = "2026-10-19T07:00:01.000Z";
const observation = (bookTs = instant) => ({ format: FRAME_FORMAT, bookTs, equity: null, cash: null, apiReplyCheckedAt: null, positions: [] });
const json = name => JSON.parse(fs.readFileSync(name));
function fixture(t, boundary, io = fs) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "ops392-"));
  fs.chmodSync(root, 0o700);
  t.after(() => { spawnSync("trash", [root]); });
  const options = { root, uid: process.getuid(), gid: process.getgid(), boundary, io };
  prepareLock(root, options.uid, options.gid);
  const store = new StageStore(options);
  return { root, store, options };
}
function current(root) {
  const pointer = json(path.join(root, "current.json"));
  return { snapshot: json(path.join(root, pointer.pair, "snapshot.json")), receipt: json(path.join(root, pointer.pair, "receipt.json")), pair: pointer.pair };
}

test("masked golden preserves raw account evidence; ingress, served and semantic negatives", () => {
  const golden = json(new URL("./fixtures/household-v2-phase-a.masked.json", import.meta.url));
  const source = json(new URL("./fixtures/switch-set-observation.masked.json", import.meta.url));
  assert.deepEqual(buildCandidate(1, source.observation.bookTs, source.observation, source.receivedAt), golden);
  assert.equal(validateContract("data", golden, { stage: "ingress" }).ok, true);
  assert.equal(acceptSnapshot("data", golden, null, golden.generatedAt).status, 200);
  assert.equal(validateContract("data", golden).ok, false);
  assert.equal(validateContract("data", { ...golden, receivedAt: instant }, { stage: "ingress" }).ok, false);
  const zero = structuredClone(golden); zero.totals.equity = { amount: "0", currency: "EUR" }; delete zero.totals.reasons.equity;
  assert.equal(validateContract("data", zero, { stage: "ingress" }).ok, false);
  const noReasons = structuredClone(golden); delete noReasons.totals.reasons;
  assert.equal(new StageStore().validProjection(noReasons), false);
  assert.doesNotMatch(JSON.stringify(golden), /"(?:account|accountHint|pnlSources|accounting|learning|moneyEvidence|heartbeatAt)"/);
  for (const desk of golden.desks) assert.equal(desk.action, "Valuation is not exact yet.");
});

test("real contract rejects replay, clock/receipt regression and +5001; +5000 passes", () => {
  const first = buildCandidate(1, instant);
  const feed = acceptSnapshot("data", first, null, instant);
  assert.equal(acceptSnapshot("data", first, feed, later).reason, "sequence_replayed");
  assert.equal(acceptSnapshot("data", buildCandidate(2, "2026-10-19T06:59:59.000Z"), feed, later).reason, "clock_regressed");
  assert.equal(acceptSnapshot("data", buildCandidate(2, instant), feed, "2026-10-19T06:59:59.000Z").reason, "clock_regressed");
  assert.equal(acceptSnapshot("data", buildCandidate(2, "2026-10-19T07:00:05.000Z"), feed, instant).status, 200);
  assert.equal(acceptSnapshot("data", buildCandidate(2, "2026-10-19T07:00:05.001Z"), feed, instant).reason, "clock_ahead");
  assert.equal(acceptSnapshot("data", buildCandidate(2, instant), feed, later).generatedAdvancedAt, instant);
  let called = false;
  assert.equal(acceptStage(() => { called = true; }, { seq: 0 }, null, instant, 0).reason, "sequence_replayed");
  assert.equal(called, false);
});

test("strict source UTC normalization rejects missing, invalid and calendar rollover instants", () => {
  for (const value of [undefined, null, "", "2026-02-30T01:00:00Z", "2026-10-19T24:00:00Z", "2026-10-19T07:00:00+00:00", "x".repeat(65)]) assert.equal(normalizeBookTs(value), null);
  assert.equal(normalizeBookTs("2026-10-19T07:00:00Z"), instant);
  assert.equal(normalizeBookTs(instant), instant);
});

test("explicit enrollment emits seq 1; exact bytes/receipt/modes; restart and repeated observation retain progress", async t => {
  const { root, store, options } = fixture(t);
  store.enroll();
  assert.equal(json(path.join(root, "sequence-state.json")).floor, 0);
  assert.throws(() => store.enroll());
  await store.open();
  assert.equal(store.stage(instant, () => instant).status, 200);
  const pair = current(root);
  assert.equal(pair.snapshot.seq, 1);
  assert.equal(Object.hasOwn(pair.snapshot, "receivedAt"), false);
  const bytes = fs.readFileSync(path.join(root, pair.pair, "snapshot.json"));
  assert.equal(pair.receipt.snapshotSha256, createHash("sha256").update(bytes).digest("hex"));
  assert.equal(pair.receipt.stagedReceivedAt, instant);
  for (const name of ["", pair.pair]) assert.equal(fs.statSync(path.join(root, name)).mode & 0o777, 0o700);
  for (const name of [".allocator.lock", "sequence-state.json", "current.json", `${pair.pair}/snapshot.json`, `${pair.pair}/receipt.json`]) {
    const stat = fs.statSync(path.join(root, name));
    assert.equal(stat.mode & 0o777, 0o600); assert.equal(stat.uid, options.uid); assert.equal(stat.gid, options.gid);
  }
  const restarted = await new StageStore(options).open();
  assert.equal(restarted.stage(instant, () => later).status, 200);
  assert.equal(current(root).snapshot.seq, 2);
  assert.equal(current(root).snapshot.generatedAt, later);
  assert.equal(current(root).receipt.generatedAdvancedAt, later);
  assert.equal(fs.readdirSync(root).filter(n => n.startsWith("pair-")).length, 2);
  assert.equal(restarted.stage("2026-02-30T06:00:00.000Z").reason, "source_time_invalid");
  assert.equal(restarted.stage(undefined).reason, "source_time_invalid");
  assert.equal(json(path.join(root, "sequence-state.json")).lastReservedSeq, 2);
});

const boundaries = ["reserve_write", "reserve_fsync", "reserve_rename", "reserve_dir_fsync", "pair_mkdir", "snapshot_write", "snapshot_fsync", "receipt_write", "receipt_fsync", "pair_fsync", "pair_rename", "pair_dir_fsync", "pointer_write", "pointer_fsync", "pointer_rename", "pointer_dir_fsync", "log_append", "log_fsync"];
for (const point of boundaries) test(`process death at ${point} preserves authoritative pair and never reuses durable reservation`, async t => {
  const { root, store, options } = fixture(t);
  store.enroll(); await store.open(); store.stage(instant, () => instant);
  // A real child dies at the boundary; no catch/finally recovery can hide residue.
  const source = `import { pathToFileURL } from 'node:url';
    const { StageStore } = await import(pathToFileURL(process.argv[1]).href);
    const store = await new StageStore({root:process.argv[2],uid:process.getuid(),gid:process.getgid()}).open();
    store.boundary = label => { if (label === process.argv[3]) process.kill(process.pid, 'SIGKILL'); };
    store.stage('2026-10-19T07:00:01.000Z', () => '2026-10-19T07:00:01.000Z');`;
  const result = spawnSync(process.execPath, ["--input-type=module", "-e", source, fileURLToPath(new URL("./v2-stage-worker.mjs", import.meta.url)), root, point], { encoding: "utf8" });
  assert.equal(result.signal, "SIGKILL", result.stderr);
  const reserved = json(path.join(root, "sequence-state.json")).lastReservedSeq;
  const pair = current(root); // Always a whole old or new pair.
  assert.ok(pair.snapshot.seq <= reserved);
  const reopened = await new StageStore(options).open();
  reopened.stage(later, () => later);
  assert.equal(current(root).snapshot.seq, reserved + 1);
  assert.ok(fs.readdirSync(root).filter(n => /^(pair-|\.next-)/.test(n)).length <= 10);
});

for (const corruption of ["missing", "malformed", "floor", "owner", "mode", "symlink", "unknown", "digest", "pair-ahead", "oversize", "null-high-water"]) test(`corrupt ${corruption} disables startup without deleting evidence`, async t => {
  const { root, store, options } = fixture(t);
  store.enroll(); await store.open(); store.stage(instant, () => instant);
  const statePath = path.join(root, "sequence-state.json");
  if (corruption === "missing") fs.renameSync(statePath, path.join(root, "held-state"));
  if (corruption === "malformed") fs.writeFileSync(statePath, "{");
  if (corruption === "floor") { const state = json(statePath); state.floor = 1; fs.writeFileSync(statePath, JSON.stringify(state)); }
  if (corruption === "owner") options.uid += 1;
  if (corruption === "mode") fs.chmodSync(statePath, 0o644);
  if (corruption === "symlink") { fs.renameSync(statePath, path.join(root, "held-state")); fs.symlinkSync("held-state", statePath); }
  if (corruption === "unknown") fs.writeFileSync(path.join(root, "unrecognized"), "", { mode: 0o600 });
  if (corruption === "digest") fs.appendFileSync(path.join(root, current(root).pair, "snapshot.json"), " ");
  if (corruption === "pair-ahead") { const state = json(statePath); state.lastReservedSeq = 0; state.lastObservationId = null; state.lastGeneratedAt = null; fs.writeFileSync(statePath, JSON.stringify(state)); }
  if (corruption === "null-high-water") { const state = json(statePath); state.lastGeneratedAt = null; state.lastObservationId = JSON.stringify(["ops392.phase-a.v1", null]); fs.writeFileSync(statePath, JSON.stringify(state)); }
  if (corruption === "oversize") fs.writeFileSync(statePath, "x".repeat(4097));
  const before = fs.readdirSync(root).sort();
  await assert.rejects(new StageStore(options).open());
  assert.deepEqual(fs.readdirSync(root).sort(), before);
});

for (const fault of ["ENOSPC", "fsync"]) test(`${fault} fails closed until restart and preserves reserved high water`, async t => {
  const { root, store, options } = fixture(t);
  store.enroll(); await store.open();
  let once = true;
  store.io = new Proxy(fs, { get(target, prop) {
    if (prop === (fault === "ENOSPC" ? "writeFileSync" : "fsyncSync")) return (...args) => {
      if (once) { once = false; throw Object.assign(new Error("synthetic"), { code: "ENOSPC" }); }
      return target[prop](...args);
    };
    return target[prop];
  } });
  assert.throws(() => store.stage(instant, () => instant));
  assert.equal(store.disabled, true);
  assert.throws(() => store.stage(instant, () => instant));
  const reopened = await new StageStore(options).open();
  assert.equal(reopened.stage(instant, () => instant).status, 200);
  assert.equal(current(root).snapshot.seq, 1);
});

test("allocator safe-integer exhaustion and clock-ahead burn without publish", async t => {
  const { root, store } = fixture(t);
  store.enroll(); await store.open();
  const reservation = store.reserve(observation(), later);
  assert.equal(store.stage(observation(), () => "2026-10-19T06:00:00.000Z", reservation).reason, "clock_ahead");
  assert.equal(fs.existsSync(path.join(root, "current.json")), false);
  assert.equal(store.state.lastReservedSeq, 1);
  store.stage(later, () => later);
  assert.equal(current(root).snapshot.seq, 2);
  store.state.lastReservedSeq = Number.MAX_SAFE_INTEGER;
  assert.throws(() => store.stage(later, () => later));
});

test("supervisor drains output, kills startup/job hangs, and restarts with bounded backoff", () => {
  const timers = new Map(); let timerId = 0;
  const children = []; const events = [];
  const supervisor = createStageSupervisor({
    launch() {
      const child = new EventEmitter(); child.kills = [];
      child.kill = signal => child.kills.push(signal);
      child.stdout = { resume() { child.drainedOut = true; } };
      child.stderr = { resume() { child.drainedErr = true; } };
      children.push(child); return child;
    },
    setTimer(fn, delay) { timers.set(++timerId, { fn, delay }); return timerId; },
    clearTimer(id) { timers.delete(id); }, emit: event => events.push(event),
  });
  function run(delay) {
    const entry = [...timers].find(([, timer]) => timer.delay === delay); assert.ok(entry);
    timers.delete(entry[0]); entry[1].fn();
  }
  assert.ok(children[0].drainedOut && children[0].drainedErr);
  run(5000); assert.deepEqual(children[0].kills, ["SIGKILL"]);
  for (const delay of [1000, 2000, 4000, 8000, 16000, 30000, 30000]) {
    children.at(-1).emit("close", 1); run(delay);
  }
  const child = children.at(-1);
  child.emit("message", { event: "ready" }); child.emit("message", { event: "job_start" });
  run(5000); assert.deepEqual(child.kills, ["SIGKILL"]);
  assert.ok(events.every(e => /^v2_stage_(disabled|restarting|committed|skipped)$/.test(e.event)));
  supervisor.stop(); assert.equal(timers.size, 0);
});

test("lock invocation uses stable inode, no-fork, and no inherited credentials", t => {
  const { root, options } = fixture(t);
  let invocation;
  launchLocked({ ...options, args: ["--enroll"], spawnWorker: (...args) => { invocation = args; return {}; } });
  assert.equal(invocation[0], "flock");
  assert.deepEqual(invocation[1].slice(0, 3), ["--no-fork", "--nonblock", path.join(root, ".allocator.lock")]);
  assert.ok(invocation[1].includes("--enroll"));
  assert.deepEqual(Object.keys(invocation[2].env).sort(), ["NODE_ENV", "PATH"]);
});

test("Linux real flock excludes a concurrent writer", { skip: process.platform !== "linux" ? "Linux flock required; no Docker/fleet lab authorized" : false }, t => {
  const { root } = fixture(t);
  const result = spawnSync("flock", ["--no-fork", "--nonblock", path.join(root, ".allocator.lock"), "sh", "-c", 'flock --nonblock "$1" true; test "$?" = 1', "sh", path.join(root, ".allocator.lock")]);
  assert.equal(result.status, 0);
});

test("worker has no outbound HTTP, broker or token surface; throw stubs see zero calls", async t => {
  const { store } = fixture(t);
  const original = globalThis.fetch; let calls = 0;
  globalThis.fetch = () => { calls++; throw new Error("outbound forbidden"); };
  t.after(() => { globalThis.fetch = original; });
  store.enroll(); await store.open(); store.stage(instant, () => instant);
  assert.equal(calls, 0);
  for (const file of ["v2-stage-worker.mjs", "v2-stage-supervisor.mjs"]) {
    const source = fs.readFileSync(new URL(file, import.meta.url), "utf8");
    assert.doesNotMatch(source, /\bfetch\s*\(|node:https?|@stoqey|readToken|TOKEN_FILE|run\/secrets|agenix/);
  }
});

test("worker frame parser bounds partial/oversized/malformed frames and issues a credit only after a job", async t => {
  const { root, store } = fixture(t);
  let connect; let partialTimeout; let stageCalls = 0;
  const events = []; const trace = [];
  store.stage = source => { stageCalls++; trace.push("stage"); assert.equal(source.bookTs, instant); return { status: 200 }; };
  const socketPath = path.join(root, "stage.sock");
  await serveWorker({
    store, socketPath, notify: message => { events.push(message); trace.push(message.event); },
    setTimer: fn => { partialTimeout = fn; return 1; }, clearTimer: () => { partialTimeout = undefined; },
    createServer(onConnection) {
      connect = onConnection;
      const server = new EventEmitter();
      server.listen = (name, ready) => { fs.writeFileSync(name, "", { mode: 0o600 }); ready(); };
      server.close = () => {};
      return server;
    },
  });
  class Socket extends EventEmitter {
    writes = []; destroyed = false;
    write(bytes) { this.writes.push(Buffer.from(bytes)); trace.push("credit"); }
    destroy() { this.destroyed = true; this.emit("close"); }
  }
  const frame = value => { const bytes = Buffer.from(JSON.stringify(value)); const b = Buffer.alloc(bytes.length + 4); b.writeUInt32BE(bytes.length); bytes.copy(b, 4); return b; };
  const good = frame(observation());
  const socket = new Socket(); connect(socket);
  assert.deepEqual(socket.writes, [Buffer.from([1])]);
  const extra = new Socket(); connect(extra); assert.equal(extra.destroyed, true);
  socket.emit("data", good.subarray(0, 2)); assert.equal(stageCalls, 0);
  socket.emit("data", good.subarray(2)); assert.equal(stageCalls, 1);
  assert.deepEqual(trace.slice(-4), ["job_start", "stage", "job_done", "credit"]);
  assert.equal(socket.writes.length, 2); socket.destroy();
  for (const invalid of [Buffer.from([0, 0, 64, 1]), Buffer.concat([good, good]), frame({ format: "wrong", bookTs: instant }), frame({ ...observation(), bookTs: "x".repeat(65) }), Buffer.from([0, 0, 0, 1, 0xff])]) {
    const next = new Socket(); connect(next); next.emit("data", invalid); assert.equal(next.destroyed, true);
  }
  const partial = new Socket(); connect(partial); partial.emit("data", Buffer.from([0]));
  assert.equal(typeof partialTimeout, "function"); partialTimeout(); assert.equal(partial.destroyed, true);
  assert.equal(stageCalls, 1);
  assert.equal(fs.statSync(socketPath).mode & 0o777, 0o600);
  assert.ok(events.every(e => ["ready", "job_start", "job_done"].includes(e.event)));
});

for (const entry of ["file", "symlink"]) test(`worker refuses to unlink unexpected socket-path ${entry}`, async t => {
  const { root, store } = fixture(t);
  const socketPath = path.join(root, "stage.sock");
  if (entry === "file") fs.writeFileSync(socketPath, "evidence", { mode: 0o600 });
  else fs.symlinkSync(".allocator.lock", socketPath);
  await assert.rejects(serveWorker({ store, socketPath }));
  assert.equal(fs.lstatSync(socketPath).isSymbolicLink(), entry === "symlink");
});

test("separate Linux memory-cgroup identities and OOM isolation", {
  skip: "Run node scripts/rehearse-household-v2-stage.mjs in the workstation lab; offline builders cannot run Docker",
}, () => {});

test("count retention keeps N pairs, prunes N+1 oldest, survives restart and permits a larger bound", async t => {
  const { root, store, options } = fixture(t);
  store.enroll(); await store.open();
  for (let seq = 1; seq <= 10; seq++) assert.equal(store.stage(instant, () => instant).seq, seq);
  const pairs = () => fs.readdirSync(root).filter(name => /^pair-/.test(name)).sort((a, b) => Number(a.slice(5)) - Number(b.slice(5)));
  assert.deepEqual(pairs(), Array.from({ length: 10 }, (_, n) => `pair-${n + 1}`));
  store.stage(instant, () => instant);
  assert.deepEqual(pairs(), Array.from({ length: 10 }, (_, n) => `pair-${n + 2}`));
  const restarted = await new StageStore(options).open();
  assert.equal(restarted.previous.value.seq, 11); assert.equal(pairs().length, 10);
  // Count only: a later observation does not prune the nine older pairs by age.
  restarted.stage("2026-10-20T07:00:00.000Z", () => "2026-10-20T07:00:00.000Z");
  assert.deepEqual(pairs(), Array.from({ length: 10 }, (_, n) => `pair-${n + 3}`));
  const bigger = await new StageStore({ ...options, retainPairs: 12 }).open();
  bigger.stage("2026-10-20T07:00:00.000Z", () => "2026-10-20T07:00:00.000Z");
  bigger.stage("2026-10-20T07:00:00.000Z", () => "2026-10-20T07:00:00.000Z");
  assert.equal(pairs().length, 12);
  await new StageStore(options).open(); assert.equal(pairs().length, 10);
  assert.throws(() => new StageStore({ ...options, retainPairs: 9 }));
});

test("receipt log appends exactly one value-free outcome per sequence and outlives pair pruning", async t => {
  const { root, store, options } = fixture(t); store.enroll(); await store.open();
  const read = () => fs.readFileSync(path.join(root, "receipts.jsonl"), "utf8");
  store.stage(instant, () => instant); const prefix = read();
  const reservation = store.reserve(observation(), later);
  store.stage(observation(), () => "2026-10-19T06:00:00.000Z", reservation);
  for (let seq = 3; seq <= 13; seq++) store.stage(later, () => later);
  assert.ok(read().startsWith(prefix));
  const rows = read().trim().split("\n").map(JSON.parse);
  assert.equal(rows.length, 13); assert.deepEqual(rows.map(row => row.seq), Array.from({ length: 13 }, (_, n) => n + 1));
  assert.equal(rows[0].outcome, "committed"); assert.equal(rows[1].outcome, "rejected");
  for (const row of rows) {
    assert.deepEqual(Object.keys(row).sort(), ["format", "seq", "outcome", "generatedAt", "stagedReceivedAt", "recordedAt", "pairSha256"].sort());
    assert.match(row.pairSha256, /^[0-9a-f]{64}$/);
  }
  const pair = current(root);
  assert.equal(rows.at(-1).pairSha256, pair.receipt.snapshotSha256);
  assert.equal(fs.statSync(path.join(root, "receipts.jsonl")).mode & 0o777, 0o600);
  const before = read(); const restarted = await new StageStore(options).open(); assert.equal(read(), before);
  restarted.stage(later, () => later); assert.ok(read().startsWith(before));
  assert.equal(fs.existsSync(path.join(root, "pair-1")), false);
});

for (const point of ["pair_dir_fsync", "pointer_dir_fsync", "log_fsync", "prune_rename_fsync", "retire_dir_fsync"]) {
  test(`retention/receipt recovery at ${point} is idempotent and never changes the sequence high water`, async t => {
    const { root, store, options } = fixture(t); store.enroll(); await store.open();
    for (let seq = 1; seq <= 10; seq++) store.stage(instant, () => instant);
    store.boundary = name => { if (name === point) throw new Error("synthetic crash"); };
    assert.throws(() => store.stage(later, () => later));
    const reopened = await new StageStore(options).open();
    assert.equal(reopened.state.lastReservedSeq, 11);
    const log = () => fs.readFileSync(path.join(root, "receipts.jsonl"), "utf8");
    const rows = log().trim().split("\n").map(JSON.parse);
    assert.equal(rows.length, 11); assert.equal(rows.at(-1).seq, 11);
    assert.equal(rows.at(-1).outcome, point === "pair_dir_fsync" ? "staged" : "committed");
    const before = log(); await new StageStore(options).open(); assert.equal(log(), before);
    reopened.stage(later, () => later); assert.equal(current(root).snapshot.seq, 12);
    assert.equal(fs.readdirSync(root).filter(name => /^pair-/.test(name)).length, 10);
  });
}

test("torn receipt log or corrupt historical pair disables staging and preserves evidence", async t => {
  const { root, store, options } = fixture(t); store.enroll(); await store.open();
  store.stage(instant, () => instant); store.stage(later, () => later);
  fs.appendFileSync(path.join(root, "pair-1/snapshot.json"), " ");
  const before = fs.readdirSync(root).sort();
  await assert.rejects(new StageStore(options).open()); assert.deepEqual(fs.readdirSync(root).sort(), before);
  const other = fixture(t); other.store.enroll(); await other.store.open(); other.store.stage(instant, () => instant);
  fs.appendFileSync(path.join(other.root, "receipts.jsonl"), "{");
  await assert.rejects(new StageStore(other.options).open());
  assert.ok(fs.readFileSync(path.join(other.root, "receipts.jsonl"), "utf8").endsWith("{"));
});

test("worker commit IPC and supervisor commit event carry only a positive sequence", async t => {
  const { root, store } = fixture(t); const events = []; let connect;
  store.stage = () => ({ status: 200, seq: 7 });
  const socketPath = path.join(root, "stage.sock");
  await serveWorker({ store, socketPath, notify: value => events.push(value), createServer(callback) {
    connect = callback;
    return { once() {}, on() {}, close() {}, listen(name, callback) { fs.writeFileSync(name, "", { mode: 0o600 }); callback(); } };
  } });
  const socket = new EventEmitter(); socket.write = () => {}; socket.destroy = () => {};
  connect(socket);
  const payload = Buffer.from(JSON.stringify(observation())); const frame = Buffer.alloc(payload.length + 4); frame.writeUInt32BE(payload.length); payload.copy(frame, 4);
  socket.emit("data", frame); socket.emit("close");
  assert.deepEqual(events.at(-1), { event: "job_done", outcome: "committed", seq: 7 });
  const child = new EventEmitter(); child.kill = () => {}; const output = [];
  const supervisor = createStageSupervisor({ launch: () => child, setTimer: () => 1, clearTimer() {}, emit: value => output.push(value) });
  child.emit("message", { event: "ready" }); child.emit("message", { event: "job_start" }); child.emit("message", events.at(-1));
  assert.deepEqual(output, [{ event: "v2_stage_committed", seq: 7 }]);
  child.emit("message", { event: "job_start" }); child.emit("message", { event: "job_done", outcome: "committed", seq: "unsafe" });
  assert.equal(output.at(-1).reason, "worker_protocol"); supervisor.stop();
});

test("a crash between pruning file unlinks recovers only the checked tombstone", async t => {
  const { root, store, options } = fixture(t); store.enroll(); await store.open();
  for (let seq = 1; seq <= 10; seq++) store.stage(instant, () => instant);
  let once = true;
  store.io = new Proxy(fs, { get(target, name) {
    if (name === "unlinkSync") return file => {
      target.unlinkSync(file);
      if (once) { once = false; throw new Error("synthetic prune crash"); }
    };
    return target[name];
  } });
  assert.throws(() => store.stage(later, () => later));
  assert.equal(fs.existsSync(path.join(root, ".retired-1")), true);
  const recovered = await new StageStore(options).open();
  assert.equal(recovered.previous.value.seq, 11);
  assert.equal(fs.existsSync(path.join(root, ".retired-1")), false);
  assert.equal(fs.readdirSync(root).filter(name => /^pair-/.test(name)).length, 10);
});
