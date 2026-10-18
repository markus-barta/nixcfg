import "../../tests/paper-desk-account-fixture.mjs";
import assert from "node:assert/strict";
import fs, { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { EventEmitter } from "node:events";
import { tmpdir } from "node:os";
import path from "node:path";
import { Readable } from "node:stream";
import { setImmediate } from "node:timers/promises";
import test from "node:test";
import { createServer as createMailbox } from "../agent-mailbox/server.mjs";
import { createServer as createExecutor, createHealthServer } from "./server.mjs";
import { mailboxHttpRequest } from "../../tests/local-mailbox-fixture.mjs";
import { createAlertDelivery, deliveryHealth, postLocalMessage } from "./mailbox-alerts.mjs";
import { MAILBOX_SOCKET_PATH } from "./local-mailbox-client.mjs";
import { admitIntent, CAPTURE_DEGRADED_ADMISSION_BYTES, openLedger } from "./state.mjs";
import { ACCOUNT, digest, newYorkDay, parseIntent } from "./policy.mjs";
import { attributionConfig, reconcileAttribution } from "./attribution.mjs";
import { executeIntent } from "./executor.mjs";
import { openSession, readPusherExecutions } from "./ib.mjs";
import { createCapture } from "../joe-results-producer/capture.mjs";
import { hash, readJournal } from "../joe-results-producer/journal.mjs";

function temporary(t) {
  const root = mkdtempSync(path.join(tmpdir(), "joed43-publication-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
}
const readState = ledger => ledger.load({ initialize: false, readOnly: true, migrate: false });
const diagnostics = state => ({ resultsCapture: state.resultsCapture, resultsCaptureAlerts: state.resultsCaptureAlerts });

// Paths are constructed from this test's mkdtemp, never from ledger output.
function storageFaults(t, root, pre, post, target = "ledger.json", { when = () => true, once = false } = {}) {
  const statePath = path.join(root, target), directories = new Set(), files = new Map(), ledgerBodies = [];
  const originals = Object.fromEntries(["openSync", "closeSync", "writeFileSync", "fsyncSync", "renameSync", "linkSync", "unlinkSync"].map(name => [name, fs[name]]));
  let enabled = true, published = false, publications = 0, preErrors = 0, postErrors = 0, conflicts = 0;
  let faultBody, error, faultLedgerPublications;
  const failure = () => {
    const ledgerPath = path.join(root, "ledger.json");
    if (fs.existsSync(ledgerPath)) faultBody = readFileSync(ledgerPath, "utf8");
    faultLedgerPublications = ledgerBodies.length;
    return error = Object.assign(new Error("synthetic-private-value /synthetic/path"), { code: "EIO" });
  };
  const armed = () => enabled && when() && (!once || preErrors + postErrors === 0);
  for (const name of ["renameSync", "linkSync"]) t.mock.method(fs, name, (from, to) => {
    if (to === statePath && pre === name && armed()) { preErrors++; throw failure(); }
    let result;
    try { result = originals[name](from, to); }
    catch (error) { if (to === statePath && error.code === "EEXIST") conflicts++; throw error; }
    published = to === statePath;
    if (published) publications++;
    if (to === path.join(root, "ledger.json")) ledgerBodies.push(readFileSync(to, "utf8"));
    return result;
  });
  t.mock.method(fs, "openSync", (file, flags, ...args) => {
    if (published && file === root && post === "directory-open" && armed()) { postErrors++; throw failure(); }
    const fd = originals.openSync(file, flags, ...args);
    files.set(fd, String(file));
    if (published && file === root && (flags & fs.constants.O_DIRECTORY)) directories.add(fd);
    return fd;
  });
  t.mock.method(fs, "closeSync", fd => {
    files.delete(fd);
    const directory = directories.delete(fd);
    const result = originals.closeSync(fd);
    if (directory) published = false;
    if (directory && post === "directory-close" && armed()) { postErrors++; throw failure(); }
    return result;
  });
  t.mock.method(fs, "writeFileSync", (fd, ...args) => {
    const file = files.get(fd);
    const targetedTemporary = file?.startsWith(`${statePath}.`) && /^[0-9a-f-]{36}\.new$/.test(file.slice(statePath.length + 1));
    if (targetedTemporary && pre === "writeFileSync" && armed()) { preErrors++; throw failure(); }
    return originals.writeFileSync(fd, ...args);
  });
  t.mock.method(fs, "fsyncSync", fd => {
    if (published && post === "directory-fsync" && directories.has(fd) && armed()) { postErrors++; throw failure(); }
    return originals.fsyncSync(fd);
  });
  t.mock.method(fs, "unlinkSync", file => {
    if (published && post === "temporary-cleanup" && String(file).startsWith(`${statePath}.`) && armed()) { postErrors++; throw failure(); }
    return originals.unlinkSync(file);
  });
  syncBuiltinESMExports();
  t.after(() => { t.mock.restoreAll(); syncBuiltinESMExports(); });
  return { restore() { enabled = false; }, ledgerBodies, get faultBody() { return faultBody; }, get error() { return error; },
    get faultLedgerPublications() { return faultLedgerPublications; },
    get counts() { return { publications, preErrors, postErrors, conflicts }; } };
}

function addRecons(state, { atCap = false } = {}) {
  const at = new Date().toISOString();
  for (const intentId of ["recon-current", "recon-legacy"]) state.intents.set(intentId, {
    action: "recon", desk: "j", status: "done", claimedAt: at, finishedAt: at,
    result: { status: "ok", action: "recon", intentId, desk: "j", observedAt: at,
      positions: [{ symbol: "AAPL", position: 1 }], openOrders: [], executions: [],
      ...(atCap ? { marks: { AAPL: "x".repeat(Math.floor(CAPTURE_DEGRADED_ADMISSION_BYTES / 2)) } } : {}),
    },
  });
}

function assertReceipts(state) {
  for (const id of ["recon-current", "recon-legacy"]) assert.equal(state.intents.get(id)?.result.resultCompacted, true, `${id} must actually be compacted`);
}

// Drive the real sender with synthetic polling/backoff; no wall-clock sleeps.
function deliveryClock(t, mailbox, { loseReply = () => false, expected = "delivered", onPost = () => {} } = {}) {
  let poll, epoch = Date.now();
  t.mock.method(globalThis, "setInterval", callback => { poll = callback; return { unref() {} }; });
  t.mock.method(globalThis, "clearInterval", () => {});
  return async ledger => {
    const delivery = createAlertDelivery({ ledger, socketPath: MAILBOX_SOCKET_PATH, now: () => epoch,
      exclusive: async work => work(),
      post: (socket, body, key) => { onPost(); return postLocalMessage(socket, body, key, { request: mailboxHttpRequest(mailbox, { loseReply }) }); },
    });
    delivery.start();
    try {
      for (let turn = 0; turn < 12; turn++) {
        await setImmediate();
        epoch += 20000;
        poll();
      }
      await setImmediate();
      assert.equal(deliveryHealth(readState(ledger), true).alertDelivery, expected);
    } finally { delivery.close(); }
  };
}

const phases = ["failure", "recovery", "delivery-persist", "re-arm", "startup"];
const posts = ["directory-fsync", "directory-open", "directory-close", "temporary-cleanup"];
const restarts = ["no", "while-failing", "after-healthy"];

function publicationApp(t, options = {}) {
  t.mock.method(console, "error", () => {});
  const app = createExecutor({ testMode: true, stateDir: temporary(t), listenHost: "127.0.0.1", listenPort: 0,
    allowlist: ["127.0.0.1"], adminAllowlist: ["127.0.0.1"], gatewayReachable: () => true, mailboxSocket: "", ...options });
  t.after(() => app.close().catch(() => {}));
  app.ledger.load();
  return app;
}

async function request(app, method, url, body) {
  const req = Readable.from(body ? [Buffer.from(JSON.stringify(body))] : []);
  Object.assign(req, { method, url, socket: { remoteAddress: "127.0.0.1" } });
  let status, result;
  await app.handle(req, { writeHead(code) { status = code; }, end(payload) { result = JSON.parse(payload); } });
  return { status, body: result };
}

function runnerIntent(action) {
  return { schema: "barta.paper-desk-intent.v2", intentId: `j-publication-${action}`, desk: "j", action,
    createdAt: new Date(Date.now() - 1000).toISOString(), expiresAt: new Date(Date.now() + 300000).toISOString(),
    ...(action === "place" ? { order: { symbol: "AAPL", side: "BUY", quantity: 2, limitPrice: 100, stopPrice: 99, currency: "USD" } } : {}),
    ...(action === "modify-stop" ? { symbol: "AAPL", orderId: 21, order: { stopPrice: 100 } } : {}),
    ...(action === "cancel" ? { orderId: 21 } : {}),
  };
}

for (const action of ["place", "modify-stop", "cancel", "flatten", "recon"]) for (const post of posts) {
  for (const capture of [false, true]) test(`runner result publication: ${action} / ${post} / capture=${capture}`, async t => {
    let executed = 0, brokerResult;
    const app = publicationApp(t, { ...(capture ? { beforePrune() {} } : {}), execute: async intent => {
      executed++;
      brokerResult = { status: "ok", intentId: intent.intentId, desk: intent.desk, action,
        observedAt: new Date().toISOString(), brokerReceipt: { orderId: 21, status: "Submitted" } };
      return brokerResult;
    } });
    const value = runnerIntent(action), ledger = app.ledger;
    // Claims are healthy. Only the finished result's publication fails, once;
    // any erroneous recovery save would succeed and overwrite the broker result.
    const faults = storageFaults(t, ledger.root, "none", post, "ledger.json", { when: () => executed === 1, once: true });
    const first = await request(app, "POST", "/v1/intents", value);
    assert.equal(faults.counts.postErrors, 1);
    assert.equal(first.status, 500);
    assert.equal(faults.counts.publications, 2, "claim and result only; never a replacement failure");
    const body = readFileSync(ledger.statePath, "utf8"), disk = JSON.parse(body), row = disk.intents[value.intentId];
    assert.equal(row.status, "done");
    if (action === "recon") assert.equal(row.result.resultSha256, digest(brokerResult));
    else assert.deepEqual(row.result, brokerResult);
    assert.equal(disk.resultsCapture, undefined, "ledger fsync cannot invent a capture outage");
    const replay = await request(app, "POST", "/v1/intents", value);
    assert.equal(replay.status, 200);
    assert.deepEqual(replay.body, { ...row.result, idempotentReplay: true });
    assert.equal(readFileSync(ledger.statePath, "utf8"), body);
    assert.equal(executed, 1);
  });

  test(`claim publication: ${action} / ${post} fails closed and replays uncertain`, async t => {
    let executed = 0;
    const app = publicationApp(t, { execute: async () => { executed++; assert.fail("published-uncertain claim reached broker"); } });
    const value = runnerIntent(action), ledger = app.ledger;
    const faults = storageFaults(t, ledger.root, "none", post, "ledger.json", { once: true });
    assert.equal((await request(app, "POST", "/v1/intents", value)).status, 500);
    assert.equal(faults.counts.postErrors, 1);
    const body = readFileSync(ledger.statePath, "utf8");
    assert.equal(JSON.parse(body).intents[value.intentId].status, "claimed");
    const replay = await request(app, "POST", "/v1/intents", value);
    assert.equal(replay.status, 409);
    assert.equal(replay.body.status, "uncertain");
    assert.equal(replay.body.idempotentReplay, true);
    assert.equal(readFileSync(ledger.statePath, "utf8"), body);
    assert.equal(executed, 0);
  });
}

for (const post of posts) for (const code of ["uncertain", "refused"]) {
  test(`runner failure result publication: ${code} / ${post} preserves its first body`, async t => {
    let executed = 0;
    const app = publicationApp(t, { execute: async () => { executed++; throw Object.assign(new Error("synthetic runner failure"), { code }); } });
    const ledger = app.ledger, value = runnerIntent("cancel");
    const faults = storageFaults(t, ledger.root, "none", post, "ledger.json", { when: () => executed === 1, once: true });
    assert.equal((await request(app, "POST", "/v1/intents", value)).status, 500);
    assert.equal(faults.counts.postErrors, 1);
    assert.equal(faults.counts.publications, 2);
    const body = readFileSync(ledger.statePath, "utf8"), row = JSON.parse(body).intents[value.intentId];
    assert.equal(row.status, code === "uncertain" ? "uncertain" : "rejected");
    const replay = await request(app, "POST", "/v1/intents", value);
    assert.equal(replay.status, code === "uncertain" ? 409 : 422);
    assert.deepEqual(replay.body, { ...row.result, idempotentReplay: true });
    assert.equal(readFileSync(ledger.statePath, "utf8"), body);
    assert.equal(executed, 1);
  });
}

for (const post of posts) test(`admin re-arm publication: ${post} returns 500 with a reset budget and sender retries`, async t => {
  const app = publicationApp(t, { beforePrune() { throw { code: "EIO" }; } }), ledger = app.ledger;
  ledger.save(readState(ledger));
  const receipt = readState(ledger).resultsCaptureAlerts[0];
  ledger.updateCaptureDelivery(receipt.outageId, "failure", () => ({ attempts: 5, status: "failed" }));
  const faults = storageFaults(t, ledger.root, "none", post, "ledger.json", { once: true });
  assert.equal((await request(app, "POST", "/v1/admin/capture-alerts/rearm")).status, 500);
  assert.equal(faults.counts.postErrors, 1);
  assert.equal(faults.counts.publications, 1);
  const body = readFileSync(ledger.statePath, "utf8"), disk = JSON.parse(body);
  assert.equal(disk.resultsCaptureAlerts[0].delivery.failure.attempts, 0);
  assert.equal(disk.resultsCaptureAlerts[0].delivery.failure.status, "pending");
  assert.deepEqual((await request(app, "POST", "/v1/admin/capture-alerts/rearm")).body, { status: "ok", rearmed: 0 });
  assert.equal(readFileSync(ledger.statePath, "utf8"), body);
  const mailbox = createMailbox({ stateDir: temporary(t), localSocketPath: MAILBOX_SOCKET_PATH, log() {} });
  t.after(() => mailbox.close());
  await deliveryClock(t, mailbox)(ledger);
  assert.equal(mailbox.mailbox.messages("amy").length, 1);
  assert.equal(readState(ledger).resultsCaptureAlerts[0].delivery.failure.attempts, 1);
});

for (const post of posts) test(`halted result publication: ${post} stays rejected without execution`, async t => {
  const app = publicationApp(t, { execute: () => assert.fail("HALT reached runner") }), ledger = app.ledger;
  assert.equal((await request(app, "POST", "/v1/halt", { reason: "operator stop" })).status, 200);
  const value = runnerIntent("place");
  const faults = storageFaults(t, ledger.root, "none", post, "ledger.json", {
    once: true, when: () => JSON.parse(readFileSync(ledger.statePath)).intents[value.intentId]?.status === "rejected",
  });
  assert.equal((await request(app, "POST", "/v1/intents", value)).status, 500);
  assert.equal(faults.counts.postErrors, 1);
  assert.equal(faults.counts.publications, 2);
  const body = readFileSync(ledger.statePath, "utf8");
  const replay = await request(app, "POST", "/v1/intents", value);
  assert.equal(replay.status, 422);
  assert.equal(replay.body.idempotentReplay, true);
  assert.match(replay.body.reason, /HALT/);
  assert.equal(readFileSync(ledger.statePath, "utf8"), body);
});

for (const post of posts) test(`HALT route publication: ${post} retains the stop and reports success`, async t => {
  const app = publicationApp(t), ledger = app.ledger;
  const faults = storageFaults(t, ledger.root, "none", post, "HALT", { once: true });
  const result = await request(app, "POST", "/v1/halt", { reason: "operator stop" });
  assert.equal(result.status, 200);
  assert.equal(result.body.active, true);
  assert.equal(faults.counts.postErrors, 1);
  assert.equal(faults.counts.publications, 1);
  assert.equal(JSON.parse(ledger.haltBody()).reason, "operator stop");
  assert.equal(ledger.captureDiagnostics().durability, "uncertain");
});

for (const post of posts) test(`loopback health publication: ${post} returns 503 without re-marking initialization`, async t => {
  t.mock.method(console, "error", () => {});
  const root = temporary(t), app = createExecutor({ testMode: true, stateDir: root,
    listenHost: "127.0.0.1", listenPort: 0, allowlist: ["127.0.0.1"], mailboxSocket: "",
    beforePrune() {}, gatewayReachable: () => true });
  t.after(() => app.close().catch(() => {}));
  const loopback = createHealthServer(() => app.readHealth());
  t.after(() => loopback.close());
  const faults = storageFaults(t, root, "none", post, "ledger.json", { once: true });
  const poll = () => new Promise(resolve => {
    let status;
    loopback.emit("request", { method: "GET", url: "/v1/health", resume() {} }, {
      writeHead(code) { status = code; }, end(raw) { resolve({ status, body: JSON.parse(raw) }); },
    });
  });
  assert.deepEqual(await poll(), { status: 503, body: { status: "unavailable" } });
  assert.equal(faults.counts.postErrors, 1);
  assert.equal(faults.counts.publications, 1);
  const body = readFileSync(app.ledger.statePath, "utf8");
  assert.equal(JSON.parse(body).resultsCapture, undefined);
  assert.equal(app.ledger.captureDiagnostics().persisted, true);
  assert.equal((await poll()).status, 200);
  assert.equal(readFileSync(app.ledger.statePath, "utf8"), body);
});

test("admission diagnostic publication: directory fsync EIO preserves the cap without claiming or executing", async t => {
  t.mock.method(console, "warn", () => {});
  const app = publicationApp(t, { beforePrune() { throw { code: "EIO" }; }, execute() { assert.fail("cap reached runner"); } });
  const ledger = app.ledger, state = readState(ledger), value = runnerIntent("place");
  state.padding = "x".repeat(CAPTURE_DEGRADED_ADMISSION_BYTES + 1024);
  ledger.save(state);
  const faults = storageFaults(t, ledger.root, "none", "directory-fsync", "ledger.json", { once: true });
  assert.equal((await request(app, "POST", "/v1/intents", value)).status, 500);
  assert.equal(faults.counts.postErrors, 1);
  assert.equal(faults.counts.publications, 1);
  const disk = JSON.parse(readFileSync(ledger.statePath));
  assert.equal(disk.intents[value.intentId], undefined);
  assert.equal(disk.resultsCapture.ok, false);
  assert.equal(disk.resultsCaptureAlerts.length, 1);
  assert.equal((await request(app, "POST", "/v1/intents", value)).body.code, "results_capture_degraded_ledger_cap");
});

for (const post of posts) test(`admin attribution publication: ${post} returns 500 without undoing its journal`, async t => {
  const app = publicationApp(t), ledger = app.ledger, state = readState(ledger);
  state.executions = [{ contract: { conId: 1, symbol: "AAPL", secType: "STK", currency: "USD" },
    execution: { execId: "publication-foreign.01", acctNumber: ACCOUNT, clientId: 28, orderId: 21,
      side: "BOT", shares: 2, price: 100, time: new Date().toISOString(), orderRef: "" } }];
  ledger.save(state);
  const faults = storageFaults(t, ledger.root, "none", post, "ledger.json", { once: true });
  const result = await request(app, "POST", "/v1/admin/attribution", { execId: "publication-foreign.01",
    disposition: "external", actor: "ops-test", reason: "Acknowledge outside activity", dryRun: false });
  assert.equal(result.status, 500);
  assert.equal(faults.counts.postErrors, 1);
  assert.equal(faults.counts.publications, 1);
  const disk = JSON.parse(readFileSync(ledger.statePath));
  assert.equal(disk.attributionJournal.length, 1);
  assert.equal(disk.attributionJournal[0].disposition, "external");
  assert.equal(readState(openLedger(ledger.root)).attributionJournal.length, 1);
});

for (const post of posts) test(`attribution receipt publication: ${post} never rolls visible receipts back in memory`, t => {
  const app = publicationApp(t), ledger = app.ledger, state = readState(ledger);
  state.executions = [{ contract: { conId: 1, symbol: "AAPL", secType: "STK", currency: "USD" },
    execution: { execId: "receipt-foreign.01", acctNumber: ACCOUNT, clientId: 28, orderId: 21,
      side: "BOT", shares: 2, price: 100, time: new Date().toISOString(), orderRef: "" } }];
  const faults = storageFaults(t, ledger.root, "none", post, "ledger.json", { once: true });
  let alerts = 0;
  assert.throws(() => reconcileAttribution(state, attributionConfig(), { saveState: ledger.save, alertForeign() { alerts++; } }), { published: true, code: "EIO" });
  assert.equal(faults.counts.postErrors, 1);
  const disk = JSON.parse(readFileSync(ledger.statePath));
  assert.deepEqual(state.executions, disk.executions);
  assert.deepEqual(state.foreignAlerts, disk.foreignAlerts);
  assert.equal(alerts, 0, "the exception still prevents alert emission");
  reconcileAttribution(state, attributionConfig(), { saveState: ledger.save, alertForeign() { alerts++; } });
  assert.equal(faults.counts.publications, 1, "no retry write or duplicate receipt");
  assert.equal(alerts, 0);
});

for (const phase of phases) for (const { pre, post } of [
  { pre: "none", post: "none" },
  { pre: phase === "startup" ? "linkSync" : "renameSync", post: "none" },
  ...posts.map(post => ({ pre: "none", post })),
]) for (const restart of restarts) {
  test(`publication table: ${phase} / post=${post} / pre=${pre} / restart=${restart}`, async t => {
    t.mock.method(console, "error", () => {});
    const root = temporary(t), mailbox = createMailbox({ stateDir: temporary(t), localSocketPath: MAILBOX_SOCKET_PATH, log() {} });
    t.after(() => mailbox.close());
    const deliver = deliveryClock(t, mailbox);
    let failing = true;
    const options = { beforePrune() { if (failing) throw { code: "EIO" }; } };
    let ledger = openLedger(root, options), state;
    if (phase === "startup") ledger.noteCaptureFailure({ code: "EIO" });
    else {
      state = ledger.load();
      addRecons(state);
      // Keep complete results on disk even when the very first failure save
      // cannot publish; restarts must exercise retained evidence, too.
      fs.writeFileSync(ledger.statePath, JSON.stringify({ ...state, intents: Object.fromEntries(state.intents), firstOrders: {} }));
      if (phase !== "failure") ledger.save(state);
      if (phase === "re-arm") ledger.updateCaptureDelivery(state.resultsCaptureAlerts[0].outageId, "failure", () => ({ status: "failed", attempts: 5 }));
    }
    if (phase === "recovery") {
      addRecons(state); // New completed snapshots must exercise compaction on recovery.
      failing = false;
    }
    const diskBefore = fs.existsSync(path.join(root, "ledger.json")) ? readFileSync(path.join(root, "ledger.json"), "utf8") : undefined;
    const faults = storageFaults(t, root, pre, post);
    let error;
    try {
      if (phase === "startup") state = ledger.load();
      else if (phase === "re-arm") ledger.rearmCaptureDelivery();
      else if (phase === "delivery-persist") ledger.updateCaptureDelivery(state.resultsCaptureAlerts[0].outageId, "failure", () => ({ status: "pending", attempts: 0 }));
      else ledger.save(state);
    } catch (caught) { error = caught; }
    const blocked = pre === (phase === "startup" ? "linkSync" : "renameSync");
    assert.equal(faults.counts.publications, blocked ? 0 : 1);
    assert.equal(faults.counts.preErrors, blocked ? 1 : 0);
    assert.equal(faults.counts.postErrors, !blocked && post !== "none" ? 1 : 0);
    assert.equal(faults.counts.preErrors + faults.counts.postErrors, pre === "none" && post === "none" ? 0 : 1, "every configured fault must fire");
    assert.equal(!!error, phase !== "delivery-persist" && (blocked || post !== "none"));
    if (error) {
      assert.equal(error.published, !blocked);
      assert.equal(error.errorClass, "EIO");
      assert.equal(error.durability, blocked ? undefined : "uncertain");
    }
    if (!blocked) {
      const disk = JSON.parse(readFileSync(path.join(root, "ledger.json")));
      assert.equal(ledger.captureDiagnostics().persisted, true, "visible publication cannot retain an unpublished overlay");
      assert.deepEqual(diagnostics(readState(ledger)), diagnostics(disk));
      if (phase === "recovery") assert.deepEqual(diagnostics(state), diagnostics(disk), "caller must adopt the recovered body before the post-publication error");
      if (post !== "none") {
        assert.equal(ledger.captureDiagnostics().durability, "uncertain");
        assert.equal(ledger.captureDiagnostics().durabilityCode, "EIO");
      }
    } else if (diskBefore !== undefined) assert.equal(readFileSync(path.join(root, "ledger.json"), "utf8"), diskBefore);

    // Keep injecting the reachable fault during delivery/restart.
    if (phase === "startup" && blocked) {
      if (restart === "while-failing") {
        ledger = openLedger(root, options);
        ledger.noteCaptureFailure({ code: "EIO" });
        assert.throws(() => ledger.load(), { code: "EIO" });
        assert.equal(fs.existsSync(path.join(root, "ledger.json")), false);
      }
      faults.restore(); // initial publication can only resume after storage returns
    }
    if (!fs.existsSync(path.join(root, "ledger.json"))) ledger.load();
    if (restart === "while-failing") ledger = openLedger(root, options);
    if (phase === "re-arm" && blocked) { faults.restore(); ledger.rearmCaptureDelivery(); }
    await deliver(ledger);
    faults.restore();
    // A fully unpublished startup/failure diagnostic may only be in memory.
    // Recreate it from the still-failing capture when the process restarted.
    ledger.save(readState(ledger));
    await deliver(ledger);
    failing = false;
    ledger.save(readState(ledger));
    if (restart === "after-healthy") ledger = openLedger(root, options);
    await deliver(ledger);
    const disk = JSON.parse(readFileSync(path.join(root, "ledger.json")));
    assert.equal(disk.resultsCapture.ok, true);
    assert.equal(ledger.captureDiagnostics().persisted, true);
    assert.equal(disk.resultsCaptureAlerts.length, 1, "one receipt for the one outage of this class");
    assert.ok(disk.resultsCaptureAlerts[0].resolvedAt);
    assert.deepEqual(diagnostics(readState(ledger)), diagnostics(disk));
    if (phase !== "startup") assertReceipts(readState(ledger));
    const messages = mailbox.mailbox.messages("amy").map(row => JSON.parse(row.body));
    assert.equal(messages.filter(row => row.event === "results_capture_failed").length, 1);
    assert.equal(messages.filter(row => row.event === "results_capture_resolved").length, 1);
    assert.doesNotMatch(JSON.stringify([messages, ledger.captureDiagnostics()]), /synthetic-private-value|synthetic\/path/);
    assert.doesNotThrow(() => admitIntent(readState(ledger), "place", { beforePrune: options.beforePrune }));
  });
}

for (const post of ["directory-fsync", "temporary-cleanup"]) {
  test(`published recovery ${post} reopens the 90% cap and a recurring class gets a new message pair`, async t => {
    t.mock.method(console, "error", () => {});
    t.mock.method(console, "warn", () => {});
    const root = temporary(t), mailbox = createMailbox({ stateDir: temporary(t), localSocketPath: MAILBOX_SOCKET_PATH, log() {} });
    t.after(() => mailbox.close());
    const deliver = deliveryClock(t, mailbox);
    let failing = true;
    const options = { beforePrune() { if (failing) throw { code: "EIO" }; } };
    const app = createExecutor({ testMode: true, stateDir: root, listenHost: "127.0.0.1", listenPort: 0,
      allowlist: ["127.0.0.1"], gatewayReachable: () => true, ...options });
    t.after(() => app.close().catch(() => {}));
    const ledger = app.ledger;
    let state = ledger.load();
    addRecons(state, { atCap: true });
    ledger.save(state);
    assert.ok(ledger.usage().ledgerBytes >= CAPTURE_DEGRADED_ADMISSION_BYTES);
    assert.throws(() => admitIntent(state, "place", { beforePrune: options.beforePrune }), /results_capture_degraded_ledger_cap/);
    await deliver(ledger);
    state = readState(ledger);
    const first = state.resultsCaptureAlerts[0].outageId;
    failing = false;
    const faults = storageFaults(t, root, "none", post);
    assert.throws(() => ledger.save(state), { code: "EIO" });
    assert.equal(faults.counts.postErrors, 1, "the ledger publication fault must actually fire");
    assert.equal(state.resultsCapture.ok, true);
    const health = await app.readHealth();
    assert.equal(health.status, "ok");
    assert.equal(health.resultsCapture.persisted, true);
    assert.equal(health.resultsCapture.durability, "uncertain");
    assert.equal(health.resultsCapture.newAdmissionsBlocked, false);
    assert.ok(health.resultsCapture.ledgerBytes < CAPTURE_DEGRADED_ADMISSION_BYTES);
    assertReceipts(readState(ledger));
    assert.doesNotThrow(() => admitIntent(state, "place", { beforePrune: options.beforePrune }));
    await deliver(ledger);
    failing = true;
    assert.throws(() => ledger.save(readState(ledger)), { code: "EIO" });
    const recurring = readState(ledger).resultsCaptureAlerts;
    assert.equal(recurring.length, 2);
    assert.equal(recurring.filter(row => !row.resolvedAt).length, 1);
    assert.notEqual(recurring.find(row => !row.resolvedAt).outageId, first);
    await deliver(ledger);
    failing = false;
    assert.throws(() => ledger.save(readState(ledger)), { code: "EIO" });
    await deliver(ledger);
    faults.restore();
    ledger.save(readState(ledger));
    const disk = JSON.parse(readFileSync(path.join(root, "ledger.json")));
    assert.equal(disk.resultsCaptureAlerts.length, 2);
    assert.ok(disk.resultsCaptureAlerts.every(row => row.resolvedAt && row.delivery.failure.status === "delivered" && row.delivery.resolution.status === "delivered"));
    const messages = mailbox.mailbox.messages("amy").map(row => JSON.parse(row.body));
    assert.equal(messages.filter(row => row.event === "results_capture_failed").length, 2);
    assert.equal(messages.filter(row => row.event === "results_capture_resolved").length, 2);
  });
}

for (const target of ["recon-evidence.jsonl", "recon-evidence.jsonl.1", "ledger.pre-ops331.json"]) for (const post of posts) {
  test(`published ${target} / ${post} completes real recon recovery at the cap`, async t => {
    t.mock.method(console, "error", () => {});
    t.mock.method(console, "warn", () => {});
    const root = temporary(t), mailbox = createMailbox({ stateDir: temporary(t), localSocketPath: MAILBOX_SOCKET_PATH, log() {} });
    t.after(() => mailbox.close());
    const deliver = deliveryClock(t, mailbox);
    let failing = true;
    const options = { beforePrune() { if (failing) throw { code: "EIO" }; } };
    const ledger = openLedger(root, options);
    let state = ledger.load();
    addRecons(state, { atCap: true });
    ledger.save(state);
    assert.ok(ledger.usage().ledgerBytes >= CAPTURE_DEGRADED_ADMISSION_BYTES);
    assert.throws(() => admitIntent(state, "place", options), /results_capture_degraded_ledger_cap/);
    await deliver(ledger);
    state = readState(ledger);
    const outage = state.resultsCaptureAlerts[0].outageId;
    if (target === "ledger.pre-ops331.json") {
      const legacy = JSON.parse(readFileSync(ledger.statePath));
      delete legacy.reconStorageVersion;
      fs.writeFileSync(ledger.statePath, JSON.stringify(legacy));
    }
    failing = false;
    const faults = storageFaults(t, root, "none", post, target);
    // Migration has a separate backup publication, followed by the same save recovery.
    if (target === "ledger.pre-ops331.json") {
      state = ledger.load();
      assert.equal(ledger.captureDiagnostics().durability, "uncertain");
    }
    ledger.save(state);
    assert.equal(faults.counts.postErrors, 1, "the targeted post-publication fault must fire");
    assert.equal(faults.counts.publications, 1);
    if (target !== "ledger.pre-ops331.json") assert.equal(ledger.captureDiagnostics().durability, "uncertain");
    assertReceipts(state);
    const archived = [ledger.reconEvidencePath, `${ledger.reconEvidencePath}.1`]
      .flatMap(file => readFileSync(file, "utf8").trim().split("\n").map(line => JSON.parse(line)));
    assert.deepEqual(archived.map(row => row.intentId).sort(), ["recon-current", "recon-legacy"]);
    for (const row of archived) assert.equal(row.resultSha256, state.intents.get(row.intentId).result.resultSha256);
    assert.equal(state.resultsCapture.ok, true);
    assert.equal(state.resultsCapture.count, 1);
    assert.equal(state.resultsCaptureAlerts.length, 1);
    assert.equal(state.resultsCaptureAlerts[0].outageId, outage);
    assert.ok(state.resultsCaptureAlerts[0].resolvedAt);
    assert.ok(ledger.usage().ledgerBytes < CAPTURE_DEGRADED_ADMISSION_BYTES);
    assert.doesNotThrow(() => admitIntent(state, "place", options));
    assert.deepEqual(diagnostics(readState(ledger)), diagnostics(state));
    await deliver(ledger);
    assert.equal(mailbox.mailbox.messages("amy").length, 2, "exactly the original outage and its resolution");
    const restarted = openLedger(root, options);
    assertReceipts(readState(restarted));
    assert.equal(readState(restarted).resultsCaptureAlerts.length, 1);
  });
}

test("healthy capture at the cap with published evidence fsync EIO creates one receipt and no outage or Amy message", async t => {
  t.mock.method(console, "error", () => {});
  t.mock.method(console, "warn", () => {});
  const root = temporary(t), mailbox = createMailbox({ stateDir: temporary(t), localSocketPath: MAILBOX_SOCKET_PATH, log() {} });
  t.after(() => mailbox.close());
  const options = { beforePrune() {} }, ledger = openLedger(root, options), state = ledger.load();
  addRecons(state);
  state.intents.delete("recon-legacy");
  state.intents.get("recon-current").result.marks = { AAPL: "x".repeat(2 * 1024 * 1024) };
  state.padding = "x".repeat(CAPTURE_DEGRADED_ADMISSION_BYTES - 1024 * 1024);
  // Seed a completed result exactly as a process restart would find it.
  fs.writeFileSync(ledger.statePath, JSON.stringify({ ...state, intents: Object.fromEntries(state.intents), firstOrders: {} }));
  assert.ok(ledger.usage().ledgerBytes >= CAPTURE_DEGRADED_ADMISSION_BYTES);
  const faults = storageFaults(t, root, "none", "directory-fsync", "recon-evidence.jsonl");
  ledger.save(state);
  assert.equal(faults.counts.postErrors, 1);
  const disk = JSON.parse(readFileSync(ledger.statePath));
  assert.equal(Object.keys(disk.intents).length, 1);
  assert.equal(disk.intents["recon-current"].result.resultCompacted, true);
  assert.equal(disk.resultsCapture, undefined, "a published evidence write is not a capture outage");
  assert.deepEqual(disk.resultsCaptureAlerts ?? [], []);
  assert.equal(ledger.captureDiagnostics().durability, "uncertain");
  assert.ok(ledger.usage().ledgerBytes < CAPTURE_DEGRADED_ADMISSION_BYTES);
  assert.doesNotThrow(() => admitIntent(readState(ledger), "place", options));
  await deliveryClock(t, mailbox)(ledger);
  assert.equal(mailbox.mailbox.messages("amy").length, 0);
});

for (const existing of [false, true]) for (const post of posts) {
  test(`migration backup publication / existing=${existing} / ${post} never aborts migration`, t => {
    t.mock.method(console, "error", () => {});
    const root = temporary(t), ledger = openLedger(root, { beforePrune() {} });
    ledger.load();
    const legacy = JSON.parse(readFileSync(ledger.statePath));
    delete legacy.reconStorageVersion;
    const state = readState(ledger);
    addRecons(state);
    legacy.intents = Object.fromEntries(state.intents);
    const original = JSON.stringify(legacy);
    fs.writeFileSync(ledger.statePath, original);
    if (existing) fs.writeFileSync(ledger.backupPath, original);
    const faults = storageFaults(t, root, "none", post, "ledger.pre-ops331.json");
    const migrated = ledger.load();
    assertReceipts(migrated);
    assert.equal(migrated.reconStorageVersion, 1);
    assert.equal(readFileSync(ledger.backupPath, "utf8"), original);
    assert.equal(faults.counts.postErrors, existing ? 0 : 1);
    assert.equal(faults.counts.publications, existing ? 0 : 1);
    assert.equal(faults.counts.postErrors + faults.counts.conflicts, 1, "either the post-publication fault or exclusive-link EEXIST must fire");
    assert.equal(migrated.resultsCapture, undefined);
    if (!existing) assert.equal(ledger.captureDiagnostics().durability, "uncertain");
  });
}

for (const post of posts) test(`HALT adopts publication after ${post}`, t => {
  const root = temporary(t), ledger = openLedger(root);
  const faults = storageFaults(t, root, "none", post, "HALT");
  const body = ledger.setHalt("operator stop");
  assert.equal(faults.counts.postErrors, 1);
  assert.equal(ledger.haltBody(), body);
});

for (const target of ["audit.jsonl", "audit.jsonl.1"]) for (const post of posts) test(`audit publication ${target} after ${post} keeps complete generations`, t => {
  const root = temporary(t), ledger = openLedger(root);
  const row = `${JSON.stringify({ event: "old", padding: "x".repeat(1024 * 1024 - 100) })}\n`;
  fs.writeFileSync(ledger.auditPath, row);
  const faults = storageFaults(t, root, "none", post, target);
  ledger.audit({ event: "new", padding: "x".repeat(200) });
  assert.equal(faults.counts.postErrors, 1, "the audit fault must actually fire");
  assert.equal(readFileSync(`${ledger.auditPath}.1`, "utf8"), row);
  assert.equal(JSON.parse(readFileSync(ledger.auditPath, "utf8")).event, "new");
});

for (const operation of ["openSync", "writeFileSync", "fsyncSync", "closeSync", "renameSync"]) {
  test(`atomic ${operation} before HALT publication throws a typed unpublished outcome`, t => {
    const root = temporary(t), ledger = openLedger(root), original = fs[operation];
    let fired = 0;
    t.mock.method(fs, operation, (...args) => {
      fired++;
      if (operation === "closeSync") original(...args);
      throw Object.assign(new Error("synthetic"), { code: "EIO" });
    });
    syncBuiltinESMExports();
    t.after(() => { t.mock.restoreAll(); syncBuiltinESMExports(); });
    assert.throws(() => ledger.setHalt("operator stop"), error => {
      assert.equal(error.published, false);
      assert.equal(error.errorClass, "EIO");
      return true;
    });
    assert.equal(fired, 1, "the pre-publication fault must actually fire");
    assert.equal(fs.existsSync(ledger.haltPath), false);
  });
}

test("exclusive backup EEXIST survives a temporary cleanup error and keeps the validated backup", t => {
  const root = temporary(t), ledger = openLedger(root, { beforePrune() {} });
  ledger.load();
  const original = JSON.parse(readFileSync(ledger.statePath));
  delete original.reconStorageVersion;
  const body = JSON.stringify(original);
  fs.writeFileSync(ledger.statePath, body);
  fs.writeFileSync(ledger.backupPath, body);
  const unlink = fs.unlinkSync;
  let fired = 0;
  t.mock.method(fs, "unlinkSync", file => {
    if (String(file).startsWith(`${ledger.backupPath}.`)) { fired++; throw { code: "EIO" }; }
    return unlink(file);
  });
  syncBuiltinESMExports();
  t.after(() => { t.mock.restoreAll(); syncBuiltinESMExports(); });
  assert.equal(ledger.load().reconStorageVersion, 1);
  assert.equal(fired, 1);
  assert.equal(readFileSync(ledger.backupPath, "utf8"), body);
});

test("a pending overlay adopts another publisher's resolved outage and delivery record before a new outage", async t => {
  t.mock.method(console, "error", () => {});
  const root = temporary(t), mailbox = createMailbox({ stateDir: temporary(t), localSocketPath: MAILBOX_SOCKET_PATH, log() {} });
  t.after(() => mailbox.close());
  const deliver = deliveryClock(t, mailbox);
  let failing = true;
  const options = { beforePrune() { if (failing) throw { code: "EIO" }; } };
  const old = openLedger(root, options);
  old.save(old.load());
  const faults = storageFaults(t, root, "renameSync", "none");
  assert.throws(() => old.save(readState(old)), { code: "EIO" });
  assert.equal(old.captureDiagnostics().persisted, false);
  faults.restore();
  failing = false;
  const publisher = openLedger(root, options);
  publisher.save(readState(publisher));
  await deliver(publisher);
  const published = readState(publisher);
  const adopted = readState(old);
  assert.deepEqual(diagnostics(adopted), diagnostics(published));
  assert.equal(old.captureDiagnostics().persisted, true);
  failing = true;
  old.save(adopted);
  const next = readState(old);
  assert.equal(next.resultsCaptureAlerts.length, 2);
  assert.notEqual(next.resultsCaptureAlerts.find(row => !row.resolvedAt).outageId, published.resultsCaptureAlerts[0].outageId);
  await deliver(old);
  failing = false;
  old.save(readState(old));
  await deliver(old);
  const messages = mailbox.mailbox.messages("amy").map(row => JSON.parse(row.body));
  assert.equal(messages.filter(row => row.event === "results_capture_failed").length, 2);
  assert.equal(messages.filter(row => row.event === "results_capture_resolved").length, 2);
});

test("a resolution retains its finite in-memory retry budget when all delivery-marker renames fail", async t => {
  t.mock.method(console, "error", () => {});
  const root = temporary(t), mailbox = createMailbox({ stateDir: temporary(t), localSocketPath: MAILBOX_SOCKET_PATH, log() {} });
  t.after(() => mailbox.close());
  let failing = true;
  const options = { beforePrune() { if (failing) throw { code: "EIO" }; } };
  const ledger = openLedger(root, options);
  ledger.save(ledger.load());
  await deliveryClock(t, mailbox)(ledger);
  failing = false;
  ledger.save(readState(ledger));
  const faults = storageFaults(t, root, "renameSync", "none");
  let attempts = 0;
  await deliveryClock(t, mailbox, { loseReply: () => true, expected: "failed", onPost() { attempts++; } })(ledger);
  assert.equal(attempts, 5);
  assert.equal(readState(ledger).resultsCaptureAlerts[0].delivery.resolution.attempts, 5);
  assert.equal(ledger.captureDiagnostics().persisted, false);
  assert.equal(mailbox.mailbox.messages("amy").length, 2);
  faults.restore();
  ledger.save(readState(ledger));
  const restarted = openLedger(root, options);
  await deliveryClock(t, mailbox, { expected: "failed", onPost() { attempts++; } })(restarted);
  assert.equal(attempts, 5);
});

for (const phase of ["initial", "recovery", "migration"]) for (const post of ["directory-fsync", "temporary-cleanup"]) {
  test(`startup outer handler preserves a published ${phase} body after ${post}`, async t => {
    t.mock.method(console, "error", () => {});
    const root = temporary(t);
    let failing = phase !== "initial";
    const app = createExecutor({ testMode: true, stateDir: root, listenHost: "127.0.0.1", listenPort: 0,
      allowlist: ["127.0.0.1"], gatewayReachable: () => true, beforePrune() { if (failing) throw { code: "EIO" }; } });
    t.after(() => app.close().catch(() => {}));
    if (phase !== "initial") app.ledger.save(app.ledger.load());
    if (phase === "migration") {
      const legacy = JSON.parse(readFileSync(path.join(root, "ledger.json")));
      delete legacy.reconStorageVersion;
      fs.writeFileSync(path.join(root, "ledger.json"), JSON.stringify(legacy));
    }
    failing = false;
    const faults = storageFaults(t, root, "none", post);
    await app.initializeCapture();
    assert.equal(faults.counts.postErrors, 1, "the startup publication fault must actually fire");
    const disk = JSON.parse(readFileSync(path.join(root, "ledger.json")));
    assert.deepEqual(diagnostics(readState(app.ledger)), diagnostics(disk));
    assert.equal(app.ledger.captureDiagnostics().persisted, true);
    assert.equal(app.ledger.captureDiagnostics().durability, "uncertain");
    if (phase === "initial") assert.equal(disk.resultsCapture, undefined);
    else {
      assert.equal(disk.resultsCapture.count, 1, "post-publication errors must not increment capture failures");
      assert.equal(disk.resultsCapture.ok, phase === "recovery");
      assert.equal(disk.resultsCaptureAlerts.length, 1);
    }
  });
}

// Real broker protocol fixture, matching executor.test.mjs. No sockets or IB service.
const events = Object.fromEntries(["error", "connected", "disconnected", "managedAccounts", "position", "positionEnd", "openOrder", "openOrderEnd", "execDetails", "execDetailsEnd", "nextValidId", "orderStatus", "contractDetails", "contractDetailsEnd", "accountUpdateMulti", "accountUpdateMultiEnd", "commissionReport", "tickPrice", "tickString", "tickSnapshotEnd"].map((key) => [key, key]));
const contract = (symbol = "AAPL", conId = 1) => ({ symbol, conId, secType: "STK", currency: "USD", exchange: "SMART" });
// Keep order dates on the same New York clock as fills and history coverage,
// including tests that freeze Date themselves.
const ref = (desk = "j", thesis = "test", now = Date.now()) => `${desk}|${newYorkDay(now).slice(2).replaceAll("-", "")}|${thesis}`;
const fill = (overrides = {}) => ({ contract: contract(), execution: { execId: "fill.1", acctNumber: ACCOUNT, clientId: 705, orderRef: ref(), side: "BOT", shares: 2, price: 100, time: `${newYorkDay().replaceAll("-", "")} 15:00:00`, orderId: 20, ...overrides } });
const order = (overrides = {}) => ({ ...contract(), orderId: 30, clientId: 705, action: "BUY", orderType: "LMT", quantity: 2, orderRef: ref(), parentId: 0, status: "Submitted", ...overrides });
function intent(action = "place", overrides = {}) {
  return parseIntent({ schema: "barta.paper-desk-intent.v2", intentId: "j-executor-test", desk: "j", action, createdAt: new Date(Date.now() - 1000).toISOString(), expiresAt: new Date(Date.now() + 300000).toISOString(), ...(action === "place" ? { orderRef: ref(), order: { symbol: "AAPL", side: "BUY", quantity: 2, limitPrice: 100, stopPrice: 99, currency: "USD" } } : {}), ...overrides });
}
function fixtureState() { return { initializedAt: new Date().toISOString(), intents: new Map(), placements: [], executions: [] }; }
function intradayCoverage() {
  const now = Date.now();
  let midnight = Math.floor(now / 3600000) * 3600000;
  while (newYorkDay(midnight - 3600000) === newYorkDay(now)) midnight -= 3600000;
  return { status: "known", gaps: [{ fromInclusive: new Date(midnight).toISOString(), toExclusive: new Date(now).toISOString(), reason: "no authoritative completeness receipt" }], target: { fromInclusive: new Date(midnight - 86400000).toISOString(), toExclusive: new Date(now).toISOString() } };
}
function harness(options = {}) {
  const broker = { managedAccounts: ACCOUNT, positionRequests: [], positions: [], orders: [], executions: [], commissions: [], placed: [], cancelled: [], connections: [], executionRequests: [], marketDataTypes: [], markRequests: [], live: new Set(), sessions: [], ...options };
  class FakeIB extends EventEmitter {
    constructor({ clientId }) { super(); this.clientId = clientId; this.autoCancelled = new Set(); }
    connect() {
      assert.equal(broker.live.has(this.clientId), false, "duplicate client session");
      broker.live.add(this.clientId); broker.connections.push(this.clientId);
      this.emit(events.connected);
    }
    disconnect() { broker.live.delete(this.clientId); this.emit(events.disconnected); }
    reqManagedAccts() { this.emit(events.managedAccounts, broker.managedAccounts); }
    reqPositions() { broker.positionRequests.push(this.clientId); for (const row of broker.positions) this.emit(events.position, ACCOUNT, row, row.position, row.averageCost || 100); this.emit(events.positionEnd); }
    reqAllOpenOrders() { for (const row of broker.orders) { this.emit(events.openOrder, row.orderId, row, { ...row, totalQuantity: row.quantity }, { status: row.status }); if (!broker.noOrderEvidence) this.emit(events.orderStatus, row.orderId, row.status, row.filled || 0, row.quantity - (row.filled || 0), 0, 0, row.parentId, 0, row.clientId); } if (!broker.noCancelOrdersEnd || !broker.cancelled.length) this.emit(events.openOrderEnd); }
    reqExecutions(id, filter) {
      broker.executionRequests.push({ id, filter });
      if (broker.executionError) this.emit(events.error, new Error("execution snapshot failed"), 201, id);
      for (const row of broker.executions) this.emit(events.execDetails, id, row.contract, row.execution);
      for (const fee of broker.commissions) this.emit(events.commissionReport, fee);
      if (!broker.noCancelExecutionsEnd || !broker.cancelled.length) this.emit(events.execDetailsEnd, broker.wrongExecutionRequest ? id + 1 : id);
      broker.onExecutionRequest?.(this, id);
    }
    reqIds() { this.emit(events.nextValidId, 100 + broker.placed.length); }
    reqContractDetails(id, request) { this.emit(events.contractDetails, id, { contract: broker.resolve ? broker.resolve(request) : contract(request.symbol, request.symbol === "AAPL" ? 1 : 2), stockType: "COMMON" }); this.emit(events.contractDetailsEnd, id); broker.onContractDetails?.(this); }
    reqAccountUpdatesMulti(id) { this.emit(events.accountUpdateMulti, id, ACCOUNT, "", "ExchangeRate", "1", "EUR"); this.emit(events.accountUpdateMulti, id, ACCOUNT, "", "ExchangeRate", "0.9", "USD"); this.emit(events.accountUpdateMultiEnd, id); broker.onFx?.(); }
    cancelAccountUpdatesMulti() {}
    reqMarketDataType(type) { broker.marketDataTypes.push(type); this.marketDataType = type; }
    reqMktData(id, c) {
      assert.equal(this.marketDataType, 3, "delayed data must be selected before requesting quotes");
      broker.markRequests.push({ id, contract: c });
      broker.onMarkRequest?.(this, id, c);
      if (broker.mark354) this.emit(events.error, new Error("Requested market data is not subscribed; delayed data is available"), 354, id);
      if (broker.mark10089) this.emit(events.error, new Error("Requested market data is not subscribed"), 10089, id);
      if (broker.mark10167) this.emit(events.error, new Error("Requested market data is not subscribed. Displaying delayed market data."), 10167, id);
      if (!broker.noMark && !broker.noMarkSymbols?.includes(c.symbol)) for (const [field, price] of broker.quotes || [[4, broker.mark ?? 101]]) this.emit(events.tickPrice, id, field, price);
      if (broker.delayedLastTimestamp !== undefined) this.emit(events.tickString, id, 88, String(broker.delayedLastTimestamp));
      if (!broker.noMarkEnd) this.emit(events.tickSnapshotEnd, id);
      broker.onMark?.(this);
    }
    cancelMktData(id) { if (broker.markCancel300) this.emit(events.error, new Error("Can't find EId with tickerId"), 300, id); }
    placeOrder(id, c, value) {
      broker.placed.push({ id, contract: { ...c }, order: { ...value }, clientId: this.clientId });
      if (broker.errorOnPlace) this.emit(events.error, new Error("paper rejection"), 201, id);
      if (!broker.noAck && !broker.noStatusAck && !(broker.missingStopAck && value.orderType === "STP")) this.emit(events.orderStatus, id, broker.partial ? "Submitted" : value.orderType === "MKT" ? "Filled" : "Submitted", broker.badQuantity ? 0 : broker.partial ? 1 : value.orderType === "MKT" ? value.totalQuantity : 0, broker.badQuantity ? 0 : broker.partial ? 1 : value.orderType === "MKT" ? 0 : value.totalQuantity, 100, 0, value.parentId, 0, this.clientId);
      if (broker.ackModification && broker.orders.some((row) => row.orderId === id && row.clientId === this.clientId)) {
        broker.orders = broker.orders.map((row) => row.orderId === id && row.clientId === this.clientId ? { ...row, ...value, quantity: value.totalQuantity } : row);
        if (!broker.noAck && !broker.noPriceAck) this.emit(events.openOrder, id, c, { ...value, clientId: this.clientId, ...broker.modificationAck }, { status: "Submitted" });
      }
      broker.afterPlace?.(broker.placed.length);
    }
    cancelOrder(id) {
      if (broker.autoCancelChildren) {
        for (const row of broker.orders.filter((row) => row.parentId === id && row.clientId === this.clientId)) this.autoCancelled.add(row.orderId);
        broker.orders = broker.orders.filter((row) => !this.autoCancelled.has(row.orderId));
      }
      broker.cancelled.push(id); if (!broker.keepCancelledOrder) broker.orders = broker.orders.filter((row) => row.orderId !== id);
      if (broker.errorOnCancel) this.emit(events.error, new Error("cancel rejection"), 201, id);
      if (broker.cancelErrorCode || this.autoCancelled.has(id)) this.emit(events.error, new Error("order is not cancellable or not found"), broker.cancelErrorCode || 161, broker.cancelErrorOrderId ?? id);
      if (broker.cancel202) this.emit(events.error, new Error("Order Canceled"), 202, broker.cancel202OrderId ?? id);
      if (!broker.noCancelAck && (!this.autoCancelled.has(id) || broker.autoCancelChildAck)) this.emit(events.orderStatus, id, broker.cancelStatus || "Cancelled", broker.cancelFilled || 0, 0, 0, 0, 0, 0, this.clientId);
      broker.afterCancel?.();
    }
  }
  const connect = async (id, sessionOptions) => {
    const session = await openSession(id, broker.wrongExecutionRequest ? 5 : 1000, { ...sessionOptions, IBApi: FakeIB, EventName: events, wait: broker.wait || (async () => {}) });
    broker.sessions.push(session);
    if (!sessionOptions?.ordersOnly) await broker.onSnapshot?.(session);
    return session;
  };
  const history = { schema: "inspr.joe.best-available-history.v1", version: 1, account: ACCOUNT, executions: options.history || [], coverage: { status: "complete", gaps: [], target: { fromInclusive: new Date(Date.now() - 40 * 86400000).toISOString(), toExclusive: new Date().toISOString() } } };
  if (options.coverage) history.coverage = options.coverage;
  const readHistory = (file, now = Date.now(), _readFile, historyOptions) => readPusherExecutions(file, now, () => { if (options.missingHistory) throw new Error("ENOENT"); return JSON.stringify(history); }, historyOptions);
  const config = { resultsCaptureEnabled: true, clientIds: { executor: 705, recon: 700 }, ownership: { j: [702], j2: [706], j5: [703], joe: [701], joel: [704] }, ownershipLedger: "/pusher-state/family-history.json", blockOnInitDay: false };
  const run = (value, state = fixtureState(), context = {}) => executeIntent(value, state, { halt: { active: false }, saveState: () => {}, ...context }, { config, connect, readHistory });
  return { broker, run, connect, readHistory, config, runtime: { config, connect, readHistory } };
}

function modifyFixture(options = {}) {
  const short = options.short === true;
  const protective = order({ orderId: 21, parentId: 20, action: short ? "BUY" : "SELL", orderType: "STP", auxPrice: short ? 120 : 95, account: ACCOUNT, tif: "DAY", outsideRth: false, triggerMethod: 2, ...options.stop });
  const execution = fill({ side: short ? "SLD" : "BOT", ...options.fill });
  const state = fixtureState();
  state.placements.push({ intentId: "original-bracket", desk: "j", symbol: "AAPL", clientId: 705, orderRef: ref(), side: short ? "SELL" : "BUY", quantity: 2, orderIds: [20, 21], day: newYorkDay(), reservedAt: new Date().toISOString(), status: "submitted", riskEur: 1, notionalEur: 200 });
  const value = intent("modify-stop", { symbol: "AAPL", orderId: 21, order: { stopPrice: short ? 115 : 100 } });
  state.intents.set(value.intentId, { action: value.action, status: "claimed", orderId: 21, claimedAt: new Date().toISOString() });
  const h = harness({ orders: [protective], executions: [execution], positions: [{ ...contract(), position: short ? -2 : 2 }], mark: 110, ackModification: true, ...options });
  return { ...h, state, value };
}

function realPublicationApp(t, action, options = {}) {
  const h = action === "modify-stop" ? modifyFixture(options) : harness({
    ...(["cancel", "flatten"].includes(action) ? { history: [fill()], executions: [fill()],
      positions: [{ ...contract(), position: 2 }], orders: [order({ action: "SELL", orderType: "STP" })] } : {}), ...options,
  });
  let liveState, executed = 0, lastError;
  const app = publicationApp(t, { beforePrune() {}, execute(value, state, context) {
    liveState = state; executed++;
    return executeIntent(value, state, context, h.runtime).catch(error => { lastError = error; throw error; });
  } });
  t.after(() => { for (const session of h.broker.sessions) { try { session.close(); } catch {} } });
  if (h.state) {
    const state = readState(app.ledger);
    state.placements = h.state.placements;
    app.ledger.save(state);
  }
  return { ...h, app, value: h.value || intent(action, action === "cancel" ? { orderId: 30 } : {}),
    get state() { return liveState; }, get executed() { return executed; }, get lastError() { return lastError; } };
}

function pendingCancellation(ledger) {
  const state = readState(ledger);
  state.intents.set("earlier-cancel", { action: "cancel", status: "uncertain", claimedAt: new Date().toISOString(),
    brokerPlan: { cancellationTargets: [{ clientId: 705, orderId: 999, quantity: 2 }] } });
  ledger.save(state);
}

for (const action of ["place", "recon"]) test(`durability manifest: ${action} result audit EIO keeps done and replay`, async t => {
  const h = realPublicationApp(t, action), ledger = h.app.ledger;
  if (action === "recon") pendingCancellation(ledger);
  const faults = storageFaults(t, ledger.root, "writeFileSync", "none", "audit.jsonl", {
    once: true, when: () => JSON.parse(readFileSync(ledger.statePath)).intents[h.value.intentId]?.status === "done",
  });
  const first = await request(h.app, "POST", "/v1/intents", h.value);
  assert.equal(faults.counts.preErrors, 1);
  assert.equal(first.status, 500);
  assert.equal(readFileSync(ledger.statePath, "utf8"), faults.faultBody, "no second ledger rename after result audit failure");
  assert.equal(faults.ledgerBodies.at(-1), faults.faultBody);
  assert.equal(faults.ledgerBodies.length, faults.faultLedgerPublications);
  const disk = JSON.parse(faults.faultBody);
  assert.equal(disk.intents[h.value.intentId].status, "done");
  if (action === "recon") {
    assert.equal(disk.intents["earlier-cancel"].resolution.status, "absent");
    assert.deepEqual(disk.intents["earlier-cancel"].resolution, JSON.parse(faults.ledgerBodies.at(-2)).intents["earlier-cancel"].resolution);
  } else assert.equal(h.broker.placed.length, 2);
  const renames = faults.ledgerBodies.length;
  const replay = await request(h.app, "POST", "/v1/intents", h.value);
  assert.equal(replay.status, 200);
  assert.equal(replay.body.idempotentReplay, true);
  assert.equal(h.executed, 1);
  assert.equal(faults.ledgerBodies.length, renames);
  assert.equal(readFileSync(ledger.statePath, "utf8"), faults.faultBody);
});

for (const action of ["place", "modify-stop", "cancel", "flatten"]) {
  test(`durability manifest: ${action} attribution audit EIO continues acknowledgement and done`, async t => {
    const h = realPublicationApp(t, action), ledger = h.app.ledger;
    let session;
    h.broker.onSnapshot = value => { if (value.api.clientId === 705) session = value; };
    const foreign = { contract: contract("AMD", 2), execution: fill({ execId: "suffix-foreign.01", clientId: 28,
      orderRef: "", time: new Date().toISOString() }).execution };
    if (["cancel", "flatten"].includes(action)) {
      const state = readState(ledger);
      state.executions.push(foreign);
      ledger.save(state);
    }
    const inject = () => { if (!session.state.executions.some(row => row.execution.execId === foreign.execution.execId)) session.state.executions.push(foreign); };
    if (["place", "modify-stop"].includes(action)) h.broker.afterPlace = count => { if (count === (action === "place" ? 2 : 1)) inject(); };
    else if (action === "flatten") h.broker.afterPlace = inject;
    const faults = storageFaults(t, ledger.root, "writeFileSync", "none", "audit.jsonl", {
      once: true, when: () => JSON.parse(readFileSync(ledger.statePath)).foreignAlerts?.some(row => row.execId === foreign.execution.execId),
    });
    const result = await request(h.app, "POST", "/v1/intents", h.value);
    assert.equal(faults.counts.preErrors, 1, h.lastError?.stack || "post-broker attribution audit fault fired once");
    assert.equal(result.status, 200);
    if (["cancel", "flatten"].includes(action)) assert.ok(h.broker.cancelled.length > 0);
    assert.equal(h.broker.placed.length, action === "place" ? 2 : action === "cancel" ? 0 : 1);
    const committed = JSON.parse(faults.faultBody);
    if (action === "place") assert.equal(committed.placements.at(-1).status, "submitted");
    if (action === "modify-stop") assert.equal(committed.placements[0].stopHistory.at(-1).status, "submitted");
    const at = faults.ledgerBodies.indexOf(faults.faultBody);
    assert.ok(at >= 0);
    assert.equal(faults.ledgerBodies.length, faults.faultLedgerPublications + 2, "only the forward acknowledgement and result saves follow the receipt");
    const later = faults.ledgerBodies.slice(at).map(body => JSON.parse(body));
    assert.equal(later.at(-1).intents[h.value.intentId].status, "done");
    assert.ok(later.every(body => !["uncertain", "rejected"].includes(body.intents[h.value.intentId].status)));
    if (action === "place") assert.ok(later.every(body => body.placements.at(-1).status === "submitted"));
    if (action === "modify-stop") assert.ok(later.every(body => body.placements[0].stopHistory.at(-1).status === "submitted"));
    assert.equal(readFileSync(ledger.statePath, "utf8"), faults.ledgerBodies.at(-1));
    const bytes = readFileSync(ledger.statePath, "utf8"), renames = faults.ledgerBodies.length;
    assert.equal((await request(h.app, "POST", "/v1/intents", h.value)).body.idempotentReplay, true);
    assert.equal(readFileSync(ledger.statePath, "utf8"), bytes);
    assert.equal(faults.ledgerBodies.length, renames);
    assert.equal(h.executed, 1);
  });
}

for (const phase of ["initial snapshot", "resolved snapshot"]) test(`durability manifest: recon ${phase} attribution audit EIO preserves resolutions`, async t => {
  const h = realPublicationApp(t, "recon"), ledger = h.app.ledger;
  pendingCancellation(ledger);
  h.broker.onSnapshot = session => {
    if (session.api.clientId === (phase === "initial snapshot" ? 700 : 705)) session.state.openOrders.push(
      order({ symbol: "AMD", conId: 2, clientId: 28, orderRef: "", orderId: 89, account: ACCOUNT }));
  };
  const faults = storageFaults(t, ledger.root, "writeFileSync", "none", "audit.jsonl", {
    once: true, when: () => JSON.parse(readFileSync(ledger.statePath)).foreignAlerts?.some(row => row.event === "foreign_open_order"),
  });
  assert.equal((await request(h.app, "POST", "/v1/intents", h.value)).status, 200);
  assert.equal(faults.counts.preErrors, 1);
  const disk = JSON.parse(readFileSync(ledger.statePath));
  assert.equal(disk.intents[h.value.intentId].status, "done");
  assert.equal(disk.intents["earlier-cancel"].resolution.status, "absent");
  if (phase === "resolved snapshot") assert.deepEqual(disk.intents["earlier-cancel"].resolution, JSON.parse(faults.faultBody).intents["earlier-cancel"].resolution);
  else assert.equal(JSON.parse(faults.faultBody).intents["earlier-cancel"].resolution, undefined, "the fault precedes the resolution phase");
  assert.ok(faults.ledgerBodies.every(body => JSON.parse(body).intents[h.value.intentId].status !== "rejected"));
  assert.equal(readFileSync(ledger.statePath, "utf8"), faults.ledgerBodies.at(-1));
});

test("durability manifest: place acknowledgement headroom throw is published with no downgrade rename", async t => {
  const h = realPublicationApp(t, "place"), ledger = h.app.ledger;
  const faults = storageFaults(t, ledger.root, "none", "none");
  let fired = 0, body, error, renames;
  t.mock.method(console, "warn", message => {
    if (JSON.parse(message).event === "ledger_headroom_warning" && !fired) {
      fired++; body = readFileSync(ledger.statePath, "utf8"); renames = faults.ledgerBodies.length;
      throw error = new Error("synthetic headroom logger failure");
    }
  });
  h.broker.afterPlace = count => { if (count === 2) h.state.padding = "x".repeat(13 * 1024 * 1024); };
  assert.equal((await request(h.app, "POST", "/v1/intents", h.value)).status, 500);
  assert.equal(fired, 1);
  assert.equal(error.published, true);
  assert.equal(readFileSync(ledger.statePath, "utf8"), body);
  assert.equal(faults.ledgerBodies.length, renames);
  assert.equal(JSON.parse(body).placements.at(-1).status, "submitted");
  assert.equal(JSON.parse(body).intents[h.value.intentId].status, "claimed");
  assert.equal(h.broker.placed.length, 2);
});

test("durability manifest: placing close throw cannot replace a saved acknowledgement", async t => {
  const h = realPublicationApp(t, "place"), ledger = h.app.ledger;
  let fired = 0;
  h.broker.onSnapshot = session => {
    if (session.api.clientId === 705) {
      const close = session.close;
      session.close = () => { close(); if (!fired) { fired++; throw new Error("synthetic close failure"); } };
    }
  };
  const faults = storageFaults(t, ledger.root, "none", "none");
  assert.equal((await request(h.app, "POST", "/v1/intents", h.value)).status, 200);
  assert.equal(fired, 1);
  assert.equal(JSON.parse(faults.ledgerBodies.at(-1)).intents[h.value.intentId].status, "done");
  assert.ok(faults.ledgerBodies.every(body => !["uncertain", "rejected"].includes(JSON.parse(body).placements.at(-1)?.status)));
  assert.equal(readFileSync(ledger.statePath, "utf8"), faults.ledgerBodies.at(-1));
});

for (const noAck of [false, true]) test(`durability manifest: modify-stop listener cleanup throw / noAck=${noAck}`, async t => {
  const h = realPublicationApp(t, "modify-stop", { noAck }), ledger = h.app.ledger;
  let fired = 0;
  h.broker.afterPlace = () => {};
  h.broker.onSnapshot = session => {
    const off = session.api.off;
    session.api.off = function(event, listener) {
      const result = off.call(this, event, listener);
      if (event === events.openOrder && h.broker.placed.length && !fired) { fired++; throw new Error("synthetic listener cleanup failure"); }
      return result;
    };
  };
  const faults = storageFaults(t, ledger.root, "none", "none");
  assert.equal((await request(h.app, "POST", "/v1/intents", h.value)).status, noAck ? 409 : 200, h.lastError?.stack);
  assert.equal(fired, 1);
  const disk = JSON.parse(readFileSync(ledger.statePath));
  assert.equal(disk.placements[0].stopHistory.at(-1).status, noAck ? "uncertain" : "submitted");
  assert.equal(disk.intents[h.value.intentId].status, noAck ? "uncertain" : "done");
  assert.equal(readFileSync(ledger.statePath, "utf8"), faults.ledgerBodies.at(-1));
  assert.ok(faults.ledgerBodies.every(body => JSON.parse(body).placements[0].stopHistory?.at(-1)?.status !== "rejected"));
});

for (const phase of ["init audit", "migration headroom", "loaded headroom"]) test(`durability manifest: ${phase} never arms a capture outage after visible ledger`, async t => {
  t.mock.method(console, "error", () => {});
  const root = temporary(t), app = createExecutor({ testMode: true, stateDir: root, listenHost: "127.0.0.1", listenPort: 0,
    allowlist: ["127.0.0.1"], mailboxSocket: "", beforePrune() {} });
  t.after(() => app.close().catch(() => {}));
  const ledger = app.ledger;
  if (phase !== "init audit") {
    ledger.load();
    const state = JSON.parse(readFileSync(ledger.statePath));
    state.padding = "x".repeat(13 * 1024 * 1024);
    if (phase === "migration headroom") delete state.reconStorageVersion;
    fs.writeFileSync(ledger.statePath, JSON.stringify(state));
  }
  const faults = storageFaults(t, root, phase === "init audit" ? "writeFileSync" : "none", "none", "audit.jsonl", { once: true });
  let warnings = 0;
  if (phase !== "init audit") t.mock.method(console, "warn", () => { if (!warnings++) throw new Error("synthetic headroom failure"); });
  await app.initializeCapture();
  assert.equal(phase === "init audit" ? faults.counts.preErrors : warnings, 1);
  const bytes = readFileSync(ledger.statePath, "utf8"), count = faults.ledgerBodies.length;
  assert.equal(readState(ledger).resultsCapture, undefined);
  assert.equal(ledger.captureDiagnostics().persisted, true);
  assert.equal(readFileSync(ledger.statePath, "utf8"), bytes);
  assert.equal(faults.ledgerBodies.length, count, "initialization must not compensate with another rename");
  ledger.save(readState(ledger));
  const disk = JSON.parse(readFileSync(ledger.statePath));
  assert.equal(disk.resultsCapture, undefined);
  assert.deepEqual(disk.resultsCaptureAlerts ?? [], []);
});

test("durability manifest: modify-stop pre-send refusal after onPlan rejects the reservation", async t => {
  const h = realPublicationApp(t, "modify-stop"), ledger = h.app.ledger;
  const faults = storageFaults(t, ledger.root, "none", "none");
  const rename = fs.renameSync;
  let fired = 0;
  t.mock.method(fs, "renameSync", (from, to) => {
    const result = rename(from, to);
    if (to === ledger.statePath && !fired && JSON.parse(readFileSync(to)).placements[0].stopHistory?.at(-1)?.status === "reserved") {
      fired++;
      // The broker's final preflight rechecks this live order after onPlan.
      h.broker.sessions.at(-1).state.openOrders.find(row => row.orderId === 21).status = "Cancelled";
    }
    return result;
  });
  syncBuiltinESMExports();
  assert.equal((await request(h.app, "POST", "/v1/intents", h.value)).status, 422);
  assert.equal(fired, 1, h.lastError?.stack);
  assert.equal(h.broker.placed.length, 0);
  const disk = JSON.parse(readFileSync(ledger.statePath));
  assert.equal(disk.placements[0].stopHistory.at(-1).status, "rejected");
  assert.equal(disk.intents[h.value.intentId].status, "rejected");
  assert.equal(readFileSync(ledger.statePath, "utf8"), faults.ledgerBodies.at(-1));
});

test("durability manifest: broker send without acknowledgement publishes uncertain", async t => {
  const h = realPublicationApp(t, "place", { noAck: true }), ledger = h.app.ledger;
  const faults = storageFaults(t, ledger.root, "none", "none");
  assert.equal((await request(h.app, "POST", "/v1/intents", h.value)).status, 409, h.lastError?.stack);
  assert.equal(h.broker.placed.length, 2, "the no-ack fault was reached after both sends");
  const disk = JSON.parse(readFileSync(ledger.statePath));
  assert.equal(disk.placements.at(-1).status, "uncertain");
  assert.equal(disk.intents[h.value.intentId].status, "uncertain");
  assert.equal(readFileSync(ledger.statePath, "utf8"), faults.ledgerBodies.at(-1));
});

test("durability manifest: capture hook fault persists the trading transition degraded", async t => {
  const h = harness(), value = intent("place");
  let fired = 0;
  const app = publicationApp(t, { beforePrune(state) {
    if (state.intents.get(value.intentId)?.status === "done" && !fired) { fired++; throw { code: "EIO" }; }
  },
    execute: (value, state, context) => executeIntent(value, state, context, h.runtime) });
  const faults = storageFaults(t, app.ledger.root, "none", "none");
  assert.equal((await request(app, "POST", "/v1/intents", value)).status, 200);
  assert.equal(fired, 1);
  const disk = JSON.parse(readFileSync(app.ledger.statePath));
  assert.equal(disk.intents[value.intentId].status, "done");
  assert.equal(disk.placements.at(-1).status, "submitted");
  assert.equal(disk.resultsCapture.ok, false);
  assert.equal(disk.resultsCaptureAlerts.length, 1);
  assert.equal(readFileSync(app.ledger.statePath, "utf8"), faults.ledgerBodies.at(-1));
});

test("durability manifest: second FX date append EIO retains journal prefix and trading ledger", t => {
  t.mock.method(console, "error", () => {});
  const root = temporary(t), filename = path.join(root, "results-input.jsonl");
  const capture = createCapture(filename, { executorClientId: 705 }, { account: ACCOUNT,
    attribute: () => ({ desk: "j" }), executionTime: Date.parse, now: () => "2026-10-18T20:00:00.000Z" });
  t.after(() => capture.close());
  capture({ executions: [] });
  const prefix = readFileSync(filename), inode = fs.statSync(filename).ino;
  const write = fs.writeSync, truncate = t.mock.method(fs, "ftruncateSync", () => assert.fail("journal must never truncate"));
  let appends = 0, fired = 0;
  t.mock.method(fs, "writeSync", (fd, ...args) => {
    if (fs.fstatSync(fd).ino === inode && ++appends === 2) { fired++; throw Object.assign(new Error("synthetic second date"), { code: "EIO" }); }
    return write(fd, ...args);
  });
  syncBuiltinESMExports();
  t.after(() => { t.mock.restoreAll(); syncBuiltinESMExports(); });
  let sampler;
  const ledger = openLedger(root, { beforePrune: state => capture({ ...state, resultsFxSampler: sampler }) }), state = ledger.load();
  sampler = { enabled: true, reason: "missing_sample", days: {
    "2026-10-16": { samples: [] }, "2026-10-17": { samples: [] },
  } };
  state.intents.set("fx-trading-transition", { action: "cancel", status: "done", claimedAt: new Date().toISOString() });
  ledger.save(state);
  assert.equal(fired, 1);
  const visible = readFileSync(filename);
  assert.ok(visible.subarray(0, prefix.length).equals(prefix));
  assert.equal(readJournal(filename).length, readJournalFromPrefix(prefix) + 1);
  assert.deepEqual(Object.keys(readJournal(filename).at(-1).fxSampler.days), ["2026-10-16"]);
  assert.equal(JSON.parse(readFileSync(ledger.statePath)).intents["fx-trading-transition"].status, "done");
  assert.equal(JSON.parse(readFileSync(ledger.statePath)).resultsFxSampler, undefined, "FX input stays outside the trading ledger");
  assert.equal(readState(ledger).resultsCapture.ok, false);
  ledger.save(readState(ledger));
  assert.deepEqual(readFileSync(filename), visible, "poisoned journal keeps its complete first date and never retries an append");
  assert.equal(truncate.mock.callCount(), 0);
});

function readJournalFromPrefix(bytes) { return bytes.toString("utf8").trim().split("\n").length; }

test("durability manifest: delivery POST lost reply preserves trading bytes and deduplicates key", async t => {
  let failing = true;
  const app = publicationApp(t, { beforePrune() { if (failing) throw { code: "EIO" }; } }), ledger = app.ledger;
  const state = readState(ledger);
  state.intents.set("delivery-trade", { action: "cancel", status: "done", claimedAt: new Date().toISOString() });
  state.placements.push({ desk: "j", symbol: "AAPL", status: "submitted", reservedAt: new Date().toISOString() });
  ledger.save(state);
  const trading = body => JSON.stringify({ intents: body.intents, placements: body.placements });
  const bytes = trading(JSON.parse(readFileSync(ledger.statePath)));
  failing = false;
  const mailbox = createMailbox({ stateDir: temporary(t), localSocketPath: MAILBOX_SOCKET_PATH, log() {} });
  t.after(() => mailbox.close());
  let fired = 0;
  const faults = storageFaults(t, ledger.root, "none", "none");
  await deliveryClock(t, mailbox, { loseReply: () => { if (!fired) { fired++; return true; } return false; },
    onPost() { assert.ok(readState(ledger).resultsCaptureAlerts[0].delivery.failure.attempts >= 1); } })(ledger);
  assert.equal(fired, 1);
  assert.equal(mailbox.mailbox.messages("amy").length, 1);
  assert.ok(faults.ledgerBodies.every(body => trading(JSON.parse(body)) === bytes));
  assert.equal(trading(JSON.parse(readFileSync(ledger.statePath))), bytes);
});

for (const phase of ["pre-claim", "pre-send"]) test(`durability manifest: ${phase} fault never calls broker`, async t => {
  const h = realPublicationApp(t, "place"), ledger = h.app.ledger;
  const faults = storageFaults(t, ledger.root, "renameSync", "none", "ledger.json", {
    once: true, when: () => phase === "pre-claim" || h.executed === 1,
  });
  const before = readFileSync(ledger.statePath, "utf8");
  assert.equal((await request(h.app, "POST", "/v1/intents", h.value)).status, phase === "pre-claim" ? 500 : 422);
  assert.equal(faults.counts.preErrors, 1);
  assert.equal(h.broker.placed.length, 0);
  if (phase === "pre-claim") {
    assert.equal(readFileSync(ledger.statePath, "utf8"), before);
    assert.equal(faults.ledgerBodies.length, 0);
    assert.equal(h.executed, 0);
    const state = readState(ledger);
    state.intents.set(h.value.intentId, { action: "place", status: "claimed", hash: digest(h.value), claimedAt: new Date().toISOString() });
    ledger.save(state);
    const claimed = readFileSync(ledger.statePath, "utf8"), renames = faults.ledgerBodies.length;
    assert.equal((await request(h.app, "POST", "/v1/intents", h.value)).status, 409);
    assert.equal((await request(h.app, "POST", "/v1/intents", { ...h.value, order: { ...h.value.order, limitPrice: 101 } })).status, 409);
    assert.equal(readFileSync(ledger.statePath, "utf8"), claimed);
    assert.equal(faults.ledgerBodies.length, renames);
    assert.equal(h.executed, 0);
  } else assert.equal(JSON.parse(readFileSync(ledger.statePath)).intents[h.value.intentId].status, "rejected");
});

for (const source of ["alertForeign", "console.warn", "diagnostic logger"]) test(`durability manifest: ${source} throw after attribution receipt preserves broker success`, async t => {
  const h = harness(), value = intent("place");
  let session, fired = 0;
  h.broker.onSnapshot = current => { if (current.api.clientId === 705) session = current; };
  h.broker.afterPlace = count => {
    if (count === 2) session.state.executions.push({ contract: contract("AMD", 2), execution: fill({
      execId: "alert-suffix.01", orderRef: "", clientId: 28, time: new Date().toISOString(),
    }).execution });
  };
  const fail = () => { fired++; throw new Error("synthetic diagnostic failure"); };
  const app = publicationApp(t, { beforePrune() {},
    ...(source === "console.warn" ? {} : { alertForeign: fail }),
    execute: (value, state, context) => executeIntent(value, state, context, h.runtime) });
  if (source === "console.warn") t.mock.method(console, "warn", fail);
  if (source === "diagnostic logger") t.mock.method(console, "error", () => { throw new Error("synthetic logger failure"); });
  const ledger = app.ledger, faults = storageFaults(t, ledger.root, "none", "none");
  const response = await request(app, "POST", "/v1/intents", value);
  assert.equal(fired, 1);
  assert.equal(response.status, 200);
  const disk = JSON.parse(readFileSync(ledger.statePath));
  assert.equal(disk.placements.at(-1).status, "submitted");
  assert.equal(disk.intents[value.intentId].status, "done");
  assert.equal(disk.foreignAlerts.length, 1);
  const firstReceipt = faults.ledgerBodies.findIndex(body => JSON.parse(body).foreignAlerts?.length === 1);
  assert.ok(firstReceipt >= 0);
  assert.ok(faults.ledgerBodies.slice(firstReceipt).every(body => JSON.parse(body).placements.at(-1).status === "submitted"));
  const bytes = readFileSync(ledger.statePath, "utf8"), renames = faults.ledgerBodies.length;
  assert.equal((await request(app, "POST", "/v1/intents", value)).body.idempotentReplay, true);
  assert.equal(readFileSync(ledger.statePath, "utf8"), bytes);
  assert.equal(faults.ledgerBodies.length, renames);
  assert.equal(fired, 1, "receipt prevents a second failed emit on replay");
});

test("durability manifest: real claim directory fsync EIO fails closed and retries 409", async t => {
  const h = realPublicationApp(t, "place"), ledger = h.app.ledger;
  const faults = storageFaults(t, ledger.root, "none", "directory-fsync", "ledger.json", { once: true });
  assert.equal((await request(h.app, "POST", "/v1/intents", h.value)).status, 500);
  assert.equal(faults.counts.postErrors, 1);
  assert.equal(faults.ledgerBodies.length, 1);
  assert.equal(JSON.parse(faults.faultBody).intents[h.value.intentId].status, "claimed");
  assert.equal(readFileSync(ledger.statePath, "utf8"), faults.faultBody);
  assert.equal((await request(h.app, "POST", "/v1/intents", h.value)).status, 409);
  assert.equal(faults.ledgerBodies.length, 1);
  assert.equal(readFileSync(ledger.statePath, "utf8"), faults.faultBody);
  assert.equal(h.executed, 0);
  assert.equal(h.broker.placed.length, 0);
});

test("durability manifest: evidence directory fsync EIO recovers at cap with matching hashes", async t => {
  t.mock.method(console, "warn", () => {});
  let failing = true;
  const app = publicationApp(t, { beforePrune() { if (failing) throw { code: "EIO" }; } }), ledger = app.ledger;
  const state = readState(ledger);
  addRecons(state, { atCap: true });
  const expected = new Map([...state.intents].map(([id, row]) => [id, digest(row.result)]));
  ledger.save(state);
  const original = readFileSync(ledger.statePath, "utf8");
  assert.ok(Buffer.byteLength(original) >= CAPTURE_DEGRADED_ADMISSION_BYTES);
  const outage = state.resultsCaptureAlerts[0].outageId;
  failing = false;
  const faults = storageFaults(t, ledger.root, "none", "directory-fsync", "recon-evidence.jsonl", { once: true });
  ledger.save(state);
  assert.equal(faults.counts.postErrors, 1);
  assert.equal(faults.ledgerBodies.length, 1, "evidence warning allows exactly the forward recovered-ledger save");
  assert.equal(state.resultsCapture.ok, true);
  assert.equal(state.resultsCaptureAlerts.length, 1);
  assert.equal(state.resultsCaptureAlerts[0].outageId, outage);
  assert.ok(state.resultsCaptureAlerts[0].resolvedAt);
  assertReceipts(state);
  for (const file of [ledger.reconEvidencePath, `${ledger.reconEvidencePath}.1`]) {
    for (const row of readFileSync(file, "utf8").trim().split("\n").filter(Boolean).map(line => JSON.parse(line))) {
      assert.equal(digest(row.result), expected.get(row.intentId));
      assert.equal(row.resultSha256, expected.get(row.intentId));
      assert.equal(state.intents.get(row.intentId).result.resultSha256, expected.get(row.intentId));
    }
  }
  const bytes = readFileSync(ledger.statePath, "utf8");
  assert.equal(bytes, faults.ledgerBodies[0]);
  assert.ok(Buffer.byteLength(bytes) < CAPTURE_DEGRADED_ADMISSION_BYTES);
  assert.doesNotThrow(() => admitIntent(readState(ledger), "place", { beforePrune() {} }));
  assert.equal(readFileSync(ledger.statePath, "utf8"), bytes);
  assert.equal(faults.ledgerBodies.length, 1);
});

test("durability manifest: recovery directory fsync EIO preserves outage identity and one resolution", async t => {
  let failing = true;
  const app = publicationApp(t, { beforePrune() { if (failing) throw { code: "EIO" }; } }), ledger = app.ledger;
  ledger.save(readState(ledger));
  const outage = readState(ledger).resultsCaptureAlerts[0].outageId;
  failing = false;
  const faults = storageFaults(t, ledger.root, "none", "directory-fsync", "ledger.json", { once: true });
  assert.throws(() => ledger.save(readState(ledger)), { published: true, code: "EIO" });
  assert.equal(faults.counts.postErrors, 1);
  const disk = JSON.parse(faults.faultBody), resolvedAt = disk.resultsCaptureAlerts[0].resolvedAt;
  assert.equal(disk.resultsCapture.ok, true);
  assert.equal(disk.resultsCaptureAlerts[0].outageId, outage);
  assert.ok(resolvedAt);
  ledger.noteCaptureFailure(faults.error);
  assert.equal(readState(ledger).resultsCaptureAlerts.length, 1);
  assert.equal(readState(ledger).resultsCaptureAlerts[0].resolvedAt, resolvedAt);
  assert.equal(readFileSync(ledger.statePath, "utf8"), faults.faultBody);
  assert.equal(faults.ledgerBodies.length, 1);
  const mailbox = createMailbox({ stateDir: temporary(t), localSocketPath: MAILBOX_SOCKET_PATH, log() {} });
  t.after(() => mailbox.close());
  await deliveryClock(t, mailbox)(ledger);
  const messages = mailbox.mailbox.messages("amy").map(row => JSON.parse(row.body));
  assert.equal(messages.filter(row => row.event === "results_capture_resolved").length, 1);
  assert.equal(readState(ledger).resultsCaptureAlerts[0].resolvedAt, resolvedAt);
  assert.equal(readState(ledger).resultsCaptureAlerts[0].outageId, outage);
});

test("durability manifest: migration backup and archived evidence retain source hashes", t => {
  const root = temporary(t), ledger = openLedger(root, { beforePrune() {} });
  ledger.load();
  const legacy = JSON.parse(readFileSync(ledger.statePath)), state = readState(ledger);
  addRecons(state);
  legacy.intents = Object.fromEntries(state.intents);
  delete legacy.reconStorageVersion;
  const original = JSON.stringify(legacy), expected = new Map([...state.intents].map(([id, row]) => [id, digest(row.result)]));
  fs.writeFileSync(ledger.statePath, original);
  const faults = storageFaults(t, root, "none", "directory-fsync", "ledger.pre-ops331.json", { once: true });
  const migrated = ledger.load();
  assert.equal(faults.counts.postErrors, 1);
  assert.equal(hash(readFileSync(ledger.backupPath, "utf8")), hash(original));
  assert.equal(readFileSync(ledger.backupPath, "utf8"), original);
  for (const row of readFileSync(ledger.reconEvidencePath, "utf8").trim().split("\n").map(line => JSON.parse(line))) {
    assert.equal(digest(row.result), expected.get(row.intentId));
    assert.equal(migrated.intents.get(row.intentId).result.resultSha256, expected.get(row.intentId));
  }
  assert.equal(faults.ledgerBodies.length, 1);
  const bytes = readFileSync(ledger.statePath, "utf8");
  ledger.load();
  assert.equal(readFileSync(ledger.statePath, "utf8"), bytes);
  assert.equal(faults.ledgerBodies.length, 1);
});
