import assert from "node:assert/strict";
import { mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { createServer, LOCAL_SENDER } from "./server.mjs";
import { validIdentity } from "./security.mjs";
import { mailboxRequest } from "../../tests/local-mailbox-fixture.mjs";

function fixture(t, options = {}) {
  const root = mkdtempSync(path.join(tmpdir(), "joed43-mailbox-"));
  const app = createServer({ stateDir: root, localSocketPath: path.join(root, "mailbox.sock"), log() {}, ...options });
  t.after(async () => { await app.close(); rmSync(root, { recursive: true, force: true }); });
  return app;
}
const message = { to: "amy", ticket: "JOED-43", body: "synthetic capture alert" };

test("local socket remains restricted from asynchronous creation until listen resolves", async t => {
  const app = fixture(t);
  const originalMask = process.umask(0o022);
  t.after(() => process.umask(originalMask));
  let createdMode;
  // Emulate Node deferring the bind until after listen() returns. A regular
  // fixture file exercises the same creation umask without opening a socket.
  t.mock.method(app.localServer, "listen", (filename, callback) => {
    setImmediate(() => {
      writeFileSync(filename, "", { mode: 0o777 });
      createdMode = statSync(filename).mode & 0o777;
      callback();
    });
    return app.localServer;
  });
  await app.listenLocal();
  assert.equal(createdMode, 0o660);
  assert.equal(process.umask(), 0o022);
});

test("failed asynchronous local listen restores the process umask", async t => {
  const app = fixture(t);
  const originalMask = process.umask(0o022);
  t.after(() => process.umask(originalMask));
  t.mock.method(app.localServer, "listen", () => {
    setImmediate(() => app.localServer.emit("error", new Error("synthetic listen failure")));
    return app.localServer;
  });
  await assert.rejects(app.listenLocal(), /synthetic listen failure/);
  assert.equal(process.umask(), 0o022);
});

test("local listener constructs safe executor identity and only sends JOED-43 to amy", async t => {
  const app = fixture(t);
  assert.equal(validIdentity(LOCAL_SENDER), true);
  const response = await mailboxRequest(app, { body: message, peer: "192.0.2.1", headers: { "x-forwarded-for": "100.64.0.14" } });
  assert.equal(response.status, 201);
  assert.equal(app.mailbox.messages("amy")[0].from, LOCAL_SENDER);
  for (const to of ["ops", LOCAL_SENDER, "unknown"]) {
    assert.equal((await mailboxRequest(app, { body: { ...message, to } })).status, 403);
  }
  for (const ticket of [undefined, "OPS-272"]) {
    assert.equal((await mailboxRequest(app, { body: { ...message, ticket } })).status, 403);
    assert.equal((await mailboxRequest(app, { body: message, headers: { "x-ticket": ticket } })).status, 403);
  }
  assert.equal(app.mailbox.unread("amy"), 1);
});

test("local health, reads, ack, events, query and other methods are always forbidden", async t => {
  const app = fixture(t);
  for (const [method, url] of [["GET", "/v1/health"], ["GET", "/v1/messages"], ["GET", "/v1/messages?wait=60"],
    ["GET", "/v1/events"], ["POST", `/v1/messages/${"0".repeat(13)}-${"a".repeat(32)}/ack`],
    ["POST", "/v1/messages?to=amy"], ["PUT", "/v1/messages"], ["DELETE", "/v1/messages"]]) {
    assert.equal((await mailboxRequest(app, { method, url, body: message })).status, 403, `${method} ${url}`);
  }
});

test("TCP identity remains source-derived and cannot claim or address the local sender", async t => {
  const app = fixture(t, { peers: { "100.64.0.14": "ops", "100.64.0.23": "amy", "100.64.0.24": LOCAL_SENDER } });
  const sent = await mailboxRequest(app, { local: false, body: message, headers: { "x-sender": LOCAL_SENDER } });
  assert.equal(sent.status, 201);
  assert.equal(app.mailbox.messages("amy")[0].from, "ops");
  assert.equal((await mailboxRequest(app, { local: false, peer: "100.64.0.24", body: message })).status, 403);
  assert.equal((await mailboxRequest(app, { local: false, peer: "192.0.2.1", body: message })).status, 403);
  assert.equal((await mailboxRequest(app, { local: false, body: { ...message, to: LOCAL_SENDER } })).status, 400);
  assert.equal((await mailboxRequest(app, { local: false, peer: "100.64.0.23", method: "GET", url: "/v1/messages" })).body.messages.length, 1);
});

test("local sender retains UTF-8, control, bidi, field and body-size checks", async t => {
  const app = fixture(t);
  for (const body of ["\u0000", "\r", "\u202e", "\ud800", "x".repeat(16385)]) {
    assert.equal((await mailboxRequest(app, { body: { ...message, body } })).status, 400);
  }
  assert.equal((await mailboxRequest(app, { body: { ...message, from: "ops" } })).status, 400);
  assert.equal((await mailboxRequest(app, { chunks: [Buffer.from('{"to":"amy","ticket":"JOED-43","body":"'), Buffer.from([0xff]), Buffer.from('"}')] })).status, 400);
  assert.equal(app.mailbox.unread("amy"), 0);
});

test("local idempotency survives lost replies, acknowledgement and mailbox restart", async t => {
  const app = fixture(t);
  const headers = { "idempotency-key": "a".repeat(64) };
  const first = await mailboxRequest(app, { body: message, headers });
  assert.equal(first.status, 201);
  assert.deepEqual((await mailboxRequest(app, { body: message, headers })).body, first.body);
  app.mailbox.ack("amy", first.body.id);
  const reopened = createServer({ stateDir: app.mailbox.root, localSocketPath: "/unused/local.sock", log() {} });
  t.after(() => reopened.close());
  assert.deepEqual((await mailboxRequest(reopened, { body: message, headers })).body, first.body);
  assert.equal(reopened.mailbox.unread("amy"), 0);
  assert.equal((await mailboxRequest(reopened, { body: { ...message, body: "changed" }, headers })).status, 400);
});
