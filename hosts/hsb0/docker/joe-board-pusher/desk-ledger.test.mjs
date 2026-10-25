import assert from "node:assert/strict";
import test from "node:test";

import {
  CURRENT_DESK_OWNERSHIP_POLICY,
  buildDeskDayBoundaryEvidence,
  calculateDeskEquities,
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
import { buildCandidate } from "./v2-stage-worker.mjs";
import { projectBook } from "./project.mjs";
import { createDeskDayPnlProducer } from "./day-baseline.mjs";

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
  return { ledgerState, verifiedHistoryState, portfolio, positions, fx, jResult };
}

function executorFixture(desk = "j", orderRef = "j2|masked", clientId = 705) {
  const input = fixture();
  Object.assign(input.ledgerState.executions[0].execution, { clientId, orderId: 101, orderRef });
  const record = { action: "place", desk, result: { bracket: { clientId, parentOrderId: 101, stopOrderId: 102 } } };
  input.executorLedger = { schema: "barta.paper-desk-executor-state.v1", account: ACCOUNT,
    intents: { "masked-intent": record }, executions: structuredClone(input.ledgerState.executions) };
  const clientIds = [...new Set([700, 705, clientId])];
  input.policy = { ...CURRENT_DESK_OWNERSHIP_POLICY, executorClientIds: clientIds };
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
  const v1 = projectBook(book, { publisherAt: new Date(OBSERVED), familyRuntimeEnabled: true, family: input.jResult, deskEquities: result });
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

for (const [clientId, intentDesk] of [[705, "j"], [705, "j2"], [705, "j5"], [705, "joe"], [705, "joel"], [700, "j"], [812, "j"]]) test(`${clientId} exact intent ${intentDesk}; J FIFO, all-desk v1 and v2 agree on raw IB rows`, () => {
  const desk = ["j2", "j5"].includes(intentDesk) ? "j" : intentDesk;
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
  const v1 = projectBook(book, { publisherAt: new Date(OBSERVED), familyRuntimeEnabled: true, family: input.jResult, deskEquities: remembered });
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
  const options = { verifiedHistoryState, account: ACCOUNT, candidateSourceObservedAt: CUTOFF,
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

test("J long and Joe short on one contract still produce desk equity and the J family projection", () => {
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

  const result = calculateDeskEquities({ ...input, account: ACCOUNT, observedAt: OBSERVED });
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
