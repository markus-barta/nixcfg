#!/usr/bin/env node
/** Synthetic provider-neutral reconciliation tests. No broker or report provider access. */
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

import {
  RECONCILIATION_EVIDENCE_SCHEMA,
  RECONCILIATION_RECEIPT_SCHEMA,
  ReconciliationError,
  canonicalReconciliationReceiptId,
  normalizeReconciliationReceipt,
  reconcileExecutionWindow,
  reconciliationJournalEntry,
  reconciliationReceiptsConflict,
  validateReconciliationEvidence,
} from "./execution-reconciliation.mjs";

const ACCOUNT = "SYNTHETIC-PAPER-ACCOUNT";
const WINDOW = {
  fromInclusive: "2026-09-10T13:00:00.000Z",
  toExclusive: "2026-09-10T15:00:00.000Z",
};
const ADAPTER = {
  adapterId: "synthetic-reviewed-final-report",
  adapterVersion: "1.0.0",
};
const ALLOWED_ADAPTERS = [ADAPTER];
const VERIFIED_AT = "2026-09-10T15:03:00.000Z";

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function localTime(index) {
  const date = new Date(Date.UTC(2026, 8, 10, 9, 30, index));
  return `${date.getUTCFullYear()}${String(date.getUTCMonth() + 1).padStart(2, "0")}${String(
    date.getUTCDate()
  ).padStart(2, "0")} ${String(date.getUTCHours()).padStart(2, "0")}:${String(
    date.getUTCMinutes()
  ).padStart(2, "0")}:${String(date.getUTCSeconds()).padStart(2, "0")} US/Eastern`;
}

function occurredAt(index) {
  return new Date(Date.UTC(2026, 8, 10, 13, 30, index)).toISOString();
}

function socketExecution(index, overrides = {}) {
  const execId = overrides.execId || `synthetic.fill.${String(index).padStart(3, "0")}.01`;
  return {
    contract: {
      conId: 10_000 + index,
      symbol: `SYN${String(index).padStart(3, "0")}`,
      secType: "STK",
      currency: "USD",
      multiplier: 1,
    },
    execution: {
      execId,
      time: overrides.time || localTime(index),
      acctNumber: overrides.account || ACCOUNT,
      clientId: overrides.clientId ?? (index === 77 ? 27 : 22),
      side: overrides.side || "BUY",
      shares: overrides.shares ?? 1,
      price: overrides.price ?? 100 + index,
      pendingPriceRevision: false,
    },
  };
}

function socketCommission(row, amount = 0.1, currency = "USD") {
  return { execId: row.execution.execId, commission: amount, currency };
}

function evidenceExecution(row, index, economics = true) {
  return {
    execId: row.execution.execId,
    occurredAt: occurredAt(index),
    account: ACCOUNT,
    ...(economics ? {
      economics: {
        side: row.execution.side,
        shares: row.execution.shares,
        price: row.execution.price,
        currency: row.contract.currency,
        commission: 0.1,
        commissionCurrency: "USD",
      },
    } : {}),
  };
}

function artifact(label = "synthetic all-account final artifact") {
  return Buffer.from(label, "utf8");
}

function evidenceInput(raw, executions, overrides = {}) {
  return {
    schema: RECONCILIATION_EVIDENCE_SCHEMA,
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
      assertionId: "synthetic-source-finality-1",
    },
    generatedAt: "2026-09-10T15:01:00.000Z",
    retrievedAt: "2026-09-10T15:02:00.000Z",
    correctionSemantics: "LATEST_EFFECTIVE",
    rawArtifactSha256: sha256(raw),
    ...ADAPTER,
    executions,
    ...overrides,
  };
}

function validate(input, raw) {
  return validateReconciliationEvidence(input, {
    rawArtifactBytes: raw,
    allowedAdapters: ALLOWED_ADAPTERS,
  });
}

function reconcile(evidence, socketExecutions, socketCommissions, overrides = {}) {
  return reconcileExecutionWindow({
    evidence,
    socketExecutions,
    socketCommissions,
    account: ACCOUNT,
    window: WINDOW,
    priorReceipts: [],
    verifiedAt: VERIFIED_AT,
    ...overrides,
  });
}

function deepFreeze(value) {
  if (!value || typeof value !== "object" || Object.isFrozen(value)) return value;
  for (const nested of Object.values(value)) deepFreeze(nested);
  return Object.freeze(value);
}

function captureError(callback) {
  try {
    callback();
  } catch (error) {
    return error;
  }
  assert.fail("expected callback to throw");
}

function fixture78() {
  const raw = artifact();
  const socketExecutions = Array.from({ length: 78 }, (_, index) => socketExecution(index));
  const socketCommissions = socketExecutions.map((row) => socketCommission(row));
  const executions = socketExecutions.map((row, index) => evidenceExecution(row, index));
  return { raw, socketExecutions, socketCommissions, input: evidenceInput(raw, executions) };
}

test("exact synthetic 78-ID evidence matches without mutating or replacing socket originals", () => {
  const values = fixture78();
  const inputSnapshot = JSON.stringify(values.input);
  const socketSnapshot = JSON.stringify({
    executions: values.socketExecutions,
    commissions: values.socketCommissions,
  });
  deepFreeze(values.input);
  deepFreeze(values.socketExecutions);
  deepFreeze(values.socketCommissions);

  const evidence = validate(values.input, values.raw);
  const result = reconcile(evidence, values.socketExecutions, values.socketCommissions);

  assert.equal(result.ok, true);
  assert.equal(result.status, "MATCHED");
  assert.equal(result.activationAuthorized, false);
  assert.equal(result.trustBoundary, "CALLER_VERIFIED_ADAPTER");
  assert.equal(result.receipt.schema, RECONCILIATION_RECEIPT_SCHEMA);
  assert.equal(result.receipt.identityCount, 78);
  assert.match(result.receipt.canonicalIdentityDigest, /^[0-9a-f]{64}$/);
  assert.match(result.receipt.matchedSocketLedgerDigest, /^[0-9a-f]{64}$/);
  assert.strictEqual(result.socketExecutions, values.socketExecutions);
  assert.strictEqual(result.socketCommissions, values.socketCommissions);
  assert.strictEqual(result.socketExecutions[77], values.socketExecutions[77]);
  assert.equal(result.socketExecutions[77].execution.clientId, 27);
  assert.equal(JSON.stringify(values.input), inputSnapshot);
  assert.equal(socketSnapshot, JSON.stringify({
    executions: values.socketExecutions,
    commissions: values.socketCommissions,
  }));
});

test("missing, extra, or report-manufactured Joe-only identities block all-account matching", () => {
  const values = fixture78();
  const missingJoe = structuredClone(values.input);
  missingJoe.executions = missingJoe.executions.slice(0, -1);
  assert.throws(
    () => reconcile(validate(missingJoe, values.raw), values.socketExecutions, values.socketCommissions),
    /effective execution identity sets differ/
  );

  const socketMissingJoe = values.socketExecutions.slice(0, -1);
  const feesMissingJoe = values.socketCommissions.slice(0, -1);
  assert.throws(
    () => reconcile(validate(values.input, values.raw), socketMissingJoe, feesMissingJoe),
    /effective execution identity sets differ/
  );

  const manufactured = structuredClone(values.input);
  manufactured.executions.push({
    execId: "synthetic.fill.999.01",
    occurredAt: "2026-09-10T14:59:00.000Z",
    account: ACCOUNT,
  });
  assert.throws(
    () => reconcile(validate(manufactured, values.raw), values.socketExecutions, values.socketCommissions),
    /effective execution identity sets differ/
  );
});

test("coverage gaps and provisional or absent finality fail despite late generation", () => {
  const values = fixture78();
  const gap = structuredClone(values.input);
  gap.fromInclusive = "2026-09-10T13:01:00.000Z";
  gap.finality.fromInclusive = gap.fromInclusive;
  assert.throws(
    () => reconcile(validate(gap, values.raw), values.socketExecutions, values.socketCommissions),
    /interval differs from the requested window/
  );

  const provisional = structuredClone(values.input);
  provisional.finality.status = "PROVISIONAL";
  provisional.generatedAt = "2026-09-10T23:59:59.000Z";
  provisional.retrievedAt = "2026-09-11T00:00:00.000Z";
  assert.throws(() => validate(provisional, values.raw), /authoritative FINAL assertion/);

  const noFinality = structuredClone(values.input);
  delete noFinality.finality;
  noFinality.generatedAt = "2026-09-10T23:59:59.000Z";
  noFinality.retrievedAt = "2026-09-11T00:00:00.000Z";
  assert.throws(() => validate(noFinality, values.raw), /fields are not canonical/);
});

test("account, all-account scope, raw SHA, and non-empty adapter allow-list are mandatory", () => {
  const values = fixture78();
  const wrongAccount = structuredClone(values.input);
  wrongAccount.account = "SYNTHETIC-OTHER-ACCOUNT";
  assert.throws(() => validate(wrongAccount, values.raw), /account differs/);

  const partialScope = structuredClone(values.input);
  partialScope.scope = "FAMILY_ONLY";
  assert.throws(() => validate(partialScope, values.raw), /ALL_ACCOUNT/);

  const partialFinality = structuredClone(values.input);
  partialFinality.finality.scope = "SUBSET";
  assert.throws(() => validate(partialFinality, values.raw), /not ALL_ACCOUNT/);

  const badSha = structuredClone(values.input);
  badSha.rawArtifactSha256 = "0".repeat(64);
  assert.throws(() => validate(badSha, values.raw), /does not match supplied bytes/);

  assert.throws(
    () => validateReconciliationEvidence(values.input, {
      rawArtifactBytes: values.raw,
      allowedAdapters: [],
    }),
    /must not be empty/
  );
});

test("report evidence cannot supply or overwrite socket clientId attribution", () => {
  const values = fixture78();
  const attributed = structuredClone(values.input);
  attributed.executions[77].clientId = 999;
  assert.throws(() => validate(attributed, values.raw), /must not contain clientId/);

  const evidence = validate(values.input, values.raw);
  const result = reconcile(evidence, values.socketExecutions, values.socketCommissions);
  assert.strictEqual(result.socketExecutions[77], values.socketExecutions[77]);
  assert.equal(result.socketExecutions[77].execution.clientId, 27);
});

test("higher corrections require exact socket capture and the corrected socket fee", () => {
  const raw = artifact("synthetic correction artifact");
  const first = socketExecution(0, { execId: "synthetic.corrected.01" });
  const corrected = socketExecution(1, { execId: "synthetic.corrected.02" });
  const socketExecutions = [first, corrected];
  const correctedEvidence = evidenceExecution(corrected, 1, false);
  const latest = validate(evidenceInput(raw, [correctedEvidence]), raw);
  const matched = reconcile(latest, socketExecutions, [socketCommission(corrected)]);
  assert.equal(matched.receipt.identityCount, 1);

  assert.throws(
    () => reconcile(latest, socketExecutions, [socketCommission(first)]),
    /higher socket correction has no captured socket fee/
  );

  const reportOnlyHigher = structuredClone(evidenceInput(raw, [correctedEvidence]));
  reportOnlyHigher.executions[0].execId = "synthetic.corrected.03";
  assert.throws(
    () => reconcile(validate(reportOnlyHigher, raw), socketExecutions, [socketCommission(corrected)]),
    /effective execution identity sets differ/
  );

  const allRevisions = structuredClone(evidenceInput(raw, [
    evidenceExecution(first, 0, false),
    correctedEvidence,
  ]));
  allRevisions.correctionSemantics = "ALL_REVISIONS";
  assert.equal(
    reconcile(validate(allRevisions, raw), socketExecutions, [socketCommission(corrected)]).ok,
    true
  );
  allRevisions.executions.shift();
  assert.throws(
    () => reconcile(validate(allRevisions, raw), socketExecutions, [socketCommission(corrected)]),
    /ALL_REVISIONS correction chains differ/
  );
});

test("common-ID economics and commission currency disagreements block", () => {
  const values = fixture78();
  const priceConflict = structuredClone(values.input);
  priceConflict.executions[0].economics.price += 0.01;
  assert.throws(
    () => reconcile(validate(priceConflict, values.raw), values.socketExecutions, values.socketCommissions),
    /price differs/
  );

  const currencyConflict = structuredClone(values.input);
  currencyConflict.executions[0].economics.commissionCurrency = "EUR";
  assert.throws(
    () => reconcile(validate(currencyConflict, values.raw), values.socketExecutions, values.socketCommissions),
    /commission currency differs/
  );
});

test("validated evidence membership cannot be forged by copying reflected Symbols", () => {
  const values = fixture78();
  const evidence = validate(values.input, values.raw);
  const reflectedSymbols = Object.getOwnPropertySymbols(evidence);
  const forged = structuredClone(evidence);
  for (const symbol of reflectedSymbols) {
    Object.defineProperty(forged, symbol, Object.getOwnPropertyDescriptor(evidence, symbol));
  }
  forged.finality.status = "PROVISIONAL";
  forged.rawArtifactSha256 = "0".repeat(64);
  forged.adapterId = "never-allowed";

  assert.deepEqual(reflectedSymbols, []);
  assert.equal(Object.isFrozen(evidence), true);
  assert.equal(Object.isFrozen(evidence.finality), true);
  assert.equal(Object.isFrozen(evidence.executions), true);
  assert.equal(Object.isFrozen(evidence.executions[0]), true);
  assert.throws(
    () => reconcile(forged, values.socketExecutions, values.socketCommissions),
    /must come from validateReconciliationEvidence/
  );
});

test("receipt normalization is frozen and its canonical ID excludes only verifiedAt", () => {
  const raw = artifact("synthetic receipt identity artifact");
  const socket = socketExecution(0, { execId: "synthetic.receipt.01" });
  const result = reconcile(
    validate(evidenceInput(raw, [evidenceExecution(socket, 0, false)]), raw),
    [socket],
    [socketCommission(socket)]
  );
  const normalized = normalizeReconciliationReceipt(result.receipt);
  const receiptId = canonicalReconciliationReceiptId(result.receipt);

  assert.deepEqual(normalized, result.receipt);
  assert.notStrictEqual(normalized, result.receipt);
  assert.equal(Object.isFrozen(normalized), true);
  assert.equal(Object.isFrozen(normalized.coverage), true);
  assert.match(receiptId, /^[0-9a-f]{64}$/);

  const reverified = structuredClone(normalized);
  reverified.verifiedAt = "2026-09-10T15:59:00.000Z";
  assert.equal(canonicalReconciliationReceiptId(reverified), receiptId);

  const changedFacts = structuredClone(normalized);
  changedFacts.canonicalIdentityDigest = "1".repeat(64);
  const changedCoverage = structuredClone(normalized);
  changedCoverage.coverage.fromInclusive = "2026-09-10T13:01:00.000Z";
  const changedAdapter = structuredClone(normalized);
  changedAdapter.adapterVersion = "1.0.1";
  const changedEvidence = structuredClone(normalized);
  changedEvidence.evidenceContentSha256 = "2".repeat(64);
  for (const changed of [changedFacts, changedCoverage, changedAdapter, changedEvidence]) {
    assert.notEqual(canonicalReconciliationReceiptId(changed), receiptId);
  }

  assert.throws(() => reconciliationJournalEntry(normalized), /live reconciliation result or overlap error/);
});

test("receipt conflict predicate structurally validates and reuses reconciliation overlap semantics", () => {
  const raw = artifact("synthetic conflict predicate artifact");
  const socket = socketExecution(0, { execId: "synthetic.predicate.01" });
  const result = reconcile(
    validate(evidenceInput(raw, [evidenceExecution(socket, 0, false)]), raw),
    [socket],
    [socketCommission(socket)]
  );
  const sameFacts = structuredClone(result.receipt);
  sameFacts.rawArtifactSha256 = "1".repeat(64);
  sameFacts.evidenceContentSha256 = "2".repeat(64);
  sameFacts.verifiedAt = "2026-09-10T15:04:00.000Z";
  assert.equal(reconciliationReceiptsConflict(result.receipt, sameFacts), false);

  const changedFacts = structuredClone(sameFacts);
  changedFacts.canonicalIdentityDigest = "3".repeat(64);
  assert.equal(reconciliationReceiptsConflict(result.receipt, changedFacts), true);

  const differentAccount = structuredClone(changedFacts);
  differentAccount.account = "SYNTHETIC-OTHER-PAPER-ACCOUNT";
  assert.equal(reconciliationReceiptsConflict(result.receipt, differentAccount), false);

  const malformed = structuredClone(result.receipt);
  delete malformed.coverage;
  assert.throws(
    () => reconciliationReceiptsConflict(result.receipt, malformed),
    /fields are not canonical/
  );
});

test("only the live reconciliation result can produce a success journal entry", () => {
  const raw = artifact("synthetic journal success artifact");
  const socket = socketExecution(0, { execId: "synthetic.journal.01" });
  const result = reconcile(
    validate(evidenceInput(raw, [evidenceExecution(socket, 0, false)]), raw),
    [socket],
    [socketCommission(socket)]
  );
  const entry = reconciliationJournalEntry(result);

  assert.deepEqual(Object.keys(entry), ["receiptId", "conflict", "receipt"]);
  assert.equal(entry.conflict, false);
  assert.equal(entry.receiptId, canonicalReconciliationReceiptId(entry.receipt));
  assert.equal(Object.isFrozen(entry), true);
  assert.equal(Object.isFrozen(entry.receipt), true);
  assert.equal(Object.isFrozen(entry.receipt.coverage), true);

  const serialized = JSON.parse(JSON.stringify(result));
  const cloned = structuredClone(result);
  const prototypeSpoof = Object.create(result);
  const symbolSpoof = structuredClone(result);
  for (const symbol of Object.getOwnPropertySymbols(result)) {
    Object.defineProperty(symbolSpoof, symbol, Object.getOwnPropertyDescriptor(result, symbol));
  }
  Object.defineProperty(symbolSpoof, Symbol("journalable reconciliation"), { value: true });
  const errorSpoof = new ReconciliationError(
    "RECEIPT_OVERLAP_CONFLICT",
    "overlapping finalized receipts require explicit future correction reconciliation"
  );
  for (const spoof of [serialized, cloned, prototypeSpoof, symbolSpoof, errorSpoof, result.receipt]) {
    assert.throws(() => reconciliationJournalEntry(spoof), /live reconciliation result or overlap error/);
  }
});

test("overlapping finalized receipts reject changed facts without mutating prior receipts", () => {
  const raw = artifact("synthetic first finalized artifact");
  const firstSocket = socketExecution(0, { execId: "synthetic.overlap.01" });
  const firstInput = evidenceInput(raw, [evidenceExecution(firstSocket, 0, false)]);
  const first = reconcile(
    validate(firstInput, raw),
    [firstSocket],
    [socketCommission(firstSocket)]
  );
  const priorReceipts = Object.freeze([first.receipt]);
  const priorSnapshot = JSON.stringify(priorReceipts);

  const confirmingRaw = artifact("synthetic independent confirming artifact");
  const confirmingInput = structuredClone(firstInput);
  confirmingInput.rawArtifactSha256 = sha256(confirmingRaw);
  confirmingInput.finality.assertionId = "synthetic-independent-finality";
  const confirmation = reconcile(
    validate(confirmingInput, confirmingRaw),
    [firstSocket],
    [socketCommission(firstSocket)],
    { priorReceipts, verifiedAt: "2026-09-10T15:04:00.000Z" }
  );
  assert.equal(confirmation.idempotent, false);
  assert.equal(confirmation.receipts.length, 2);
  assert.notEqual(confirmation.receipt.rawArtifactSha256, first.receipt.rawArtifactSha256);
  assert.equal(confirmation.receipt.canonicalIdentityDigest, first.receipt.canonicalIdentityDigest);
  assert.equal(confirmation.receipt.matchedSocketLedgerDigest, first.receipt.matchedSocketLedgerDigest);

  const changedLedgerSocket = structuredClone(firstSocket);
  changedLedgerSocket.contract.conId += 1;
  const changedLedgerRaw = artifact("synthetic changed socket-ledger artifact");
  const changedLedgerInput = structuredClone(firstInput);
  changedLedgerInput.rawArtifactSha256 = sha256(changedLedgerRaw);
  changedLedgerInput.finality.assertionId = "synthetic-changed-ledger-finality";
  assert.throws(
    () => reconcile(
      validate(changedLedgerInput, changedLedgerRaw),
      [changedLedgerSocket],
      [socketCommission(changedLedgerSocket)],
      { priorReceipts, verifiedAt: "2026-09-10T15:05:00.000Z" }
    ),
    /overlapping finalized receipts require explicit future correction reconciliation/
  );

  const correctedSocket = socketExecution(1, { execId: "synthetic.overlap.02" });
  const reboundInput = evidenceInput(raw, [evidenceExecution(correctedSocket, 1, false)]);
  const reboundError = captureError(() => reconcile(
    validate(reboundInput, raw),
    [firstSocket, correctedSocket],
    [socketCommission(firstSocket), socketCommission(correctedSocket)],
    { priorReceipts, verifiedAt: "2026-09-10T15:06:00.000Z" }
  ));
  assert.equal(reboundError.code, "RECEIPT_CONFLICT");
  assert.match(reboundError.message, /raw artifact digest was previously bound to different content/);
  assert.throws(
    () => reconciliationJournalEntry(reboundError),
    /live reconciliation result or overlap error/
  );

  const correctedRaw = artifact("synthetic conflicting corrected artifact");
  const correctedInput = evidenceInput(correctedRaw, [evidenceExecution(correctedSocket, 1, false)]);
  const correctionError = captureError(() => reconcile(
    validate(correctedInput, correctedRaw),
    [firstSocket, correctedSocket],
    [socketCommission(firstSocket), socketCommission(correctedSocket)],
    { priorReceipts, verifiedAt: "2026-09-10T15:06:00.000Z" }
  ));
  assert.equal(correctionError.code, "RECEIPT_OVERLAP_CONFLICT");
  assert.match(
    correctionError.message,
    /overlapping finalized receipts require explicit future correction reconciliation/
  );
  const conflictEntry = reconciliationJournalEntry(correctionError);
  assert.equal(conflictEntry.conflict, true);
  assert.equal(conflictEntry.receipt.rawArtifactSha256, sha256(correctedRaw));
  assert.equal(conflictEntry.receiptId, canonicalReconciliationReceiptId(conflictEntry.receipt));
  assert.equal(Object.isFrozen(conflictEntry), true);
  assert.equal(Object.isFrozen(conflictEntry.receipt), true);
  const serializedConflict = JSON.parse(JSON.stringify(correctionError));
  const clonedConflict = structuredClone(correctionError);
  const conflictPrototypeSpoof = Object.create(correctionError);
  const conflictSymbolSpoof = new ReconciliationError(correctionError.code, correctionError.message);
  for (const symbol of Object.getOwnPropertySymbols(correctionError)) {
    Object.defineProperty(
      conflictSymbolSpoof,
      symbol,
      Object.getOwnPropertyDescriptor(correctionError, symbol)
    );
  }
  for (const spoof of [
    serializedConflict,
    clonedConflict,
    conflictPrototypeSpoof,
    conflictSymbolSpoof,
  ]) {
    assert.throws(() => reconciliationJournalEntry(spoof), /live reconciliation result or overlap error/);
  }

  const partiallyOverlappingReceipt = structuredClone(first.receipt);
  partiallyOverlappingReceipt.coverage = {
    fromInclusive: "2026-09-10T13:30:00.000Z",
    toExclusive: "2026-09-10T14:30:00.000Z",
    completeThrough: "2026-09-10T14:30:00.000Z",
    asOf: "2026-09-10T14:30:00.000Z",
  };
  assert.throws(
    () => reconcile(
      validate(confirmingInput, confirmingRaw),
      [firstSocket],
      [socketCommission(firstSocket)],
      { priorReceipts: [partiallyOverlappingReceipt], verifiedAt: "2026-09-10T15:06:00.000Z" }
    ),
    /overlapping finalized receipts require explicit future correction reconciliation/
  );
  assert.equal(JSON.stringify(priorReceipts), priorSnapshot);
  assert.strictEqual(priorReceipts[0], first.receipt);
});

test("prior-history overlap and malformed-receipt errors cannot become journal entries", () => {
  const raw = artifact("synthetic prior-history artifact");
  const socket = socketExecution(0, { execId: "synthetic.prior.01" });
  const evidence = validate(evidenceInput(raw, [evidenceExecution(socket, 0, false)]), raw);
  const first = reconcile(evidence, [socket], [socketCommission(socket)]);

  const conflictingPrior = structuredClone(first.receipt);
  conflictingPrior.rawArtifactSha256 = "3".repeat(64);
  conflictingPrior.evidenceContentSha256 = "4".repeat(64);
  conflictingPrior.matchedSocketLedgerDigest = "5".repeat(64);
  const priorReceipts = [first.receipt, conflictingPrior];
  const priorSnapshot = JSON.stringify(priorReceipts);
  const priorConflict = captureError(() => reconcile(
    evidence,
    [socket],
    [socketCommission(socket)],
    { priorReceipts, verifiedAt: "2026-09-10T15:04:00.000Z" }
  ));
  assert.equal(priorConflict.code, "RECEIPT_OVERLAP_CONFLICT");
  assert.throws(
    () => reconciliationJournalEntry(priorConflict),
    /live reconciliation result or overlap error/
  );
  assert.equal(JSON.stringify(priorReceipts), priorSnapshot);

  const malformedPrior = structuredClone(first.receipt);
  delete malformedPrior.adapterId;
  const malformedError = captureError(() => reconcile(
    evidence,
    [socket],
    [socketCommission(socket)],
    { priorReceipts: [malformedPrior], verifiedAt: "2026-09-10T15:04:00.000Z" }
  ));
  assert.throws(
    () => reconciliationJournalEntry(malformedError),
    /live reconciliation result or overlap error/
  );
});

test("receipts append immutably, identical evidence is idempotent, and digest reuse conflicts", () => {
  const values = fixture78();
  const evidence = validate(values.input, values.raw);
  const first = reconcile(evidence, values.socketExecutions, values.socketCommissions);
  const priorReceipts = Object.freeze([first.receipt]);
  const priorSnapshot = JSON.stringify(priorReceipts);
  const again = reconcile(evidence, values.socketExecutions, values.socketCommissions, {
    priorReceipts,
    verifiedAt: "2026-09-10T15:04:00.000Z",
  });
  assert.equal(again.idempotent, true);
  assert.strictEqual(again.receipt, first.receipt);
  assert.equal(again.receipts.length, 1);
  assert.equal(
    reconciliationJournalEntry(again).receiptId,
    reconciliationJournalEntry(first).receiptId
  );
  assert.equal(JSON.stringify(priorReceipts), priorSnapshot);

  const conflictingInput = structuredClone(values.input);
  conflictingInput.finality.assertionId = "synthetic-source-finality-reparsed";
  const conflicting = validate(conflictingInput, values.raw);
  const reboundError = captureError(() =>
    reconcile(conflicting, values.socketExecutions, values.socketCommissions, {
      priorReceipts,
      verifiedAt: "2026-09-10T15:04:00.000Z",
    }));
  assert.equal(reboundError.code, "RECEIPT_CONFLICT");
  assert.match(reboundError.message, /previously bound to different content/);
  assert.throws(
    () => reconciliationJournalEntry(reboundError),
    /live reconciliation result or overlap error/
  );

  const economicsConflict = structuredClone(values.input);
  economicsConflict.executions[0].economics.price += 1;
  const unrelatedError = captureError(() =>
    reconcile(
      validate(economicsConflict, values.raw),
      values.socketExecutions,
      values.socketCommissions
    ));
  assert.equal(unrelatedError.code, "ECONOMICS_MISMATCH");
  assert.throws(
    () => reconciliationJournalEntry(unrelatedError),
    /live reconciliation result or overlap error/
  );
});
