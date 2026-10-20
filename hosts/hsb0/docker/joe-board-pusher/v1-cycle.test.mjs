import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { EventEmitter } from "node:events";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { setImmediate as turn } from "node:timers/promises";
import { startCycle, validCycle, frame, cycleReceipt } from "./v1-cycle.mjs";
import { createCycleStore } from "./v1-cycle-store.mjs";
import { createStageHandoff, copyObservation } from "./v2-stage-handoff.mjs";
import { StageStore, prepareLock, serveWorker, validObservation } from "./v2-stage-worker.mjs";
import { runPusher } from "./fixtures/pusher-harness.mjs";

const at = "2026-10-20T11:00:00.000Z";
const hash = bytes => createHash("sha256").update(bytes).digest("hex");
const body = '{"schema":"inspr.joe.household.v1","private":"MASKED-CYCLE-BODY","generatedAt":"2026-10-20T11:00:00.000Z"}';
function temp(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "ops392-binding-"));
  t.after(() => spawnSync("trash", [root]));
  return root;
}
const read = name => JSON.parse(fs.readFileSync(name));
const source = status => ({ book: { ts: at, positions: [], summary: {} }, v1Body: body, v1Cycle: startCycle(body)(status, at) });

test("closed cycle envelope rejects unknown keys, raw failures, malformed hashes/statuses/IDs/times", () => {
  const good = source(200);
  assert.equal(validCycle(good.v1Cycle), true);
  assert.equal(validObservation(copyObservation(good)), true);
  for (const change of [
    c => { c.body = body; }, c => { c.v1Sha256 = "x".repeat(64); }, c => { c.v1Status = 600; },
    c => { c.v1Status = "PRIVATE-ERROR"; }, c => { c.observationId = at; }, c => { c.v1RepliedAt = "2026-02-31T00:00:00.000Z"; },
  ]) {
    const candidate = structuredClone(good.v1Cycle); change(candidate);
    assert.equal(validCycle(candidate), false); assert.equal(copyObservation({ ...good, v1Cycle: candidate }), null);
    assert.equal(validObservation({ ...copyObservation(good), v1Cycle: candidate }), false);
  }
  assert.notEqual(source(200).v1Cycle.observationId, good.v1Cycle.observationId);
  assert.equal(JSON.stringify(copyObservation(good)).includes("MASKED-CYCLE-BODY"), false);
});

test("pusher-only store preserves exact bytes, modes and pair sequence set by count", async t => {
  const root = temp(t), cycles = path.join(root, "v1-cycles"), v2 = path.join(root, "v2");
  fs.mkdirSync(v2, { mode: 0o700 });
  const options = { root: v2, uid: process.getuid(), gid: process.getgid() };
  prepareLock(v2, options.uid, options.gid);
  const store = new StageStore(options); store.enroll(); await store.open();
  const events = [], writer = createCycleStore({ root: cycles, emit: event => events.push(event) });
  for (let i = 1; i <= 14; i++) {
    const observation = copyObservation(source(i === 3 ? "post_failed" : 200));
    const reservation = store.reserve(observation);
    assert.equal(await writer.write(reservation.seq, body, observation.v1Cycle.v1Sha256), true);
    assert.equal(store.stage(observation, () => at, reservation, true).status, 200);
    await writer.prune(store.retainedSeqs());
  }
  assert.deepEqual(store.retainedSeqs(), [5, 6, 7, 8, 9, 10, 11, 12, 13, 14]);
  assert.deepEqual(fs.readdirSync(cycles).sort(), store.retainedSeqs().map(seq => `${seq}.json`).sort());
  assert.equal(fs.statSync(cycles).mode & 0o7777, 0o700);
  for (const name of fs.readdirSync(cycles)) {
    assert.equal(fs.statSync(path.join(cycles, name)).mode & 0o7777, 0o600);
    assert.equal(fs.readFileSync(path.join(cycles, name), "utf8"), body);
    const receipt = read(path.join(v2, `pair-${name.slice(0, -5)}`, "receipt.json"));
    assert.equal(receipt.v1Sha256, hash(fs.readFileSync(path.join(cycles, name))));
    assert.equal(receipt.v1Status, 200);
    assert.equal(receipt.seq, Number(name.slice(0, -5)));
  }
  const log = fs.readFileSync(path.join(v2, "receipts.jsonl"), "utf8");
  assert.equal(JSON.parse(log.trim().split("\n")[2]).v1Status, "post_failed");
  assert.equal(log.includes("MASKED-CYCLE-BODY"), false);
  assert.equal(events.length, 0);
  await new StageStore(options).open();
  // Restart/reconnect removes a body left by a crash before pair publication.
  await writer.write(15, body, hash(body)); await writer.prune(store.retainedSeqs());
  assert.equal(fs.existsSync(path.join(cycles, "15.json")), false);
});

for (const fault of ["open", "writeFile", "sync"]) test(`store ${fault} failure leaves a closed value-free event and v1_unbound receipt`, async t => {
  const root = temp(t), events = [];
  const io = new Proxy(fs.promises, { get(target, name) {
    if (name !== "open") return target[name];
    return async (...args) => {
      if (fault === "open") throw new Error(body);
      const handle = await target.open(...args);
      return new Proxy(handle, { get(h, key) {
        if (key === fault) return async () => { throw new Error(body); };
        return typeof h[key] === "function" ? h[key].bind(h) : h[key];
      } });
    };
  } });
  const writer = createCycleStore({ root: path.join(root, "v1-cycles"), io, emit: e => events.push(e) });
  const cycle = source(503).v1Cycle;
  const stored = await writer.write(1, body, cycle.v1Sha256);
  assert.equal(stored, false);
  assert.deepEqual(cycleReceipt(cycle, stored), { ...cycle, v1PostStatus: 503, v1Status: "v1_unbound" });
  assert.deepEqual(events, [{ event: "v1_cycle_unbound", reason: "store_write_failed" }]);
});

test("store refuses symlinks, wrong modes, overwrite and unexpected prune entries without deleting evidence", async t => {
  const root = temp(t), cycles = path.join(root, "cycles"), writer = createCycleStore({ root: cycles, emit() {} });
  assert.equal(await writer.write(1, body, hash(body)), true);
  assert.equal(await writer.write(1, "different", hash("different")), false);
  fs.writeFileSync(path.join(cycles, "unexpected"), "masked", { mode: 0o600 });
  assert.equal(await writer.prune([]), false); assert.equal(fs.existsSync(path.join(cycles, "1.json")), true);
  const link = path.join(root, "link"); fs.symlinkSync(cycles, link);
  assert.equal(await createCycleStore({ root: link, emit() {} }).write(2, body, hash(body)), false);
  fs.chmodSync(cycles, 0o755);
  assert.equal(await writer.write(2, body, hash(body)), false);
});

for (const mode of ["ok", "write-failure", "hung-store"]) test(`real pusher POST bytes and status settle independently of ${mode}`, async () => {
  const result = await runPusher(new URL("./pusher.mjs", import.meta.url), { stageState: "idle" });
  assert.equal(result.requests.length, 1);
  assert.equal(result.cycle.v1Sha256, hash(result.requests[0].body));
  assert.equal(result.cycle.v1Status, 200);
  assert.deepEqual(result.trace.slice(0, 3), ["fetch", "response-settled", "handoff"]);
  assert.equal(JSON.stringify(result.logs).includes(result.requests[0].body.toString()), false);
  const writes = [], events = [];
  class Socket extends EventEmitter {
    writable = true; writableLength = 0; destroyed = false; connecting = false;
    connect() {} destroy() { this.destroyed = true; }
    write(bytes) { writes.push(bytes); return true; }
  }
  const socket = new Socket();
  const handoff = createStageHandoff({ socketPath: "/run/joe-household-v2/stage.sock", makeSocket: () => socket,
    cycleStore: { write() { events.push("write"); if (mode === "write-failure") throw new Error(body);
      return mode === "hung-store" ? new Promise(() => {}) : true; } } });
  socket.emit("data", Buffer.from([1]));
  const input = source(200); assert.equal(handoff.offer(input), true);
  const assignment = frame({ event: "v1_store", seq: 1, observationId: input.v1Cycle.observationId });
  socket.emit("data", assignment.subarray(0, 2)); socket.emit("data", assignment.subarray(2)); await turn();
  assert.deepEqual(events, ["write"]);
  if (mode !== "hung-store") assert.equal(JSON.parse(writes[1].subarray(4)).stored, mode === "ok");
  else assert.equal(writes.length, 1);
  assert.equal(writes.some(bytes => bytes.includes("MASKED-CYCLE-BODY")), false); handoff.stop();
});

for (const mode of ["bound", "failed-post", "unbound", "timeout", "disconnect", "bad-ack", "bad-json"]) test(`worker reserves and binds the same seq/observation in both receipts: ${mode}`, async t => {
  const parent = temp(t), root = path.join(parent, "v2"); fs.mkdirSync(root, { mode: 0o700 });
  const options = { root, uid: process.getuid(), gid: process.getgid() };
  prepareLock(root, options.uid, options.gid); const store = new StageStore(options); store.enroll(); await store.open();
  let connect, timeout; const events = [];
  await serveWorker({ store, socketPath: path.join(parent, "stage.sock"), notify: e => events.push(e),
    setTimer(fn) { timeout = fn; return 1; }, clearTimer() { timeout = undefined; },
    createServer(fn) { connect = fn; const server = new EventEmitter();
      server.listen = (name, ready) => { fs.writeFileSync(name, "", { mode: 0o600 }); ready(); }; server.close = () => {}; return server; } });
  class Socket extends EventEmitter { writes = []; destroyed = false;
    write(bytes) { this.writes.push(bytes); } destroy() { this.destroyed = true; this.emit("close"); } }
  const socket = new Socket(); connect(socket);
  // Worker uses its real local receipt clock; source time remains bounded.
  const input = source(mode === "failed-post" ? "post_failed" : 200);
  input.book.ts = new Date().toISOString();
  const observation = copyObservation(input); socket.emit("data", frame(observation));
  const assignment = JSON.parse(socket.writes.at(-1).subarray(4));
  assert.equal(assignment.seq, 1); assert.equal(assignment.observationId, observation.v1Cycle.observationId);
  assert.equal(fs.existsSync(path.join(root, "pair-1")), false);
  if (mode === "timeout") timeout();
  else if (mode === "disconnect") socket.destroy();
  else if (mode === "bad-ack") socket.emit("data", frame({ seq: 2, observationId: assignment.observationId, stored: true }));
  else if (mode === "bad-json") socket.emit("data", Buffer.from([0, 0, 0, 1, 0xff]));
  else socket.emit("data", frame({ seq: assignment.seq, observationId: assignment.observationId, stored: mode !== "unbound" }));
  const receipt = read(path.join(root, "pair-1/receipt.json"));
  const log = JSON.parse(fs.readFileSync(path.join(root, "receipts.jsonl"), "utf8").trim());
  for (const field of ["seq", "v1Sha256", "v1Status", "v1PostStatus", "v1RepliedAt", "observationId"]) assert.equal(log[field], receipt[field]);
  assert.equal(receipt.v1Status, ["timeout", "unbound", "disconnect", "bad-ack", "bad-json"].includes(mode) ? "v1_unbound" : input.v1Cycle.v1Status);
  assert.equal(receipt.v1Sha256, hash(body)); assert.equal(receipt.observationId, input.v1Cycle.observationId);
  assert.equal(JSON.stringify(events).includes("MASKED-CYCLE-BODY"), false);
  await new StageStore(options).open();
});

for (const fault of ["none", "store-write", "post-failed", "http-failed"]) test(`actual POST through handoff, body writer and worker receipts: ${fault}`, { timeout: 5000 }, async t => {
  const pushed = await runPusher(new URL("./pusher.mjs", import.meta.url), fault === "post-failed" ? { fetchError: { synthetic: "private-post-error" } }
    : fault === "http-failed" ? { httpStatus: 503 } : {});
  assert.equal(pushed.requests.length, 1);
  const posted = pushed.requests[0].body.toString(), bookTs = JSON.parse(posted).brokerAccount.observedAt;
  const parent = temp(t), root = path.join(parent, "v2"); fs.mkdirSync(root, { mode: 0o700 });
  const options = { root, uid: process.getuid(), gid: process.getgid() };
  prepareLock(root, options.uid, options.gid); const store = new StageStore(options); store.enroll(); await store.open();
  const stage = store.stage.bind(store); store.stage = (observation, _now, reservation, stored) => stage(observation, () => bookTs, reservation, stored);
  let connect, completed;
  const done = new Promise(resolve => { completed = resolve; });
  const controls = [];
  await serveWorker({ store, socketPath: path.join(parent, "stage.sock"), notify: event => {
    controls.push(event); if (event.event === "job_done") completed(event);
  }, createServer(fn) {
    connect = fn; const server = new EventEmitter();
    server.listen = (name, ready) => { fs.writeFileSync(name, "", { mode: 0o600 }); ready(); }; server.close = () => {}; return server;
  } });
  class Endpoint extends EventEmitter {
    writable = true; writableLength = 0; destroyed = false; connecting = false;
    write(bytes) { const copy = Buffer.from(bytes); queueMicrotask(() => this.peer.emit("data", copy)); return true; }
    destroy() { if (this.destroyed) return; this.destroyed = true; this.emit("close"); }
    connect() { queueMicrotask(() => connect(this.peer)); }
  }
  const client = new Endpoint(), worker = new Endpoint(); client.peer = worker; worker.peer = client;
  const io = fault === "store-write" ? new Proxy(fs.promises, { get(target, name) {
    return name === "open" ? async () => { throw new Error(posted); } : target[name];
  } }) : fs.promises;
  const events = [], cycleRoot = path.join(parent, "v1-cycles");
  const writer = createCycleStore({ root: cycleRoot, io, emit: event => events.push(event) });
  const handoff = createStageHandoff({ socketPath: "/run/joe-household-v2/stage.sock", makeSocket: () => client, cycleStore: writer });
  t.after(() => { handoff.stop(); worker.destroy(); });
  await turn();
  assert.equal(handoff.offer({ book: { ts: bookTs, positions: [], summary: {} }, v1Body: posted, v1Cycle: pushed.cycle }), true);
  assert.equal((await done).outcome, "committed");
  await writer.prune(store.retainedSeqs());
  const receipt = read(path.join(root, "pair-1/receipt.json"));
  assert.equal(receipt.v1Status, fault === "store-write" ? "v1_unbound" : fault === "post-failed" ? "post_failed" : fault === "http-failed" ? 503 : 200);
  assert.equal(receipt.v1Sha256, hash(pushed.requests[0].body)); assert.equal(receipt.observationId, pushed.cycle.observationId);
  if (fault !== "store-write") assert.equal(fs.readFileSync(path.join(cycleRoot, "1.json"), "utf8"), posted);
  for (const lines of [events, controls, pushed.logs, pushed.errors]) assert.equal(JSON.stringify(lines).includes(posted), false);
  assert.equal(JSON.stringify(events).includes("private-post-error"), false);
});

test("hung storage holds at most one body and coalesces pruning to the latest sequence set", async t => {
  const root = path.join(temp(t), "cycles");
  let release; const gate = new Promise(resolve => { release = resolve; });
  const events = [], io = new Proxy(fs.promises, { get(target, name) {
    return name === "open" ? async (...args) => { await gate; return target.open(...args); } : target[name];
  } });
  const writer = createCycleStore({ root, io, emit: event => events.push(event) });
  const writing = writer.write(1, body, hash(body));
  assert.equal(await writer.write(2, body, hash(body)), false);
  const pruning = writer.prune([1]);
  for (let i = 0; i < 20; i++) assert.equal(writer.prune(i === 19 ? [] : [1]), pruning);
  release(); assert.equal(await writing, true); assert.equal(await pruning, true);
  assert.deepEqual(fs.readdirSync(root), []);
  assert.deepEqual(events, [{ event: "v1_cycle_unbound", reason: "store_busy" }]);
});

test("retention control handles split frames and a coalesced credit at the supported 1024-pair bound", () => {
  let retained;
  class Socket extends EventEmitter {
    writable = true; writableLength = 0; destroyed = false; connecting = false;
    connect() {} destroy() { this.destroyed = true; } write() { return true; }
  }
  const socket = new Socket();
  const handoff = createStageHandoff({ socketPath: "/run/joe-household-v2/stage.sock", makeSocket: () => socket,
    cycleStore: { prune(seqs) { retained = seqs; } } });
  const seqs = Array.from({ length: 1024 }, (_, index) => Number.MAX_SAFE_INTEGER - index);
  const message = Buffer.concat([frame({ event: "v1_retained", retainedSeqs: seqs }), Buffer.from([1])]);
  socket.emit("data", message.subarray(0, 2)); socket.emit("data", message.subarray(2));
  assert.equal(socket.destroyed, false); assert.deepEqual(retained, seqs);
  assert.equal(handoff.offer(source(200)), true); handoff.stop();
});
