import "../../tests/paper-desk-account-fixture.mjs";
import assert from "node:assert/strict";
import fs, { existsSync, mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { admitIntent, openLedger, pruneState, RETENTION_MS, MAX_STATE_BYTES, CAPTURE_DEGRADED_ADMISSION_BYTES } from "./state.mjs";
import { createCapture } from "../joe-results-producer/capture.mjs";
import { hash, readJournal } from "../joe-results-producer/journal.mjs";

const start = "2026-10-16T10:00:00.000Z";
const at = "2026-10-16T14:00:00.000Z";
const config = { executorClientId: 705, foreignAlertSince: start };
const dependencies = { account: "synthetic-account", attribute: () => ({ desk: "j" }), executionTime: Date.parse, now: () => at };

function evidence(state) {
  const old = new Date(Date.now() - RETENTION_MS - 86400000).toISOString();
  state.intents.set("expired-recon", { action: "recon", status: "done", finishedAt: old,
    result: { status: "ok", executions: [{ evidence: "synthetic-recon-evidence" }] } });
  state.placements.push({ desk: "j", symbol: "ACME", status: "filled", reservedAt: old });
  state.executions.push({ contract: { conId: 123, symbol: "ACME", currency: "EUR" }, execution: {
    execId: "synthetic-fill.01", acctNumber: dependencies.account, clientId: 705,
    time: "2026-10-16T12:00:00.000Z", side: "BOT", shares: "1", price: "10",
  } });
}

for (const mode of ["invalid-date", "missing-execId", "ENOSPC", "EIO"]) {
  test(`capture ${mode} fails open at admission/save and recovers before catch-up pruning`, t => {
    const logs = t.mock.method(console, "error", () => {});
    const root = mkdtempSync(path.join(tmpdir(), "joed43-capture-"));
    const filename = path.join(root, "results-input.jsonl");
    let capture = createCapture(filename, config, dependencies), failing = true;
    t.after(() => capture.close());
    // Initialize before injecting a write/fsync error, so the failure occurs
    // in the real journal append, rather than initial directory creation.
    capture({ executions: [] });
    const journalInode = statSync(filename).ino;
    const operation = mode === "ENOSPC" ? "writeSync" : "fsyncSync";
    if (["ENOSPC", "EIO"].includes(mode)) {
      const original = fs[operation];
      t.mock.method(fs, operation, (fd, ...args) => {
        if (failing && fs.fstatSync(fd).ino === journalInode) throw Object.assign(new Error("synthetic-private-value"), { code: mode });
        return original(fd, ...args);
      });
      syncBuiltinESMExports();
      t.after(() => { t.mock.restoreAll(); syncBuiltinESMExports(); });
    }
    const ledger = openLedger(root, { beforePrune: state => capture({ ...state,
      ...(failing && mode === "invalid-date" ? { resultsFxSampler: { days: { "invalid-date": { samples: [] } } } } : {}),
    }) });
    const state = ledger.load();
    evidence(state);
    if (mode === "missing-execId") delete state.executions[0].execution.execId;
    const retained = structuredClone({ intents: state.intents, placements: state.placements, executions: state.executions });
    const code = ["ENOSPC", "EIO"].includes(mode) ? mode : "unavailable";
    // The real journal intentionally latches an I/O failure until reopened.
    // Reopen between attempts to exercise the same class without erasing it.
    function reopen() { capture.close(); capture = createCapture(filename, config, dependencies); }
    admitIntent(state, "place", { beforePrune: ledger.beforePrune });
    if (["ENOSPC", "EIO"].includes(mode)) reopen();
    admitIntent(state, "recon", { beforePrune: ledger.beforePrune });
    if (["ENOSPC", "EIO"].includes(mode)) reopen();
    ledger.save(state);
    const disk = JSON.parse(readFileSync(ledger.statePath));
    assert.deepEqual(state.intents, retained.intents);
    assert.deepEqual(disk.intents, Object.fromEntries(retained.intents));
    assert.deepEqual(disk.placements, retained.placements);
    assert.deepEqual(disk.executions, retained.executions);
    assert.equal(existsSync(ledger.reconEvidencePath), false);
    assert.deepEqual(disk.resultsCapture, { ok: false, since: state.resultsCapture.since,
      lastErrorAt: state.resultsCapture.lastErrorAt, code, count: 3 });
    assert.equal(disk.resultsCaptureAlerts.length, 1);
    assert.equal(disk.resultsCaptureAlerts[0].code, code);
    assert.equal(disk.resultsCaptureAlerts[0].count, 3);
    assert.equal(logs.mock.callCount(), 1);
    assert.equal(JSON.stringify([disk.resultsCapture, disk.resultsCaptureAlerts, logs.mock.calls]).includes("synthetic-private-value"), false);
    const failedBytes = statSync(ledger.statePath).size;
    // Restart during the outage: diagnostics survive, and another failure of
    // the same class produces no additional transition log.
    const restarted = ledger.load({ readOnly: true });
    assert.deepEqual(restarted.resultsCapture, disk.resultsCapture);
    if (["ENOSPC", "EIO"].includes(mode)) reopen();
    ledger.save(restarted);
    assert.equal(restarted.resultsCapture.count, 4);
    assert.equal(logs.mock.callCount(), 1);
    failing = false;
    reopen();
    if (mode === "missing-execId") restarted.executions[0].execution.execId = "synthetic-fill.01";
    ledger.save(restarted);
    assert.equal(restarted.resultsCapture.ok, true);
    assert.ok(restarted.resultsCaptureAlerts.every(row => row.resolvedAt));
    assert.ok(Number.isFinite(Date.parse(restarted.resultsCapture.lastRecoveredAt)));
    assert.equal(restarted.intents.has("expired-recon"), false);
    assert.deepEqual(restarted.placements, []);
    assert.ok(statSync(ledger.statePath).size < failedBytes);
    assert.equal(readJournal(filename).flatMap(row => row.fills || []).some(fill => fill.key === hash("synthetic-fill.")), true);
    assert.match(readFileSync(ledger.reconEvidencePath, "utf8"), /synthetic-recon-evidence/);
    assert.equal(logs.mock.callCount(), 1);
  });
}

test("failure class transitions are value-free, deduplicated, bounded and retained like foreign alerts", t => {
  const logs = t.mock.method(console, "error", () => {});
  let saveCode;
  const ledger = openLedger(mkdtempSync(path.join(tmpdir(), "joed43-classes-")), { beforePrune: () => {
    if (saveCode) throw { code: saveCode, message: "synthetic-private-value" };
  } });
  const state = ledger.load();
  const now = Date.now();
  const fail = (code, time = now) => pruneState(state, time, { beforePrune: () => { throw { code, message: "synthetic-private-value" }; } });
  for (const code of ["ENOSPC", "ENOSPC", "EIO", "EIO", "synthetic-private-value", "synthetic-private-value", "ENOSPC"]) fail(code);
  assert.equal(logs.mock.callCount(), 3);
  assert.equal(state.resultsCapture.count, 7);
  assert.deepEqual(state.resultsCaptureAlerts.map(row => [row.code, row.count]), [["ENOSPC", 3], ["EIO", 2], ["unavailable", 2]]);
  // Repeated saves and alternating classes never re-alert during one outage.
  for (let i = 0; i < 60; i++) {
    saveCode = ["ENOSPC", "EIO", "synthetic-private-value"][i % 3];
    ledger.save(state);
  }
  saveCode = undefined;
  assert.equal(logs.mock.callCount(), 3);
  assert.equal(state.resultsCapture.count, 67);
  assert.equal(JSON.stringify([state.resultsCapture, state.resultsCaptureAlerts, logs.mock.calls]).includes("synthetic-private-value"), false);
  fail("ENOSPC", now + RETENTION_MS + 1);
  assert.deepEqual(state.resultsCaptureAlerts.map(row => row.code), ["ENOSPC", "EIO", "unavailable"]);
  // A broken logger is also unable to block the intent path.
  logs.mock.mockImplementation(() => { throw new Error("logging unavailable"); });
  fail("EDQUOT", now + RETENTION_MS + 2);
  assert.equal(logs.mock.callCount(), 4);
  pruneState(state, now + 2 * RETENTION_MS + 3, { beforePrune: () => {} });
  assert.equal(state.resultsCapture.ok, false);
  ledger.save(state);
  assert.equal(state.resultsCapture.ok, true);
  assert.ok(state.resultsCaptureAlerts.every(row => row.resolvedAt));
  pruneState(state, now + 2 * RETENTION_MS + 3);
  assert.deepEqual(state.resultsCaptureAlerts, []);
  logs.mock.mockImplementation(() => {});
  fail("EIO");
  assert.equal(logs.mock.callCount(), 5);
});

test("legacy migration persists full evidence on capture failure and retries after recovery", t => {
  const logs = t.mock.method(console, "error", () => {});
  const root = mkdtempSync(path.join(tmpdir(), "joed43-migration-"));
  const initial = openLedger(root), state = initial.load();
  evidence(state);
  const legacy = { ...state, intents: Object.fromEntries(state.intents), firstOrders: {}, reconStorageVersion: undefined };
  writeFileSync(initial.statePath, JSON.stringify(legacy));
  let failing = true, captured;
  const ledger = openLedger(root, { beforePrune: value => {
    if (failing) throw Object.assign(new Error("synthetic-private-value"), { code: "EIO" });
    captured = structuredClone(value.intents.get("expired-recon").result);
  } });
  for (let attempt = 0; attempt < 2; attempt++) {
    const loaded = ledger.load();
    assert.equal(loaded.reconStorageVersion, undefined);
    assert.deepEqual(loaded.intents.get("expired-recon"), state.intents.get("expired-recon"));
    assert.deepEqual(JSON.parse(readFileSync(ledger.statePath)).intents, legacy.intents);
    assert.equal(loaded.resultsCapture.count, attempt + 1);
    assert.equal(existsSync(ledger.backupPath), false);
    assert.equal(existsSync(ledger.reconEvidencePath), false);
  }
  assert.equal(logs.mock.callCount(), 1);
  failing = false;
  const loaded = ledger.load();
  assert.deepEqual(captured, state.intents.get("expired-recon").result);
  assert.equal(loaded.reconStorageVersion, 1);
  assert.equal(loaded.resultsCapture.ok, false);
  assert.equal(loaded.intents.get("expired-recon").result.resultCompacted, true);
  assert.deepEqual(JSON.parse(readFileSync(ledger.backupPath)).intents, legacy.intents);
  ledger.save(loaded);
  assert.equal(loaded.resultsCapture.ok, true);
  assert.equal(loaded.intents.size, 0);
});

test("capture-degraded admissions refuse new placements at 90% without pruning; safety actions stay allowed", t => {
  t.mock.method(console, "error", () => {});
  t.mock.method(console, "warn", () => {});
  const beforePrune = () => { throw Object.assign(new Error("synthetic-private-value"), { code: "ENOSPC" }); };
  const ledger = openLedger(mkdtempSync(path.join(tmpdir(), "joed43-bound-")), { beforePrune });
  const state = ledger.load();
  evidence(state);
  state.intents.get("expired-recon").result.padding = "x".repeat(CAPTURE_DEGRADED_ADMISSION_BYTES + 1024);
  ledger.save(state);
  const retained = readFileSync(ledger.statePath);
  assert.ok(retained.length >= CAPTURE_DEGRADED_ADMISSION_BYTES && retained.length < MAX_STATE_BYTES);
  assert.throws(() => admitIntent(state, "place", { beforePrune }), error => {
    assert.equal(error.publicCode, "results_capture_degraded_ledger_cap");
    assert.equal(error.message, "results_capture_degraded_ledger_cap");
    return true;
  });
  for (const action of ["recon", "cancel", "flatten", "modify-stop"]) assert.doesNotThrow(() => admitIntent(state, action, { beforePrune }));
  assert.equal(state.intents.has("expired-recon"), true);
  assert.equal(state.placements.length, 1);
  assert.equal(existsSync(ledger.reconEvidencePath), false);
  assert.deepEqual(readFileSync(ledger.statePath), retained);
  state.intents.get("expired-recon").result.padding = "x".repeat(CAPTURE_DEGRADED_ADMISSION_BYTES - 4096);
  assert.doesNotThrow(() => admitIntent(state, "place", { beforePrune }));
});

test("capture success followed by failed catch-up preserves degraded health and evidence until full recovery", t => {
  const logs = t.mock.method(console, "error", () => {});
  const root = mkdtempSync(path.join(tmpdir(), "joed43-catchup-"));
  const filename = path.join(root, "results-input.jsonl");
  const capture = createCapture(filename, config, dependencies);
  t.after(() => capture.close());
  let failing = true;
  const ledger = openLedger(root, { beforePrune: state => {
    if (failing) throw Object.assign(new Error("synthetic-private-value"), { code: "ENOSPC" });
    capture(state);
  } });
  const state = ledger.load();
  evidence(state);
  state.intents.get("expired-recon").result.padding = "x".repeat(10000);
  ledger.save(state);
  const before = structuredClone(state.intents);
  const since = state.resultsCapture.since;
  const failedBytes = statSync(ledger.statePath).size;
  failing = false;
  const rename = fs.renameSync;
  let pruneFails = true;
  t.mock.method(fs, "renameSync", (from, to) => {
    if (pruneFails && to === ledger.reconEvidencePath) throw Object.assign(new Error("synthetic-private-value"), { code: "EIO" });
    return rename(from, to);
  });
  syncBuiltinESMExports();
  t.after(() => { t.mock.restoreAll(); syncBuiltinESMExports(); });
  ledger.save(state);
  // Capture committed evidence, but the catch-up archive/prune did not finish.
  assert.ok(readJournal(filename).some(row => row.fills?.length));
  assert.deepEqual(state.intents, before);
  assert.equal(state.placements.length, 1);
  assert.equal(state.resultsCapture.ok, false);
  assert.equal(state.resultsCapture.since, since);
  assert.equal(state.resultsCapture.lastRecoveredAt, undefined);
  assert.equal(state.resultsCapture.code, "EIO");
  assert.ok(state.resultsCaptureAlerts.every(row => !row.resolvedAt));
  assert.deepEqual(ledger.load({ readOnly: true }).resultsCapture, state.resultsCapture);
  // A successful admission capture+retention cannot resolve a failed save.
  const admission = structuredClone(state);
  admitIntent(admission, "place", { beforePrune: ledger.beforePrune });
  assert.equal(admission.resultsCapture.ok, false);
  assert.equal(logs.mock.callCount(), 2);
  pruneFails = false;
  ledger.save(state);
  assert.equal(state.resultsCapture.ok, true);
  assert.ok(state.resultsCapture.lastRecoveredAt);
  assert.ok(state.resultsCaptureAlerts.every(row => row.resolvedAt === state.resultsCapture.lastRecoveredAt));
  assert.equal(state.intents.size, 0);
  assert.equal(state.placements.length, 0);
  assert.ok(statSync(ledger.statePath).size < failedBytes);
  assert.match(readFileSync(ledger.reconEvidencePath, "utf8"), /synthetic-recon-evidence/);
  assert.equal(logs.mock.callCount(), 2);
  failing = true;
  ledger.save(state);
  assert.equal(logs.mock.callCount(), 3);
  assert.equal(state.resultsCaptureAlerts.find(row => row.code === "ENOSPC").resolvedAt, undefined);
});

test("capture disabled preserves ledger bytes and failing capture preserves admission limits", t => {
  t.mock.method(console, "error", () => {});
  const root = mkdtempSync(path.join(tmpdir(), "joed43-off-"));
  const control = openLedger(root, { beforePrune: () => {} });
  const state = control.load();
  evidence(state);
  const offRoot = mkdtempSync(path.join(tmpdir(), "joed43-off-"));
  const off = openLedger(offRoot);
  // Feed the exact same initialized state through the previous no-op-hook
  // behavior and capture disabled, including recon compaction and retention.
  control.save(structuredClone(state));
  off.save(structuredClone(state));
  assert.deepEqual(readFileSync(off.statePath), readFileSync(control.statePath));
  assert.equal(readFileSync(off.statePath, "utf8").includes("resultsCapture"), false);
  assert.deepEqual(readFileSync(off.reconEvidencePath), readFileSync(control.reconEvidencePath));
  const plain = { ...state, intents: Object.fromEntries(state.intents) };
  const fail = () => { throw new Error("synthetic-failure"); };
  admitIntent(plain, "place", { beforePrune: fail });
  assert.deepEqual(plain.intents, state.intents);
  state.intents = new Map(Array.from({ length: 5000 }, (_, i) => [`synthetic-${i}`, { action: "place", status: "uncertain" }]));
  assert.throws(() => admitIntent(state, "place", { beforePrune: fail }), /ledger capacity reached/);
  assert.equal(state.intents.size, 5000);
  assert.equal(state.resultsCapture.ok, false);
});

test("capture and catch-up preserve live placement, claim and stop-change identities across saves", t => {
  t.mock.method(console, "error", () => {});
  let failing = false;
  const ledger = openLedger(mkdtempSync(path.join(tmpdir(), "joed43-live-")), { beforePrune: () => {
    if (failing) throw { code: "EIO" };
  } });
  const state = ledger.load();
  const change = { status: "reserved" };
  const placement = { desk: "j", symbol: "ACME", status: "reserved", reservedAt: new Date().toISOString(), stopHistory: [change] };
  const claim = { action: "modify-stop", status: "claimed", claimedAt: new Date().toISOString(), modification: change };
  state.placements.push(placement);
  state.intents.set("synthetic-live-change", claim);
  for (const failed of [false, true, false]) {
    failing = failed;
    ledger.save(state);
    assert.equal(state.placements[0], placement);
    assert.equal(state.intents.get("synthetic-live-change"), claim);
    assert.equal(state.placements[0].stopHistory[0], change);
  }
  placement.status = "submitted";
  change.status = "submitted";
  ledger.save(state);
  const disk = JSON.parse(readFileSync(ledger.statePath));
  assert.equal(disk.placements[0].status, "submitted");
  assert.equal(disk.placements[0].stopHistory[0].status, "submitted");
  assert.equal(disk.intents["synthetic-live-change"].modification.status, "submitted");
});

test("retention-prune failure after successful capture remains degraded and preserves rows for retry", t => {
  t.mock.method(console, "error", () => {});
  let failing = true;
  const ledger = openLedger(mkdtempSync(path.join(tmpdir(), "joed43-prune-")), { beforePrune: () => {
    if (failing) throw { code: "EIO" };
  } });
  const state = ledger.load();
  evidence(state);
  ledger.save(state);
  failing = false;
  const previous = process.env.PAPER_DESK_FOREIGN_ALERT_RETENTION_DAYS;
  t.after(() => {
    if (previous === undefined) delete process.env.PAPER_DESK_FOREIGN_ALERT_RETENTION_DAYS;
    else process.env.PAPER_DESK_FOREIGN_ALERT_RETENTION_DAYS = previous;
  });
  process.env.PAPER_DESK_FOREIGN_ALERT_RETENTION_DAYS = "0";
  ledger.save(state);
  assert.equal(state.resultsCapture.ok, false);
  assert.equal(state.resultsCapture.code, "unavailable");
  assert.equal(state.resultsCapture.lastRecoveredAt, undefined);
  assert.equal(state.intents.has("expired-recon"), true);
  assert.equal(state.intents.get("expired-recon").result.resultCompacted, undefined);
  assert.equal(state.placements.length, 1);
  assert.equal(ledger.load({ readOnly: true }).resultsCapture.ok, false);
  process.env.PAPER_DESK_FOREIGN_ALERT_RETENTION_DAYS = "14";
  ledger.save(state);
  assert.equal(state.resultsCapture.ok, true);
  assert.equal(state.intents.size, 0);
  assert.equal(state.placements.length, 0);
});

test("failed ledger publication cannot clear degraded state or resolve alerts after successful catch-up", t => {
  t.mock.method(console, "error", () => {});
  let failing = true;
  const ledger = openLedger(mkdtempSync(path.join(tmpdir(), "joed43-publish-")), { beforePrune: () => {
    if (failing) throw { code: "EIO" };
  } });
  const state = ledger.load();
  evidence(state);
  ledger.save(state);
  const original = readFileSync(ledger.statePath);
  failing = false;
  const rename = fs.renameSync;
  let publicationFails = true;
  t.mock.method(fs, "renameSync", (from, to) => {
    if (publicationFails && to === ledger.statePath) throw Object.assign(new Error("synthetic-private-value"), { code: "EIO" });
    return rename(from, to);
  });
  syncBuiltinESMExports();
  t.after(() => { t.mock.restoreAll(); syncBuiltinESMExports(); });
  assert.throws(() => ledger.save(state), { code: "EIO" });
  assert.equal(state.resultsCapture.ok, false);
  assert.equal(state.resultsCapture.lastRecoveredAt, undefined);
  assert.ok(state.resultsCaptureAlerts.every(row => !row.resolvedAt));
  assert.equal(state.intents.has("expired-recon"), true);
  assert.deepEqual(readFileSync(ledger.statePath), original);
  publicationFails = false;
  ledger.save(state);
  assert.equal(state.resultsCapture.ok, true);
  assert.ok(state.resultsCaptureAlerts.every(row => row.resolvedAt));
});
