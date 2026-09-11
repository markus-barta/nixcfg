#!/usr/bin/env node
/** Synthetic-only receipt-journal tests. They do not prove report finality or contact a broker. */
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";

import * as reconciliation from "./execution-reconciliation.mjs";
import {
  RECONCILIATION_RECEIPT_JOURNAL_LIMITS,
  RECONCILIATION_RECEIPT_JOURNAL_SCHEMA,
  RECONCILIATION_RECEIPT_JOURNAL_TRUST_BOUNDARY,
  ReconciliationReceiptJournalError,
  createFileReconciliationReceiptJournal,
} from "./reconciliation-receipt-journal.mjs";
import { RETENTION_CONTRACT } from "./retention-windows.mjs";

const ACCOUNT = "SYNTHETIC-PAPER-ACCOUNT";
const PROVIDER = "synthetic-reviewed-final-provider";
const TIME_ZONE = "Europe/Vienna";
const CONFIG = {
  account: ACCOUNT,
  configuredProviderId: PROVIDER,
  configuredGatewayTimeZone: TIME_ZONE,
};
const WINDOW = {
  fromInclusive: "2026-09-09T22:00:00.000Z",
  toExclusive: "2026-09-10T22:00:00.000Z",
};
const ADAPTER = {
  adapterId: "synthetic-reviewed-final-adapter",
  adapterVersion: "1.0.0",
};
function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function canonicalJson(value) {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  return `{${Object.keys(value).sort().map((key) =>
    `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;
}

function createTemporaryDirectory() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "hostd39-receipt-journal-"));
  OWNED_TEMP_DIRECTORIES.add(directory);
  return directory;
}

function removeOwnedTree(root) {
  if (!fs.existsSync(root)) return;
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const target = path.join(root, entry.name);
    if (entry.isDirectory() && !entry.isSymbolicLink()) {
      removeOwnedTree(target);
    } else {
      fs.unlinkSync(target);
    }
  }
  fs.rmdirSync(root);
}

const OWNED_TEMP_DIRECTORIES = new Set();

after(() => {
  for (const directory of OWNED_TEMP_DIRECTORIES) removeOwnedTree(directory);
});

function temporaryTest() {
  const directory = createTemporaryDirectory();
  return { directory, filePath: path.join(directory, "receipt-journal.json") };
}

function openStore(filePath, config = CONFIG) {
  return createFileReconciliationReceiptJournal(filePath, config);
}

function writeJson(filePath, value, mode = 0o600) {
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, { mode });
  fs.chmodSync(filePath, mode);
}

function emptyState(overrides = {}) {
  return {
    schema: RECONCILIATION_RECEIPT_JOURNAL_SCHEMA,
    trustBoundary: RECONCILIATION_RECEIPT_JOURNAL_TRUST_BOUNDARY,
    account: ACCOUNT,
    configuredProviderId: PROVIDER,
    configuredGatewayTimeZone: TIME_ZONE,
    receiptSetDigest: sha256(canonicalJson([])),
    records: [],
    readiness: null,
    ...overrides,
  };
}

function socketExecution({ execId, symbol = "SYN", conId = 10_001 } = {}) {
  return {
    contract: { conId, symbol, secType: "STK", currency: "USD", multiplier: 1 },
    execution: {
      execId,
      time: "20260910 09:30:00 US/Eastern",
      acctNumber: ACCOUNT,
      clientId: 22,
      side: "BUY",
      shares: 1,
      price: 100,
      pendingPriceRevision: false,
    },
  };
}

function evidenceExecution(row) {
  return {
    execId: row.execution.execId,
    occurredAt: "2026-09-10T13:30:00.000Z",
    account: ACCOUNT,
    economics: {
      side: row.execution.side,
      shares: row.execution.shares,
      price: row.execution.price,
      currency: row.contract.currency,
      commission: 0.1,
      commissionCurrency: "USD",
    },
  };
}

function syntheticOutcome({
  execId = "synthetic.fill.001.01",
  symbol = "SYN",
  conId = 10_001,
  artifactLabel = "synthetic final artifact A",
  assertionId = `synthetic-finality-${artifactLabel}`,
  verifiedAt = "2026-09-10T22:00:04.000Z",
  priorReceipts = [],
} = {}) {
  const raw = Buffer.from(artifactLabel, "utf8");
  const row = socketExecution({ execId, symbol, conId });
  const evidence = reconciliation.validateReconciliationEvidence({
    schema: reconciliation.RECONCILIATION_EVIDENCE_SCHEMA,
    account: ACCOUNT,
    scope: "ALL_ACCOUNT",
    fromInclusive: WINDOW.fromInclusive,
    toExclusive: WINDOW.toExclusive,
    completeThrough: WINDOW.toExclusive,
    finality: {
      status: "FINAL",
      scope: "ALL_ACCOUNT",
      fromInclusive: WINDOW.fromInclusive,
      toExclusive: WINDOW.toExclusive,
      assertionId,
    },
    generatedAt: "2026-09-10T22:00:01.000Z",
    retrievedAt: "2026-09-10T22:00:03.000Z",
    correctionSemantics: "LATEST_EFFECTIVE",
    rawArtifactSha256: sha256(raw),
    ...ADAPTER,
    executions: [evidenceExecution(row)],
  }, {
    rawArtifactBytes: raw,
    allowedAdapters: [ADAPTER],
  });
  return reconciliation.reconcileExecutionWindow({
    evidence,
    socketExecutions: [row],
    socketCommissions: [{ execId, commission: 0.1, currency: "USD" }],
    account: ACCOUNT,
    window: WINDOW,
    priorReceipts,
    verifiedAt,
  });
}

function syntheticConflict(candidate, priorReceipt) {
  try {
    syntheticOutcome({ ...candidate, priorReceipts: [priorReceipt] });
  } catch (error) {
    assert.equal(error.code, "RECEIPT_OVERLAP_CONFLICT");
    return error;
  }
  assert.fail("synthetic overlap was expected to conflict");
}

function operatorBaseline() {
  return {
    schema: RETENTION_CONTRACT.stateSchema,
    status: "ready",
    baselineRequired: false,
    reason: null,
    providerId: PROVIDER,
    gatewayTimeZone: TIME_ZONE,
    evaluatedAt: "2026-09-10T21:59:30.000Z",
    observedThrough: "2026-09-10T21:59:30.000Z",
    maxReplayAgeMs: 30_000,
    reconciledWindows: [],
    unreconciledWindows: [],
    unresolvedConflictWindows: [],
    invalidatedReceiptIdsByWindow: [],
  };
}

function freshReplay({
  observedThrough = "2026-09-10T22:00:10.000Z",
  completedAt = "2026-09-10T22:00:15.000Z",
} = {}) {
  return {
    schema: RETENTION_CONTRACT.replaySchema,
    source: "raw-socket-ledger",
    calendarTimeZone: TIME_ZONE,
    windowBegin: "2026-09-10T22:00:00.000Z",
    completeness: "validated-current-window",
    knownExecutionSet: "retained",
    conflict: false,
    executionCount: 0,
    observedThrough,
    completedAt,
  };
}

const identityTest = test;

test("new store is dormant, explicitly bound, mode-safe, and single-writer", (t) => {
  const { filePath } = temporaryTest(t);
  const store = openStore(filePath);
  t.after(() => store.close());
  assert.deepEqual(store.load(), {
    ok: true,
    journal: null,
    readyForUse: false,
    needsRecomputation: true,
    reason: "receipt journal does not exist",
  });
  assert.throws(
    () => openStore(filePath),
    (error) => error instanceof ReconciliationReceiptJournalError && error.code === "SINGLE_WRITER_CONFLICT",
  );
  assert.equal(fs.statSync(`${filePath}.lock`).mode & 0o777, 0o600);
});

test("abrupt child exit leaves a fail-closed lock requiring explicit operator recovery", (t) => {
  const { filePath } = temporaryTest(t);
  const moduleUrl = new URL("./reconciliation-receipt-journal.mjs", import.meta.url).href;
  const child = spawnSync(process.execPath, [
    "--input-type=module",
    "--eval",
    `import { createFileReconciliationReceiptJournal } from ${JSON.stringify(moduleUrl)};
createFileReconciliationReceiptJournal(${JSON.stringify(filePath)}, ${JSON.stringify(CONFIG)});
process.stdout.write("locked");
process.exit(0);`,
  ], { encoding: "utf8" });
  assert.equal(child.status, 0, child.stderr);
  assert.equal(child.stdout, "locked");
  assert.equal(fs.statSync(`${filePath}.lock`).mode & 0o777, 0o600);
  assert.throws(
    () => openStore(filePath),
    (error) => error instanceof ReconciliationReceiptJournalError && error.code === "SINGLE_WRITER_CONFLICT",
  );
  assert.equal(fs.existsSync(`${filePath}.lock`), true);
});

test("strict loader rejects corrupt, unsafe, unknown, mismatched, symlinked, and oversized state", async (t) => {
  async function rejects(label, prepare, reasonPattern, config = CONFIG) {
    await t.test(label, (nested) => {
      const { directory, filePath } = temporaryTest(nested);
      prepare({ directory, filePath });
      const store = openStore(filePath, config);
      nested.after(() => store.close());
      const loaded = store.load();
      assert.equal(loaded.ok, false);
      assert.match(loaded.reason, reasonPattern);
    });
  }

  await rejects("truncated JSON", ({ filePath }) => {
    fs.writeFileSync(filePath, "{\"schema\":", { mode: 0o600 });
  }, /truncated or invalid/);
  await rejects("unknown field", ({ filePath }) => {
    writeJson(filePath, { ...emptyState(), unexpected: true });
  }, /fields are not canonical/);
  await rejects("binding mismatch", ({ filePath }) => {
    writeJson(filePath, emptyState());
  }, /binding changed/, { ...CONFIG, configuredProviderId: "different-provider" });
  await rejects("unsafe mode", ({ filePath }) => {
    writeJson(filePath, emptyState(), 0o640);
  }, /mode.*unsafe/);
  await rejects("symlink", ({ directory, filePath }) => {
    const target = path.join(directory, "target.json");
    writeJson(target, emptyState());
    fs.symlinkSync(target, filePath);
  }, /read failed/);
  await rejects("oversize", ({ filePath }) => {
    fs.writeFileSync(filePath, Buffer.alloc(RECONCILIATION_RECEIPT_JOURNAL_LIMITS.maxStateBytes + 1), {
      mode: 0o600,
    });
  }, /size is unsafe/);
});

test("configuration requires an absolute path and canonical explicit calendar", (t) => {
  const { filePath } = temporaryTest(t);
  assert.throws(() => createFileReconciliationReceiptJournal("relative.json", CONFIG), /must be absolute/);
  assert.throws(
    () => openStore(filePath, { ...CONFIG, configuredGatewayTimeZone: "UTC+2" }),
    /explicit IANA time zone/,
  );
  assert.equal(fs.existsSync(`${filePath}.lock`), false);
});

identityTest("shared identity is stable across verification clocks and rejects authority clones", (t) => {
  const { filePath } = temporaryTest(t);
  const first = syntheticOutcome();
  const later = syntheticOutcome({ verifiedAt: "2026-09-10T22:00:05.000Z" });
  const firstEntry = reconciliation.reconciliationJournalEntry(first);
  const laterEntry = reconciliation.reconciliationJournalEntry(later);
  assert.equal(firstEntry.receiptId, laterEntry.receiptId);
  assert.equal(firstEntry.receiptId, reconciliation.canonicalReconciliationReceiptId(first.receipt));
  assert.match(firstEntry.receiptId, /^[0-9a-f]{64}$/);
  assert.ok(Object.isFrozen(firstEntry));
  assert.ok(Object.isFrozen(firstEntry.receipt));

  const store = openStore(filePath);
  t.after(() => store.close());
  assert.equal(store.appendOutcomes([first]).changed, true);
  assert.equal(store.appendOutcomes([later]).changed, false);
  assert.equal(store.load().journal.records.length, 1);
  assert.throws(
    () => store.appendOutcomes([{ ...first }]),
    (error) => error.code === "UNTRUSTED_OUTCOME",
  );
  assert.throws(
    () => store.appendOutcomes([first.receipt]),
    (error) => error.code === "UNTRUSTED_OUTCOME",
  );
});

identityTest("saved readiness is diagnostic on same-process and cold load until fresh recomputation", (t) => {
  const { filePath } = temporaryTest(t);
  const accepted = syntheticOutcome();
  let store = openStore(filePath);
  const initial = store.transition({
    outcomes: [accepted],
    operatorBaseline: operatorBaseline(),
    now: "2026-09-10T22:00:20.000Z",
    freshReplay: freshReplay(),
    maxReplayAgeMs: 30_000,
  });
  assert.equal(initial.ready, true);
  assert.equal(initial.persisted, true);

  const sameProcessLoad = store.load();
  assert.equal(sameProcessLoad.readyForUse, false);
  assert.equal(sameProcessLoad.needsRecomputation, true);
  assert.equal(sameProcessLoad.journal.readiness.result.status, "ready");
  assert.match(sameProcessLoad.reason, /diagnostic only; fresh recomputation is required/);
  store.close();

  store = openStore(filePath);
  t.after(() => store.close());
  const coldLoad = store.load();
  assert.equal(coldLoad.readyForUse, false);
  assert.equal(coldLoad.needsRecomputation, true);
  assert.equal(coldLoad.journal.readiness.result.status, "ready");

  const failed = store.recomputeReadiness({
    now: "2026-09-10T22:00:19.000Z",
    freshReplay: freshReplay(),
    maxReplayAgeMs: 30_000,
  });
  assert.equal(failed.ready, false);
  assert.match(failed.reason, /clock moved backward/);
  const afterFailure = store.load();
  assert.equal(afterFailure.readyForUse, false);
  assert.equal(afterFailure.journal.readiness.result.status, "blocked");

  const fresh = store.recomputeReadiness({
    now: "2026-09-10T22:00:21.000Z",
    freshReplay: freshReplay(),
    maxReplayAgeMs: 30_000,
  });
  assert.equal(fresh.ready, true);
  assert.equal(store.load().readyForUse, false);
});

identityTest("A1 later success contradicting active journal evidence is durably promoted and blocks", (t) => {
  const { filePath } = temporaryTest(t);
  const accepted = syntheticOutcome();
  const contradictory = syntheticOutcome({
    execId: "synthetic.fill.002.01",
    symbol: "ALT",
    conId: 10_002,
    artifactLabel: "synthetic A1 contradictory artifact",
  });
  const acceptedId = reconciliation.reconciliationJournalEntry(accepted).receiptId;
  const contradictoryId = reconciliation.reconciliationJournalEntry(contradictory).receiptId;
  const store = openStore(filePath);
  t.after(() => store.close());
  assert.equal(store.transition({
    outcomes: [accepted],
    operatorBaseline: operatorBaseline(),
    now: "2026-09-10T22:00:20.000Z",
    freshReplay: freshReplay(),
    maxReplayAgeMs: 30_000,
  }).ready, true);

  const blocked = store.transition({
    outcomes: [contradictory],
    now: "2026-09-10T22:00:21.000Z",
    freshReplay: freshReplay(),
    maxReplayAgeMs: 30_000,
  });
  assert.equal(blocked.ready, false);
  assert.match(blocked.reason, /conflicting receipt/);
  const conflicts = new Set(blocked.journal.records.filter((record) => record.conflict)
    .map((record) => record.receiptId));
  assert.deepEqual(conflicts, new Set([acceptedId, contradictoryId]));
  const invalidated = new Set(blocked.result.invalidatedReceiptIdsByWindow
    .flatMap((record) => record.receiptIds));
  assert.deepEqual(invalidated, new Set([acceptedId, contradictoryId]));
});

identityTest("A2 contradictory successes in one baseline transaction cannot produce ready", (t) => {
  const { filePath } = temporaryTest(t);
  const accepted = syntheticOutcome();
  const contradictory = syntheticOutcome({
    execId: "synthetic.fill.002.01",
    symbol: "ALT",
    conId: 10_002,
    artifactLabel: "synthetic A2 contradictory artifact",
  });
  const ids = new Set([accepted, contradictory]
    .map((outcome) => reconciliation.reconciliationJournalEntry(outcome).receiptId));
  const store = openStore(filePath);
  t.after(() => store.close());
  const blocked = store.transition({
    outcomes: [accepted, contradictory],
    operatorBaseline: operatorBaseline(),
    now: "2026-09-10T22:00:20.000Z",
    freshReplay: freshReplay(),
    maxReplayAgeMs: 30_000,
  });
  assert.equal(blocked.persisted, true);
  assert.equal(blocked.ready, false);
  assert.match(blocked.reason, /conflicting receipt/);
  assert.deepEqual(new Set(blocked.journal.records.filter((record) => record.conflict)
    .map((record) => record.receiptId)), ids);
  assert.deepEqual(new Set(blocked.result.invalidatedReceiptIdsByWindow
    .flatMap((record) => record.receiptIds)), ids);
});

identityTest("B contradictory replacement batch blocks while a later distinct single-fact proof recovers", (t) => {
  const { filePath } = temporaryTest(t);
  const accepted = syntheticOutcome();
  const conflicting = syntheticConflict({
    execId: "synthetic.fill.002.01",
    symbol: "ALT",
    conId: 10_002,
    artifactLabel: "synthetic B conflicting artifact",
  }, accepted.receipt);
  const conflictingReceipt = reconciliation.reconciliationJournalEntry(conflicting).receipt;
  const replacementC = syntheticOutcome({
    artifactLabel: "synthetic replacement C",
    priorReceipts: [accepted.receipt],
  });
  const replacementD = syntheticOutcome({
    execId: "synthetic.fill.002.01",
    symbol: "ALT",
    conId: 10_002,
    artifactLabel: "synthetic replacement D",
    priorReceipts: [conflictingReceipt],
  });
  const ids = Object.fromEntries(Object.entries({ accepted, conflicting, replacementC, replacementD })
    .map(([name, outcome]) => [name, reconciliation.reconciliationJournalEntry(outcome).receiptId]));

  const store = openStore(filePath);
  t.after(() => store.close());
  assert.equal(store.transition({
    outcomes: [accepted],
    operatorBaseline: operatorBaseline(),
    now: "2026-09-10T22:00:20.000Z",
    freshReplay: freshReplay(),
    maxReplayAgeMs: 30_000,
  }).ready, true);
  assert.equal(store.transition({
    outcomes: [conflicting],
    now: "2026-09-10T22:00:21.000Z",
    freshReplay: freshReplay(),
    maxReplayAgeMs: 30_000,
  }).ready, false);

  const contradictoryReplacements = store.transition({
    outcomes: [replacementC, replacementD],
    now: "2026-09-10T22:00:22.000Z",
    freshReplay: freshReplay(),
    maxReplayAgeMs: 30_000,
  });
  assert.equal(contradictoryReplacements.ready, false);
  assert.match(contradictoryReplacements.reason, /conflicting receipt/);
  const newlyInvalidated = new Set(contradictoryReplacements.result.invalidatedReceiptIdsByWindow
    .flatMap((record) => record.receiptIds));
  assert.ok(newlyInvalidated.has(ids.replacementC));
  assert.ok(newlyInvalidated.has(ids.replacementD));

  const replacementE = syntheticOutcome({
    artifactLabel: "synthetic replacement E",
    priorReceipts: [replacementC.receipt],
  });
  const replacementEId = reconciliation.reconciliationJournalEntry(replacementE).receiptId;
  const recovered = store.transition({
    outcomes: [replacementE],
    now: "2026-09-10T22:00:23.000Z",
    freshReplay: freshReplay(),
    maxReplayAgeMs: 30_000,
  });
  assert.equal(recovered.ready, true);
  assert.deepEqual(recovered.result.reconciledWindows.at(-1).receiptIds, [replacementEId]);
  assert.deepEqual(new Set(recovered.journal.records.map((record) => record.receiptId)),
    new Set([...Object.values(ids), replacementEId]));
});

identityTest("same verified facts from independent synthetic artifacts remain compatible", (t) => {
  const { filePath } = temporaryTest(t);
  const accepted = syntheticOutcome();
  const confirmation = syntheticOutcome({
    artifactLabel: "synthetic same-facts confirmation",
    priorReceipts: [accepted.receipt],
  });
  const ids = [accepted, confirmation]
    .map((outcome) => reconciliation.reconciliationJournalEntry(outcome).receiptId)
    .sort();
  assert.equal(new Set(ids).size, 2);
  assert.equal(reconciliation.reconciliationReceiptsConflict(
    accepted.receipt,
    confirmation.receipt,
  ), false);

  const store = openStore(filePath);
  t.after(() => store.close());
  const ready = store.transition({
    outcomes: [accepted, confirmation],
    operatorBaseline: operatorBaseline(),
    now: "2026-09-10T22:00:20.000Z",
    freshReplay: freshReplay(),
    maxReplayAgeMs: 30_000,
  });
  assert.equal(ready.ready, true);
  assert.equal(ready.journal.records.some((record) => record.conflict), false);
  assert.deepEqual(ready.result.reconciledWindows[0].receiptIds, ids);
});

identityTest("load rejects contradictory active successes even with a valid rewritten head digest", (t) => {
  const { filePath } = temporaryTest(t);
  const accepted = syntheticOutcome();
  const contradictory = syntheticOutcome({
    execId: "synthetic.fill.002.01",
    symbol: "ALT",
    conId: 10_002,
    artifactLabel: "synthetic disk contradiction",
  });
  let store = openStore(filePath);
  store.appendOutcomes([accepted]);
  store.close();

  const persisted = JSON.parse(fs.readFileSync(filePath, "utf8"));
  persisted.records.push(reconciliation.reconciliationJournalEntry(contradictory));
  persisted.receiptSetDigest = sha256(canonicalJson(persisted.records));
  persisted.readiness = null;
  writeJson(filePath, persisted);

  store = openStore(filePath);
  t.after(() => store.close());
  const loaded = store.load();
  assert.equal(loaded.ok, false);
  assert.match(loaded.reason, /contradictory active reconciliation receipts/);
  assert.equal(loaded.readyForUse, undefined);
});

identityTest("duplicate content is idempotent and later conflict promotion is monotonic", (t) => {
  const { filePath } = temporaryTest(t);
  const accepted = syntheticOutcome({
    execId: "synthetic.fill.002.01",
    symbol: "ALT",
    conId: 10_002,
    artifactLabel: "synthetic conflicting artifact B",
  });
  const established = syntheticOutcome();
  const conflict = syntheticConflict({
    execId: "synthetic.fill.002.01",
    symbol: "ALT",
    conId: 10_002,
    artifactLabel: "synthetic conflicting artifact B",
  }, established.receipt);
  const id = reconciliation.reconciliationJournalEntry(accepted).receiptId;
  assert.equal(reconciliation.reconciliationJournalEntry(conflict).receiptId, id);

  const store = openStore(filePath);
  t.after(() => store.close());
  store.appendOutcomes([accepted, accepted]);
  store.appendOutcomes([conflict, conflict]);
  const records = store.load().journal.records;
  assert.equal(records.length, 2);
  assert.deepEqual(records.map((record) => record.conflict), [false, true]);
  assert.equal(records[0].receiptId, records[1].receiptId);
  assert.deepEqual(records[0].receipt, records[1].receipt);
  assert.equal(fs.statSync(filePath).mode & 0o777, 0o600);
});

identityTest("raw digest rebound and non-journalable rebound errors are rejected without mutation", (t) => {
  const { filePath } = temporaryTest(t);
  const accepted = syntheticOutcome({ assertionId: "synthetic-finality-original" });
  const rebound = syntheticOutcome({ assertionId: "synthetic-finality-rebound" });
  const acceptedEntry = reconciliation.reconciliationJournalEntry(accepted);
  const reboundEntry = reconciliation.reconciliationJournalEntry(rebound);
  assert.equal(acceptedEntry.receipt.rawArtifactSha256, reboundEntry.receipt.rawArtifactSha256);
  assert.notEqual(acceptedEntry.receiptId, reboundEntry.receiptId);

  const store = openStore(filePath);
  t.after(() => store.close());
  store.appendOutcomes([accepted]);
  const before = fs.readFileSync(filePath);
  assert.throws(
    () => store.appendOutcomes([rebound]),
    (error) => error.code === "RAW_DIGEST_REBOUND",
  );
  assert.deepEqual(fs.readFileSync(filePath), before);

  let rawReboundError;
  try {
    syntheticOutcome({
      assertionId: "synthetic-finality-rebound",
      priorReceipts: [accepted.receipt],
    });
  } catch (error) {
    rawReboundError = error;
  }
  assert.equal(rawReboundError?.code, "RECEIPT_CONFLICT");
  assert.throws(
    () => store.appendOutcomes([rawReboundError]),
    (error) => error.code === "UNTRUSTED_OUTCOME",
  );
});

identityTest("phase-one append survives failed readiness and restart without dropping conflict", (t) => {
  const { filePath } = temporaryTest(t);
  const accepted = syntheticOutcome();
  let store = openStore(filePath);
  const ready = store.transition({
    outcomes: [accepted],
    operatorBaseline: operatorBaseline(),
    now: "2026-09-10T22:00:20.000Z",
    freshReplay: freshReplay(),
    maxReplayAgeMs: 30_000,
  });
  assert.equal(ready.ready, true);
  assert.equal(ready.persisted, true);

  const conflicting = syntheticConflict({
    execId: "synthetic.fill.002.01",
    symbol: "ALT",
    conId: 10_002,
    artifactLabel: "synthetic conflicting artifact B",
  }, accepted.receipt);
  const conflictId = reconciliation.reconciliationJournalEntry(conflicting).receiptId;
  const failed = store.transition({
    outcomes: [conflicting],
    now: "2026-09-10T22:00:21.000Z",
    freshReplay: freshReplay(),
    // Intentionally absent: a bad caller clock/TTL phase must not erase the append.
  });
  assert.equal(failed.ready, false);
  assert.equal(failed.persisted, false);
  assert.match(failed.reason, /maxReplayAgeMs/);
  assert.equal(store.load().needsRecomputation, true);
  assert.equal(store.load().journal.records.at(-1).conflict, true);

  const backwardClock = store.recomputeReadiness({
    now: "2026-09-10T22:00:19.000Z",
    freshReplay: freshReplay(),
    maxReplayAgeMs: 30_000,
  });
  assert.equal(backwardClock.persisted, false);
  assert.match(backwardClock.reason, /clock moved backward/);
  assert.ok(store.load().journal.records.some((record) =>
    record.receiptId === conflictId && record.conflict));
  store.close();

  store = openStore(filePath);
  t.after(() => store.close());
  const restarted = store.load();
  assert.equal(restarted.readyForUse, false);
  assert.equal(restarted.needsRecomputation, true);
  assert.ok(restarted.journal.records.some((record) =>
    record.receiptId === conflictId && record.conflict));

  const acknowledged = store.recomputeReadiness({
    now: "2026-09-10T22:00:22.000Z",
    freshReplay: freshReplay(),
    maxReplayAgeMs: 30_000,
  });
  assert.equal(acknowledged.persisted, true);
  assert.equal(acknowledged.ready, false);
  assert.match(acknowledged.reason, /conflicting receipt/);
  assert.ok(acknowledged.result.invalidatedReceiptIdsByWindow.flatMap((item) => item.receiptIds)
    .includes(conflictId));

  const replacement = syntheticOutcome({
    artifactLabel: "synthetic restart replacement artifact",
    priorReceipts: [accepted.receipt],
  });
  const replacementId = reconciliation.reconciliationJournalEntry(replacement).receiptId;
  const invalidReplay = store.transition({
    outcomes: [replacement],
    now: "2026-09-10T22:00:23.000Z",
    freshReplay: { ...freshReplay(), knownExecutionSet: "lost" },
    maxReplayAgeMs: 30_000,
  });
  assert.equal(invalidReplay.persisted, true);
  assert.equal(invalidReplay.ready, false);
  assert.match(invalidReplay.reason, /known execution set/);
  assert.ok(store.load().journal.records.some((record) =>
    record.receiptId === conflictId && record.conflict));
  assert.ok(store.load().journal.records.some((record) => record.receiptId === replacementId));

  const recovered = store.recomputeReadiness({
    now: "2026-09-10T22:00:24.000Z",
    freshReplay: freshReplay(),
    maxReplayAgeMs: 30_000,
  });
  assert.equal(recovered.persisted, true);
  assert.equal(recovered.ready, true);
  assert.deepEqual(recovered.result.reconciledWindows[0].receiptIds, [replacementId]);
});

identityTest("distinct compatible replacement restores readiness with complete cumulative coverage", (t) => {
  const { filePath } = temporaryTest(t);
  const accepted = syntheticOutcome();
  const conflicting = syntheticConflict({
    execId: "synthetic.fill.002.01",
    symbol: "ALT",
    conId: 10_002,
    artifactLabel: "synthetic conflicting artifact B",
  }, accepted.receipt);
  const replacement = syntheticOutcome({
    artifactLabel: "synthetic compatible replacement artifact C",
    priorReceipts: [accepted.receipt],
  });
  const acceptedId = reconciliation.reconciliationJournalEntry(accepted).receiptId;
  const conflictId = reconciliation.reconciliationJournalEntry(conflicting).receiptId;
  const replacementId = reconciliation.reconciliationJournalEntry(replacement).receiptId;
  assert.equal(new Set([acceptedId, conflictId, replacementId]).size, 3);

  const store = openStore(filePath);
  t.after(() => store.close());
  assert.equal(store.transition({
    outcomes: [accepted],
    operatorBaseline: operatorBaseline(),
    now: "2026-09-10T22:00:20.000Z",
    freshReplay: freshReplay(),
    maxReplayAgeMs: 30_000,
  }).ready, true);
  assert.equal(store.transition({
    outcomes: [conflicting],
    now: "2026-09-10T22:00:21.000Z",
    freshReplay: freshReplay(),
    maxReplayAgeMs: 30_000,
  }).ready, false);

  const recovered = store.transition({
    outcomes: [replacement],
    now: "2026-09-10T22:00:22.000Z",
    freshReplay: freshReplay(),
    maxReplayAgeMs: 30_000,
  });
  assert.equal(recovered.persisted, true);
  assert.equal(recovered.ready, true);
  assert.deepEqual(recovered.result.reconciledWindows[0].receiptIds, [replacementId]);
  assert.ok(recovered.result.invalidatedReceiptIdsByWindow[0].receiptIds.includes(acceptedId));
  assert.ok(recovered.result.invalidatedReceiptIdsByWindow[0].receiptIds.includes(conflictId));
  assert.deepEqual(new Set(recovered.journal.records.map((record) => record.receiptId)),
    new Set([acceptedId, conflictId, replacementId]));
  assert.equal(recovered.journal.records.some((record) => record.conflict), true);
});

identityTest("readiness is head-bound and malformed persisted receipt references fail closed", (t) => {
  const { filePath } = temporaryTest(t);
  const accepted = syntheticOutcome();
  let store = openStore(filePath);
  assert.equal(store.transition({
    outcomes: [accepted],
    operatorBaseline: operatorBaseline(),
    now: "2026-09-10T22:00:20.000Z",
    freshReplay: freshReplay(),
    maxReplayAgeMs: 30_000,
  }).ready, true);
  store.close();

  const persisted = JSON.parse(fs.readFileSync(filePath, "utf8"));
  persisted.readiness.receiptIds = ["f".repeat(64)];
  writeJson(filePath, persisted);
  store = openStore(filePath);
  t.after(() => store.close());
  const loaded = store.load();
  assert.equal(loaded.ok, false);
  assert.match(loaded.reason, /receipt references do not match/);
});

identityTest("reload rejects noncanonical receipt content and receipt-ID rebinding", async (t) => {
  async function rejects(label, mutate, reasonPattern) {
    await t.test(label, (nested) => {
      const { filePath } = temporaryTest(nested);
      const accepted = syntheticOutcome();
      let store = openStore(filePath);
      store.appendOutcomes([accepted]);
      store.close();
      const persisted = JSON.parse(fs.readFileSync(filePath, "utf8"));
      mutate(persisted.records[0]);
      writeJson(filePath, persisted);
      store = openStore(filePath);
      nested.after(() => store.close());
      const loaded = store.load();
      assert.equal(loaded.ok, false);
      assert.match(loaded.reason, reasonPattern);
    });
  }

  await rejects("unknown receipt field", (record) => {
    record.receipt.unexpected = true;
  }, /stored reconciliation receipt is invalid/);
  await rejects("receipt facts rebound under old ID", (record) => {
    record.receipt.rawArtifactSha256 = "0".repeat(64);
  }, /receiptId does not match/);
});

identityTest("ingress validation is transactional before the append phase", (t) => {
  const { filePath } = temporaryTest(t);
  const accepted = syntheticOutcome();
  const store = openStore(filePath);
  t.after(() => store.close());
  store.appendOutcomes([accepted]);
  const before = fs.readFileSync(filePath, "utf8");
  assert.throws(
    () => store.appendOutcomes([accepted, { ...accepted }]),
    (error) => error.code === "UNTRUSTED_OUTCOME",
  );
  assert.equal(fs.readFileSync(filePath, "utf8"), before);
});
