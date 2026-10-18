import "../../tests/paper-desk-account-fixture.mjs";
import assert from "node:assert/strict";
import fs, { existsSync, mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { admitIntent, openLedger, pruneState, RETENTION_MS } from "./state.mjs";
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
  const state = { intents: new Map(), firstOrders: new Map(), placements: [], executions: [] };
  const now = Date.now();
  const fail = (code, time = now) => pruneState(state, time, { beforePrune: () => { throw { code, message: "synthetic-private-value" }; } });
  for (const code of ["ENOSPC", "ENOSPC", "EIO", "EIO", "synthetic-private-value", "synthetic-private-value", "ENOSPC"]) fail(code);
  assert.equal(logs.mock.callCount(), 4);
  assert.equal(state.resultsCapture.count, 7);
  assert.deepEqual(state.resultsCaptureAlerts.map(row => [row.code, row.count]), [["ENOSPC", 3], ["EIO", 2], ["unavailable", 2]]);
  assert.equal(JSON.stringify([state.resultsCapture, state.resultsCaptureAlerts, logs.mock.calls]).includes("synthetic-private-value"), false);
  fail("ENOSPC", now + RETENTION_MS + 1);
  assert.deepEqual(state.resultsCaptureAlerts.map(row => row.code), ["ENOSPC"]);
  // A broken logger is also unable to block the intent path.
  logs.mock.mockImplementation(() => { throw new Error("logging unavailable"); });
  fail("EIO", now + RETENTION_MS + 2);
  pruneState(state, now + 2 * RETENTION_MS + 3, { beforePrune: () => {} });
  assert.equal(state.resultsCapture.ok, true);
  assert.deepEqual(state.resultsCaptureAlerts, []);
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
  assert.equal(loaded.resultsCapture.ok, true);
  assert.equal(loaded.intents.get("expired-recon").result.resultCompacted, true);
  assert.deepEqual(JSON.parse(readFileSync(ledger.backupPath)).intents, legacy.intents);
  ledger.save(loaded);
  assert.equal(loaded.intents.size, 0);
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
