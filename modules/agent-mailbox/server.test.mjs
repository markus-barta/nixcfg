import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtempSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { Readable } from "node:stream";
import test from "node:test";
import { createServer, HEARTBEAT_MS, STREAM_LIFETIME_MS, STREAM_LIMIT } from "./server.mjs";
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

for (const [label, points] of [
  ["C0 except tab/newline", Array.from({ length: 32 }, (_, i) => i).filter((i) => ![9, 10, 13].includes(i))],
  ["carriage return", [13]],
  ["DEL", [127]],
  ["C1", Array.from({ length: 32 }, (_, i) => 128 + i)],
  ["bidi overrides/embeddings", Array.from({ length: 5 }, (_, i) => 0x202a + i)],
  ["bidi isolates", Array.from({ length: 4 }, (_, i) => 0x2066 + i)],
  ["bidi marks and invisible characters", [0x061c, 0x200b, 0x200e, 0x200f, 0x2060, 0x2061, 0x2062, 0x2063, 0x2064, 0xfeff]],
  ["Unicode tags E0000–E003F", Array.from({ length: 64 }, (_, i) => 0xe0000 + i)],
  ["Unicode tags E0040–E007F", Array.from({ length: 64 }, (_, i) => 0xe0040 + i)],
]) {
  test(`send rejects every ${label} character without storing`, async (t) => {
    const { app, request } = start(t);
    for (const point of points) {
      const response = await request("POST", "/v1/messages", { ...valid, body: `before${String.fromCodePoint(point)}after` });
      assert.deepEqual(response, { status: 400, result: { error: "body contains control characters" } }, `U+${point.toString(16)}`);
    }
    assert.equal(app.mailbox.unread("ops"), 0);
  });
}

test("send rejects malformed UTF-8 inside JSON and escaped lone surrogates", async (t) => {
  const { app, request } = start(t);
  const prefix = Buffer.from('{"to":"ops","body":"');
  const suffix = Buffer.from('"}');
  for (const bytes of [[0xff], [0x80], [0xc0, 0xaf], [0xc2], [0xe2, 0x82], [0xe2, 0x28, 0xa1], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80]]) {
    assert.deepEqual(await request("POST", "/v1/messages", undefined, { chunks: [prefix, Buffer.from(bytes), suffix] }),
      { status: 400, result: { error: "body must be valid UTF-8" } });
  }
  for (const body of ["\ud800", "\udfff", "\ud800x", "x\udfff"]) {
    assert.deepEqual(await request("POST", "/v1/messages", { ...valid, body }),
      { status: 400, result: { error: "body must be valid UTF-8" } });
  }
  assert.equal(app.mailbox.unread("ops"), 0);
});

test("multiline German/English with tabs, umlauts and emoji survives split UTF-8 chunks exactly", async (t) => {
  const { request } = start(t);
  const body = "Grüße aus Österreich: äöü ÄÖÜ ß\nHello Amy!\t😀 🚀 👩‍💻\n\n";
  const raw = Buffer.from(JSON.stringify({ ...valid, body }));
  const sent = await request("POST", "/v1/messages", undefined, { chunks: Array.from(raw, (byte) => Buffer.from([byte])) });
  assert.equal(sent.status, 201);
  assert.equal((await request("GET", "/v1/messages", undefined, ops)).result.messages[0].body, body);
});

async function connect(app, url = "/v1/events", peer = ops.peer, headers = {}, options = {}) {
  const request = Readable.from([]);
  Object.assign(request, { method: "GET", url, headers, socket: { remoteAddress: peer } });
  const response = new EventEmitter();
  Object.assign(response, {
    chunks: [], ended: false,
    writeHead(status, values) { this.status = status; this.headers = values; },
    write(chunk) { this.chunks.push(chunk); return options.writable !== false; },
    end(chunk) { if (chunk) this.chunks.push(chunk); this.ended = true; },
    destroy() { this.destroyed = true; this.emit("close"); },
  });
  response.events = () => response.chunks.join("").split("\n\n").filter((frame) => frame.startsWith("id:")).map((frame) => JSON.parse(frame.split("\ndata: ")[1]));
  await app.handle(request, response);
  return response;
}

test("SSE replays all unread then emits live, isolates identity and never acknowledges", async (t) => {
  const { app, request } = start(t);
  const ids = Array.from({ length: 55 }, () => app.mailbox.send("amy", valid).id);
  const stream = await connect(app);
  assert.equal(stream.status, 200);
  assert.equal(stream.headers["Content-Type"], "text/event-stream; charset=utf-8");
  assert.equal(stream.headers["X-Mailbox-Policy"], POLICY);
  assert.equal(stream.headers["Cache-Control"], "no-store");
  assert.deepEqual(new Set(stream.events().map((row) => row.id)), new Set(ids));
  const live = await request("POST", "/v1/messages", { ...valid, body: "live\nbody ☃" });
  assert.equal(stream.events().at(-1).id, live.result.id);
  assert.equal(stream.events().at(-1).body, "live\nbody ☃");
  app.mailbox.send("ops", { to: "amy", body: "private", ticket: null });
  assert.equal(stream.events().length, 56);
  assert.equal(app.mailbox.unread("ops"), 56);
  assert.equal((await connect(app, "/v1/events", "100.64.0.9", { "x-forwarded-for": ops.peer })).status, 403);
  const amyStream = await connect(app, "/v1/events", "100.64.0.10");
  assert.deepEqual(amyStream.events().map((row) => row.body), ["private"]);
});

test("legacy stored CR/ESC/C1/bidi/invisible rows can be read, streamed and acknowledged", async (t) => {
  const { app, request, stateDir } = start(t);
  const sent = app.mailbox.send("amy", valid);
  const body = "line1\r\nline2\x1b[31m\u0085\u061c\u202e\u200b\u{e0061}";
  const stored = { ...sent, ...valid, from: "amy", body };
  writeFileSync(path.join(stateDir, "inbox", "ops", `${sent.id}.json`), JSON.stringify(stored));
  assert.deepEqual((await request("GET", "/v1/messages", undefined, ops)).result.messages, [stored]);
  assert.deepEqual((await connect(app)).events(), [stored]);
  assert.equal((await request("POST", `/v1/messages/${sent.id}/ack`, undefined, ops)).status, 200);
  assert.equal(app.mailbox.unread("ops"), 0);
  assert.deepEqual(readdirSync(path.join(stateDir, "archive", "ops")), [`${sent.id}.json`]);
});

test("fifth SSE connection evicts and destroys the oldest before reading replay", async (t) => {
  const { app } = start(t);
  const streams = [];
  for (let i = 0; i < STREAM_LIMIT; i++) streams.push(await connect(app));
  const read = app.mailbox.messages;
  t.mock.method(app.mailbox, "messages", (...args) => {
    assert.equal(streams[0].ended, true);
    assert.equal(streams[0].destroyed, true);
    return read(...args);
  });
  const fifth = await connect(app);
  assert.equal(fifth.status, 200);
  assert.ok(streams.slice(1).every((stream) => !stream.ended));
  app.mailbox.send("amy", valid);
  assert.equal(streams[0].events().length, 0);
  assert.equal(fifth.events().length, 1);
});

test("rejected long-poll at capacity does not read the inbox", async (t) => {
  const { app } = start(t);
  for (let i = 0; i < STREAM_LIMIT; i++) await connect(app, "/v1/messages?wait=60");
  t.mock.method(app.mailbox, "messages", () => { throw new Error("rejected request read inbox"); });
  assert.equal((await connect(app, "/v1/messages?wait=60")).status, 429);
});

test("shutdown completes a pending long-poll with an empty JSON message list", async (t) => {
  const { app } = start(t);
  const poll = await connect(app, "/v1/messages?wait=60");
  await app.close();
  assert.equal(poll.status, 200);
  assert.equal(poll.ended, true);
  assert.deepEqual(JSON.parse(poll.chunks.join("")), { messages: [] });
});

test("reconnect cursors cannot lose same-time, older-clock or unacked messages", async (t) => {
  let clock = Date.now();
  const { app } = start(t, { now: () => clock });
  const first = app.mailbox.send("amy", valid);
  const stream = await connect(app);
  stream.emit("close");
  const sameTime = app.mailbox.send("amy", valid);
  clock -= 1000;
  const older = app.mailbox.send("amy", valid);
  for (const [url, headers] of [["/v1/events", { "last-event-id": first.id }], [`/v1/events?since=${first.id}`, {}]]) {
    const reconnect = await connect(app, url, ops.peer, headers);
    assert.deepEqual(new Set(reconnect.events().map((row) => row.id)), new Set([first.id, sameTime.id, older.id]));
    reconnect.emit("close");
  }
  app.mailbox.ack("ops", first.id);
  const reconnect = await connect(app, "/v1/events", ops.peer, { "last-event-id": first.id });
  assert.deepEqual(new Set(reconnect.events().map((row) => row.id)), new Set([sameTime.id, older.id]));
  assert.equal((await connect(app, "/v1/events?since=invalid")).status, 400);
});

test("heartbeat, stream lifetime, backpressure and per-identity limits release slots", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "setInterval"] });
  const { app } = start(t);
  const streams = [];
  for (let i = 0; i < STREAM_LIMIT; i++) streams.push(await connect(app));
  assert.equal((await connect(app)).status, 200);
  assert.equal(streams[0].ended, true);
  assert.equal(streams[0].destroyed, true);
  const amyStream = await connect(app, "/v1/events", "100.64.0.10");
  assert.equal(amyStream.status, 200);
  t.mock.timers.tick(HEARTBEAT_MS);
  assert.equal(streams[1].chunks.join(""), ": heartbeat\n\n");
  streams[1].emit("close");
  const blocked = await connect(app, "/v1/events", ops.peer, {}, { writable: false });
  t.mock.timers.tick(HEARTBEAT_MS);
  assert.equal(blocked.destroyed, undefined);
  t.mock.timers.tick(HEARTBEAT_MS);
  assert.equal(blocked.destroyed, true);
  assert.equal((await connect(app)).status, 200);
  t.mock.timers.tick(STREAM_LIFETIME_MS);
  assert.ok(streams.every((stream) => stream.ended));
  assert.equal(amyStream.ended, true);
  assert.equal((await connect(app)).status, 200);
  await app.close();
  t.mock.timers.tick(HEARTBEAT_MS);
});

test("SSE pauses on backpressure and resumes replay then live without dropping accepted chunks", async (t) => {
  const { app } = start(t);
  const first = app.mailbox.send("amy", valid);
  const second = app.mailbox.send("amy", valid);
  const options = { writable: false };
  const stream = await connect(app, "/v1/events", ops.peer, {}, options);
  assert.equal(stream.events().length, 1);
  const live = app.mailbox.send("amy", valid);
  assert.equal(stream.events().length, 1);
  options.writable = true;
  stream.emit("drain");
  assert.deepEqual(new Set(stream.events().map((row) => row.id)), new Set([first.id, second.id, live.id]));
  assert.equal(stream.events().at(-1).id, live.id);
  assert.equal(stream.destroyed, undefined);
});

test("long-poll wakes only for its identity and returns empty at timeout", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { app } = start(t);
  const poll = await connect(app, "/v1/messages?wait=60");
  assert.equal(poll.ended, false);
  app.mailbox.send("ops", { to: "amy", ticket: null, body: "other identity" });
  assert.equal(poll.ended, false);
  t.mock.timers.tick(1000);
  const sent = app.mailbox.send("amy", valid);
  assert.equal(poll.ended, true);
  assert.equal(JSON.parse(poll.chunks.join("")).messages[0].id, sent.id);
  const immediate = await connect(app, "/v1/messages?wait=60");
  assert.equal(immediate.ended, true);
  assert.equal(JSON.parse(immediate.chunks.join("")).messages[0].id, sent.id);
  app.mailbox.ack("ops", sent.id);
  const timeout = await connect(app, "/v1/messages?wait=2");
  t.mock.timers.tick(1999);
  assert.equal(timeout.ended, false);
  t.mock.timers.tick(1);
  assert.deepEqual(JSON.parse(timeout.chunks.join("")), { messages: [] });
  for (const wait of ["61", "-1", "1.5", "NaN", ""]) assert.equal((await connect(app, `/v1/messages?wait=${wait}`)).status, 400);
  assert.equal((await connect(app, "/v1/messages?wait=0")).ended, true);
  const polls = [];
  for (let i = 0; i < STREAM_LIMIT; i++) polls.push(await connect(app, "/v1/messages?wait=60"));
  assert.equal((await connect(app, "/v1/messages?wait=60")).status, 429);
  polls[0].emit("close");
  assert.equal((await connect(app, "/v1/events")).status, 200);
});

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
