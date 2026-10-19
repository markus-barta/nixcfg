import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { execFileSync, spawnSync } from "node:child_process";
import { EventEmitter } from "node:events";
import test, { before, after } from "node:test";
import { createStageHandoff } from "./v2-stage-handoff.mjs";
import { runPusher } from "./fixtures/pusher-harness.mjs";

const file = "hosts/hsb0/docker/joe-board-pusher/pusher.mjs";
const candidate = fs.readFileSync(new URL("./pusher.mjs", import.meta.url), "utf8");
const main = "276814526032980d24114fd5e70e9b95e0b42efe";
const baseline = execFileSync("git", ["show", `${main}:${file}`], { encoding: "utf8" });
const candidateURL = new URL("./pusher.mjs", import.meta.url);
let baselineURL, baselineRoot;
before(() => {
  baselineRoot = fs.mkdtempSync(path.join(os.tmpdir(), "ops392-main-pusher-"));
  const tree = "hosts/hsb0/docker/joe-board-pusher";
  const names = execFileSync("git", ["ls-tree", "--full-tree", "--name-only", `${main}:${tree}`], { encoding: "utf8" }).trim().split("\n");
  for (const name of names.filter(name => /^[a-z-]+\.mjs$/.test(name))) {
    fs.writeFileSync(path.join(baselineRoot, name), execFileSync("git", ["show", `${main}:${tree}/${name}`]));
  }
  baselineURL = pathToFileURL(path.join(baselineRoot, "pusher.mjs"));
});
after(() => { if (baselineRoot) spawnSync("trash", [baselineRoot]); });
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
  const adapter = createStageHandoff({ socketPath: "/run/joe-household-v2/stage.sock", makeSocket: () => { const socket = new Socket(); sockets.push(socket); return socket; }, defer: fn => { deferred.push(fn); return {}; } });
  return { adapter, sockets, deferred };
}

test("unrecognized socket setting cannot select a network destination", () => {
  let created = false;
  const adapter = createStageHandoff({ socketPath: "unexpected", makeSocket() { created = true; } });
  assert.equal(adapter.offer(instant), false); assert.equal(created, false); adapter.stop();
});

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
  assert.doesNotThrow(() => createStageHandoff({ socketPath: "/run/joe-household-v2/stage.sock", makeSocket: () => { throw new Error("synthetic"); } }));
});

for (const variant of ["normal", "retained", "outage"]) for (const stageState of ["idle", "busy", "hang", "nonzero-exit", "OOM", "backpressure", "throw", "slow-fsync", "ENOSPC", "restart", "corrupt-state"]) {
  test(`original/candidate v1 bytes, one POST and result: ${variant}/${stageState}`, async () => {
    const old = await runPusher(baselineURL, { variant }); const next = await runPusher(candidateURL, { variant, stageState });
    assert.deepEqual(next.result, old.result);
    assert.deepEqual(next.errors, old.errors);
    assert.deepEqual(next.schedule, old.schedule);
    assert.equal(old.requests.length, 1); assert.equal(next.requests.length, 1);
    assert.ok(old.requests[0].body.equals(next.requests[0].body));
    assert.equal(JSON.stringify({ ...next.requests[0], body: undefined }), JSON.stringify({ ...old.requests[0], body: undefined }));
    assert.deepEqual(next.observations, [instant]);
    assert.deepEqual(next.trace, ["fetch", "response-settled", "handoff"]);
    assert.equal(old.inputsUnchanged && next.inputsUnchanged, true);
    assert.deepEqual(next.counts, { reads: 1, observes: 1 });
  });
}
for (const failureAt of ["fetch", "body"]) test(`v1 ${failureAt} rejection retains original identity and still offers only after settlement`, async () => {
  const error = Object.freeze({ synthetic: "rejection" });
  const args = { [failureAt === "fetch" ? "fetchError" : "bodyError"]: error };
  const old = await runPusher(baselineURL, args); const next = await runPusher(candidateURL, { ...args, stageState: "throw" });
  assert.equal(old.errorIdentityPreserved, true); assert.equal(next.errorIdentityPreserved, true);
  assert.equal(next.requests.length, 1); assert.ok(old.requests[0].body.equals(next.requests[0].body));
  assert.equal(next.trace.at(-1), "handoff");
});
for (const variant of ["incomplete", "no-timestamp", "no-token"]) test(`${variant} keeps coherent-source/token skip without a handoff`, async () => {
  const old = await runPusher(baselineURL, { variant }); const next = await runPusher(candidateURL, { variant, stageState: "idle" });
  assert.deepEqual(next.result, old.result); assert.deepEqual(next.errors, old.errors);
  assert.equal(next.requests.length, 0); assert.equal(next.observations.length, 0);
});

test("unchanged schedule/token reader and sole v1 serialization; no hot-path connection/contract work", () => {
  const schedule = source => source.slice(source.indexOf("setTimeout(() => {\n  push"));
  assert.equal(schedule(candidate).replaceAll("pushWithStage()", "pushOnce()"), schedule(baseline));
  const fetchBlock = source => source.slice(source.indexOf("  const res = await fetch(INBOX_URL, {"), source.indexOf("\n}\n", source.indexOf("  const res = await fetch(INBOX_URL, {")));
  assert.equal(fetchBlock(candidate), fetchBlock(baseline));
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
