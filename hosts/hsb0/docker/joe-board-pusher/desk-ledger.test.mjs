import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  CURRENT_DESK_OWNERSHIP_POLICY,
  DESK_LOT_ON_FLAT_CONTRACT,
  LEDGER_UNRECONCILED,
  buildDeskDayBoundaryEvidence,
  calculateDeskEquities,
  deskLedgerAlert,
  deskLedgerMatchesHistory,
  deskOwnershipPolicyContract,
  deskLedgerRevisionAt,
} from "./desk-ledger.mjs";
import { J_DATED_CLIENT_ASSIGNMENTS, J_FAMILY_CLASSIFIER, executionTime } from "./execution-history.mjs";
import { copyDeskActivity, deskState, executionActivity, newYorkDay } from "./desk-activity.mjs";
import { projectBestAvailableHistory } from "./family-history.mjs";
import { contractsNeedingFlatNetMarks } from "./flat-net-marks.mjs";
import { EXECUTION_CAPTURE_SCHEMA, reconcileExecutionCapture } from "./execution-reconciliation.mjs";
import { VIRTUAL_SHARED_ACCOUNT_OWNERSHIP, calculateFamily } from "./family-ledger.mjs";
import { createExecutorAttribution } from "./executor-attribution.mjs";
import { createExecutorAttributionMemory } from "./executor-attribution-memory.mjs";
import { copyObservation } from "./v2-stage-handoff.mjs";
import { buildCandidate, validObservation } from "./v2-stage-worker.mjs";
import { validateContract } from "./contracts/index.mjs";
import { projectBook } from "./project.mjs";
import { createDeskDayPnlProducer } from "./day-baseline.mjs";

const ACCOUNT = "SYNTHETIC-PAPER";
const START = "2026-09-10T04:00:00Z";
const CUTOFF = "2026-09-11T15:00:00.000Z";
const OBSERVED = "2026-09-11T15:00:02.000Z";
// Historical synthetic ledgers predate the OPS-557 fills and use that policy.
const PRE_OVERRIDE_POLICY = { ...CURRENT_DESK_OWNERSHIP_POLICY, fillAttributionOverrides: [] };
// The NVDA-only fixture holds the OPS-557 fills alone: the policy as deployed
// before JOED-196. currentFixture() adds the AVGO/AMD fills for the full table.
const OPS557_POLICY = { ...CURRENT_DESK_OWNERSHIP_POLICY, fillAttributionOverrides:
  CURRENT_DESK_OWNERSHIP_POLICY.fillAttributionOverrides.filter(rule => rule.basis.startsWith("OPS-557 ")) };
const JOED196_OVERRIDES = CURRENT_DESK_OWNERSHIP_POLICY.fillAttributionOverrides.filter(rule => rule.basis.startsWith("JOED-196 "));
const UNRECONCILED_DESKS = { j: { reconciled: false }, joe: { reconciled: false }, joel: { reconciled: false } };

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
    markObservedAt: "2026-09-11T14:59:59Z",
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
    ownershipMode: VIRTUAL_SHARED_ACCOUNT_OWNERSHIP,
  });
  return { ledgerState, verifiedHistoryState, portfolio, positions, fx, jResult, policy: PRE_OVERRIDE_POLICY };
}

function crossBookedFills() {
  const source = JSON.parse(readFileSync(new URL("./fixtures/joed196-avgo-amd.json", import.meta.url), "utf8"));
  return source.fills.map(({ symbol, ...fill }) => ({ contract: structuredClone(source.contracts[symbol]),
    execution: { ...fill, acctNumber: source.account, pendingPriceRevision: false } }));
}

// NVDA plus the JOED-196 AVGO/AMD fills: every row of the current table matches.
function currentFixture() {
  return nvdaFixture({ policy: CURRENT_DESK_OWNERSHIP_POLICY, extra: crossBookedFills() });
}

function nvdaFixture({ policy = OPS557_POLICY, extra = [] } = {}) {
  const source = JSON.parse(readFileSync(new URL("./fixtures/ops557-nvda.json", import.meta.url), "utf8"));
  const observedAt = "2026-11-04T12:00:00.000Z";
  const executions = [...source.fills.map(fill => ({ contract: structuredClone(source.contract),
    execution: { ...fill, acctNumber: source.account, pendingPriceRevision: false } })), ...extra];
  const commissions = executions.map(row => commission(row.execution.execId));
  const executorAttribution = createExecutorAttribution({ account: ACCOUNT, executionRows: executions,
    ledger: { schema: "barta.paper-desk-executor-state.v1", account: ACCOUNT, executions,
      intents: { "ops557-synthetic": { action: "place", desk: "joe",
        result: { bracket: { clientId: 705, parentOrderId: 557, stopOrderId: 558 } } } } } });
  return {
    account: ACCOUNT, observedAt, executorAttribution, policy,
    ledgerState: { account: ACCOUNT, periodStart: START, coverageThrough: observedAt,
      coverageTradingDay: "2026-11-04", queryExecutionIdentities: [], executions, commissions },
    verifiedHistoryState: officialHistory(executions, commissions, { toExclusive: observedAt, capturedAt: observedAt }),
    portfolio: [],
    positions: fixture().positions.filter(row => row.symbol !== "ACME"),
    fx: { baseCurrency: "EUR", rates: { EUR: 1, USD: 0.9 },
      rateObservedAt: { EUR: observedAt, USD: observedAt }, observedAt },
  };
}

test("an exact fill override wins over the clientId rule without changing broker records", () => {
  const input = fixture();
  const before = structuredClone(input.ledgerState);
  const policy = { ...CURRENT_DESK_OWNERSHIP_POLICY, fillAttributionOverrides: [
    { execId: "j.open.01", desk: "joe", basis: "synthetic cross-booked close", date: "2026-11-04" },
  ] };
  const result = calculateDeskEquities({ ...input, account: ACCOUNT, observedAt: OBSERVED, policy, jResult: null });
  assert.equal(result.ok, true, result.reason);
  assert.deepEqual(result.desks.j.positions, []);
  assert.equal(result.desks.joe.positions[0].quantity, 1);
  assert.deepEqual(input.ledgerState, before);
  assert.deepEqual(policy.assignments, CURRENT_DESK_OWNERSHIP_POLICY.assignments);
});

test("absent and similar override identities fail closed without redirecting a fill", () => {
  const input = fixture();
  const before = structuredClone(input);
  for (const execId of ["absent.01", "j.open.02", "prefix-j.open.01", "j.open.01-suffix"]) {
    const policy = { ...CURRENT_DESK_OWNERSHIP_POLICY, fillAttributionOverrides: [
      { execId, desk: "joe", basis: "synthetic absent override", date: "2026-11-04" },
    ] };
    const result = calculateDeskEquities({ ...input, account: ACCOUNT, observedAt: OBSERVED, policy });
    assert.equal(result.ok, false);
    assert.equal(result.reason, "desk fill attribution override fillAttributionOverrides[0] must match exactly one fill");
    assert.equal(Object.hasOwn(result, "desks"), false);
    assert.deepEqual(input, before);
  }
});

test("OPS-557 closes both NVDA desk ledgers and the account without flat-net marks", () => {
  const input = nvdaFixture();
  const before = structuredClone(input.ledgerState);
  const { fillAttributionOverrides } = input.policy;
  assert.equal(fillAttributionOverrides.length, 3);
  const jResult = calculateFamily({ ...input, executions: input.ledgerState.executions,
    commissions: input.ledgerState.commissions, familyClientIds: J_FAMILY_CLASSIFIER.familyClientIds,
    familyClientAssignments: J_DATED_CLIENT_ASSIGNMENTS, fillAttributionOverrides,
    excludedSymbols: J_FAMILY_CLASSIFIER.excludedSymbols, periodStart: START,
    ownershipMode: VIRTUAL_SHARED_ACCOUNT_OWNERSHIP });
  assert.equal(jResult.ok, true, jResult.reason);
  const result = calculateDeskEquities({ ...input, jResult });
  assert.equal(result.ok, true, result.reason);
  assert.equal(input.ledgerState.executions.reduce((net, row) => net +
    (row.execution.side === "BOT" ? 1 : -1) * row.execution.shares, 0), 0);
  for (const desk of ["j", "joe", "joel"]) {
    assert.deepEqual(result.desks[desk].positions, [], `${desk} has no residual NVDA lots`);
    assert.equal(result.desks[desk].unrealizedPnl, 0);
  }
  assert.equal(result.desks.j.realizedPnl, 13.76);
  assert.equal(result.desks.joe.realizedPnl, 11.3);
  assert.equal(jResult.equity, result.desks.j.equity);
  const history = projectBestAvailableHistory({ state: input.verifiedHistoryState,
    familyClientAssignments: J_DATED_CLIENT_ASSIGNMENTS, fillAttributionOverrides,
    executorAttribution: input.executorAttribution });
  assert.equal(history.capturedSubtotal.executionCount, 4);
  assert.deepEqual(history.capturedSubtotal.endingOpenQuantities, []);
  assert.deepEqual(contractsNeedingFlatNetMarks({ ...input, executions: input.ledgerState.executions,
    familyClientIds: J_FAMILY_CLASSIFIER.familyClientIds, familyClientAssignments: J_DATED_CLIENT_ASSIGNMENTS,
    fillAttributionOverrides }), []);
  const legacyMarks = contractsNeedingFlatNetMarks({ ...input, executions: input.ledgerState.executions,
    familyClientIds: J_FAMILY_CLASSIFIER.familyClientIds, familyClientAssignments: J_DATED_CLIENT_ASSIGNMENTS });
  assert.equal(legacyMarks.length, 1, "the fixture reproduces the pre-override virtual NVDA exposure");
  const activity = executionActivity({ ...input.ledgerState, coverageThrough: "2026-10-12T20:00:00Z",
    coverageTradingDay: "2026-10-12" }, input.executorAttribution);
  assert.deepEqual(activity.latest, { j: null, joe: "2026-10-12T19:50:12.000Z", joel: null });
  assert.deepEqual(input.ledgerState, before, "retained economic records remain unchanged");
});

test("fill override identities, desks, basis and date bind the policy hash and history revision", () => {
  const input = currentFixture();
  const priorPolicy = { ...CURRENT_DESK_OWNERSHIP_POLICY, fillAttributionOverrides: [] };
  assert.equal(deskOwnershipPolicyContract(priorPolicy).policyHash,
    "0f9071ea04830168c6b83acd61a9bc0a74553d40ec5fd5216dfac4564d8dd877");
  const current = deskOwnershipPolicyContract();
  assert.notEqual(current.policyHash, deskOwnershipPolicyContract(priorPolicy).policyHash);
  const revision = policy => {
    const result = deskLedgerRevisionAt({ ...input, throughInclusive: input.observedAt, policy });
    return result;
  };
  assert.equal(revision(CURRENT_DESK_OWNERSHIP_POLICY).ok, true);
  assert.equal(revision(priorPolicy).ok, true);
  assert.notEqual(revision(CURRENT_DESK_OWNERSHIP_POLICY).historyRevision, revision(priorPolicy).historyRevision);
  const reversed = { ...CURRENT_DESK_OWNERSHIP_POLICY,
    fillAttributionOverrides: [...CURRENT_DESK_OWNERSHIP_POLICY.fillAttributionOverrides].reverse() };
  assert.deepEqual(deskOwnershipPolicyContract(reversed), current);
  assert.deepEqual(revision(reversed), revision(CURRENT_DESK_OWNERSHIP_POLICY));
  for (const patch of [{ execId: "different.01" }, { desk: "joe" }, { basis: "different evidence" }, { date: "2026-11-03" }]) {
    const policy = structuredClone(CURRENT_DESK_OWNERSHIP_POLICY);
    Object.assign(policy.fillAttributionOverrides[0], patch);
    assert.notEqual(deskOwnershipPolicyContract(policy).policyHash, current.policyHash);
    const changed = revision(policy);
    if (patch.execId) {
      assert.equal(changed.ok, false);
      assert.match(changed.reason, /fillAttributionOverrides\[\d\] must match exactly one fill/);
    } else {
      assert.equal(changed.ok, true, changed.reason);
      assert.notEqual(changed.historyRevision, revision(CURRENT_DESK_OWNERSHIP_POLICY).historyRevision);
    }
  }
});

test("the redundant legacy-route override is a matched guard with unchanged economics", () => {
  const input = currentFixture();
  const result = calculateDeskEquities(input);
  assert.equal(result.ok, true, result.reason);
  const guard = CURRENT_DESK_OWNERSHIP_POLICY.fillAttributionOverrides[1];
  assert.equal(input.ledgerState.executions.filter(row => row.execution.execId === guard.execId).length, 1);
  const policy = { ...CURRENT_DESK_OWNERSHIP_POLICY,
    fillAttributionOverrides: CURRENT_DESK_OWNERSHIP_POLICY.fillAttributionOverrides.filter(rule => rule !== guard) };
  const withoutGuard = calculateDeskEquities({ ...input, policy });
  assert.equal(withoutGuard.ok, true, withoutGuard.reason);
  assert.deepEqual(withoutGuard.desks, result.desks);
  assert.deepEqual(withoutGuard.equity, result.equity);
  assert.notEqual(withoutGuard.sourceContract.policyHash, result.sourceContract.policyHash);
  assert.notEqual(withoutGuard.historyRevision, result.historyRevision);
});

test("missing overrides withhold ledger revisions, authoritative boundary proof and mark selection", () => {
  const input = fixture();
  const policy = { ...PRE_OVERRIDE_POLICY, fillAttributionOverrides: [
    { execId: "synthetic.missing.01", desk: "j", basis: "synthetic missing guard", date: "2026-11-04" },
  ] };
  const revision = deskLedgerRevisionAt({ ...input, account: ACCOUNT, policy, throughInclusive: CUTOFF });
  assert.deepEqual(revision, { ok: false,
    reason: "desk fill attribution override fillAttributionOverrides[0] must match exactly one fill" });
  const boundary = buildDeskDayBoundaryEvidence({
    verifiedHistoryState: input.verifiedHistoryState, account: ACCOUNT, policy,
    candidateSourceObservedAt: "2026-09-11T03:59:00Z", periodStart: "2026-09-11T04:00:00Z",
    proofObservedAt: OBSERVED, candidateHistoryRevision: "a".repeat(64),
  });
  assert.deepEqual(boundary, revision);
  assert.throws(() => contractsNeedingFlatNetMarks({ ...input, executions: input.ledgerState.executions,
    account: ACCOUNT, familyClientIds: J_FAMILY_CLASSIFIER.familyClientIds,
    fillAttributionOverrides: policy.fillAttributionOverrides }), { message: revision.reason });
});

test("a cross-desk close on a flat account is counted as an alert, valued once marked, until its exact override clears both desks", () => {
  const input = fixture();
  const executions = [execution("cross.open.01", 27, "ACME", 101),
    execution("cross.close.01", 22, "ACME", 101, { side: "SLD", price: 11 })];
  const commissions = executions.map(row => commission(row.execution.execId));
  Object.assign(input.ledgerState, { executions, commissions,
    queryExecutionIdentities: executions.map(row => row.execution.execId).sort() });
  input.verifiedHistoryState = officialHistory(executions, commissions);
  input.positions = input.positions.filter(row => row.symbol !== "ACME");
  input.portfolio = [];
  input.jResult = null;
  assert.equal(executions.reduce((net, row) => net + (row.execution.side === "BOT" ? 1 : -1) * row.execution.shares, 0), 0);
  const calculate = policy => calculateDeskEquities({ ...input, policy, account: ACCOUNT, observedAt: OBSERVED, phaseB: true });
  const counted = { accountMismatch: 0, crossBooked: 1 };
  const alert = { reason: DESK_LOT_ON_FLAT_CONTRACT, crossBooked: 1 };
  const crossed = calculate(PRE_OVERRIDE_POLICY);
  assert.equal(crossed.ok, false);
  assert.match(crossed.reason, /J desk calculation unavailable: .*mark/);
  assert.equal(crossed.phaseBDesks.j.reconciled, false);
  assert.equal(crossed.phaseBDesks.joe.reconciled, false);
  assert.deepEqual(crossed.ledgerReconciliation, counted, "the count survives the later missing-mark failure");
  assert.deepEqual(deskLedgerAlert(crossed), alert);
  // OPS-555, mitigated by JOED-196: a real flat-net mark still values the
  // unassigned cross close and publishes J +1 / Joe -1. Rule 2 is alert-only,
  // so the pair is no longer silent, but it is not withheld either.
  input.portfolio = [{ account: ACCOUNT, contract: contract("ACME", 101), symbol: "ACME", pos: 0,
    marketPrice: 11, markObservedAt: OBSERVED }];
  const marked = calculate(PRE_OVERRIDE_POLICY);
  assert.equal(marked.ok, true, marked.reason);
  assert.deepEqual(marked.desks.j.positions.map(({ symbol, quantity }) => ({ symbol, quantity })), [{ symbol: "ACME", quantity: 1 }]);
  assert.deepEqual(marked.desks.joe.positions.map(({ symbol, quantity }) => ({ symbol, quantity })), [{ symbol: "ACME", quantity: -1 }]);
  assert.equal(marked.phaseBDesks.j.reconciled, true);
  assert.equal(marked.phaseBDesks.joe.reconciled, true);
  assert.deepEqual(marked.ledgerReconciliation, counted);
  assert.deepEqual(deskLedgerAlert(marked), alert);
  const policy = { ...PRE_OVERRIDE_POLICY, fillAttributionOverrides: [
    { execId: "cross.close.01", desk: "j", basis: "synthetic cross-desk close", date: "2026-11-04" },
  ] };
  const corrected = calculate(policy);
  assert.equal(corrected.ok, true, corrected.reason);
  for (const desk of ["j", "joe", "joel"]) assert.deepEqual(corrected.desks[desk].positions, []);
  assert.equal(Object.hasOwn(corrected, "ledgerReconciliation"), false);
  assert.equal(deskLedgerAlert(corrected), null);
  const before = structuredClone(input.ledgerState);
  for (const change of [
    rows => { rows[1].execution.execId = "cross.near-close.01"; },
    rows => { rows.push(structuredClone(rows[1])); },
    rows => { const correction = structuredClone(rows[1]); correction.execution.execId = "cross.close.02"; rows.push(correction); },
  ]) {
    input.ledgerState = structuredClone(before);
    change(input.ledgerState.executions);
    const failed = calculate(policy);
    assert.equal(failed.ok, false);
    assert.equal(failed.reason, "desk fill attribution override fillAttributionOverrides[0] must match exactly one fill");
    assert.equal(Object.hasOwn(failed, "desks"), false);
    assert.equal(Object.hasOwn(failed, "phaseBDesks"), false);
    const j = calculateFamily({ ...input, executions: input.ledgerState.executions, commissions,
      account: ACCOUNT, observedAt: OBSERVED, periodStart: START,
      familyClientIds: J_FAMILY_CLASSIFIER.familyClientIds, fillAttributionOverrides: policy.fillAttributionOverrides,
      ownershipMode: VIRTUAL_SHARED_ACCOUNT_OWNERSHIP });
    assert.equal(j.ok, false);
    assert.equal(j.reason, failed.reason);
  }
});

test("JOED-196 books each cross-booked AVGO/AMD pair to one desk and leaves the OPS-557 rows untouched", () => {
  const rows = CURRENT_DESK_OWNERSHIP_POLICY.fillAttributionOverrides;
  const ops557 = { basis: "OPS-557 cross-booked NVDA close, 2026-11-04", date: "2026-11-04" };
  const joed196 = { basis: "JOED-196 cross-booked AVGO/AMD close, 2026-11-17", date: "2026-11-17" };
  // The reviewed decision, one row per fill. A changed desk decision edits it
  // here, in desk-ledger.mjs, in replay-joed196.mjs and in the README table.
  assert.deepEqual(rows.map(row => ({ ...row })), [
    { execId: "0000dc8f.6bb0d852.01.01", desk: "j", ...ops557 },
    { execId: "0000dc8f.6bd3bc59.01.01", desk: "j", ...ops557 },
    { execId: "00025b45.6ace1f95.01.01", desk: "joe", ...ops557 },
    { execId: "0000e0d5.6ab27b67.01.01", desk: "j", ...joed196 },
    { execId: "0000dc8f.6bb12ac9.01.01", desk: "j", ...joed196 },
    { execId: "0000dc8f.6bb12336.01.01", desk: "joe", ...joed196 },
    { execId: "0000e0d5.6abb75ef.01.01", desk: "joe", ...joed196 },
  ]);
  assert.equal(Object.isFrozen(rows) && rows.every(row => Object.isFrozen(row)), true);
  assert.deepEqual(OPS557_POLICY.fillAttributionOverrides, rows.slice(0, 3));
  assert.deepEqual(JOED196_OVERRIDES, rows.slice(3));
  assert.equal(deskOwnershipPolicyContract(OPS557_POLICY).policyHash,
    "a7b2b7316e318e78727095d9178df156d5f84a55b7ca801dc9a9aabb12f2591d", "the table deployed before JOED-196");
  assert.equal(deskOwnershipPolicyContract().policyHash,
    "cb3aa48a186a8274f59d09386a7899cee347ec827cea28a5eabce7136e80b2bf");
});

test("JOED-196 closes AVGO and AMD on every desk; the earlier tables leave flat-contract mirrors that are counted", () => {
  const input = currentFixture();
  const before = structuredClone(input.ledgerState);
  const rows = input.ledgerState.executions;
  const net = symbol => rows.filter(row => row.contract.symbol === symbol).reduce((sum, row) => sum +
    (row.execution.side === "BOT" ? 1 : -1) * row.execution.shares, 0);
  for (const symbol of ["NVDA", "AVGO", "AMD"]) assert.equal(net(symbol), 0, `the account is flat on ${symbol}`);
  for (const rule of JOED196_OVERRIDES) assert.equal(rows.filter(row => row.execution.execId === rule.execId).length, 1);
  const jFamily = (fillAttributionOverrides, portfolio = input.portfolio) => calculateFamily({ ...input, portfolio,
    executions: rows, commissions: input.ledgerState.commissions, familyClientIds: J_FAMILY_CLASSIFIER.familyClientIds,
    familyClientAssignments: J_DATED_CLIENT_ASSIGNMENTS, fillAttributionOverrides,
    excludedSymbols: J_FAMILY_CLASSIFIER.excludedSymbols, periodStart: START, ownershipMode: VIRTUAL_SHARED_ACCOUNT_OWNERSHIP });
  const marketData = { fillAttributionOverrides: [], executions: rows,
    familyClientIds: J_FAMILY_CLASSIFIER.familyClientIds, familyClientAssignments: J_DATED_CLIENT_ASSIGNMENTS };

  // The table deployed before JOED-196: J keeps a long, Joe the equal short.
  const marksAt = (symbols, marketPrice) => symbols.map(symbol => ({ account: ACCOUNT, symbol, pos: 0, marketPrice,
    contract: rows.find(row => row.contract.symbol === symbol).contract, markObservedAt: input.observedAt }));
  const marks = marksAt(["AVGO", "AMD"], 77);
  const mirroredJ = jFamily(OPS557_POLICY.fillAttributionOverrides, marks);
  assert.equal(mirroredJ.ok, true, mirroredJ.reason);
  assert.deepEqual(mirroredJ.positions.map(({ symbol, side }) => ({ symbol, side })),
    [{ symbol: "AMD", side: "Long" }, { symbol: "AVGO", side: "Long" }]);
  assert.equal(contractsNeedingFlatNetMarks({ ...input, ...marketData,
    fillAttributionOverrides: OPS557_POLICY.fillAttributionOverrides }).length, 2);
  // Alert-only: each earlier table is counted, never withheld. Without marks the
  // phantom lots cannot be valued, and the count survives that failure. With
  // marks the mirror is published: the two desks move equal and opposite.
  for (const [policy, symbols] of [[OPS557_POLICY, ["AMD", "AVGO"]], [PRE_OVERRIDE_POLICY, ["AMD", "AVGO", "NVDA"]]]) {
    const counted = { accountMismatch: 0, crossBooked: symbols.length };
    const unmarked = calculateDeskEquities({ ...input, policy, portfolio: [], phaseB: true });
    assert.equal(unmarked.ok, false);
    assert.match(unmarked.reason, /^J desk calculation unavailable: missing portfolio mark/);
    assert.deepEqual(unmarked.ledgerReconciliation, counted);
    const valued = marketPrice => {
      const mirrored = calculateDeskEquities({ ...input, policy, portfolio: marksAt(symbols, marketPrice), phaseB: true });
      assert.equal(mirrored.ok, true, mirrored.reason);
      assert.deepEqual(mirrored.ledgerReconciliation, counted, "NVDA, AVGO and AMD mirrors are counted");
      assert.deepEqual(deskLedgerAlert(mirrored), { reason: DESK_LOT_ON_FLAT_CONTRACT, crossBooked: symbols.length });
      assert.deepEqual(mirrored.desks.j.positions.map(({ symbol, side }) => ({ symbol, side })),
        symbols.map(symbol => ({ symbol, side: "Long" })));
      assert.deepEqual(mirrored.desks.joe.positions.map(({ symbol, side }) => ({ symbol, side })),
        symbols.map(symbol => ({ symbol, side: "Short" })));
      for (const desk of ["j", "joe", "joel"]) assert.equal(mirrored.phaseBDesks[desk].reconciled, true);
      return mirrored;
    };
    const [low, high] = [valued(77), valued(78)];
    const move = desk => Math.round((high.desks[desk].unrealizedPnl - low.desks[desk].unrealizedPnl) * 100);
    assert.ok(move("j") > 0, "J's phantom longs gain on a higher mark");
    assert.equal(move("joe"), -move("j"), "the mirror image JOED-196 reported");
    assert.equal(high.equity.total, low.equity.total, "the pair never moves the three-desk total");
  }

  // The current table: each pair is one desk's round trip.
  const fillAttributionOverrides = input.policy.fillAttributionOverrides;
  assert.equal(fillAttributionOverrides.length, 7);
  const jResult = jFamily(fillAttributionOverrides);
  assert.equal(jResult.ok, true, jResult.reason);
  const result = calculateDeskEquities({ ...input, jResult, phaseB: true });
  assert.equal(result.ok, true, result.reason);
  assert.equal(Object.hasOwn(result, "ledgerReconciliation"), false);
  assert.equal(deskLedgerAlert(result), null);
  for (const symbol of ["AVGO", "AMD"]) {
    const desks = new Set(rows.filter(row => row.contract.symbol === symbol)
      .map(row => fillAttributionOverrides.find(rule => rule.execId === row.execution.execId).desk));
    assert.equal(desks.size, 1, `both ${symbol} fills belong to one desk`);
  }
  // The reviewed decision in money: J realises NVDA 13.76 plus AVGO 5.22, Joe
  // NVDA 11.30 plus AMD 7.92. The synthetic pairs realise different amounts,
  // so booking either pair to the other desk fails here. A changed desk
  // decision changes these two numbers (README, JOED-196).
  const realized = { j: 18.98, joe: 19.22, joel: 0 };
  for (const desk of ["j", "joe", "joel"]) {
    assert.deepEqual(result.desks[desk].positions, [], `${desk} has no residual lots`);
    assert.equal(result.desks[desk].unrealizedPnl, 0);
    assert.equal(result.desks[desk].realizedPnl, realized[desk], desk);
    assert.equal(result.phaseBDesks[desk].reconciled, true);
  }
  assert.equal(result.equity.total, 15038.2, "the desk decision moves realised money between desks, never the total");
  assert.equal(jResult.equity, result.desks.j.equity);
  assert.deepEqual(contractsNeedingFlatNetMarks({ ...input, ...marketData, fillAttributionOverrides }), []);
  const history = projectBestAvailableHistory({ state: input.verifiedHistoryState,
    familyClientAssignments: J_DATED_CLIENT_ASSIGNMENTS, fillAttributionOverrides,
    executorAttribution: input.executorAttribution });
  assert.deepEqual(history.capturedSubtotal.endingOpenQuantities, []);
  assert.deepEqual(input.ledgerState, before, "retained economic records remain unchanged");
});

function crossDeskCloseFixture() {
  const input = fixture();
  const executions = [execution("cross.open.01", 27, "ACME", 101),
    execution("cross.close.01", 22, "ACME", 101, { side: "SLD", price: 11 })];
  const commissions = executions.map(row => commission(row.execution.execId));
  Object.assign(input.ledgerState, { executions, commissions,
    queryExecutionIdentities: executions.map(row => row.execution.execId).sort() });
  input.verifiedHistoryState = officialHistory(executions, commissions);
  input.positions = input.positions.filter(row => row.symbol !== "ACME");
  input.portfolio = [{ account: ACCOUNT, contract: contract("ACME", 101), symbol: "ACME", pos: 0,
    marketPrice: 11, observedAt: OBSERVED, markObservedAt: OBSERVED }];
  input.jResult = calculateFamily({ executions, commissions, portfolio: input.portfolio, positions: input.positions,
    fx: input.fx, account: ACCOUNT, familyClientIds: J_FAMILY_CLASSIFIER.familyClientIds,
    excludedSymbols: J_FAMILY_CLASSIFIER.excludedSymbols, periodStart: START, observedAt: OBSERVED,
    ownershipMode: VIRTUAL_SHARED_ACCOUNT_OWNERSHIP });
  return input;
}

// Rule 1 of the flat-contract guard: J owns one ACME, the account holds two.
function accountMismatchFixture() {
  const input = fixture();
  input.positions.find(row => row.symbol === "ACME").pos = 2;
  input.portfolio[0].pos = 2;
  input.jResult = calculateFamily({ executions: input.ledgerState.executions, commissions: input.ledgerState.commissions,
    portfolio: input.portfolio, positions: input.positions, fx: input.fx, account: ACCOUNT,
    familyClientIds: J_FAMILY_CLASSIFIER.familyClientIds, excludedSymbols: J_FAMILY_CLASSIFIER.excludedSymbols,
    periodStart: START, observedAt: OBSERVED, ownershipMode: VIRTUAL_SHARED_ACCOUNT_OWNERSHIP });
  return input;
}

// The pusher's observation as the v2 stager receives it, validated end to end.
function stageV2(input, family, deskEquities, revision) {
  const book = { ts: OBSERVED, gateway: true, gatewayLastSeenAt: OBSERVED, apiReplyCheckedAt: OBSERVED,
    summary: { NetLiquidation: { value: "170000.25", currency: "EUR" }, TotalCashValue: { value: "1234.56", currency: "EUR" } },
    summaryObservedAt: { NetLiquidation: OBSERVED, TotalCashValue: OBSERVED },
    positions: input.positions.map(row => ({ ...row, currency: row.contract.currency })), portfolio: input.portfolio,
    positionsCoverage: { status: "complete", observedAt: OBSERVED }, openOrders: [], ordersObservedAt: OBSERVED };
  const observation = copyObservation({ book, family, deskEquities, executions: executionActivity(input.ledgerState) }, revision);
  assert.equal(validObservation(observation), true);
  const snapshot = buildCandidate(1, OBSERVED, observation, OBSERVED, null, revision);
  const checked = validateContract("data", snapshot, { stage: "ingress" });
  assert.equal(checked.ok, true, JSON.stringify(checked.errors));
  return snapshot;
}

test("desk lots that do not add up to the account stage contract-valid v2 with every desk stuck and all money ledger_unreconciled", () => {
  const input = accountMismatchFixture();
  // The J FIFO replays every fill on the account and fails on the same book.
  assert.deepEqual(input.jResult, { ok: false, failureKind: "pending-input",
    reason: "execution replay does not reconcile with observed broker positions" });
  const deskEquities = calculateDeskEquities({ ...input, jResult: null, account: ACCOUNT, observedAt: OBSERVED, phaseB: true });
  assert.deepEqual(deskEquities, { ok: false, reason: LEDGER_UNRECONCILED,
    ledgerReconciliation: { accountMismatch: 1, crossBooked: 0 }, phaseBDesks: UNRECONCILED_DESKS });
  assert.equal(deskLedgerAlert(deskEquities), null, "a mismatch is the fail-closed reason, not the alert");
  const unreconciled = Object.fromEntries(["equity", "dayPnl", "openPnl", "totalPnl"].map(field => [field, LEDGER_UNRECONCILED]));
  for (const revision of [10, 11]) {
    const snapshot = stageV2(input, input.jResult, deskEquities, revision);
    for (const desk of snapshot.desks) {
      assert.deepEqual(desk.money, { equity: null, dayPnl: null, openPnl: null, totalPnl: null, reasons: unreconciled }, desk.id);
      assert.equal(desk.state, "stuck", desk.id);
    }
    assert.deepEqual(snapshot.totals, { equity: null, dayPnl: null, openPnl: null, totalPnl: null, reasons: unreconciled });
    assert.equal(snapshot.positions.rows.every(row => row.desk === null), true);
  }
});

test("a counted mirror stays alert-only: v1 and contract-valid v2 keep publishing every desk's money", () => {
  const input = crossDeskCloseFixture();
  assert.equal(input.jResult.ok, true, input.jResult.reason);
  const deskEquities = calculateDeskEquities({ ...input, account: ACCOUNT, observedAt: OBSERVED, phaseB: true });
  assert.equal(deskEquities.ok, true, deskEquities.reason);
  assert.deepEqual(deskEquities.ledgerReconciliation, { accountMismatch: 0, crossBooked: 1 });
  assert.deepEqual(deskLedgerAlert(deskEquities), { reason: DESK_LOT_ON_FLAT_CONTRACT, crossBooked: 1 });
  for (const revision of [10, 11]) {
    const snapshot = stageV2(input, input.jResult, deskEquities, revision);
    for (const desk of snapshot.desks) {
      for (const field of ["equity", "openPnl", "totalPnl"]) {
        assert.equal(desk.money[field].currency, "EUR", `${desk.id} ${field} stays published`);
      }
      assert.deepEqual(desk.money.reasons, { dayPnl: "sod_missing" }, `${desk.id}: only DAY waits, for its own reason`);
    }
    assert.deepEqual(snapshot.desks.map(desk => desk.state), ["working", "working", "sit-out"]);
    for (const field of ["equity", "openPnl", "totalPnl"]) assert.equal(snapshot.totals[field].currency, "EUR", field);
    assert.equal(JSON.stringify(snapshot).includes(LEDGER_UNRECONCILED), false, "nothing is withheld as unreconciled");
    assert.equal(JSON.stringify(snapshot).includes(DESK_LOT_ON_FLAT_CONTRACT), false, "the alert changes no pair or contract field");
  }
  const v1 = projectBook({ ts: OBSERVED, gateway: true, summary: {}, positions: input.positions },
    { publisherAt: new Date(OBSERVED), familyRuntimeEnabled: true, family: input.jResult, deskEquities,
      deskOwnershipPolicy: input.policy });
  for (const id of ["j", "joe", "joel"]) {
    assert.equal(v1.desks.find(desk => desk.id === id).money.equity, deskEquities.equity[id], id);
  }
  assert.equal(v1.totals.equity, deskEquities.equity.total);
  assert.deepEqual(v1.desks.flatMap(desk => desk.issues), []);
});

test("flat-contract guard passes owned, flat, exact-KEEP and same-direction shared books", () => {
  const owned = calculateDeskEquities({ ...fixture(), account: ACCOUNT, observedAt: OBSERVED, phaseB: true });
  assert.equal(owned.ok, true, owned.reason);
  assert.equal(owned.desks.j.positions[0].quantity, 1, "J's lot is the account's position");
  assert.equal(Object.hasOwn(owned, "ledgerReconciliation"), false);

  const flat = fixture();
  flat.ledgerState.executions.shift();
  flat.ledgerState.commissions.shift();
  flat.ledgerState.queryExecutionIdentities = flat.ledgerState.executions.map(row => row.execution.execId).sort();
  flat.verifiedHistoryState = officialHistory(flat.ledgerState.executions, flat.ledgerState.commissions);
  flat.positions = flat.positions.filter(row => row.symbol !== "ACME");
  assert.deepEqual(flat.positions.map(row => row.symbol), ["SXR8", "TSLA"], "only exact KEEP remains in the account");
  flat.portfolio = [];
  const flatResult = calculateDeskEquities({ ...flat, jResult: null, account: ACCOUNT, observedAt: OBSERVED, phaseB: true });
  assert.equal(flatResult.ok, true, flatResult.reason);
  for (const desk of ["j", "joe", "joel"]) {
    assert.deepEqual(flatResult.desks[desk].positions, []);
    assert.equal(flatResult.phaseBDesks[desk].reconciled, true);
  }

  const shared = fixture();
  const joeAlso = execution("joe.acme.01", 22, "ACME", 101, { shares: 2, time: "20260911 10:05:00 US/Eastern" });
  shared.ledgerState.executions.push(joeAlso);
  shared.ledgerState.commissions.push(commission(joeAlso.execution.execId));
  shared.ledgerState.queryExecutionIdentities = shared.ledgerState.executions.map(row => row.execution.execId).sort();
  shared.verifiedHistoryState = officialHistory(shared.ledgerState.executions, shared.ledgerState.commissions);
  shared.positions.find(row => row.symbol === "ACME").pos = 3;
  shared.portfolio[0].pos = 3;
  const sharedResult = calculateDeskEquities({ ...shared, jResult: null, account: ACCOUNT, observedAt: OBSERVED });
  assert.equal(sharedResult.ok, true, sharedResult.reason);
  assert.equal(sharedResult.desks.j.positions[0].quantity, 1);
  assert.equal(sharedResult.desks.joe.positions[0].quantity, 2);
});

test("flat-contract guard leaves an opposite lot on a contract the account still holds to the sum", () => {
  // Documented boundary (README, JOED-196): J +4 and Joe -1 add up to the
  // account's +3. Only a flat contract proves that no desk can hold a lot.
  const input = fixture();
  input.ledgerState.executions[0].execution.shares = 4;
  const joeShort = execution("joe.acme.short.01", 22, "ACME", 101, { side: "SLD", time: "20260911 10:05:00 US/Eastern" });
  input.ledgerState.executions.push(joeShort);
  input.ledgerState.commissions.push(commission(joeShort.execution.execId));
  input.ledgerState.queryExecutionIdentities = input.ledgerState.executions.map(row => row.execution.execId).sort();
  input.verifiedHistoryState = officialHistory(input.ledgerState.executions, input.ledgerState.commissions);
  input.positions.find(row => row.symbol === "ACME").pos = 3;
  input.portfolio[0].pos = 3;
  const result = calculateDeskEquities({ ...input, jResult: null, account: ACCOUNT, observedAt: OBSERVED });
  assert.equal(result.ok, true, result.reason);
  assert.equal(result.desks.j.positions[0].quantity, 4);
  assert.equal(result.desks.joe.positions[0].quantity, -1);
});

for (const [label, change] of [
  ["the account holds more than the desks own", input => { input.positions.find(row => row.symbol === "ACME").pos = 2; }],
  ["the account holds the opposite direction", input => { input.positions.find(row => row.symbol === "ACME").pos = -1; }],
  ["a desk lot the account does not hold", input => { input.positions = input.positions.filter(row => row.symbol !== "ACME"); }],
  ["a non-KEEP position no desk owns", input => {
    input.positions.push({ account: ACCOUNT, contract: contract("OTHER", 103), symbol: "OTHER", pos: 1 });
  }],
]) test(`flat-contract guard: ${label} is ledger_unreconciled before any desk is valued`, () => {
  const input = fixture();
  const before = structuredClone(input.ledgerState);
  change(input);
  for (const jResult of [input.jResult, null]) {
    assert.deepEqual(calculateDeskEquities({ ...input, jResult, account: ACCOUNT, observedAt: OBSERVED, phaseB: true }), {
      ok: false, reason: LEDGER_UNRECONCILED,
      ledgerReconciliation: { accountMismatch: 1, crossBooked: 0 }, phaseBDesks: UNRECONCILED_DESKS,
    });
  }
  const plain = calculateDeskEquities({ ...input, account: ACCOUNT, observedAt: OBSERVED });
  assert.deepEqual(plain, { ok: false, reason: LEDGER_UNRECONCILED, ledgerReconciliation: { accountMismatch: 1, crossBooked: 0 } });
  assert.deepEqual(input.ledgerState, before);
});

test("KEEP, ownership and input failures keep their own reasons ahead of the flat-contract guard", () => {
  const mismatch = accountMismatchFixture();
  const calculate = change => {
    const input = structuredClone({ ...mismatch, jResult: null });
    change(input);
    return calculateDeskEquities({ ...input, policy: PRE_OVERRIDE_POLICY, account: ACCOUNT, observedAt: OBSERVED, phaseB: true });
  };
  assert.equal(calculate(() => {}).reason, LEDGER_UNRECONCILED);
  const keep = calculate(input => { input.positions.find(row => row.symbol === "SXR8").pos = 1400; });
  assert.match(keep.reason, /KEEP positions do not exactly match/);
  const unclaimed = calculate(input => {
    input.ledgerState.executions[1].execution.clientId = 99;
    input.verifiedHistoryState = officialHistory(input.ledgerState.executions, input.ledgerState.commissions);
  });
  assert.match(unclaimed.reason, /unclaimed by the desk ownership policy/);
  const duplicateKeep = calculate(input => { input.positions.push(structuredClone(input.positions.find(row => row.symbol === "SXR8"))); });
  assert.match(duplicateKeep.reason, /KEEP positions do not exactly match/);
  const duplicate = calculate(input => { input.positions.push(structuredClone(input.positions.find(row => row.symbol === "ACME"))); });
  assert.match(duplicate.reason, /duplicate observed position contract/);
  const malformed = calculate(input => { input.positions.push({ account: ACCOUNT, pos: 1 }); });
  assert.match(malformed.reason, /position contract symbol is missing/);
  for (const result of [keep, unclaimed, duplicateKeep, duplicate, malformed]) {
    assert.equal(result.ok, false);
    assert.equal(Object.hasOwn(result, "ledgerReconciliation"), false);
    assert.equal(Object.hasOwn(result, "phaseBDesks"), false);
  }
});

test("the ledger-versus-history proof is the valuation's own comparison and fails for the valuation's reason", () => {
  // JOED-196 (Codex gate r2): the offline deploy gate reuses this proof, so a
  // ledger the valuation would reject cannot pass the gate.
  assert.deepEqual(deskLedgerMatchesHistory(currentFixture()), { ok: true });
  assert.equal(calculateDeskEquities(currentFixture()).ok, true);
  const AVGO_BUY = "0000e0d5.6ab27b67.01.01";
  const row = input => input.ledgerState.executions.find(item => item.execution.execId === AVGO_BUY);
  const fee = input => input.ledgerState.commissions.find(item => item.execId === AVGO_BUY);
  const drifted = "live ledger historical economics do not match authoritative all-account history";
  for (const [label, change, reason] of [
    ["price", input => { row(input).execution.price += 1; }, drifted],
    ["quantity", input => { row(input).execution.shares += 1; }, drifted],
    ["side", input => { row(input).execution.side = "SLD"; }, drifted],
    ["time", input => { row(input).execution.time = "2026-09-22T16:08:52Z"; }, drifted],
    ["client", input => { row(input).execution.clientId = 80; }, drifted],
    ["commission amount", input => { fee(input).commission += 0.01; }, drifted],
    ["commission currency", input => { fee(input).currency = "EUR"; }, drifted],
    ["an extra ledger fill", input => {
      const extra = execution("extra.ledger.01", 27, "OTHER", 103, { time: "2026-10-01T15:00:00Z" });
      input.ledgerState.executions.push(extra);
      input.ledgerState.commissions.push(commission("extra.ledger.01"));
    }, drifted],
    ["a history-only price", input => {
      const executions = structuredClone(input.ledgerState.executions);
      executions.find(item => item.execution.execId === AVGO_BUY).execution.price += 1;
      input.verifiedHistoryState = officialHistory(executions, input.ledgerState.commissions,
        { toExclusive: input.observedAt, capturedAt: input.observedAt });
    }, drifted],
    ["missing commission", input => { input.ledgerState.commissions.splice(input.ledgerState.commissions.indexOf(fee(input)), 1); },
      `missing commission for classified execution ${AVGO_BUY}`],
    ["pending correction", input => { row(input).execution.pendingPriceRevision = true; },
      "all-account ledger contains a pending execution correction"],
    ["foreign account", input => { row(input).execution.acctNumber = "SYNTHETIC-OTHER"; },
      "execution account does not match the all-desk source"],
    ["fill after coverage", input => { row(input).execution.time = "2026-11-04T12:00:01Z"; },
      "live ledger contains an execution after its coverage boundary"],
  ]) {
    const input = currentFixture();
    change(input);
    const valuation = calculateDeskEquities(input);
    assert.equal(valuation.ok, false, label);
    assert.equal(valuation.reason, reason, label);
    assert.deepEqual(deskLedgerMatchesHistory(input), { ok: false, reason }, label);
  }
  assert.equal(deskLedgerMatchesHistory({ ...currentFixture(), account: "SYNTHETIC-OTHER" }).ok, false);
  assert.equal(deskLedgerMatchesHistory({ ...currentFixture(), ledgerState: undefined }).ok, false);
  assert.equal(deskLedgerMatchesHistory().ok, false);

  // Fills of the ledger's current New York day lie outside the comparison, here
  // exactly as in the valuation: direct coverage values them from the ledger.
  const today = fixture();
  today.ledgerState.executions[0].execution.price += 1;
  assert.deepEqual(deskLedgerMatchesHistory({ ...today, account: ACCOUNT }), { ok: true });
  assert.equal(calculateDeskEquities({ ...today, jResult: null, account: ACCOUNT, observedAt: OBSERVED }).ok, true);
});

test("NVDA NY boundary evidence uses corrected ownership and rejects a pre-override history revision", () => {
  const input = currentFixture();
  const candidateSourceObservedAt = "2026-11-05T04:59:50.000Z";
  const periodStart = "2026-11-05T05:00:00.000Z";
  const revision = policy => deskLedgerRevisionAt({ ...input, policy,
    throughInclusive: candidateSourceObservedAt });
  const candidate = revision(CURRENT_DESK_OWNERSHIP_POLICY);
  assert.equal(candidate.ok, true, candidate.reason);
  const options = { ...input, candidateSourceObservedAt, periodStart,
    proofObservedAt: "2026-11-05T05:00:10.000Z",
    verifiedHistoryState: officialHistory(input.ledgerState.executions, input.ledgerState.commissions, {
      toExclusive: "2026-11-05T05:00:01.000Z", capturedAt: "2026-11-05T05:00:02.000Z",
    }) };
  const proof = buildDeskDayBoundaryEvidence({ ...options, candidateHistoryRevision: candidate.historyRevision });
  assert.equal(proof.ok, true, proof.reason);
  assert.equal(proof.policyHash, deskOwnershipPolicyContract().policyHash);
  const old = revision({ ...CURRENT_DESK_OWNERSHIP_POLICY, fillAttributionOverrides: [] });
  assert.equal(old.ok, true, old.reason);
  assert.match(buildDeskDayBoundaryEvidence({ ...options, candidateHistoryRevision: old.historyRevision }).reason,
    /economic history changed/);
});

test("invalid and duplicate fill override policies fail closed", () => {
  for (const patch of [{ execId: "" }, { execId: " padded " }, { desk: "unclaimed" },
    { desk: "joel" }, { basis: "" }, { date: "2026-02-30" }, { date: "yesterday" }]) {
    const policy = structuredClone(CURRENT_DESK_OWNERSHIP_POLICY);
    Object.assign(policy.fillAttributionOverrides[0], patch);
    assert.throws(() => deskOwnershipPolicyContract(policy), /override|explicitly empty/);
  }
  const duplicate = structuredClone(CURRENT_DESK_OWNERSHIP_POLICY);
  duplicate.fillAttributionOverrides.push(duplicate.fillAttributionOverrides[0]);
  assert.throws(() => deskOwnershipPolicyContract(duplicate), /duplicate execution/);
});

function executorFixture(desk = "j", orderRef = "j2|masked", clientId = 705) {
  const input = fixture();
  Object.assign(input.ledgerState.executions[0].execution, { clientId, orderId: 101, orderRef });
  const record = { action: "place", desk, result: { bracket: { clientId, parentOrderId: 101, stopOrderId: 102 } } };
  input.executorLedger = { schema: "barta.paper-desk-executor-state.v1", account: ACCOUNT,
    intents: { "masked-intent": record }, executions: structuredClone(input.ledgerState.executions) };
  const clientIds = [...new Set([700, 705, clientId])];
  input.policy = { ...PRE_OVERRIDE_POLICY, executorClientIds: clientIds };
  input.executorAttribution = createExecutorAttribution({ ledger: input.executorLedger, account: ACCOUNT, clientIds });
  input.verifiedHistoryState = officialHistory(input.ledgerState.executions, input.ledgerState.commissions);
  input.jResult = executorFamily(input);
  return input;
}

function executorFamily(input) {
  return calculateFamily({ ...input,
    executions: input.ledgerState.executions, commissions: input.ledgerState.commissions,
    account: ACCOUNT, familyClientIds: J_FAMILY_CLASSIFIER.familyClientIds,
    familyClientAssignments: J_DATED_CLIENT_ASSIGNMENTS, periodStart: START, observedAt: OBSERVED,
    ownershipMode: VIRTUAL_SHARED_ACCOUNT_OWNERSHIP,
  });
}

function opsTestFixture({ flat = true, marker = "ops-test-ko", clientId = 705, mixed = false } = {}) {
  const input = fixture();
  const tests = ["BOT", "SLD"].map((side, index) => {
    const row = execution(`ops.${index}.01`, clientId, "OPS-SYNTH", 303,
      { side, shares: !flat && index ? 2 : 1, price: 50 + index,
        time: `20260910 10:0${index}:00 US/Eastern` });
    Object.assign(row.execution, { orderId: 900 + index, orderRef: `joe|261006|${marker}` });
    return row;
  });
  if (mixed) tests.push({ ...structuredClone(tests[0]), contract: contract("OPS-OTHER", 304),
    execution: { ...tests[0].execution, execId: "ops.other.01", orderId: 902 } });
  input.ledgerState.executions.push(...tests);
  input.ledgerState.commissions.push(...tests.map(row => commission(row.execution.execId, 123)));
  input.executorAttribution = createExecutorAttribution({ account: ACCOUNT, executionRows: input.ledgerState.executions,
    ledger: { schema: "barta.paper-desk-executor-state.v1", account: ACCOUNT, intents: {}, executions: tests }, onEvent() {} });
  input.verifiedHistoryState = officialHistory(input.ledgerState.executions, input.ledgerState.commissions);
  input.jResult = executorFamily(input);
  return input;
}

test("flat OPS tests leave valued desks, fees, history revisions, day-provider acceptance and published totals intact", () => {
  const baseline = calculateDeskEquities({ ...fixture(), account: ACCOUNT, observedAt: OBSERVED });
  const input = opsTestFixture();
  const before = structuredClone(input.ledgerState);
  const result = calculateDeskEquities({ ...input, account: ACCOUNT, observedAt: OBSERVED });
  assert.equal(input.jResult.ok, true, input.jResult.reason);
  assert.equal(result.ok, true, result.reason);
  assert.equal(result.opsTestExecutionCount, 2);
  assert.deepEqual(result.executorClients, [{ client: 705, matched: 0, unmatched: 0, opsTest: 2 }]);
  for (const key of ["desks", "equity", "historyRevision", "ownershipEvidence", "sourceContract"]) {
    assert.deepEqual(result[key], baseline[key], `${key} excludes OPS money, commissions and ownership`);
  }
  assert.deepEqual(Object.keys(result.ownershipEvidence).sort(), ["status", "policyHash", "unclaimedExecutionCount", "exactKeepPositions"].sort());
  let saved;
  const producer = createDeskDayPnlProducer({ account: ACCOUNT, providerContract: result.sourceContract,
    historyRevisionMethod: result.historyRevisionMethod, store: { load: () => ({ ok: true, state: null }), save: state => { saved = state; } },
    buildBoundaryEvidence: () => ({ ok: false }), getVerifiedHistoryState: () => input.verifiedHistoryState, now: () => OBSERVED });
  producer.observe(result);
  assert.deepEqual(saved.latest.equity, baseline.equity, "day-baseline exact provider contract accepts the separate diagnostic");
  const book = { ts: OBSERVED, gateway: true, gatewayLastSeenAt: OBSERVED,
    summary: {}, positions: input.positions.map(row => ({ ...row, currency: row.contract.currency })), portfolio: input.portfolio,
    positionsCoverage: { status: "complete" }, openOrders: [], ordersObservedAt: OBSERVED };
  const v1 = projectBook(book, { publisherAt: new Date(OBSERVED), deskOwnershipPolicy: input.policy,
    familyRuntimeEnabled: true, family: input.jResult, deskEquities: result });
  assert.equal(v1.totals.equity, baseline.equity.total);
  for (const desk of ["j", "joe", "joel"]) assert.equal(v1.desks.find(row => row.id === desk).money.equity, baseline.equity[desk]);
  const v2 = buildCandidate(1, OBSERVED, copyObservation({ book, family: input.jResult, deskEquities: result,
    executions: executionActivity(input.ledgerState, input.executorAttribution), executorAttribution: input.executorAttribution }));
  assert.equal(v2.desks.some(row => row.state === "stuck"), false);
  assert.equal(JSON.stringify(v2).includes("opsTestExecutionCount"), false, "rev 9 is unchanged");
  assert.deepEqual(input.ledgerState, before, "raw broker records remain immutable");
});

for (const options of [{ flat: false }, { mixed: true }, { marker: "xops-test-ko" }, { clientId: 230 }]) {
  test(`unclaimed OPS-looking set ${JSON.stringify(options)} still nulls published totals`, () => {
    const input = opsTestFixture(options);
    const result = calculateDeskEquities({ ...input, account: ACCOUNT, observedAt: OBSERVED, jResult: null });
    assert.equal(result.ok, false);
    assert.match(result.reason, options.flat === false || options.mixed ? /ops_test_not_flat/ : /unclaimed/);
    if (options.mixed) assert.equal(result.opsTestExecutionCount, 2, "flat instrument is independently excluded");
    const projected = projectBook({ ts: OBSERVED, gateway: true, summary: {}, positions: input.positions },
      { publisherAt: new Date(OBSERVED), familyRuntimeEnabled: true, family: input.jResult, deskEquities: result });
    assert.equal(projected.totals.equity, null);
  });
}

test("OPS exceptions preserve all-account historical coverage and receipt checks", () => {
  const input = opsTestFixture();
  input.verifiedHistoryState = officialHistory(fixture().ledgerState.executions, fixture().ledgerState.commissions,
    { fromInclusive: "2026-09-11T04:00:00Z" });
  assert.equal(calculateDeskEquities({ ...input, account: ACCOUNT, observedAt: OBSERVED }).ok, false,
    "missing baseline-to-current-day official coverage stays fail-closed");
  const missingFee = opsTestFixture();
  missingFee.ledgerState.commissions = missingFee.ledgerState.commissions.filter(row => row.execId !== "ops.0.01");
  const feeResult = calculateDeskEquities({ ...missingFee, account: ACCOUNT, observedAt: OBSERVED });
  assert.equal(feeResult.ok, false);
  assert.match(feeResult.reason, /missing commission/);
  const missingReceipt = opsTestFixture();
  missingReceipt.verifiedHistoryState = { ...missingReceipt.verifiedHistoryState, receipts: [] };
  assert.equal(calculateDeskEquities({ ...missingReceipt, account: ACCOUNT, observedAt: OBSERVED }).ok, false,
    "trusted official identities are still required");
});

for (const [clientId, intentDesk] of [[705, "j"], [705, "j2"], [705, "j3"], [705, "j4"], [705, "j5"], [705, "joe"], [705, "joel"], [700, "j"], [812, "j"]]) test(`${clientId} exact intent ${intentDesk}; J FIFO, all-desk v1 and v2 agree on raw IB rows`, () => {
  const desk = ["j2", "j3", "j4", "j5"].includes(intentDesk) ? "j" : intentDesk;
  const input = executorFixture(intentDesk, "joel|masked", clientId);
  assert.equal(input.executorAttribution.attribute(input.ledgerState.executions[0].execution).subDesk, intentDesk);
  const result = calculateDeskEquities({ ...input, account: ACCOUNT, observedAt: OBSERVED });
  assert.equal(input.jResult.ok, true, input.jResult.reason);
  assert.equal(result.ok, true, result.reason);
  assert.deepEqual(result.desks.j.positions, input.jResult.positions);
  assert.equal(result.desks.j.equity, input.jResult.equity);
  assert.equal(result.desks[desk].positions[0].symbol, "ACME");
  assert.equal(Object.values(result.desks).flatMap(value => value.positions).length, 1);
  assert.deepEqual(result.executorClients, [{ client: clientId, matched: 1, unmatched: 0 }]);
  const book = { ts: OBSERVED, gateway: true, gatewayLastSeenAt: OBSERVED,
    summary: {}, positions: input.positions.map(row => ({ ...row, currency: row.contract.currency })), portfolio: input.portfolio,
    positionsCoverage: { status: "complete" }, openOrders: [], ordersObservedAt: OBSERVED };
  const v1 = projectBook(book, { publisherAt: new Date(OBSERVED), familyRuntimeEnabled: true, family: input.jResult, deskEquities: result, deskOwnershipPolicy: input.policy });
  assert.equal(v1.desks.find(value => value.id === desk).money.equity, result.desks[desk].equity);
  const v2 = buildCandidate(1, OBSERVED, copyObservation({ book, family: input.jResult, deskEquities: result,
    executions: executionActivity(input.ledgerState, input.executorAttribution), executorAttribution: input.executorAttribution }));
  assert.equal(v2.positions.rows.find(value => value.symbol === "ACME").desk, desk);
  assert.equal(v2.desks.find(value => value.id === desk).state, "working");
  assert.equal(JSON.stringify(v2).includes('"subDesk"'), false, "rev 9 has no internal sub-desk field");
});

test("executor configuration changes the baseline policy hash while client ordering does not", () => {
  const baseline = deskOwnershipPolicyContract();
  assert.equal(deskOwnershipPolicyContract({ ...CURRENT_DESK_OWNERSHIP_POLICY, executorClientIds: [705, 700] }).policyHash, baseline.policyHash);
  assert.notEqual(deskOwnershipPolicyContract({ ...CURRENT_DESK_OWNERSHIP_POLICY, executorClientIds: [700, 705, 812] }).policyHash, baseline.policyHash);
});

test("remembered executor proofs preserve exact all-desk equity, J history and unstuck v2 states after intent retention", () => {
  const input = executorFixture("j5");
  const memory = createExecutorAttributionMemory({ account: ACCOUNT });
  input.executorAttribution = createExecutorAttribution({ ledger: input.executorLedger, account: ACCOUNT, memory });
  const matched = calculateDeskEquities({ ...input, account: ACCOUNT, observedAt: OBSERVED });
  assert.equal(matched.ok, true, matched.reason);
  const history = projectBestAvailableHistory({ state: input.verifiedHistoryState, executorAttribution: input.executorAttribution });
  input.executorLedger.intents = {};
  input.executorAttribution = createExecutorAttribution({ ledger: input.executorLedger, account: ACCOUNT, memory });
  assert.equal(input.executorAttribution.attribute(input.ledgerState.executions[0].execution).cause, "remembered");
  input.jResult = executorFamily(input);
  const remembered = calculateDeskEquities({ ...input, account: ACCOUNT, observedAt: OBSERVED });
  assert.deepEqual(remembered, matched, "remembering changes no economics, ownership contract or history digest");
  assert.deepEqual(projectBestAvailableHistory({ state: input.verifiedHistoryState, executorAttribution: input.executorAttribution }), history);
  const book = { ts: OBSERVED, gateway: true, gatewayLastSeenAt: OBSERVED,
    summary: {}, positions: input.positions.map(row => ({ ...row, currency: row.contract.currency })), portfolio: input.portfolio,
    positionsCoverage: { status: "complete" }, openOrders: [], ordersObservedAt: OBSERVED };
  const v1 = projectBook(book, { publisherAt: new Date(OBSERVED), deskOwnershipPolicy: input.policy,
    familyRuntimeEnabled: true, family: input.jResult, deskEquities: remembered });
  assert.equal(v1.totals.equity, matched.equity.total);
  const v2 = buildCandidate(1, OBSERVED, copyObservation({ book, family: input.jResult, deskEquities: remembered,
    executions: executionActivity(input.ledgerState, input.executorAttribution), executorAttribution: input.executorAttribution }));
  assert.equal(v2.desks.some(desk => desk.state === "stuck"), false);
  assert.equal(v2.desks.find(desk => desk.id === "j").state, "working");
});

test("only explicit intent desks roll up; bad desks and ambiguous/unmatched routes fail closed everywhere", () => {
  for (const prefix of ["j2", "j5"]) {
    const valid = executorFixture("j", `${prefix}|masked`);
    assert.equal(calculateDeskEquities({ ...valid, account: ACCOUNT, observedAt: OBSERVED }).ok, true);
  }
  for (const condition of ["unmatched", "duplicate", "invalid-desk"]) {
    const input = executorFixture();
    if (condition === "unmatched") input.executorLedger.intents = {};
    if (condition === "duplicate") input.executorLedger.intents.second = structuredClone(input.executorLedger.intents["masked-intent"]);
    if (condition === "invalid-desk") input.executorLedger.intents["masked-intent"].desk = "j20";
    input.executorAttribution = createExecutorAttribution({ ledger: input.executorLedger, account: ACCOUNT });
    const result = calculateDeskEquities({ ...input, account: ACCOUNT, observedAt: OBSERVED, jResult: null });
    assert.equal(result.ok, false);
    assert.match(result.reason, /unclaimed by executor intent ledger/);
    assert.deepEqual(result.executorClients, [{ client: 705, matched: 0, unmatched: 1 }]);
    assert.equal(executorFamily(input).ok, false);
    assert.equal(executionActivity(input.ledgerState, input.executorAttribution).cause, "execution_unowned");
    assert.throws(() => projectBestAvailableHistory({ state: input.verifiedHistoryState, executorAttribution: input.executorAttribution }), /unclaimed/);
  }
});

test("internal sub-desk attribution changes history evidence even when the parent desk stays J", () => {
  const input = executorFixture("j2");
  const before = structuredClone(input.ledgerState.executions);
  const first = deskLedgerRevisionAt({ ...input, account: ACCOUNT, throughInclusive: CUTOFF });
  assert.equal(first.ok, true, first.reason);
  input.executorLedger.intents["masked-intent"].desk = "j5";
  input.executorAttribution = createExecutorAttribution({ ledger: input.executorLedger, account: ACCOUNT });
  const second = deskLedgerRevisionAt({ ...input, account: ACCOUNT, throughInclusive: CUTOFF });
  assert.equal(second.ok, true, second.reason);
  assert.notEqual(second.historyRevision, first.historyRevision);
  assert.deepEqual(input.ledgerState.executions, before, "retained broker rows stay unchanged");
});

test("unmatched KEEP executions on 705 are excluded before intent matching, including missing commissions", () => {
  const input = fixture();
  for (const symbol of ["SXR8", "TSLA"]) {
    const row = execution(`keep.${symbol}.01`, 705, symbol, symbol === "SXR8" ? 201 : 202, { currency: symbol === "SXR8" ? "EUR" : "USD" });
    input.ledgerState.executions.push(row);
    input.ledgerState.queryExecutionIdentities.push(row.execution.execId);
  }
  const result = calculateDeskEquities({ ...input, account: ACCOUNT, observedAt: OBSERVED });
  assert.equal(result.ok, true, result.reason);
  assert.deepEqual(result.desks.j.positions, input.jResult.positions);
  assert.equal(result.executorClients, undefined);
});

test("normalized retained 705 history and NY boundary proofs require the same executor intent key", () => {
  const input = executorFixture();
  const revision = deskLedgerRevisionAt({ ...input, account: ACCOUNT, throughInclusive: CUTOFF });
  assert.equal(revision.ok, true, revision.reason);
  const periodStart = "2026-09-12T04:00:00Z";
  const proofObservedAt = "2026-09-12T04:02:00Z";
  const verifiedHistoryState = officialHistory(input.ledgerState.executions, input.ledgerState.commissions, {
    toExclusive: periodStart, capturedAt: proofObservedAt,
  });
  const options = { verifiedHistoryState, account: ACCOUNT, policy: input.policy, candidateSourceObservedAt: CUTOFF,
    candidateHistoryRevision: revision.historyRevision, periodStart, proofObservedAt,
    executorAttribution: input.executorAttribution };
  const proof = buildDeskDayBoundaryEvidence(options);
  assert.equal(proof.ok, true, proof.reason);
  assert.equal(proof.boundaryHistoryRevision, revision.historyRevision);
  assert.equal(buildDeskDayBoundaryEvidence({ ...options, executorAttribution: null }).ok, false);
  input.executorLedger.intents["masked-intent"].desk = "joe";
  const changed = createExecutorAttribution({ ledger: input.executorLedger, account: ACCOUNT });
  assert.match(buildDeskDayBoundaryEvidence({ ...options, executorAttribution: changed }).reason, /economic history changed/);
});

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

function legacyMacFixture(clientId, time, prefix = "j") {
  const input = fixture();
  const observedAt = new Date(Date.parse(executionTime(time)) + 60_000).toISOString();
  const row = input.ledgerState.executions[0];
  Object.assign(row.execution, { clientId, time, orderRef: `${prefix}|261006|synthetic` });
  Object.assign(input.ledgerState, {
    coverageThrough: observedAt,
    coverageTradingDay: newYorkDay(Date.parse(observedAt)),
    queryExecutionIdentities: [row.execution.execId],
  });
  input.verifiedHistoryState = officialHistory(input.ledgerState.executions, input.ledgerState.commissions, {
    toExclusive: observedAt, capturedAt: observedAt,
  });
  Object.assign(input.portfolio[0], { observedAt, markObservedAt: observedAt });
  Object.assign(input.fx, { observedAt, rateObservedAt: { EUR: observedAt, USD: observedAt } });
  input.jResult = calculateFamily({
    executions: input.ledgerState.executions, commissions: input.ledgerState.commissions,
    portfolio: input.portfolio, positions: input.positions, fx: input.fx,
    account: ACCOUNT, familyClientIds: J_FAMILY_CLASSIFIER.familyClientIds,
    familyClientAssignments: J_DATED_CLIENT_ASSIGNMENTS, excludedSymbols: J_FAMILY_CLASSIFIER.excludedSymbols,
    periodStart: START, observedAt, ownershipMode: VIRTUAL_SHARED_ACCOUNT_OWNERSHIP,
  });
  return { ...input, observedAt, account: ACCOUNT };
}

test("J's dated legacy route has one canonical open-ended assignment shared by all-desk accounting", () => {
  assert.deepEqual(CURRENT_DESK_OWNERSHIP_POLICY.assignments.filter(row => row.clientId === 229), J_DATED_CLIENT_ASSIGNMENTS);
  assert.equal(J_DATED_CLIENT_ASSIGNMENTS[0].desk, "j");
  assert.equal(J_DATED_CLIENT_ASSIGNMENTS[0].fromInclusive, "2026-10-06T13:40:47Z");
  assert.equal(J_DATED_CLIENT_ASSIGNMENTS[0].toExclusive, null);
  const prior = structuredClone(CURRENT_DESK_OWNERSHIP_POLICY);
  prior.assignments = prior.assignments.filter(row => row.clientId !== 229);
  assert.notEqual(deskOwnershipPolicyContract().policyHash, deskOwnershipPolicyContract(prior).policyHash);
});

for (const prefix of ["J", "j"]) for (const time of [
  "20261006 09:40:47 US/Eastern",
  "2026-10-06T13:40:47Z", "2026-10-06T13:40:47.000Z", "2026-10-20T13:40:47.000Z", "2027-10-20T13:40:47.000Z",
]) test(`legacy client 229 belongs to J at ${time} with ${prefix}| and keeps v1/v2 aligned`, () => {
  const input = legacyMacFixture(229, time, prefix);
  assert.equal(input.jResult.ok, true, input.jResult.reason);
  assert.equal(input.jResult.executionCount, 1);
  const result = calculateDeskEquities(input);
  assert.equal(result.ok, true, result.reason);
  assert.deepEqual(result.equity, { j: 5000.81, joe: 4998.92, joel: 5000, total: 14999.73 });
  assert.equal(result.ownershipEvidence.unclaimedExecutionCount, 0);
  assert.equal(result.desks.j.positions[0].symbol, "ACME");
  const executions = executionActivity(input.ledgerState);
  assert.deepEqual(executions.latest, { j: executionTime(time), joe: null, joel: null });
  const activity = copyDeskActivity({
    book: { ts: input.observedAt, gateway: true, positionsCoverage: { status: "complete" },
      ordersObservedAt: input.observedAt, openOrders: [] }, deskEquities: result, executions,
  });
  assert.equal(deskState(activity.j, input.observedAt, input.observedAt), "working");
  assert.equal(deskState(activity.joe, input.observedAt, input.observedAt), "sit-out");
  const history = projectBestAvailableHistory({ state: input.verifiedHistoryState,
    familyClientAssignments: J_DATED_CLIENT_ASSIGNMENTS });
  assert.equal(history.capturedSubtotal.executionCount, 1);
  assert.equal(history.capturedSubtotal.commissionCount, 1);
});

for (const [clientId, time] of [
  [229, "20261006 09:40:46 US/Eastern"],
  [229, "2026-10-06T13:40:46Z"], [229, "2026-10-06T13:40:46.999Z"], [230, "2026-10-06T13:40:47Z"],
]) test(`client ${clientId} at ${time} fails closed even with a J| tag`, () => {
  const input = legacyMacFixture(clientId, time, "J");
  const result = calculateDeskEquities(input);
  assert.equal(result.ok, false);
  assert.match(result.reason, /unclaimed/);
  const executions = executionActivity(input.ledgerState);
  assert.deepEqual(executions, { cause: "execution_unowned", clientId });
  const activity = copyDeskActivity({
    book: { ts: input.observedAt, gateway: true, ordersObservedAt: input.observedAt, openOrders: [] },
    deskEquities: result, executions,
  });
  assert.equal(deskState(activity.j, input.observedAt, input.observedAt), "stuck");
  assert.equal(projectBestAvailableHistory({ state: input.verifiedHistoryState,
    familyClientAssignments: J_DATED_CLIENT_ASSIGNMENTS }).capturedSubtotal.executionCount, 0);
});

test("flat-net mark selection applies the same dated J assignment", () => {
  for (const [time, expected] of [["2026-10-06T13:40:46Z", 0], ["2026-10-06T13:40:47Z", 1]]) {
    const j = execution("synthetic.mac.01", 229, "ACME", 101, { time });
    const joe = execution("synthetic.other.01", 22, "ACME", 101, { time, side: "SLD" });
    const needed = contractsNeedingFlatNetMarks({ executions: [j, joe], account: ACCOUNT,
      familyClientIds: J_FAMILY_CLASSIFIER.familyClientIds, familyClientAssignments: J_DATED_CLIENT_ASSIGNMENTS });
    assert.equal(needed.length, expected);
  }
});

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
  assert.deepEqual(result.sourceContract, deskOwnershipPolicyContract(input.policy));
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
    policy: input.policy,
    throughInclusive: periodStart,
  });
  const history = officialHistory(input.ledgerState.executions, input.ledgerState.commissions, {
    toExclusive: "2026-09-12T04:01:00Z",
    capturedAt: "2026-09-12T04:01:01Z",
  });
  const boundary = buildDeskDayBoundaryEvidence({
    verifiedHistoryState: history,
    account: ACCOUNT,
    policy: input.policy,
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
    policy: input.policy,
    throughInclusive: periodStart,
  });
  const revisedHistory = officialHistory(input.ledgerState.executions, input.ledgerState.commissions, {
    toExclusive: "2026-09-12T04:01:00Z",
    capturedAt: "2026-09-12T04:01:01Z",
  });
  assert.match(buildDeskDayBoundaryEvidence({
    verifiedHistoryState: revisedHistory,
    account: ACCOUNT,
    policy: input.policy,
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
    policy: input.policy,
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
    policy: input.policy,
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
    policy: input.policy,
    candidateSourceObservedAt: candidateAt,
    candidateHistoryRevision: candidate.historyRevision,
    periodStart,
    proofObservedAt: "2026-09-12T04:02:00Z",
  }).reason, /economic history changed/);
});

test("Joe ownership claims the 2026-09-23 shared-account order clients and exact KEEP", () => {
  const joe = CURRENT_DESK_OWNERSHIP_POLICY.assignments.filter((row) => row.desk === "joe");
  assert.deepEqual(joe.map((row) => row.clientId), [22, 89, 90, 91, 119, 130, 131, 148, 151, 152]);
  assert.equal(joe.every((row) => row.fromInclusive === START && row.toExclusive === null), true);
  assert.deepEqual(CURRENT_DESK_OWNERSHIP_POLICY.excludedSymbols, ["SXR8", "TSLA"]);
  assert.deepEqual(CURRENT_DESK_OWNERSHIP_POLICY.keepPositions.map((row) => ({ ...row })), [
    { symbol: "SXR8", quantity: 1401 },
    { symbol: "TSLA", quantity: 1 },
  ]);
  const reader = fixture();
  reader.ledgerState.executions.push(execution("reader.01", 92, "OTHER", 103));
  reader.ledgerState.commissions.push(commission("reader.01"));
  reader.ledgerState.queryExecutionIdentities.push("reader.01");
  reader.ledgerState.queryExecutionIdentities.sort();
  reader.verifiedHistoryState = officialHistory(reader.ledgerState.executions, reader.ledgerState.commissions);
  assert.match(calculateDeskEquities({ ...reader, account: ACCOUNT, observedAt: OBSERVED }).reason, /unclaimed/);
});

test("J long and Joe short on one flat contract still produce desk equity and the J family projection, counted as an alert", () => {
  const input = fixture();
  const jLong = execution("j.nvda.long.01", 83, "NVDA", 5001, {
    shares: 4,
    price: 10,
    time: "20260911 10:30:00 US/Eastern",
  });
  const joeShort = execution("joe.nvda.short.01", 119, "NVDA", 5001, {
    side: "SLD",
    shares: 4,
    price: 12,
    time: "20260911 10:31:00 US/Eastern",
  });
  input.ledgerState.executions.push(jLong, joeShort);
  input.ledgerState.commissions.push(commission(jLong.execution.execId), commission(joeShort.execution.execId));
  input.ledgerState.queryExecutionIdentities.push(jLong.execution.execId, joeShort.execution.execId);
  input.ledgerState.queryExecutionIdentities.sort();
  input.verifiedHistoryState = officialHistory(input.ledgerState.executions, input.ledgerState.commissions);
  input.portfolio.push({
    account: ACCOUNT,
    contract: contract("NVDA", 5001),
    symbol: "NVDA",
    pos: 0,
    marketPrice: 11,
    observedAt: "2026-09-11T14:59:59Z",
    markObservedAt: "2026-09-11T14:59:59Z",
  });
  input.jResult = calculateFamily({
    executions: input.ledgerState.executions,
    commissions: input.ledgerState.commissions,
    portfolio: input.portfolio,
    positions: input.positions,
    fx: input.fx,
    account: ACCOUNT,
    familyClientIds: J_FAMILY_CLASSIFIER.familyClientIds,
    excludedSymbols: J_FAMILY_CLASSIFIER.excludedSymbols,
    periodStart: START,
    observedAt: OBSERVED,
    ownershipMode: VIRTUAL_SHARED_ACCOUNT_OWNERSHIP,
  });
  assert.equal(input.jResult.ok, true, input.jResult.reason);
  const nvda = input.jResult.positions.find((row) => row.symbol === "NVDA");
  assert.equal(nvda.side, "Long");
  assert.equal(nvda.quantity, 4);
  assert.deepEqual(input.jResult.openPnlEvidence.residualNonKeepPositions, [
    { contractKey: "conId:5001", symbol: "NVDA", quantity: -4 },
  ]);

  // JOED decision (JOED-196, M1): the fills cannot tell this legitimate book
  // from a cross-booked close, so it keeps its money (as before JOED-196) and
  // is only counted. The executor's anti-piling rule is what keeps it rare.
  for (const jResult of [input.jResult, null]) {
    const result = calculateDeskEquities({ ...input, jResult, account: ACCOUNT, observedAt: OBSERVED });
    assert.equal(result.ok, true, result.reason);
    assert.equal(result.equity.j, 5004.32);
    assert.equal(result.equity.joe, 5002.43);
    assert.equal(result.equity.joel, 5000);
    assert.equal(result.equity.total, 15006.75);
    assert.deepEqual(
      result.desks.j.positions.filter((row) => row.symbol === "NVDA").map(({ side, quantity }) => ({ side, quantity })),
      [{ side: "Long", quantity: 4 }],
    );
    assert.deepEqual(
      result.desks.joe.positions.map(({ symbol, side, quantity }) => ({ symbol, side, quantity })),
      [{ symbol: "NVDA", side: "Short", quantity: -4 }],
    );
    assert.deepEqual(result.ownershipEvidence.exactKeepPositions, [
      { symbol: "SXR8", quantity: 1401 },
      { symbol: "TSLA", quantity: 1 },
    ]);
    assert.deepEqual(result.ledgerReconciliation, { accountMismatch: 0, crossBooked: 1 });
    assert.deepEqual(deskLedgerAlert(result), { reason: DESK_LOT_ON_FLAT_CONTRACT, crossBooked: 1 });
  }
  // Once the account holds the contract again the count clears, although both
  // lots are still open: a cleared count is not proof of correction.
  const held = execution("j.nvda.add.01", 83, "NVDA", 5001, { shares: 1, price: 11, time: "20260911 10:32:00 US/Eastern" });
  input.ledgerState.executions.push(held);
  input.ledgerState.commissions.push(commission(held.execution.execId));
  input.ledgerState.queryExecutionIdentities.push(held.execution.execId);
  input.ledgerState.queryExecutionIdentities.sort();
  input.verifiedHistoryState = officialHistory(input.ledgerState.executions, input.ledgerState.commissions);
  input.positions.push({ account: ACCOUNT, contract: contract("NVDA", 5001), symbol: "NVDA", pos: 1 });
  input.portfolio.find(row => row.symbol === "NVDA").pos = 1;
  const cleared = calculateDeskEquities({ ...input, jResult: null, account: ACCOUNT, observedAt: OBSERVED });
  assert.equal(cleared.ok, true, cleared.reason);
  assert.deepEqual(cleared.desks.j.positions.filter(row => row.symbol === "NVDA").map(row => row.quantity), [5]);
  assert.deepEqual(cleared.desks.joe.positions.map(row => row.quantity), [-4]);
  assert.equal(Object.hasOwn(cleared, "ledgerReconciliation"), false);
  assert.equal(deskLedgerAlert(cleared), null);
});

test("the health reason is present exactly while a flat contract is counted, whatever the outcome", () => {
  const alert = { reason: "desk_lot_on_flat_contract", crossBooked: 2 };
  assert.equal(DESK_LOT_ON_FLAT_CONTRACT, alert.reason);
  for (const ok of [true, false]) {
    assert.deepEqual(deskLedgerAlert({ ok, ledgerReconciliation: { accountMismatch: 0, crossBooked: 2 } }), alert);
    assert.deepEqual(deskLedgerAlert({ ok, reason: LEDGER_UNRECONCILED, ledgerReconciliation: { accountMismatch: 1, crossBooked: 2 } }), alert);
  }
  for (const value of [undefined, null, {}, { ok: true }, { ok: false, reason: LEDGER_UNRECONCILED },
    { ok: false, ledgerReconciliation: { accountMismatch: 3, crossBooked: 0 } },
    { ok: true, ledgerReconciliation: { accountMismatch: 0, crossBooked: -1 } },
    { ok: true, ledgerReconciliation: { accountMismatch: 0, crossBooked: 1.5 } },
    { ok: true, ledgerReconciliation: { accountMismatch: 0, crossBooked: "2" } }]) {
    assert.equal(deskLedgerAlert(value), null);
  }
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

test("Phase B takes money and used FX provenance from the existing reconciled FIFO ledger", () => {
  const input = fixture();
  const value = calculateDeskEquities({ ...input, account: ACCOUNT, observedAt: OBSERVED, phaseB: true });
  assert.equal(value.ok, true, value.reason);
  assert.equal(value.phaseBDesks.j.base, 5000);
  for (const id of ["j", "joe", "joel"]) {
    const row = value.phaseBDesks[id];
    assert.equal(row.reconciled, true);
    assert.equal(row.equity, value.desks[id].equity);
    assert.equal(row.totalPnl, value.desks[id].totalPnl);
    assert.equal(row.openPnl, value.desks[id].unrealizedPnl);
  }
  assert.deepEqual(value.phaseBDesks.j.fx, { base: "USD", quote: "EUR", rate: input.fx.rates.USD,
    source: "ib-account-ExchangeRate", observedAt: "2026-09-11T14:59:58.000Z" });
  assert.equal(value.phaseBDesks.j.oldestInputAt, "2026-09-11T14:59:57.000Z");
  assert.equal(value.phaseBDesks.joel.fx, null, "flat EUR desk makes no conversion claim");
});

test("Phase B keeps independently reconciled siblings when J has no current portfolio mark", () => {
  const input = fixture(); input.portfolio = []; input.jResult = null;
  const value = calculateDeskEquities({ ...input, account: ACCOUNT, observedAt: OBSERVED, phaseB: true });
  assert.equal(value.ok, false);
  assert.deepEqual(value.phaseBDesks.j, { reconciled: false });
  assert.equal(value.phaseBDesks.joe.reconciled, true);
  assert.equal(value.phaseBDesks.joel.reconciled, true);
  assert.equal(value.phaseBDesks.joe.totalPnl, -1.08, "closed owned FIFO after fees, at used USD rate");
});

for (const kind of ["unclaimed", "pre-ledger", "history-gap", "keep-mismatch"]) test(`Phase B ${kind} never supplies exact desk evidence`, () => {
  const input = fixture(); input.jResult = null;
  if (kind === "unclaimed") {
    input.ledgerState.executions[0].execution.clientId = 999;
    input.verifiedHistoryState = officialHistory(input.ledgerState.executions, input.ledgerState.commissions);
  }
  if (kind === "pre-ledger") input.positions.push({ account: ACCOUNT, contract: contract("UNCLAIMED", 999), symbol: "UNCLAIMED", pos: 1 });
  if (kind === "history-gap") input.verifiedHistoryState = { ...structuredClone(input.verifiedHistoryState), receipts: [] };
  if (kind === "keep-mismatch") input.positions.find(row => row.symbol === "TSLA").pos = 2;
  const value = calculateDeskEquities({ ...input, account: ACCOUNT, observedAt: OBSERVED, phaseB: true });
  assert.equal(value.ok, false);
  assert.equal(Object.values(value.phaseBDesks || {}).some(row => row.reconciled), false);
});
