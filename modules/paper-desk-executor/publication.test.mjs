import "../../tests/paper-desk-account-fixture.mjs";
import assert from "node:assert/strict";
import fs, { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import { setImmediate } from "node:timers/promises";
import test from "node:test";
import { createServer as createMailbox } from "../agent-mailbox/server.mjs";
import { createServer as createExecutor } from "./server.mjs";
import { mailboxHttpRequest } from "../../tests/local-mailbox-fixture.mjs";
import { createAlertDelivery, deliveryHealth, postLocalMessage } from "./mailbox-alerts.mjs";
import { MAILBOX_SOCKET_PATH } from "./local-mailbox-client.mjs";
import { admitIntent, CAPTURE_DEGRADED_ADMISSION_BYTES, openLedger } from "./state.mjs";

function temporary(t) {
  const root = mkdtempSync(path.join(tmpdir(), "joed43-publication-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
}
const readState = ledger => ledger.load({ initialize: false, readOnly: true, migrate: false });
const diagnostics = state => ({ resultsCapture: state.resultsCapture, resultsCaptureAlerts: state.resultsCaptureAlerts });

// Paths are constructed from this test's mkdtemp, never from ledger output.
function storageFaults(t, root, pre, post, target = "ledger.json") {
  const statePath = path.join(root, target), directories = new Set();
  const originals = Object.fromEntries(["openSync", "closeSync", "fsyncSync", "renameSync", "linkSync", "unlinkSync"].map(name => [name, fs[name]]));
  let enabled = true, published = false, publications = 0, preErrors = 0, postErrors = 0, conflicts = 0;
  const failure = () => Object.assign(new Error("synthetic-private-value /synthetic/path"), { code: "EIO" });
  for (const name of ["renameSync", "linkSync"]) t.mock.method(fs, name, (from, to) => {
    if (enabled && to === statePath && pre === name) { preErrors++; throw failure(); }
    let result;
    try { result = originals[name](from, to); }
    catch (error) { if (to === statePath && error.code === "EEXIST") conflicts++; throw error; }
    published = to === statePath;
    if (published) publications++;
    return result;
  });
  t.mock.method(fs, "openSync", (file, flags, ...args) => {
    if (enabled && published && file === root && post === "directory-open") { postErrors++; throw failure(); }
    const fd = originals.openSync(file, flags, ...args);
    if (published && file === root && (flags & fs.constants.O_DIRECTORY)) directories.add(fd);
    return fd;
  });
  t.mock.method(fs, "closeSync", fd => {
    const directory = directories.delete(fd);
    const result = originals.closeSync(fd);
    if (directory) published = false;
    if (enabled && directory && post === "directory-close") { postErrors++; throw failure(); }
    return result;
  });
  t.mock.method(fs, "fsyncSync", fd => {
    if (enabled && published && post === "directory-fsync" && directories.has(fd)) { postErrors++; throw failure(); }
    return originals.fsyncSync(fd);
  });
  t.mock.method(fs, "unlinkSync", file => {
    if (enabled && published && post === "temporary-cleanup" && String(file).startsWith(`${statePath}.`)) { postErrors++; throw failure(); }
    return originals.unlinkSync(file);
  });
  syncBuiltinESMExports();
  t.after(() => { t.mock.restoreAll(); syncBuiltinESMExports(); });
  return { restore() { enabled = false; }, get counts() { return { publications, preErrors, postErrors, conflicts }; } };
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
