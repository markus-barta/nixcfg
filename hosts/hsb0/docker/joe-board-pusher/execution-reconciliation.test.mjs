#!/usr/bin/env node
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

import {
  effectiveExecutionRecords,
  reconcileExecutionCapture,
  validateBestAvailableHistoryState,
} from "./execution-reconciliation.mjs";

const ACCOUNT = "SYNTHETIC-PAPER";
const CLASSIFIER = { familyClientIds: [51, 56], excludedSymbols: ["SXR8", "TSLA"] };
const TARGET = { fromInclusive: "2026-09-09T04:00:00Z", toExclusive: "2026-09-12T04:00:00Z" };
const ENDPOINT = createHash("sha256").update("paper.invalid:4002:94").digest("hex");

function hash(value) {
  return createHash("sha256").update(value).digest("hex");
}

function execution(execId, time, price = 10) {
  return {
    contract: { conId: 101, symbol: "ACME", secType: "STK", currency: "USD", multiplier: 1 },
    execution: { execId, acctNumber: ACCOUNT, clientId: 56, side: "BUY", shares: 1, price, time },
  };
}

function commission(execId, amount = 0.25) {
  return { execId, commission: amount, currency: "USD", realizedPNL: 0 };
}

function capture({
  id,
  capturedAt,
  window,
  executions = [],
  commissions = [],
  coverageStatus = "complete",
  provider = "ibkr-official-sdk-execution-window-v1",
  endpoint = ENDPOINT,
  includeOfficialMetadata = true,
} = {}) {
  return {
    schema: "inspr.ib.execution-capture.v1",
    account: ACCOUNT,
    classifier: structuredClone(CLASSIFIER),
    source: {
      kind: "paper-api",
      id,
      sha256: hash(`source:${id}`),
      metadata: includeOfficialMetadata ? {
        adapterId: "official-window-json",
        adapterVersion: "1",
        endpointIdentitySha256: endpoint,
        requestId: id,
      } : {},
    },
    capturedAt,
    window,
    coverageStatus,
    completenessAssertion: coverageStatus === "complete" ? { provider, assertionId: `assertion:${id}` } : null,
    executions: structuredClone(executions),
    commissions: structuredClone(commissions),
  };
}

function reconcile(prior, item) {
  return reconcileExecutionCapture({ prior, capture: item, target: TARGET });
}

test("same COMPLETE facts with fresh capture provenance retain one unchanged receipt", () => {
  const row = execution("stable.synthetic.01", "2026-09-11T11:00:00Z");
  const window = { fromInclusive: "2026-09-11T04:00:00Z", toExclusive: "2026-09-11T12:00:00Z" };
  const first = reconcile(null, capture({
    id: "request-1", capturedAt: "2026-09-11T12:00:01Z", window,
    executions: [row], commissions: [commission(row.execution.execId)],
  }));
  const replay = reconcile(first, capture({
    id: "request-2", capturedAt: "2026-09-11T12:15:01Z", window,
    executions: [row], commissions: [commission(row.execution.execId)],
  }));

  assert.deepEqual(replay, first);
  assert.equal(replay.receipts.length, 1);
});

test("advancing same-day COMPLETE windows stay bounded and retain later facts and corrections", () => {
  const original = execution("growing.synthetic.01", "2026-09-11T10:00:00Z");
  let rows = [original];
  let fees = [commission(original.execution.execId)];
  let state = null;
  for (let index = 0; index < 5; index += 1) {
    if (index === 3) {
      const correction = execution("growing.synthetic.02", "2026-09-11T10:00:00Z", 11);
      const laterFill = execution("later-fill.synthetic.01", "2026-09-11T13:00:00Z", 12);
      rows = [...rows, correction, laterFill];
      fees = [...fees, commission(correction.execution.execId, 0.3), commission(laterFill.execution.execId, 0.4)];
    }
    state = reconcile(state, capture({
      id: `advance-${index}`,
      capturedAt: `2026-09-11T1${index + 2}:15:01Z`,
      window: { fromInclusive: "2026-09-11T04:00:00Z", toExclusive: `2026-09-11T1${index + 2}:15:00Z` },
      executions: rows,
      commissions: fees,
    }));
    assert.equal(state.receipts.length, 1);
  }

  assert.deepEqual(state.executions.map((row) => row.execution.execId), [
    "growing.synthetic.01",
    "growing.synthetic.02",
    "later-fill.synthetic.01",
  ]);
  assert.deepEqual(effectiveExecutionRecords(state).map((row) => row.execution.execId), [
    "growing.synthetic.02",
    "later-fill.synthetic.01",
  ]);
  assert.deepEqual(state.receipts[0].executionIds, [
    "growing.synthetic.01",
    "growing.synthetic.02",
    "later-fill.synthetic.01",
  ]);
  assert.deepEqual(state.receipts[0].commissionIds, [
    "growing.synthetic.01",
    "growing.synthetic.02",
    "later-fill.synthetic.01",
  ]);
});

test("coalescing preserves other dates, partial and non-subsumed proofs, wrong authorities, and legacy memberships", () => {
  const priorDay = execution("prior-day.synthetic.01", "2026-09-10T10:00:00Z");
  const today = execution("today.synthetic.01", "2026-09-11T10:00:00Z");
  let state = reconcile(null, capture({
    id: "prior-day", capturedAt: "2026-09-11T04:00:01Z",
    window: { fromInclusive: "2026-09-10T04:00:00Z", toExclusive: "2026-09-11T04:00:00Z" },
    executions: [priorDay], commissions: [commission(priorDay.execution.execId)],
  }));
  state = reconcile(state, capture({
    id: "today-partial", capturedAt: "2026-09-11T11:00:01Z",
    window: { fromInclusive: "2026-09-11T04:00:00Z", toExclusive: "2026-09-11T11:00:00Z" },
    executions: [today], commissions: [commission(today.execution.execId)], coverageStatus: "known",
  }));
  state = reconcile(state, capture({
    id: "today-late-slice", capturedAt: "2026-09-11T14:00:01Z",
    window: { fromInclusive: "2026-09-11T13:00:00Z", toExclusive: "2026-09-11T14:00:00Z" },
    executions: [], commissions: [],
  }));
  state = reconcile(state, capture({
    id: "today-legacy-membership", capturedAt: "2026-09-11T11:30:01Z",
    window: { fromInclusive: "2026-09-11T04:00:00Z", toExclusive: "2026-09-11T11:30:00Z" },
    executions: [today], commissions: [commission(today.execution.execId)],
  }));
  state = reconcile(state, capture({
    id: "today-other-endpoint", capturedAt: "2026-09-11T12:15:01Z",
    window: { fromInclusive: "2026-09-11T04:00:00Z", toExclusive: "2026-09-11T12:15:00Z" },
    executions: [today], commissions: [commission(today.execution.execId)], endpoint: hash("other-endpoint"),
  }));

  const legacyReceiptId = state.receipts.find((receipt) => receipt.source.id === "today-legacy-membership").receiptId;
  const legacyState = structuredClone(state);
  const legacyReceipt = legacyState.receipts.find((receipt) => receipt.receiptId === legacyReceiptId);
  delete legacyReceipt.executionIds;
  delete legacyReceipt.commissionIds;
  assert.equal(validateBestAvailableHistoryState(legacyState), true);

  const advanced = reconcile(legacyState, capture({
    id: "today-authoritative", capturedAt: "2026-09-11T13:00:01Z",
    window: { fromInclusive: "2026-09-11T04:00:00Z", toExclusive: "2026-09-11T13:00:00Z" },
    executions: [today], commissions: [commission(today.execution.execId)],
  }));

  assert.ok(advanced.receipts.some((receipt) => receipt.source.id === "prior-day"));
  assert.ok(advanced.receipts.some((receipt) => receipt.source.id === "today-partial"));
  assert.ok(advanced.receipts.some((receipt) => receipt.source.id === "today-late-slice"));
  assert.ok(advanced.receipts.some((receipt) => receipt.source.id === "today-other-endpoint"));
  assert.ok(advanced.receipts.some((receipt) => receipt.receiptId === legacyReceiptId));
  assert.ok(advanced.receipts.some((receipt) => receipt.source.id === "today-authoritative"));
  assert.deepEqual(advanced.receipts.map((receipt) => receipt.coverageStatus).sort(), [
    "complete", "complete", "complete", "complete", "complete", "known",
  ]);

  const tampered = structuredClone(advanced);
  tampered.receipts.find((receipt) => receipt.executionIds)?.executionIds.push("invented.synthetic.01");
  assert.throws(() => validateBestAvailableHistoryState(tampered), /execution identities are invalid/);
});
