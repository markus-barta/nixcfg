import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { execFileSync } from "node:child_process";
import { EventEmitter } from "node:events";
import test from "node:test";
import { createStageHandoff } from "./v2-stage-handoff.mjs";
import { projectBook } from "./project.mjs";

const file = "hosts/hsb0/docker/joe-board-pusher/pusher.mjs";
const candidate = fs.readFileSync(new URL("./pusher.mjs", import.meta.url), "utf8");
const baseline = execFileSync("git", ["show", `27681452:${file}`], { encoding: "utf8" });
const instant = "2026-10-19T07:00:00.000Z";
class Socket extends EventEmitter {
  writable = true; writableLength = 0; destroyed = false; connecting = false;
  writes = []; result = true;
  connect() { assert.ok(this.listenerCount("error") && this.listenerCount("close")); }
  write(bytes) { this.writes.push(Buffer.from(bytes)); if (this.failure) throw this.failure; return this.result; }
  destroy() { this.destroyed = true; }
}
function handoff() {
  const sockets = []; const deferred = [];
  const adapter = createStageHandoff({ socketPath: "/synthetic/stage.sock", makeSocket: () => { const socket = new Socket(); sockets.push(socket); return socket; }, defer: fn => { deferred.push(fn); return {}; } });
  return { adapter, sockets, deferred };
}

test("one 0x01 credit permits one uint32-be bounded scalar frame, including backpressure", () => {
  const { adapter, sockets } = handoff(); const socket = sockets[0];
  assert.equal(adapter.offer(instant), false);
  socket.emit("data", Buffer.from([1])); socket.result = false;
  assert.equal(adapter.offer(instant), false);
  assert.equal(adapter.offer(instant), false); assert.equal(socket.writes.length, 1);
  const frame = socket.writes[0];
  assert.equal(frame.readUInt32BE(), frame.length - 4);
  assert.ok(frame.readUInt32BE() <= 4096);
  assert.deepEqual(JSON.parse(frame.subarray(4)), { format: "ops392.phase-a-observation.v1", bookTs: instant });
  socket.emit("data", Buffer.from([1])); socket.writableLength = 1;
  assert.equal(adapter.offer(instant), false); socket.writableLength = 0;
  assert.equal(adapter.offer("x".repeat(65)), false);
  socket.result = true; assert.equal(adapter.offer(instant), true);
  assert.equal(socket.writes.length, 2); adapter.stop();
});

for (const code of ["EPIPE", "ECONNRESET", "ERR_STREAM_DESTROYED"]) test(`${code} drops credit and reconnects outside offer only after close`, () => {
  const { adapter, sockets, deferred } = handoff(); const socket = sockets[0];
  socket.emit("data", Buffer.from([1])); socket.failure = Object.assign(new Error("synthetic"), { code });
  assert.doesNotThrow(() => adapter.offer(instant)); assert.equal(socket.destroyed, true);
  assert.equal(deferred.length, 0); assert.equal(sockets.length, 1);
  socket.emit("error", socket.failure); socket.emit("close");
  assert.equal(deferred.length, 1); assert.equal(adapter.offer(instant), false);
  deferred.shift()(); assert.equal(sockets.length, 2); adapter.stop();
});

test("duplicate/invalid credits close the socket; construction failure is contained", () => {
  for (const bytes of [Buffer.from([2]), Buffer.from([1, 1])]) {
    const { adapter, sockets } = handoff(); sockets[0].emit("data", bytes);
    assert.equal(sockets[0].destroyed, true); adapter.stop();
  }
  const { adapter, sockets } = handoff(); sockets[0].emit("data", Buffer.from([1])); sockets[0].emit("data", Buffer.from([1]));
  assert.equal(sockets[0].destroyed, true); adapter.stop();
  assert.doesNotThrow(() => createStageHandoff({ makeSocket: () => { throw new Error("synthetic"); } }));
});

function harness(source, { variant = "normal", socket, fetchError, bodyError } = {}) {
  const start = source.indexOf("async function pushOnce() {");
  const end = source.indexOf("\nconnectionSupervisor =", start);
  const book = {
    ts: instant, gatewayLastSeenAt: instant, gateway: variant !== "outage",
    summary: {}, portfolio: [], positions: [],
  };
  const retained = variant === "retained" ? { observedAt: instant, status: "retained", desks: {} } : null;
  const inputBefore = JSON.stringify({ book, retained });
  const requests = []; const observations = []; const trace = []; let reads = 0; let observes = 0;
  const failure = { ok: false, reason: "synthetic-unavailable" };
  const context = {
    HOST: "synthetic.invalid", LIVE_PORT: 4001, PORT: 4002, INBOX_URL: "https://synthetic.invalid/inbox",
    portUp: async () => false, waitForExecutionCycle: async () => {}, bookSnapshot: () => variant === "incomplete" ? null : book,
    familyAdapter: { requestInFlight: false, project: () => failure, projectDeskEquities: () => failure },
    familyHistoryAdapter: { project: () => failure },
    dayPnlProducer: { observe() { observes++; return failure; }, inspectState: () => ({ latest: retained }) },
    calculateDeskEquities: () => {}, CURRENT_DESK_OWNERSHIP_POLICY: {},
    projectBook: (b, options) => variant === "no-timestamp" ? null : projectBook(b, options),
    readToken() { reads++; return variant === "no-token" ? "" : "synthetic-test-token"; },
    adapter: { connected: variant !== "outage" },
    fetch: async (url, options) => {
      requests.push({ url, ...options, body: Buffer.from(options.body) }); trace.push("fetch");
      if (fetchError) { trace.push("fetch-rejected"); throw fetchError; }
      return { ok: true, status: 200, text: async () => {
        trace.push("response-settled"); if (bodyError) throw bodyError; return '{"ok":true}';
      } };
    },
    Date: class extends Date { constructor() { super(instant); } },
    console: { log() {}, warn() {}, error() {} },
    v2StageHandoff: socket ? { offer(bookTs) { trace.push("handoff"); observations.push(bookTs); return socket.offer(bookTs); } } : null,
  };
  const push = vm.runInNewContext(`${source.slice(start, end)}\npushOnce`, context);
  return { push, requests, observations, trace, inputsUnchanged: () => inputBefore === JSON.stringify({ book, retained }), counts: () => ({ reads, observes }) };
}
for (const variant of ["normal", "retained", "outage"]) for (const stageState of ["idle", "busy", "hang", "nonzero-exit", "OOM", "backpressure", "throw", "slow-fsync", "ENOSPC", "restart", "corrupt-state"]) {
  test(`original/candidate v1 bytes, one POST and result: ${variant}/${stageState}`, async () => {
    const { adapter, sockets } = handoff(); const socket = sockets[0];
    if (["idle", "backpressure", "throw"].includes(stageState)) socket.emit("data", Buffer.from([1]));
    if (stageState === "backpressure") socket.result = false;
    if (stageState === "throw") socket.failure = new Error("synthetic");
    if (["nonzero-exit", "OOM", "corrupt-state"].includes(stageState)) { socket.emit("error", new Error("synthetic")); socket.emit("close"); }
    const old = harness(baseline, { variant }); const next = harness(candidate, { variant, socket: adapter });
    const oldResult = await old.push(); const result = await next.push();
    assert.equal(JSON.stringify(result), JSON.stringify(oldResult));
    assert.equal(old.requests.length, 1); assert.equal(next.requests.length, 1);
    assert.ok(old.requests[0].body.equals(next.requests[0].body));
    assert.equal(JSON.stringify({ ...next.requests[0], body: undefined }), JSON.stringify({ ...old.requests[0], body: undefined }));
    assert.deepEqual(next.observations, [instant]);
    assert.deepEqual(next.trace, ["fetch", "response-settled", "handoff"]);
    assert.equal(old.inputsUnchanged() && next.inputsUnchanged(), true);
    assert.deepEqual(next.counts(), { reads: 1, observes: 1 }); adapter.stop();
  });
}
for (const failureAt of ["fetch", "body"]) test(`v1 ${failureAt} rejection retains original identity and still offers only after settlement`, async () => {
  const error = new Error("synthetic"); const { adapter, sockets } = handoff();
  sockets[0].emit("data", Buffer.from([1])); sockets[0].failure = new Error("stage failure");
  const args = { [failureAt === "fetch" ? "fetchError" : "bodyError"]: error };
  const old = harness(baseline, args); const next = harness(candidate, { ...args, socket: adapter });
  await assert.rejects(old.push(), e => e === error); await assert.rejects(next.push(), e => e === error);
  assert.equal(next.requests.length, 1); assert.ok(old.requests[0].body.equals(next.requests[0].body));
  assert.equal(next.trace.at(-1), "handoff"); adapter.stop();
});
for (const variant of ["incomplete", "no-timestamp", "no-token"]) test(`${variant} keeps coherent-source/token skip without a handoff`, async () => {
  const old = harness(baseline, { variant }); const next = harness(candidate, { variant, socket: { offer() { throw new Error("unexpected"); } } });
  assert.equal(JSON.stringify(await old.push()), JSON.stringify(await next.push()));
  assert.equal(next.requests.length, 0); assert.equal(next.observations.length, 0);
});

test("unchanged schedule/token reader and sole v1 serialization; no hot-path connection/contract work", () => {
  assert.equal(candidate.slice(candidate.indexOf("setTimeout(() => {\n  pushOnce()")), baseline.slice(baseline.indexOf("setTimeout(() => {\n  pushOnce()")));
  for (const name of ["readToken", "bookSnapshot"]) {
    const part = source => source.match(new RegExp(`function ${name}\\(\\) \\{[\\s\\S]*?\\n\\}`))[0];
    assert.equal(part(candidate), part(baseline));
  }
  assert.equal((candidate.match(/JSON\.stringify\(snap\)/g) || []).length, 1);
  assert.equal((candidate.match(/await fetch\(/g) || []).length, 1);
  assert.doesNotMatch(candidate, /(?:from|import\()\s*["'][^"']*contracts/);
  assert.match(candidate, /process\.env\.JOE_V2_STAGE_SOCKET\s*\? createStageHandoff/);
  const hot = candidate.slice(candidate.indexOf("async function pushOnce"), candidate.indexOf("\nconnectionSupervisor ="));
  assert.doesNotMatch(hot, /createStageHandoff|\.connect\(|setTimeout|setImmediate|fsync|validateContract|acceptSnapshot/);
});
