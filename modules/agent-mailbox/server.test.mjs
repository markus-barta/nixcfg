import assert from "node:assert/strict";
import { mkdtempSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { Readable } from "node:stream";
import test from "node:test";
import { createServer } from "./server.mjs";
import { BODY_LIMIT, POLICY } from "./security.mjs";
import { HOUR_MS, RETENTION_MS } from "./state.mjs";

// Like the executor, drive the real handler with IncomingMessage-shaped
// streams. Bind/peer configuration is separately checked without host access.
function start(t, options = {}) {
  const logs = [];
  const stateDir = options.stateDir ?? mkdtempSync(path.join(tmpdir(), "ops272-http-"));
  const app = createServer({ ...options, stateDir, log: (line) => logs.push(JSON.parse(line)) });
  t.after(() => app.close());
  async function request(method, url, body, { peer = "100.64.0.10", headers = {}, chunks } = {}) {
    const raw = body === undefined ? "" : typeof body === "string" ? body : JSON.stringify(body);
    const stream = Readable.from(chunks ?? (raw.length ? [Buffer.from(raw)] : []));
    stream.method = method;
    stream.url = url;
    stream.headers = { ...(method === "POST" ? { "content-type": "application/json" } : {}), ...headers };
    stream.socket = { remoteAddress: peer };
    let status; let values; let result;
    await app.handle(stream, { writeHead(code, responseHeaders) { status = code; values = responseHeaders; }, end(payload) { result = JSON.parse(payload); } });
    assert.equal(values["X-Mailbox-Policy"], POLICY);
    assert.equal(values["Content-Type"], "application/json; charset=utf-8");
    assert.equal(values["Cache-Control"], "no-store");
    assert.equal(values["Content-Length"], Buffer.byteLength(JSON.stringify(result)));
    return { status, result };
  }
  return { app, logs, stateDir, request };
}
const valid = { to: "ops", ticket: "OPS-272", body: "hello from Amy" };
const ops = { peer: "100.64.0.14" };

test("bidirectional send/read/health/ack preserve source identity and recipient isolation", async (t) => {
  const ctx = start(t);
  assert.deepEqual((await ctx.request("GET", "/v1/health")).result, { ok: true, identity: "amy", unread: 0 });
  const sent = await ctx.request("POST", "/v1/messages", valid);
  assert.equal(sent.status, 201);
  assert.match(sent.result.id, /^[0-9]{13}-[a-f0-9]{32}$/);
  assert.ok(Number.isFinite(Date.parse(sent.result.createdAt)));
  assert.deepEqual((await ctx.request("GET", "/v1/messages")).result, { messages: [] });
  const received = await ctx.request("GET", "/v1/messages", undefined, ops);
  assert.deepEqual(received.result.messages, [{ ...sent.result, from: "amy", ...valid }]);
  assert.equal((await ctx.request("GET", "/v1/health", undefined, ops)).result.unread, 1);
  assert.equal((await ctx.request("POST", `/v1/messages/${sent.result.id}/ack`)).status, 403);
  assert.equal((await ctx.request("POST", `/v1/messages/${sent.result.id}/ack`, undefined, ops)).status, 200);
  assert.equal((await ctx.request("GET", "/v1/health", undefined, ops)).result.unread, 0);
  assert.equal((await ctx.request("POST", `/v1/messages/${sent.result.id}/ack`, undefined, ops)).status, 404);
  const reply = await ctx.request("POST", "/v1/messages", { to: "amy", body: "reply" }, ops);
  assert.equal(reply.status, 201);
  assert.deepEqual((await ctx.request("GET", "/v1/messages")).result.messages, [{ ...reply.result, from: "ops", to: "amy", ticket: null, body: "reply" }]);
  assert.deepEqual(readdirSync(path.join(ctx.stateDir, "archive", "ops")), [`${sent.result.id}.json`]);
});

test("unknown source is refused before reading any body; headers never confer identity", async (t) => {
  const ctx = start(t);
  const stream = new Readable({ read() { throw new Error("must not read unauthorized body"); } });
  stream.method = "POST"; stream.url = "/v1/messages";
  stream.socket = { remoteAddress: "100.64.0.9" };
  stream.headers = { "x-forwarded-for": "100.64.0.10", "content-type": "application/json" };
  let status; let headers;
  await ctx.app.handle(stream, { writeHead(code, values) { status = code; headers = values; }, end() {} });
  assert.equal(status, 403);
  assert.equal(stream.readableFlowing, null);
  assert.equal(headers["X-Mailbox-Policy"], POLICY);
  for (const peer of ["127.0.0.1", "::1", "100.64.0.20"]) assert.equal((await ctx.request("POST", "/v1/messages", valid, { peer, headers: { "x-forwarded-for": "100.64.0.14" } })).status, 403);
  const sent = await ctx.request("POST", "/v1/messages", valid, { peer: "::ffff:100.64.0.10", headers: { "x-forwarded-for": "100.64.0.14" } });
  assert.equal(sent.status, 201);
  assert.equal((await ctx.request("GET", "/v1/messages", undefined, ops)).result.messages[0].from, "amy");
  const health = await ctx.request("GET", "/v1/health", undefined, { peer: "::ffff:100.64.0.14" });
  assert.equal(health.result.identity, "ops");
});

test("spoofed body identity, caller paths and extra fields are rejected without storing", async (t) => {
  const ctx = start(t);
  for (const key of ["from", "identity", "id", "createdAt", "path", "__proto__", "constructor"]) {
    const value = JSON.parse(JSON.stringify(valid).replace(/}$/, `,"${key}":"ops"}`));
    assert.equal((await ctx.request("POST", "/v1/messages", value)).status, 400);
  }
  for (const to of ["amy", "unknown", "../ops", "constructor"]) assert.equal((await ctx.request("POST", "/v1/messages", { ...valid, to })).status, 400);
  const missing = `${Date.now()}-${"a".repeat(32)}`;
  assert.equal((await ctx.request("POST", `/v1/messages/${missing}/ack`)).status, 404);
  for (const id of ["../../etc/passwd", "%2e%2e%2fetc%2fpasswd", "../health", "bad.json", `${missing}%2f..`]) assert.equal((await ctx.request("POST", `/v1/messages/${id}/ack`)).status, 404);
  assert.equal((await ctx.request("GET", "/v1/messages/../health")).status, 404);
  assert.equal(ctx.app.mailbox.unread("ops"), 0);
});

test("JSON media type, UTF-8, schema and body-size boundaries are enforced", async (t) => {
  const ctx = start(t);
  for (const type of ["text/plain", "", "application/jsonp", "application/json; charset=latin1"]) assert.equal((await ctx.request("POST", "/v1/messages", valid, { headers: { "content-type": type } })).status, 415);
  for (const body of ["{", "null", "[]", "", { ...valid, ticket: "ops-272" }, { ...valid, body: "" }, { ...valid, body: "x\0y" }, { ...valid, body: "x".repeat(16385) }]) assert.equal((await ctx.request("POST", "/v1/messages", body)).status, 400);
  assert.equal((await ctx.request("POST", "/v1/messages", { ...valid, body: "x".repeat(16384) })).status, 201);
  const envelope = JSON.stringify(valid);
  assert.equal((await ctx.request("POST", "/v1/messages", `${envelope}${" ".repeat(BODY_LIMIT - Buffer.byteLength(envelope))}`)).status, 201);
  assert.equal((await ctx.request("POST", "/v1/messages", `${envelope}${" ".repeat(BODY_LIMIT - Buffer.byteLength(envelope) + 1)}`)).status, 413);
  assert.equal((await ctx.request("POST", "/v1/messages", { ...valid, body: "€".repeat(7000) })).status, 413);
  const chunked = await ctx.request("POST", "/v1/messages", undefined, { chunks: [Buffer.alloc(10000), Buffer.alloc(10000), Buffer.alloc(481)] });
  assert.equal(chunked.status, 413);
  const invalidUtf8 = await ctx.request("POST", "/v1/messages", undefined, { chunks: [Buffer.from([0xff])] });
  assert.equal(invalidUtf8.status, 400);
  assert.equal((await ctx.request("POST", "/v1/messages", valid, { headers: { "content-length": String(BODY_LIMIT + 1) } })).status, 413);
  assert.equal((await ctx.request("GET", "/v1/health", "x")).status, 400);
  assert.equal((await ctx.request("POST", "/v1/messages", valid, { headers: { "content-type": "application/json; charset=utf-8" } })).status, 201);
});

test("120 POSTs per sender include failed attempts and acks and survive server restart", async (t) => {
  let clock = Date.now();
  const ctx = start(t, { now: () => clock });
  const sent = await ctx.request("POST", "/v1/messages", valid);
  assert.equal((await ctx.request("POST", `/v1/messages/${sent.result.id}/ack`, {}, ops)).status, 200);
  for (let index = 1; index < 120; index++) assert.equal((await ctx.request("POST", "/v1/messages", { ...valid, to: "unknown" })).status, 400);
  assert.equal((await ctx.request("POST", "/v1/messages", valid)).status, 429);
  assert.equal((await ctx.request("POST", `/v1/messages/${sent.result.id}/ack`)).status, 429);
  assert.equal((await ctx.request("GET", "/v1/health")).status, 200);
  assert.equal((await ctx.request("POST", "/v1/messages", { to: "amy", body: "reply" }, ops)).status, 201);
  await ctx.app.close();
  const restarted = start(t, { now: () => clock, stateDir: ctx.stateDir });
  assert.equal((await restarted.request("POST", "/v1/messages", valid)).status, 429);
  clock += HOUR_MS;
  assert.equal((await restarted.request("POST", "/v1/messages", valid)).status, 201);
});

test("concurrent sends cannot exceed 500 unread, and reads return oldest 50", async (t) => {
  let clock = Date.now();
  const ctx = start(t, { now: () => clock++ });
  const ids = [];
  for (let index = 0; index < 499; index++) ids.push(ctx.app.mailbox.send("amy", valid).id);
  const results = await Promise.all([ctx.request("POST", "/v1/messages", valid), ctx.request("POST", "/v1/messages", valid)]);
  assert.deepEqual(results.map((row) => row.status).sort(), [201, 429]);
  assert.equal((await ctx.request("GET", "/v1/health", undefined, ops)).result.unread, 500);
  assert.deepEqual((await ctx.request("GET", "/v1/messages", undefined, ops)).result.messages.map((row) => row.id), ids.slice(0, 50));
});

test("hourly archive pruning is scheduled and close removes the timer", async (t) => {
  let clock = Date.now();
  t.mock.timers.enable({ apis: ["setInterval"] });
  const ctx = start(t, { now: () => clock });
  const sent = await ctx.request("POST", "/v1/messages", valid);
  await ctx.request("POST", `/v1/messages/${sent.result.id}/ack`, undefined, ops);
  clock += RETENTION_MS + 1;
  t.mock.timers.tick(HOUR_MS);
  assert.deepEqual(readdirSync(path.join(ctx.stateDir, "archive", "ops")), []);
  await ctx.app.close();
  t.mock.timers.tick(HOUR_MS);
});

test("logs contain one safe line per request and no bodies, queries, or arbitrary paths", async (t) => {
  const ctx = start(t);
  const marker = "test-text-never-log-123";
  await ctx.request("POST", "/v1/messages", { ...valid, body: marker });
  await ctx.request("GET", `/v1/health?body=${marker}`);
  await ctx.request("GET", `/bad/${marker}`);
  await ctx.request("POST", "/v1/messages", `{"${marker}":`);
  const corruptId = `${Date.now()}-${"f".repeat(32)}`;
  writeFileSync(path.join(ctx.stateDir, "inbox", "ops", `${corruptId}.json`), marker, { mode: 0o600 });
  const failed = await ctx.request("GET", "/v1/messages", undefined, ops);
  assert.deepEqual(failed, { status: 500, result: { error: "mailbox operation failed" } });
  assert.equal(ctx.logs.length, 5);
  assert.equal(JSON.stringify(ctx.logs).includes(marker), false);
  assert.deepEqual(ctx.logs[0], { method: "POST", path: "/v1/messages", identity: "amy", status: 201 });
  assert.deepEqual(ctx.logs[2], { method: "GET", path: "[unknown]", identity: "amy", status: 404 });
});

test("HTTP parser error responses also carry policy and never log parser content", async (t) => {
  const ctx = start(t);
  let wire;
  const socket = { writable: true, remoteAddress: "100.64.0.10", end(value) { wire = value; } };
  ctx.app.server.emit("clientError", { code: "HPE_INVALID_METHOD", rawPacket: Buffer.from("test-body-do-not-log") }, socket);
  assert.match(wire, /^HTTP\/1.1 400/);
  assert.ok(wire.includes(`X-Mailbox-Policy: ${POLICY}\r\n`));
  assert.equal(JSON.stringify(ctx.logs).includes("test-body-do-not-log"), false);
  ctx.app.server.emit("clientError", { code: "ERR_HTTP_REQUEST_TIMEOUT" }, socket);
  assert.match(wire, /^HTTP\/1.1 408/);
});

test("Expect requests cannot trigger an automatic interim reply or bypass source admission", async (t) => {
  const ctx = start(t);
  for (const [event, peer, expected] of [["checkContinue", "100.64.0.10", 417], ["checkExpectation", "100.64.0.10", 417], ["checkContinue", "100.64.0.9", 403]]) {
    const stream = new Readable({ read() { throw new Error("must not read rejected body"); } });
    stream.method = "POST"; stream.url = "/v1/messages";
    stream.socket = { remoteAddress: peer };
    stream.headers = { expect: "100-continue", "content-type": "application/json" };
    const result = await new Promise((resolve) => {
      let status; let headers;
      ctx.app.server.emit(event, stream, { writeHead(code, values) { status = code; headers = values; }, end() { resolve({ status, headers }); } });
    });
    assert.equal(result.status, expected);
    assert.equal(result.headers["X-Mailbox-Policy"], POLICY);
    assert.equal(stream.readableFlowing, null);
  }
});
