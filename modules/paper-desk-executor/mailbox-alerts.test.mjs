import "../../tests/paper-desk-account-fixture.mjs";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { createHash } from "node:crypto";
import fs, { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import { Readable } from "node:stream";
import { setTimeout as delay } from "node:timers/promises";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { createServer, createHealthServer } from "./server.mjs";
import { createServer as createMailbox } from "../agent-mailbox/server.mjs";
import { createAlertDelivery, deliveryHealth, MAX_DELIVERY_ATTEMPTS, postLocalMessage } from "./mailbox-alerts.mjs";
import { openLedger, MAX_STATE_BYTES, CAPTURE_DEGRADED_ADMISSION_BYTES } from "./state.mjs";
import { sendTestAlert } from "./send-test-alert.mjs";
import { mailboxHttpRequest } from "../../tests/local-mailbox-fixture.mjs";
import { MAILBOX_SOCKET_PATH } from "./local-mailbox-client.mjs";
import { createCapture } from "../joe-results-producer/capture.mjs";

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
  const delivery = createAlertDelivery({ socketPath: MAILBOX_SOCKET_PATH, ledger, post, pollMs: 5,
    exclusive(work) { const result = chain.then(work); chain = result.catch(() => {}); return result; }, ...extras });
  t.after(() => delivery.close());
  delivery.start();
  return delivery;
}

test("foreign mailbox paths fail before filesystem access or a transport request", async t => {
  const prior = process.env.PAPER_DESK_MAILBOX_SOCKET;
  t.after(() => {
    if (prior === undefined) delete process.env.PAPER_DESK_MAILBOX_SOCKET;
    else process.env.PAPER_DESK_MAILBOX_SOCKET = prior;
  });
  const calls = [];
  for (const name of ["mkdirSync", "openSync", "lstatSync", "unlinkSync", "chmodSync", "readFileSync", "writeFileSync", "statSync", "realpathSync"]) {
    t.mock.method(fs, name, () => { calls.push(name); throw new Error("unexpected filesystem access"); });
  }
  syncBuiltinESMExports();
  t.after(() => { t.mock.restoreAll(); syncBuiltinESMExports(); });
  for (const socketPath of ["/etc/x.sock", "../x.sock", `${path.dirname(MAILBOX_SOCKET_PATH)}/../x.sock`, path.join(tmpdir(), "joed43-client/x.sock")]) {
    assert.throws(() => createServer({ mailboxSocket: socketPath }), /socket path is invalid/);
    assert.throws(() => createAlertDelivery({ socketPath }), /socket path is invalid/);
    process.env.PAPER_DESK_MAILBOX_SOCKET = socketPath;
    assert.throws(() => createServer({}), /socket path is invalid/);
    await assert.rejects(postLocalMessage(socketPath, "synthetic", undefined, {
      request() { calls.push("request"); throw new Error("unexpected transport request"); },
    }), /mailbox_unavailable/);
  }
  assert.deepEqual(calls, []);
});

test("once-per-class failures and resolutions reach amy, with durable dedupe after restart and a lost reply", async t => {
  t.mock.method(console, "error", () => {});
  const root = temporary(t), mailboxRoot = temporary(t);
  let code = "EIO", loseReply = true;
  const ledger = openLedger(root, { beforePrune() { if (code) throw { code, message: "synthetic-private-value" }; } });
  const state = ledger.load();
  for (let i = 0; i < 20; i++) ledger.save(state);
  code = "ENOSPC";
  for (let i = 0; i < 20; i++) ledger.save(state);
  const app = createMailbox({ stateDir: mailboxRoot, localSocketPath: MAILBOX_SOCKET_PATH, log() {} });
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

// Fail the actual journal append AND publication on the same state volume;
// the independent mailbox volume must remain writable.
function sharedVolumeFailure(t, ledgerPath, journalPath, code, operation) {
  let ledgerFailed = true, journalFailed = true;
  const journalInode = fs.statSync(journalPath).ino, ledgerHandles = new Set();
  const originals = Object.fromEntries(["openSync", "closeSync", "writeSync", "writeFileSync", "renameSync"].map(name => [name, fs[name]]));
  const failure = () => Object.assign(new Error("synthetic-private-value /synthetic/path"), { code });
  t.mock.method(fs, "openSync", (file, ...args) => {
    const fd = originals.openSync(file, ...args);
    if (String(file).startsWith(`${ledgerPath}.`) && String(file).endsWith(".new")) ledgerHandles.add(fd);
    return fd;
  });
  t.mock.method(fs, "closeSync", fd => { ledgerHandles.delete(fd); return originals.closeSync(fd); });
  t.mock.method(fs, "writeSync", (fd, ...args) => {
    if (journalFailed && fs.fstatSync(fd).ino === journalInode) throw failure();
    return originals.writeSync(fd, ...args);
  });
  t.mock.method(fs, "writeFileSync", (fd, ...args) => {
    if (ledgerFailed && operation === "write" && ledgerHandles.has(fd)) throw failure();
    return originals.writeFileSync(fd, ...args);
  });
  t.mock.method(fs, "renameSync", (from, to) => {
    if (ledgerFailed && operation === "rename" && to === ledgerPath) throw failure();
    return originals.renameSync(from, to);
  });
  syncBuiltinESMExports();
  t.after(() => { t.mock.restoreAll(); syncBuiltinESMExports(); });
  return { restoreLedger() { ledgerFailed = false; }, restoreStorage() { ledgerFailed = journalFailed = false; } };
}

// Fail after the ledger is visible, then optionally fail subsequent renames.
// Match only this ledger/directory so the independent mailbox remains real.
function partialLedgerPublication(t, ledger, code, operation, repeat = false) {
  let failing = true, published = false;
  const directories = new Set();
  const originals = Object.fromEntries(["openSync", "closeSync", "fsyncSync", "renameSync", "linkSync", "unlinkSync"].map(name => [name, fs[name]]));
  const failure = () => Object.assign(new Error("synthetic-private-value /synthetic/path"), { code });
  for (const name of ["renameSync", "linkSync"]) t.mock.method(fs, name, (from, to) => {
    if (failing && published && !repeat && to === ledger.statePath) throw failure();
    const result = originals[name](from, to);
    if (to === ledger.statePath) published = true;
    return result;
  });
  t.mock.method(fs, "openSync", (file, flags, ...args) => {
    if (failing && published && operation === "directory-open" && file === ledger.root && (flags & fs.constants.O_DIRECTORY)) throw failure();
    const fd = originals.openSync(file, flags, ...args);
    if ((flags & fs.constants.O_DIRECTORY) && file === ledger.root) directories.add(fd);
    return fd;
  });
  t.mock.method(fs, "fsyncSync", fd => {
    if (failing && published && operation === "directory-fsync" && directories.has(fd)) throw failure();
    return originals.fsyncSync(fd);
  });
  t.mock.method(fs, "closeSync", fd => {
    const directory = directories.delete(fd);
    originals.closeSync(fd);
    if (failing && published && operation === "directory-close" && directory) throw failure();
  });
  t.mock.method(fs, "unlinkSync", file => {
    if (failing && published && operation === "temporary-cleanup" && String(file).startsWith(`${ledger.statePath}.`)) throw failure();
    return originals.unlinkSync(file);
  });
  syncBuiltinESMExports();
  t.after(() => { t.mock.restoreAll(); syncBuiltinESMExports(); });
  return { restore() { failing = false; } };
}

const halfVisibleCases = [
  ...["EIO", "ENOSPC", "EROFS"].flatMap(code => ["restart after send", "restart before send", "lost reply"].map(order => ({ code, order, operation: "directory-fsync" }))),
  ...["directory-open", "directory-close", "temporary-cleanup"].map(operation => ({ code: "EIO", order: "restart after send", operation })),
  { code: "EIO", order: "repeated publications", operation: "directory-fsync", repeat: true },
];
for (const { code, order, operation, repeat } of halfVisibleCases) {
  test(`half-visible ledger ${code} ${operation}, ${order}: one mailbox key and receipt through restart and disk return`, async t => {
    t.mock.method(console, "error", () => {});
    const root = temporary(t), options = { beforePrune() { throw { code }; } };
    const ledger = openLedger(root, options), initial = ledger.load();
    const mailbox = createMailbox({ stateDir: temporary(t), localSocketPath: MAILBOX_SOCKET_PATH, log() {} });
    t.after(() => mailbox.close());
    const storage = partialLedgerPublication(t, ledger, code, operation, repeat);
    assert.throws(() => ledger.save(initial), error => error.code === code);
    const visible = JSON.parse(readFileSync(ledger.statePath)).resultsCaptureAlerts[0];
    const posts = [];
    let loseReply = order === "lost reply";
    const post = async (socket, body, key) => {
      posts.push({ body, key });
      await postLocalMessage(socket, body, key, { request: mailboxHttpRequest(mailbox, {
        loseReply() { const lost = loseReply; loseReply = false; return lost; },
      }) });
    };
    const restarted = openLedger(root, options);
    const ledgers = order === "restart before send" ? [restarted, ledger] : [ledger, restarted];
    for (const [index, current] of ledgers.entries()) {
      const delivery = sender(t, current, post);
      if (order === "lost reply" && index === 0) {
        await until(() => readState(current).resultsCaptureAlerts[0].delivery?.failure?.nextAttemptAt);
      } else {
        await until(() => deliveryHealth(readState(current), true).alertDelivery === "delivered");
      }
      delivery.close();
    }
    // The original process must also adopt the key already sent when storage
    // returns, even if its pending overlay predates the visible publication.
    storage.restore();
    ledger.save(readState(ledger));
    const disk = JSON.parse(readFileSync(ledger.statePath));
    assert.equal(mailbox.mailbox.messages("amy").length, 1);
    assert.equal(disk.resultsCaptureAlerts.length, 1);
    assert.equal(disk.resultsCaptureAlerts[0].outageId, visible.outageId);
    assert.equal(disk.resultsCaptureAlerts[0].at, visible.at);
    const expectedKey = createHash("sha256").update(`${visible.outageId}:failure`).digest("hex");
    assert.ok(posts.length >= 1);
    assert.ok(posts.every(row => row.key === expectedKey));
    assert.ok(posts.every(row => JSON.parse(row.body).since === visible.at && JSON.parse(row.body).at === visible.at));
    assert.ok(posts.every(row => row.body === posts[0].body));
    assert.equal(disk.resultsCaptureAlerts[0].delivery.failure.status, order === "lost reply" ? "pending" : "delivered");
    const finalDelivery = sender(t, ledger, post, { now: () => Date.now() + 20000 });
    await until(() => deliveryHealth(readState(ledger), true).alertDelivery === "delivered");
    finalDelivery.close();
    assert.equal(mailbox.mailbox.messages("amy").length, 1);
    assert.equal(JSON.parse(readFileSync(ledger.statePath)).resultsCaptureAlerts.length, 1);
    assert.doesNotMatch(JSON.stringify(posts), /synthetic-private-value|synthetic\/path/);
  });
}

test("a half-visible initial hard link keeps its receipt identity when initialization and later renames fail", async t => {
  t.mock.method(console, "error", () => {});
  const root = temporary(t), options = { beforePrune() { throw { code: "EIO" }; } };
  const ledger = openLedger(root, options);
  // A startup diagnostic can exist before the initial ledger is linked.
  ledger.noteCaptureFailure({ code: "EIO" });
  const pending = structuredClone(readState(ledger).resultsCaptureAlerts[0]);
  const storage = partialLedgerPublication(t, ledger, "EIO", "directory-fsync");
  assert.throws(() => ledger.load(), { code: "EIO" });
  const visible = JSON.parse(readFileSync(ledger.statePath)).resultsCaptureAlerts[0];
  const mailbox = createMailbox({ stateDir: temporary(t), localSocketPath: MAILBOX_SOCKET_PATH, log() {} });
  t.after(() => mailbox.close());
  const posts = [];
  const post = async (socket, body, key) => {
    posts.push({ body, key });
    await postLocalMessage(socket, body, key, { request: mailboxHttpRequest(mailbox) });
  };
  for (const current of [ledger, openLedger(root, options)]) {
    const delivery = sender(t, current, post);
    await until(() => deliveryHealth(readState(current), true).alertDelivery === "delivered");
    delivery.close();
  }
  storage.restore();
  ledger.save(readState(ledger));
  const disk = JSON.parse(readFileSync(ledger.statePath));
  assert.equal(visible.outageId, pending.outageId);
  assert.equal(mailbox.mailbox.messages("amy").length, 1);
  assert.equal(disk.resultsCaptureAlerts.length, 1);
  assert.equal(disk.resultsCaptureAlerts[0].outageId, visible.outageId);
  assert.deepEqual(posts[1], posts[0]);
});

test("pending diagnostics adopt the unresolved on-disk class identity, timestamp and delivered record", async t => {
  t.mock.method(console, "error", () => {});
  const root = temporary(t), options = { beforePrune() { throw { code: "EIO" }; } };
  const ledger = openLedger(root, options), initial = ledger.load();
  const rename = fs.renameSync;
  let blocked = true;
  t.mock.method(fs, "renameSync", (from, to) => {
    if (blocked && to === ledger.statePath) throw Object.assign(new Error("synthetic failure"), { code: "EIO" });
    return rename(from, to);
  });
  syncBuiltinESMExports();
  t.after(() => { t.mock.restoreAll(); syncBuiltinESMExports(); });
  assert.throws(() => ledger.save(initial), { code: "EIO" });
  // Another process publishes/delivers the class before the old process next
  // loads. Its durable identity and delivery record must outrank the overlay.
  blocked = false;
  const publisher = openLedger(root, options);
  publisher.save(readState(publisher));
  const mailbox = createMailbox({ stateDir: temporary(t), localSocketPath: MAILBOX_SOCKET_PATH, log() {} });
  t.after(() => mailbox.close());
  const posts = [];
  const post = async (socket, body, key) => {
    posts.push({ body, key });
    await postLocalMessage(socket, body, key, { request: mailboxHttpRequest(mailbox) });
  };
  const publishedDelivery = sender(t, publisher, post);
  await until(() => deliveryHealth(readState(publisher), true).alertDelivery === "delivered");
  publishedDelivery.close();
  const authoritative = structuredClone(readState(publisher).resultsCaptureAlerts[0]);
  const oldDelivery = sender(t, ledger, post);
  await until(() => deliveryHealth(readState(ledger), true).alertDelivery === "delivered");
  oldDelivery.close();
  ledger.save(readState(ledger));
  const disk = JSON.parse(readFileSync(ledger.statePath));
  assert.equal(mailbox.mailbox.messages("amy").length, 1);
  assert.equal(posts.length, 1);
  assert.equal(disk.resultsCaptureAlerts.length, 1);
  assert.equal(disk.resultsCaptureAlerts[0].outageId, authoritative.outageId);
  assert.equal(disk.resultsCaptureAlerts[0].at, authoritative.at);
  assert.deepEqual(disk.resultsCaptureAlerts[0].delivery, authoritative.delivery);
});

test("a half-visible claim still fails closed and returns uncertain on replay without a broker call", async t => {
  t.mock.method(console, "error", () => {});
  let executed = 0;
  const app = executor(t, { beforePrune() { throw { code: "EIO" }; },
    execute: async () => { executed++; return { status: "ok" }; } });
  app.ledger.load();
  const storage = partialLedgerPublication(t, app.ledger, "EIO", "directory-fsync");
  const intent = { schema: "barta.paper-desk-intent.v2", intentId: "synthetic-half-visible-claim", desk: "j", action: "recon",
    createdAt: new Date(Date.now() - 1000).toISOString(), expiresAt: new Date(Date.now() + 60000).toISOString() };
  const first = await executorRequest(app, "POST", "/v1/intents", intent);
  assert.equal(first.status, 500);
  assert.equal(first.body.status, "rejected");
  assert.equal(executed, 0);
  const visible = JSON.parse(readFileSync(app.ledger.statePath));
  assert.equal(visible.intents[intent.intentId].status, "claimed");
  const health = await app.readHealth();
  assert.equal(health.status, "degraded");
  assert.equal(health.resultsCapture.persisted, true);
  assert.equal(health.resultsCapture.durability, "uncertain");
  const second = await executorRequest(app, "POST", "/v1/intents", intent);
  assert.equal(second.status, 409);
  assert.equal(second.body.status, "uncertain");
  await app.close().catch(() => {});
  const restarted = executor(t, { stateDir: app.ledger.root, beforePrune() { throw { code: "EIO" }; },
    execute: async () => { executed++; return { status: "ok" }; } });
  const replay = await executorRequest(restarted, "POST", "/v1/intents", intent);
  assert.equal(replay.status, 409);
  assert.equal(replay.body.status, "uncertain");
  assert.equal(executed, 0);
  storage.restore();
  restarted.ledger.save(readState(restarted.ledger));
  const disk = JSON.parse(readFileSync(app.ledger.statePath));
  assert.equal(disk.resultsCaptureAlerts.length, 1);
  assert.equal(disk.resultsCaptureAlerts[0].outageId, visible.resultsCaptureAlerts[0].outageId);
});

for (const code of ["ENOSPC", "EROFS", "EIO"]) for (const operation of ["write", "rename"]) {
  test(`shared-volume ${code} ledger ${operation}: rejects undurable intent, degrades both health routes and dedupes across full-disk restart`, async t => {
    const logs = t.mock.method(console, "error", () => {});
    const root = temporary(t), mailboxRoot = temporary(t), journalPath = path.join(root, "results-input.jsonl");
    const captureOptions = { account: "synthetic-account", attribute: () => ({ desk: "j" }), executionTime: Date.parse,
      now: () => "2026-10-18T10:00:00.000Z" };
    let capture = createCapture(journalPath, { executorClientId: 705 }, captureOptions);
    capture({ executions: [] });
    t.after(() => capture.close());
    const seed = openLedger(root), initial = seed.load();
    initial.executions.push({ contract: { conId: 123, symbol: "ACME", currency: "EUR" }, execution: {
      execId: "synthetic-full-disk.01", acctNumber: "synthetic-account", clientId: 705,
      time: "2026-10-18T09:00:00.000Z", side: "BOT", shares: "1", price: "10" } });
    seed.save(initial);
    const before = readFileSync(seed.statePath), journalBefore = readFileSync(journalPath);
    const mailbox = createMailbox({ stateDir: mailboxRoot, localSocketPath: MAILBOX_SOCKET_PATH, log() {} });
    t.after(() => mailbox.close());
    const posts = [];
    const post = async (socket, body, key) => {
      posts.push({ body, key });
      await postLocalMessage(socket, body, key, { request: mailboxHttpRequest(mailbox) });
    };
    let executed = 0;
    const options = { stateDir: root, beforePrune: state => {
      // The real journal latches a write fault. Reopen to exercise the same
      // storage class on every capture instead of the generic latch error.
      capture.close();
      capture = createCapture(journalPath, { executorClientId: 705 }, captureOptions);
      capture(state);
    }, mailboxSocket: MAILBOX_SOCKET_PATH,
      execute: async () => { executed++; return { status: "ok" }; }, alertDelivery: { pollMs: 5, post } };
    const app = executor(t, options);
    // Warm the healthy sender cache before changing only the in-memory state.
    await delay(25);
    const storage = sharedVolumeFailure(t, seed.statePath, journalPath, code, operation);
    const intent = { schema: "barta.paper-desk-intent.v2", intentId: "synthetic-full-disk-intent", desk: "j", action: "recon",
      createdAt: new Date(Date.now() - 1000).toISOString(), expiresAt: new Date(Date.now() + 60000).toISOString() };
    const response = await executorRequest(app, "POST", "/v1/intents", intent);
    assert.equal(response.status, 500);
    assert.equal(response.body.status, "rejected");
    assert.equal(executed, 0, "no broker call without a durable claim");
    assert.deepEqual(readFileSync(seed.statePath), before);
    assert.equal(readState(app.ledger).intents.has(intent.intentId), false, "pending diagnostics must not retain an undurable claim");
    const health = await executorRequest(app, "GET", "/v1/health");
    assert.equal(health.body.status, "degraded");
    assert.equal(health.body.resultsCapture.persisted, false);
    assert.equal(health.body.resultsCapture.code, code);
    const loopback = createHealthServer(() => app.readHealth());
    const loopbackHealth = await new Promise(resolve => loopback.emit("request", { method: "GET", url: "/v1/health", resume() {} },
      { writeHead(status) { assert.equal(status, 200); }, end(body) { resolve(JSON.parse(body)); } }));
    assert.equal(loopbackHealth.status, "degraded");
    assert.equal(loopbackHealth.resultsCapture.persisted, false);
    await until(() => deliveryHealth(readState(app.ledger), true).alertDelivery === "delivered");
    assert.equal(mailbox.mailbox.messages("amy").length, 1);
    const receipt = structuredClone(readState(app.ledger).resultsCaptureAlerts[0]);
    for (let i = 0; i < 15; i++) assert.throws(() => app.ledger.save(readState(app.ledger)), error => error.code === code);
    assert.equal(readState(app.ledger).resultsCaptureAlerts.length, 1);
    assert.equal(posts.length, 1);
    await app.close().catch(() => {});
    capture.close();
    capture = createCapture(journalPath, { executorClientId: 705 }, captureOptions);
    const restarted = executor(t, options);
    await restarted.initializeCapture();
    await until(() => deliveryHealth(readState(restarted.ledger), true).alertDelivery === "delivered");
    assert.equal(readState(restarted.ledger).resultsCaptureAlerts[0].outageId, receipt.outageId);
    assert.deepEqual(posts[1], posts[0], "restart must reconstruct the same key AND body for mailbox dedupe");
    assert.equal(mailbox.mailbox.messages("amy").length, 1);
    assert.equal((await restarted.readHealth()).resultsCapture.persisted, false);
    storage.restoreLedger();
    // Capture is still unavailable: publish diagnostics and the delivered
    // marker first, without creating a resolution message yet.
    restarted.ledger.save(readState(restarted.ledger));
    const disk = JSON.parse(readFileSync(seed.statePath));
    assert.equal(disk.resultsCaptureAlerts[0].outageId, receipt.outageId);
    assert.equal(disk.resultsCaptureAlerts[0].delivery.failure.status, "delivered");
    assert.equal((await restarted.readHealth()).resultsCapture.persisted, true);
    await delay(25);
    assert.equal(mailbox.mailbox.messages("amy").length, 1);
    assert.deepEqual(readFileSync(journalPath), journalBefore);
    assert.deepEqual(disk.executions, initial.executions);
    assert.equal(Object.hasOwn(disk.intents, intent.intentId), false);
    assert.doesNotMatch(JSON.stringify([health.body.resultsCapture, posts]), /synthetic-private-value|synthetic\/path/);
    // Recovery still requires capture, catch-up AND durable publication.
    storage.restoreStorage();
    restarted.ledger.save(readState(restarted.ledger));
    assert.equal((await restarted.readHealth()).resultsCapture.state, "ok");
    assert.ok(readState(restarted.ledger).resultsCaptureAlerts[0].resolvedAt);
    assert.ok(logs.mock.callCount() >= 1);
  });
}

test("unpersisted delivery keeps one post per class in flight and bounded backoff after a lost reply", async t => {
  t.mock.method(console, "error", () => {});
  const ledger = openLedger(temporary(t), { beforePrune() { throw { code: "ENOSPC" }; } });
  ledger.load();
  const rename = fs.renameSync;
  t.mock.method(fs, "renameSync", (from, to) => {
    if (to === ledger.statePath) throw Object.assign(new Error("synthetic-private-value"), { code: "ENOSPC" });
    return rename(from, to);
  });
  syncBuiltinESMExports();
  t.after(() => { t.mock.restoreAll(); syncBuiltinESMExports(); });
  assert.throws(() => ledger.save(readState(ledger)), error => error.code === "ENOSPC");
  let attempts = 0, epoch = Date.now(), release;
  const blocked = new Promise(resolve => { release = resolve; });
  sender(t, ledger, async () => { attempts++; await blocked; throw new Error("synthetic lost reply"); }, { now: () => epoch });
  await until(() => attempts === 1);
  await delay(35);
  assert.equal(attempts, 1);
  release();
  await until(() => readState(ledger).resultsCaptureAlerts[0].delivery?.failure?.nextAttemptAt > epoch);
  await delay(35);
  assert.equal(attempts, 1);
  for (let i = 2; i <= MAX_DELIVERY_ATTEMPTS; i++) {
    epoch += 20000;
    await until(() => readState(ledger).resultsCaptureAlerts[0].delivery?.failure?.attempts === i);
    await until(() => readState(ledger).resultsCaptureAlerts[0].delivery.failure.nextAttemptAt > epoch);
  }
  assert.equal(deliveryHealth(readState(ledger), true).alertDelivery, "failed");
  epoch += 100000;
  await delay(35);
  assert.equal(attempts, MAX_DELIVERY_ATTEMPTS);
});

test("persisted outage still reaches amy when attempt-marker rename fails, including a lost reply and full-disk restart", async t => {
  t.mock.method(console, "error", () => {});
  const root = temporary(t), mailboxRoot = temporary(t);
  const options = { beforePrune() { throw { code: "ENOSPC" }; } };
  const ledger = openLedger(root, options);
  ledger.save(ledger.load());
  const before = readFileSync(ledger.statePath);
  let failing = true, loseReply = true;
  const rename = fs.renameSync;
  t.mock.method(fs, "renameSync", (from, to) => {
    if (failing && to === ledger.statePath) throw Object.assign(new Error("synthetic-private-value"), { code: "ENOSPC" });
    return rename(from, to);
  });
  syncBuiltinESMExports();
  t.after(() => { t.mock.restoreAll(); syncBuiltinESMExports(); });
  const mailbox = createMailbox({ stateDir: mailboxRoot, localSocketPath: MAILBOX_SOCKET_PATH, log() {} });
  t.after(() => mailbox.close());
  const posts = [];
  const post = async (socket, body, key) => {
    posts.push({ body, key });
    await postLocalMessage(socket, body, key, { request: mailboxHttpRequest(mailbox, {
      loseReply() { const lost = loseReply; loseReply = false; return lost; },
    }) });
  };
  const delivery = sender(t, ledger, post);
  await until(() => readState(ledger).resultsCaptureAlerts[0].delivery?.failure?.nextAttemptAt);
  assert.equal(mailbox.mailbox.messages("amy").length, 1);
  assert.equal(ledger.captureDiagnostics().persisted, false);
  assert.deepEqual(readFileSync(ledger.statePath), before);
  delivery.close();
  const restarted = openLedger(root, options);
  sender(t, restarted, post);
  await until(() => deliveryHealth(readState(restarted), true).alertDelivery === "delivered");
  assert.equal(mailbox.mailbox.messages("amy").length, 1);
  assert.deepEqual(posts[1], posts[0]);
  failing = false;
  restarted.save(readState(restarted));
  assert.equal(JSON.parse(readFileSync(ledger.statePath)).resultsCaptureAlerts[0].delivery.failure.status, "delivered");
  assert.equal(restarted.captureDiagnostics().persisted, true);
});

test("a byte-identical healthy publication after restart gives the next unpersisted outage a fresh delivery key", async t => {
  t.mock.method(console, "error", () => {});
  const root = temporary(t), mailboxRoot = temporary(t);
  let failing = true;
  const options = { beforePrune() { if (failing) throw { code: "ENOSPC" }; } };
  const ledger = openLedger(root, options);
  const state = ledger.load(), before = readFileSync(ledger.statePath);
  const rename = fs.renameSync;
  t.mock.method(fs, "renameSync", (from, to) => {
    if (failing && to === ledger.statePath) throw Object.assign(new Error("synthetic-private-value"), { code: "ENOSPC" });
    return rename(from, to);
  });
  syncBuiltinESMExports();
  t.after(() => { t.mock.restoreAll(); syncBuiltinESMExports(); });
  const mailbox = createMailbox({ stateDir: mailboxRoot, localSocketPath: MAILBOX_SOCKET_PATH, log() {} });
  t.after(() => mailbox.close());
  const posts = [];
  const post = async (socket, body, key) => {
    posts.push({ body, key });
    await postLocalMessage(socket, body, key, { request: mailboxHttpRequest(mailbox) });
  };
  assert.throws(() => ledger.save(state), error => error.code === "ENOSPC");
  const delivery = sender(t, ledger, post);
  await until(() => deliveryHealth(readState(ledger), true).alertDelivery === "delivered");
  delivery.close();
  // Simulate restart after the disk healed: the unsaved diagnostic is gone,
  // and a clean capture may republish exactly the previous ledger bytes.
  failing = false;
  await delay(25);
  const restarted = openLedger(root, options), healthy = readState(restarted);
  restarted.save(healthy);
  assert.deepEqual(readFileSync(ledger.statePath), before);
  failing = true;
  assert.throws(() => restarted.save(healthy), error => error.code === "ENOSPC");
  sender(t, restarted, post);
  await until(() => posts.length === 2);
  assert.notEqual(posts[1].key, posts[0].key, "a new healthy publication must start a fresh outage identity");
  await until(() => deliveryHealth(readState(restarted), true).alertDelivery === "delivered");
  assert.equal(mailbox.mailbox.messages("amy").length, 2);
});

test("OPS re-arms only unresolved failed capture deliveries under the exclusive queue without changing evidence", async t => {
  t.mock.method(console, "error", () => {});
  let captures = 0;
  const app = executor(t, { allowlist: ["127.0.0.1", "100.64.0.23"], adminAllowlist: ["127.0.0.1"],
    beforePrune() { captures++; throw { code: "EIO" }; } });
  const state = app.ledger.load();
  state.executions.push({ evidence: "synthetic-retained-evidence" });
  app.ledger.save(state);
  const id = readState(app.ledger).resultsCaptureAlerts[0].outageId;
  const body = JSON.stringify({ event: "results_capture_failed", code: "EIO" });
  app.ledger.updateCaptureDelivery(id, "failure", () => ({ status: "failed", attempts: 5, body, nextAttemptAt: 9999999999999 }));
  const seeded = JSON.parse(readFileSync(app.ledger.statePath));
  seeded.resultsCaptureAlerts.push({ ...seeded.resultsCaptureAlerts[0], code: "ENOSPC", outageId: "synthetic-resolved-outage", resolvedAt: new Date().toISOString() });
  fs.writeFileSync(app.ledger.statePath, JSON.stringify(seeded));
  const evidence = value => ({ ...value, resultsCaptureAlerts: value.resultsCaptureAlerts.map(({ delivery, ...receipt }) => receipt) });
  assert.equal((await executorRequest(app, "POST", "/v1/admin/capture-alerts/rearm", {}, "100.64.0.23")).status, 403);
  const rename = fs.renameSync;
  let storageFailed = true;
  t.mock.method(fs, "renameSync", (from, to) => {
    if (storageFailed && to === app.ledger.statePath) throw Object.assign(new Error("synthetic-private-value"), { code: "EROFS" });
    return rename(from, to);
  });
  syncBuiltinESMExports();
  t.after(() => { t.mock.restoreAll(); syncBuiltinESMExports(); });
  assert.equal((await executorRequest(app, "POST", "/v1/admin/capture-alerts/rearm", {})).status, 500);
  assert.deepEqual(JSON.parse(readFileSync(app.ledger.statePath)), seeded);
  assert.equal(readState(app.ledger).resultsCaptureAlerts[0].delivery.failure.status, "failed");
  storageFailed = false;
  const response = await executorRequest(app, "POST", "/v1/admin/capture-alerts/rearm", {});
  assert.deepEqual(response, { status: 200, body: { status: "ok", rearmed: 1 } });
  const after = JSON.parse(readFileSync(app.ledger.statePath));
  assert.deepEqual(evidence(after), evidence(seeded));
  assert.deepEqual(after.resultsCaptureAlerts[1], seeded.resultsCaptureAlerts[1]);
  assert.equal(after.resultsCaptureAlerts[0].delivery.failure.attempts, 0);
  assert.equal(after.resultsCaptureAlerts[0].delivery.failure.status, "pending");
  assert.equal(after.resultsCaptureAlerts[0].delivery.failure.body, body);
  assert.equal(after.resultsCaptureAlerts[0].delivery.failure.nextAttemptAt, 0);
  assert.equal(captures, 1, "re-arm must never capture, prune or compact");
  const delivered = [];
  sender(t, app.ledger, async (_socket, payload) => { delivered.push(payload); });
  await until(() => readState(app.ledger).resultsCaptureAlerts[0].delivery.failure.status === "delivered");
  assert.equal(delivered.filter(payload => payload === body).length, 1);
  assert.equal((await executorRequest(app, "POST", "/v1/admin/capture-alerts/rearm", {})).body.rearmed, 0);
});

test("capture delivery re-arm waits for the active intent queue and preserves its newly committed evidence", async t => {
  t.mock.method(console, "error", () => {});
  let entered, release;
  const active = new Promise(resolve => { entered = resolve; });
  const blocked = new Promise(resolve => { release = resolve; });
  const app = executor(t, { adminAllowlist: ["127.0.0.1"], beforePrune() { throw { code: "EIO" }; },
    execute: async (_intent, state) => { entered(); await blocked; state.executions.push({ evidence: "synthetic-newly-committed-evidence" }); return { status: "ok" }; } });
  app.ledger.save(app.ledger.load());
  const id = readState(app.ledger).resultsCaptureAlerts[0].outageId;
  app.ledger.updateCaptureDelivery(id, "failure", () => ({ status: "failed", attempts: 5 }));
  const intent = executorRequest(app, "POST", "/v1/intents", { schema: "barta.paper-desk-intent.v2", intentId: "synthetic-concurrent-rearm",
    desk: "j", action: "recon", createdAt: new Date(Date.now() - 1000).toISOString(), expiresAt: new Date(Date.now() + 60000).toISOString() });
  await active;
  let settled = false;
  const rearm = executorRequest(app, "POST", "/v1/admin/capture-alerts/rearm", {}).then(response => { settled = true; return response; });
  await delay(25);
  assert.equal(settled, false);
  release();
  assert.equal((await intent).status, 200);
  assert.equal((await rearm).body.rearmed, 1);
  const state = readState(app.ledger);
  assert.deepEqual(state.executions, [{ evidence: "synthetic-newly-committed-evidence" }]);
  assert.equal(state.intents.get("synthetic-concurrent-rearm").status, "done");
});

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
  const app = executor(t, { beforePrune() { throw { code: "EIO" }; }, mailboxSocket: MAILBOX_SOCKET_PATH,
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
  const app = executor(t, { stateDir: root, mailboxSocket: MAILBOX_SOCKET_PATH });
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
