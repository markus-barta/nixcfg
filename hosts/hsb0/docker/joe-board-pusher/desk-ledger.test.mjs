import assert from "node:assert/strict";
import test from "node:test";

import {
  CURRENT_DESK_OWNERSHIP_POLICY,
  buildDeskDayBoundaryEvidence,
  calculateDeskEquities,
  deskOwnershipPolicyContract,
  deskLedgerRevisionAt,
} from "./desk-ledger.mjs";
import { J_FAMILY_CLASSIFIER } from "./execution-history.mjs";
import { EXECUTION_CAPTURE_SCHEMA, reconcileExecutionCapture } from "./execution-reconciliation.mjs";
import { calculateFamily } from "./family-ledger.mjs";

const ACCOUNT = "SYNTHETIC-PAPER";
const START = "2026-09-10T04:00:00Z";
const CUTOFF = "2026-09-11T15:00:00.000Z";
const OBSERVED = "2026-09-11T15:00:02.000Z";

function contract(symbol, conId, currency = "USD") {
  return { symbol, conId, currency, secType: "STK", exchange: "SMART", multiplier: 1 };
}

function execution(execId, clientId, symbol, conId, overrides = {}) {
  return {
    contract: contract(symbol, conId, overrides.currency),
    execution: {
      execId,
      acctNumber: ACCOUNT,
      clientId,
      side: overrides.side || "BOT",
      shares: overrides.shares ?? 1,
      price: overrides.price ?? 10,
      time: overrides.time || "20260911 10:00:00 US/Eastern",
      pendingPriceRevision: false,
    },
  };
}

function commission(execId, amount = 0.1) {
  return { execId, commission: amount, currency: "USD", realizedPNL: null };
}

function officialHistory(executions, commissions, { fromInclusive = START, toExclusive = CUTOFF, capturedAt = OBSERVED } = {}) {
  return reconcileExecutionCapture({
    capture: {
      schema: EXECUTION_CAPTURE_SCHEMA,
      account: ACCOUNT,
      classifier: J_FAMILY_CLASSIFIER,
      source: {
        kind: "paper-api",
        id: "synthetic-official",
        sha256: "a".repeat(64),
        metadata: {
          adapterId: "official-window-json",
          adapterVersion: "1",
          sdkPackage: "ibapi",
          sdkVersion: "10.45.1",
          serverVersion: 223,
          executionRequestFraming: "protobuf",
          parameterizedExecutionFilters: true,
          responseEndedCleanly: true,
          completenessClaimed: true,
        },
      },
      capturedAt,
      window: { fromInclusive, toExclusive },
      coverageStatus: "complete",
      completenessAssertion: { provider: "ibkr-official-sdk-execution-window-v1", assertionId: "synthetic-proof" },
      executions,
      commissions,
    },
    target: { fromInclusive: START, toExclusive },
  });
}

function fixture() {
  const executions = [
    execution("j.open.01", 27, "ACME", 101),
    execution("joe.buy.01", 22, "INTC", 102, { price: 100, time: "20260911 10:10:00 US/Eastern" }),
    execution("joe.sell.01", 22, "INTC", 102, { side: "SLD", price: 99, time: "20260911 10:20:00 US/Eastern" }),
  ];
  const commissions = executions.map((row) => commission(row.execution.execId));
  const portfolio = [{
    account: ACCOUNT,
    contract: contract("ACME", 101),
    symbol: "ACME",
    pos: 1,
    marketPrice: 11,
    observedAt: "2026-09-11T14:59:59Z",
  }];
  const positions = [
    { account: ACCOUNT, contract: contract("ACME", 101), symbol: "ACME", pos: 1 },
    { account: ACCOUNT, contract: contract("SXR8", 201, "EUR"), symbol: "SXR8", pos: 1401 },
    { account: ACCOUNT, contract: contract("TSLA", 202), symbol: "TSLA", pos: 1 },
  ];
  const ledgerState = {
    account: ACCOUNT,
    periodStart: START,
    coverageThrough: CUTOFF,
    coverageTradingDay: "2026-09-11",
    queryExecutionIdentities: executions.map((row) => row.execution.execId).sort(),
    executions,
    commissions,
  };
  const verifiedHistoryState = officialHistory(executions, commissions);
  const fx = {
    baseCurrency: "EUR",
    rates: { EUR: 1, USD: 0.9 },
    rateObservedAt: { EUR: "2026-09-11T14:59:57Z", USD: "2026-09-11T14:59:58Z" },
    observedAt: "2026-09-11T14:59:58Z",
  };
  const jResult = calculateFamily({
    executions,
    commissions,
    portfolio,
    positions,
    fx,
    account: ACCOUNT,
    familyClientIds: J_FAMILY_CLASSIFIER.familyClientIds,
    excludedSymbols: J_FAMILY_CLASSIFIER.excludedSymbols,
    periodStart: START,
    observedAt: OBSERVED,
  });
  return { ledgerState, verifiedHistoryState, portfolio, positions, fx, jResult };
}

function asynchronousHistoricalFixture() {
  const input = fixture();
  for (let index = 0; index < 60; index += 1) {
    input.ledgerState.executions.push(
      execution(`history.${index}.buy.01`, 27, "ACME", 101, { price: 10 }),
      execution(`history.${index}.sell.01`, 27, "ACME", 101, { side: "SLD", price: 10 }),
    );
  }
  input.ledgerState.commissions = input.ledgerState.executions.map((row) => commission(row.execution.execId));
  input.ledgerState.coverageThrough = "2026-09-12T06:02:00Z";
  input.ledgerState.coverageTradingDay = "2026-09-12";
  input.ledgerState.queryExecutionIdentities = [];
  input.verifiedHistoryState = officialHistory(input.ledgerState.executions, input.ledgerState.commissions, {
    toExclusive: "2026-09-12T04:00:00Z",
    capturedAt: "2026-09-12T04:00:01Z",
  });
  input.jResult = null;
  return input;
}

test("complete official all-account evidence produces real J/Joe/Joel EUR equity", () => {
  const input = fixture();
  const result = calculateDeskEquities({ ...input, account: ACCOUNT, observedAt: OBSERVED });
  assert.equal(result.ok, true, result.reason);
  assert.deepEqual(result.equity, { j: 5000.81, joe: 4998.92, joel: 5000, total: 14999.73 });
  assert.equal(result.desks.j.positions.length, 1);
  assert.deepEqual(result.desks.joe.positions, []);
  assert.deepEqual(result.desks.joel.positions, []);
  assert.equal(result.executionCoverage.status, "complete");
  assert.equal(result.executionCoverage.throughInclusive, CUTOFF);
  assert.equal(result.oldestSourceObservedAt, "2026-09-11T14:59:57.000Z");
  assert.equal(result.sourceContract.scope, "stage0-virtual-desks-keep-excluded");
  assert.equal(result.sourceContract.keepExcluded, true);
  assert.deepEqual(result.sourceContract, deskOwnershipPolicyContract());
  assert.match(result.historyRevision, /^[0-9a-f]{64}$/);
  assert.match(result.sourceContract.policyHash, /^[0-9a-f]{64}$/);
});

test("official history composes with a later complete empty current-day cycle", () => {
  const input = asynchronousHistoricalFixture();
  assert.equal(input.ledgerState.executions.length, 123);
  const result = calculateDeskEquities({
    ...input,
    account: ACCOUNT,
    observedAt: "2026-09-12T06:02:00Z",
  });
  assert.equal(result.ok, true, result.reason);
  assert.equal(result.executionCoverage.throughInclusive, "2026-09-12T06:02:00.000Z");
  assert.equal(result.sourceObservedAt, "2026-09-12T06:02:00.000Z");
  assert.equal(Number.isFinite(result.equity.total), true);
});

test("a sidecar-lagging current-day Joe roundtrip is accepted only from the complete direct cycle", () => {
  const input = asynchronousHistoricalFixture();
  const before = calculateDeskEquities({
    ...input,
    account: ACCOUNT,
    observedAt: "2026-09-12T06:02:00Z",
  });
  assert.equal(before.ok, true, before.reason);
  const buy = execution("today.joe.buy.01", 22, "HPE", 104, {
    price: 20,
    time: "20260912 01:00:00 US/Eastern",
  });
  const sell = execution("today.joe.sell.01", 22, "HPE", 104, {
    side: "SLD",
    price: 19,
    time: "20260912 01:01:00 US/Eastern",
  });
  input.ledgerState.executions.push(buy, sell);
  input.ledgerState.commissions.push(commission(buy.execution.execId), commission(sell.execution.execId));
  input.ledgerState.queryExecutionIdentities = [buy.execution.execId, sell.execution.execId];
  const result = calculateDeskEquities({
    ...input,
    account: ACCOUNT,
    observedAt: "2026-09-12T06:02:00Z",
  });
  assert.equal(result.ok, true, result.reason);
  assert.equal(result.desks.joe.positions.length, 0);
  assert.ok(result.desks.joe.realizedPnl < before.desks.joe.realizedPnl);
});

test("an exact-midnight candidate promotes only when no execution exists at the boundary", () => {
  const input = fixture();
  const periodStart = "2026-09-12T04:00:00Z";
  input.ledgerState.coverageThrough = periodStart;
  const candidate = deskLedgerRevisionAt({
    ledgerState: input.ledgerState,
    account: ACCOUNT,
    throughInclusive: periodStart,
  });
  const history = officialHistory(input.ledgerState.executions, input.ledgerState.commissions, {
    toExclusive: "2026-09-12T04:01:00Z",
    capturedAt: "2026-09-12T04:01:01Z",
  });
  const boundary = buildDeskDayBoundaryEvidence({
    verifiedHistoryState: history,
    account: ACCOUNT,
    candidateSourceObservedAt: periodStart,
    candidateHistoryRevision: candidate.historyRevision,
    periodStart,
    proofObservedAt: "2026-09-12T04:02:00Z",
  });
  assert.equal(boundary.ok, true, boundary.reason);
  assert.deepEqual(boundary.executionCoverage, {
    status: "complete",
    fromInclusive: "2026-09-12T04:00:00.000Z",
    throughExclusive: "2026-09-12T04:00:00.000Z",
  });

  const midnight = execution("midnight.01", 27, "NEXT", 301, { time: periodStart });
  input.ledgerState.executions.push(midnight);
  input.ledgerState.commissions.push(commission(midnight.execution.execId));
  const withMidnight = deskLedgerRevisionAt({
    ledgerState: input.ledgerState,
    account: ACCOUNT,
    throughInclusive: periodStart,
  });
  const revisedHistory = officialHistory(input.ledgerState.executions, input.ledgerState.commissions, {
    toExclusive: "2026-09-12T04:01:00Z",
    capturedAt: "2026-09-12T04:01:01Z",
  });
  assert.match(buildDeskDayBoundaryEvidence({
    verifiedHistoryState: revisedHistory,
    account: ACCOUNT,
    candidateSourceObservedAt: periodStart,
    candidateHistoryRevision: withMidnight.historyRevision,
    periodStart,
    proofObservedAt: "2026-09-12T04:02:00Z",
  }).reason, /economic history changed/);
});

test("unclaimed clients, incomplete official coverage, missing fees, and changed KEEP fail closed", () => {
  const unknown = fixture();
  unknown.ledgerState.executions.push(execution("unknown.01", 99, "OTHER", 103));
  unknown.ledgerState.commissions.push(commission("unknown.01"));
  unknown.ledgerState.queryExecutionIdentities.push("unknown.01");
  unknown.ledgerState.queryExecutionIdentities.sort();
  unknown.verifiedHistoryState = officialHistory(unknown.ledgerState.executions, unknown.ledgerState.commissions);
  assert.match(calculateDeskEquities({ ...unknown, account: ACCOUNT, observedAt: OBSERVED }).reason, /unclaimed/);

  const identity = fixture();
  identity.ledgerState.queryExecutionIdentities.pop();
  assert.match(calculateDeskEquities({ ...identity, account: ACCOUNT, observedAt: OBSERVED }).reason, /identities are incomplete/);

  const gap = fixture();
  gap.verifiedHistoryState = officialHistory(gap.ledgerState.executions, gap.ledgerState.commissions, {
    fromInclusive: "2026-09-10T05:00:00Z",
  });
  assert.match(calculateDeskEquities({ ...gap, account: ACCOUNT, observedAt: OBSERVED }).reason, /coverage is incomplete/);

  const fee = fixture();
  fee.ledgerState.commissions.pop();
  assert.match(calculateDeskEquities({ ...fee, account: ACCOUNT, observedAt: OBSERVED }).reason, /missing its commission/);

  const staleDay = fixture();
  staleDay.ledgerState.coverageTradingDay = "2026-09-10";
  assert.match(calculateDeskEquities({ ...staleDay, account: ACCOUNT, observedAt: OBSERVED }).reason, /coverage metadata is invalid/);

  const keep = fixture();
  keep.positions.find((row) => row.symbol === "SXR8").pos = 1400;
  assert.match(calculateDeskEquities({ ...keep, account: ACCOUNT, observedAt: OBSERVED }).reason, /KEEP positions do not exactly match/);
});

test("candidate ledger revision promotes only when official economics remain unchanged to NY midnight", () => {
  const input = fixture();
  const candidateAt = "2026-09-12T03:55:00Z";
  const periodStart = "2026-09-12T04:00:00Z";
  input.ledgerState.coverageThrough = candidateAt;
  const candidate = deskLedgerRevisionAt({
    ledgerState: input.ledgerState,
    account: ACCOUNT,
    throughInclusive: candidateAt,
  });
  assert.equal(candidate.ok, true, candidate.reason);
  const history = officialHistory(input.ledgerState.executions, input.ledgerState.commissions, {
    toExclusive: "2026-09-12T04:01:00Z",
    capturedAt: "2026-09-12T04:01:01Z",
  });
  const boundary = buildDeskDayBoundaryEvidence({
    verifiedHistoryState: history,
    account: ACCOUNT,
    candidateSourceObservedAt: candidateAt,
    candidateHistoryRevision: candidate.historyRevision,
    periodStart,
    proofObservedAt: "2026-09-12T04:02:00Z",
  });
  assert.equal(boundary.ok, true, boundary.reason);
  assert.equal(boundary.boundaryHistoryRevision, candidate.historyRevision);
  assert.equal(boundary.executionCoverage.status, "complete");

  const corrected = structuredClone(input.ledgerState.executions);
  corrected[0].execution.execId = "j.open.02";
  corrected[0].execution.price = 12;
  const revised = officialHistory(corrected, [commission("j.open.02"), ...input.ledgerState.commissions.slice(1)], {
    toExclusive: "2026-09-12T04:01:00Z",
    capturedAt: "2026-09-12T04:01:01Z",
  });
  assert.match(buildDeskDayBoundaryEvidence({
    verifiedHistoryState: revised,
    account: ACCOUNT,
    candidateSourceObservedAt: candidateAt,
    candidateHistoryRevision: candidate.historyRevision,
    periodStart,
    proofObservedAt: "2026-09-12T04:02:00Z",
  }).reason, /economic history changed/);
});

test("overlapping client ownership policy is rejected before any valuation", () => {
  const input = fixture();
  const policy = structuredClone(CURRENT_DESK_OWNERSHIP_POLICY);
  policy.assignments.push({
    desk: "joel", clientId: 22, fromInclusive: START, toExclusive: null, basis: "synthetic conflict",
  });
  policy.emptyDesks = [];
  assert.match(calculateDeskEquities({ ...input, account: ACCOUNT, policy, observedAt: OBSERVED }).reason, /conflicting desk ownership intervals/);
});
