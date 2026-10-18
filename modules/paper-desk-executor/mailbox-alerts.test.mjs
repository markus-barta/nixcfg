import "../../tests/paper-desk-account-fixture.mjs";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { Readable } from "node:stream";
import { setTimeout as delay } from "node:timers/promises";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { createServer } from "./server.mjs";
import { createServer as createMailbox } from "../agent-mailbox/server.mjs";
import { createAlertDelivery, deliveryHealth, MAX_DELIVERY_ATTEMPTS, postLocalMessage } from "./mailbox-alerts.mjs";
import { openLedger, MAX_STATE_BYTES, CAPTURE_DEGRADED_ADMISSION_BYTES } from "./state.mjs";
import { sendTestAlert } from "./send-test-alert.mjs";
import { mailboxHttpRequest } from "../../tests/local-mailbox-fixture.mjs";

function temporary(t) {
  const root = mkdtempSync(path.join(tmpdir(), "joed43-delivery-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
}
async function until(check, timeout = 3000) {
  const deadline = Date.now() + timeout;
  while (!(await check())) {
    if (Date.now() > deadline) assert.fail("background delivery did not settle");
    await delay(5);
  }
}
const readState = ledger => ledger.load({ initialize: false, readOnly: true });
function sender(t, ledger, post, extras = {}) {
  let chain = Promise.resolve();
  const delivery = createAlertDelivery({ socketPath: "/synthetic/mailbox.sock", ledger, post, pollMs: 5,
    exclusive(work) { const result = chain.then(work); chain = result.catch(() => {}); return result; }, ...extras });
  t.after(() => delivery.close());
  delivery.start();
  return delivery;
}

test("once-per-class failures and resolutions reach amy, with durable dedupe after restart and a lost reply", async t => {
  t.mock.method(console, "error", () => {});
  const root = temporary(t), mailboxRoot = temporary(t);
  let code = "EIO", loseReply = true;
  const ledger = openLedger(root, { beforePrune() { if (code) throw { code, message: "synthetic-private-value" }; } });
  const state = ledger.load();
  for (let i = 0; i < 20; i++) ledger.save(state);
  code = "ENOSPC";
  for (let i = 0; i < 20; i++) ledger.save(state);
  const app = createMailbox({ stateDir: mailboxRoot, localSocketPath: "/unused/mailbox.sock", log() {} });
  t.after(() => app.close());
  const post = (socket, body, key) => postLocalMessage(socket, body, key, { request: mailboxHttpRequest(app, {
    loseReply() { const lost = loseReply; loseReply = false; return lost; },
  }) });
  const delivery = sender(t, ledger, post);
  await until(() => deliveryHealth(readState(ledger), true).alertDelivery === "delivered");
  const failures = app.mailbox.messages("amy");
  assert.equal(failures.length, 2);
  assert.deepEqual(failures.map(row => JSON.parse(row.body).code).sort(), ["EIO", "ENOSPC"]);
  for (const row of failures) {
    assert.equal(row.from, "paper-desk-executor");
    assert.equal(row.ticket, "JOED-43");
    const value = JSON.parse(row.body);
    assert.deepEqual(Object.keys(value).sort(), ["at", "code", "event", "ledgerBytes", "ledgerCapBytes", "newAdmissionsBlocked", "since"]);
    assert.equal(value.event, "results_capture_failed");
    assert.equal(value.ledgerCapBytes, MAX_STATE_BYTES);
    assert.equal(row.body.includes("synthetic-private-value"), false);
    assert.equal(row.body.includes(root), false);
  }
  app.mailbox.ack("amy", failures[0].id);
  delivery.close();
  const restarted = openLedger(root, { beforePrune() { if (code) throw { code }; } });
  sender(t, restarted, post);
  await delay(40);
  assert.equal(app.mailbox.unread("amy"), 1);
  code = undefined;
  restarted.save(readState(restarted));
  await until(() => deliveryHealth(readState(restarted), true).alertDelivery === "delivered");
  const messages = app.mailbox.messages("amy");
  assert.equal(messages.filter(row => JSON.parse(row.body).event === "results_capture_resolved").length, 2);
  // New outage of the same class gets its own pair, rather than inheriting a
  // delivered marker from the previous outage.
  code = "EIO";
  restarted.save(readState(restarted));
  await until(() => deliveryHealth(readState(restarted), true).alertDelivery === "delivered");
  assert.equal(app.mailbox.messages("amy").filter(row => JSON.parse(row.body).event === "results_capture_failed").length, 2);
});

test("recovery before the first delivery retains both the outage and its resolution", async t => {
  t.mock.method(console, "error", () => {});
  let failing = true;
  const ledger = openLedger(temporary(t), { beforePrune() { if (failing) throw { code: "EIO" }; } });
  const state = ledger.load();
  ledger.save(state);
  failing = false;
  ledger.save(state);
  const messages = [];
  sender(t, ledger, async (_socket, body) => { messages.push(JSON.parse(body)); });
  await until(() => deliveryHealth(readState(ledger), true).alertDelivery === "delivered");
  assert.deepEqual(messages.map(row => row.event), ["results_capture_failed", "results_capture_resolved"]);
});

test("failed deliveries use persisted bounded retries and backoff, then remain failed on restart", async t => {
  t.mock.method(console, "error", () => {});
  const ledger = openLedger(temporary(t), { beforePrune() { throw { code: "EIO" }; } });
  ledger.save(ledger.load());
  let attempts = 0, epoch = Date.now();
  const post = async () => { attempts++; throw new Error("synthetic-private-value"); };
  const delivery = sender(t, ledger, post, { now: () => epoch });
  await until(() => readState(ledger).resultsCaptureAlerts[0].delivery?.failure?.nextAttemptAt);
  assert.equal(deliveryHealth(readState(ledger), true).alertDelivery, "pending");
  const first = attempts;
  await delay(35);
  assert.equal(attempts, first);
  for (let i = 2; i <= MAX_DELIVERY_ATTEMPTS; i++) {
    epoch += 20000;
    await until(() => readState(ledger).resultsCaptureAlerts[0].delivery?.failure?.attempts === i);
    await until(() => readState(ledger).resultsCaptureAlerts[0].delivery.failure.nextAttemptAt > epoch);
  }
  const health = deliveryHealth(readState(ledger), true);
  assert.equal(health.alertDelivery, "failed");
  assert.equal(health.lastAttemptAt, new Date(epoch).toISOString());
  assert.equal(JSON.stringify(health).includes("synthetic-private-value"), false);
  delivery.close();
  sender(t, ledger, post, { now: () => epoch + 100000 });
  await delay(35);
  assert.equal(attempts, MAX_DELIVERY_ATTEMPTS);
});

async function executorRequest(app, method, url, body, peer = "127.0.0.1") {
  const request = Readable.from(body ? [Buffer.from(JSON.stringify(body))] : []);
  Object.assign(request, { method, url, socket: { remoteAddress: peer }, headers: { "content-type": "application/json" } });
  let status, result;
  await app.handle(request, { writeHead(code) { status = code; }, end(payload) { result = JSON.parse(payload); } });
  return { status, body: result };
}
function executor(t, overrides) {
  const app = createServer({ testMode: true, stateDir: temporary(t), listenHost: "127.0.0.1", listenPort: 0,
    allowlist: ["127.0.0.1"], gatewayReachable: () => true, ...overrides });
  t.after(() => { app.close().catch(() => {}); });
  return app;
}

test("allowed peer health exposes agreed names, cap reason and recovery; disabled mailbox is unconfigured", async t => {
  t.mock.method(console, "error", () => {});
  t.mock.method(console, "warn", () => {});
  let failing = true;
  const app = executor(t, { beforePrune() { if (failing) throw { code: "EIO" }; } });
  let state = app.ledger.load();
  app.ledger.save(state);
  let response = await executorRequest(app, "GET", "/v1/health");
  assert.equal(response.status, 200);
  const capture = response.body.resultsCapture;
  assert.equal(capture.state, "degraded");
  assert.equal(capture.reason, "results_capture_failed");
  assert.equal(capture.ledgerCapBytes, MAX_STATE_BYTES);
  assert.equal(capture.ledgerMaxBytes, MAX_STATE_BYTES);
  assert.equal(capture.alertDelivery, "unconfigured");
  state.padding = "x".repeat(CAPTURE_DEGRADED_ADMISSION_BYTES);
  app.ledger.save(state);
  response = await executorRequest(app, "GET", "/v1/health");
  assert.equal(response.body.resultsCapture.reason, "ledger_size_limit");
  assert.equal(response.body.resultsCapture.newAdmissionsBlocked, true);
  delete state.padding;
  failing = false;
  app.ledger.save(state);
  response = await executorRequest(app, "GET", "/v1/health");
  assert.equal(response.body.resultsCapture.state, "ok");
  assert.equal(Object.hasOwn(response.body.resultsCapture, "reason"), false);
  assert.equal((await executorRequest(app, "GET", "/v1/health", undefined, "192.0.2.1")).status, 403);
});

test("a stalled mailbox never holds an intent, save or health poll; timeout leaves pending health", async t => {
  t.mock.method(console, "error", () => {});
  let destroyed = false, attempted = false;
  const app = executor(t, { beforePrune() { throw { code: "EIO" }; }, mailboxSocket: "/synthetic/mailbox.sock",
    execute: async intent => ({ status: "ok", intentId: intent.intentId }),
    alertDelivery: { pollMs: 5, post: (socket, body, key) => postLocalMessage(socket, body, key, { timeoutMs: 150,
      request() { attempted = true; const request = new EventEmitter(); request.end = () => {}; request.destroy = () => { destroyed = true; }; return request; } }) } });
  app.ledger.save(app.ledger.load());
  await until(() => attempted);
  const now = Date.now();
  const intent = { schema: "barta.paper-desk-intent.v2", intentId: "synthetic-delivery-recon", desk: "j", action: "recon",
    createdAt: new Date(now - 1000).toISOString(), expiresAt: new Date(now + 60000).toISOString() };
  const before = Date.now();
  const response = await executorRequest(app, "POST", "/v1/intents", intent);
  assert.equal(response.status, 200);
  assert.equal(response.body.status, "ok");
  assert.equal(destroyed, false);
  const health = await executorRequest(app, "GET", "/v1/health");
  assert.equal(health.status, 200);
  assert.equal(health.body.resultsCapture.alertDelivery, "pending");
  assert.ok(Date.now() - before < 150);
  await until(() => destroyed);
  assert.equal((await app.readHealth()).resultsCapture.alertDelivery, "pending");
});

test("capture off with mailbox wiring preserves ledger bytes and produces no messages", async t => {
  let attempts = 0;
  const root = temporary(t), ledger = openLedger(root), state = ledger.load();
  ledger.save(state);
  const before = readFileSync(ledger.statePath);
  const delivery = sender(t, ledger, async () => { attempts++; });
  const app = executor(t, { stateDir: root, mailboxSocket: "/synthetic/mailbox.sock" });
  const health = await executorRequest(app, "GET", "/v1/health");
  assert.equal(health.status, 200);
  assert.equal(health.body.resultsCapture, undefined);
  await delay(25);
  assert.deepEqual(readFileSync(ledger.statePath), before);
  assert.equal(attempts, 0);
  delivery.close();
});

test("test sender posts one fixed message without touching executor state and has value-free failure output", async t => {
  const root = temporary(t), ledger = openLedger(root);
  ledger.load();
  const before = readFileSync(ledger.statePath), files = readdirSync(root);
  const calls = [];
  await sendTestAlert("/synthetic/mailbox.sock", async (...args) => calls.push(args));
  assert.deepEqual(calls, [["/synthetic/mailbox.sock", "[TEST] JOED-43 capture alert path check"]]);
  assert.deepEqual(readFileSync(ledger.statePath), before);
  assert.deepEqual(readdirSync(root), files);
  const result = spawnSync(process.execPath, [new URL("./send-test-alert.mjs", import.meta.url).pathname],
    { encoding: "utf8", env: { ...process.env, PAPER_DESK_MAILBOX_SOCKET: path.join(root, "missing.sock") } });
  assert.equal(result.status, 1);
  assert.equal(result.stdout, "");
  assert.equal(result.stderr, "JOED-43 test alert failed\n");
  assert.deepEqual(readFileSync(ledger.statePath), before);
});
