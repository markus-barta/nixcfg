import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  FAMILY_BASELINE_PERIOD_START,
  createFamilySessionAdapter,
  createFileFamilyStateStore,
} from "./family-state.mjs";
import {
  EXECUTION_CAPTURE_SCHEMA,
  reconcileExecutionCapture,
} from "./execution-reconciliation.mjs";
import { calculateFamily } from "./family-ledger.mjs";
import { normalizeEconomicCommission, normalizeEconomicExecution } from "./execution-history.mjs";

const ACCOUNT = "SYNTHETIC-PAPER";
const FAMILY_IDS = [27, 28, 29, 50, 51, 52, 53, 54, 55, 56];
const CLASSIFIER = { familyClientIds: FAMILY_IDS, excludedSymbols: ["SXR8", "TSLA"] };
const EVENTS = {
  connected: "connected",
  disconnected: "disconnected",
  managedAccounts: "managedAccounts",
  accountUpdateMulti: "accountUpdateMulti",
  execDetails: "execDetails",
  execDetailsEnd: "execDetailsEnd",
  commissionReport: "commissionReport",
};

class FakeApi extends EventEmitter {
  requests = [];
  reqManagedAccts() { this.requests.push(["managedAccounts"]); }
  reqAccountUpdatesMulti(...args) { this.requests.push(["accountUpdatesMulti", ...args]); }
  cancelAccountUpdatesMulti(...args) { this.requests.push(["cancelAccountUpdatesMulti", ...args]); }
  reqExecutions(...args) { this.requests.push(["executions", ...args]); }
}

function memoryStore(initial = null) {
  let current = initial ? structuredClone(initial) : null;
  let saves = 0;
  return {
    load({ account, periodStart, classifier } = {}) {
      if (current && current.account !== account) return { ok: false, reason: "state account does not match configured account" };
      if (current && current.periodStart !== periodStart) return { ok: false, reason: "state periodStart does not match configured baseline" };
      if (current && JSON.stringify(current.classifier) !== JSON.stringify(classifier)) {
        return { ok: false, reason: "state classifier does not match configured family" };
      }
      return { ok: true, state: current ? structuredClone(current) : null };
    },
    save(next) { current = structuredClone(next); saves += 1; },
    get state() { return current ? structuredClone(current) : null; },
    get saves() { return saves; },
  };
}

function fakeTimers() {
  let nextId = 0;
  const pending = new Map();
  return {
    set(fn, delay) {
      const id = ++nextId;
      pending.set(id, { fn, delay });
      return id;
    },
    clear(id) { pending.delete(id); },
    runDelay(delay) {
      const entry = [...pending.entries()].find(([, value]) => value.delay === delay);
      assert.ok(entry, `no ${delay}ms timer pending`);
      pending.delete(entry[0]);
      entry[1].fn();
    },
    count(delay) { return [...pending.values()].filter((item) => item.delay === delay).length; },
  };
}

function contract(symbol = "ACME", conId = 101, currency = "USD") {
  return { conId, symbol, secType: "STK", currency, exchange: "SMART" };
}

function execution(execId, clientId, overrides = {}) {
  return {
    contract: contract(overrides.symbol, overrides.conId, overrides.currency),
    execution: {
      execId,
      acctNumber: ACCOUNT,
      clientId,
      side: overrides.side || "BOT",
      shares: overrides.shares || 1,
      price: overrides.price || 10,
      time: overrides.time || "20260910 09:30:00 US/Eastern",
    },
  };
}

function commission(execId, overrides = {}) {
  return { execId, commission: overrides.commission ?? 0.25, currency: overrides.currency || "USD" };
}

function calculator(args) {
  return {
    ok: true,
    equity: 5001,
    totalPnl: 1,
    realizedPnl: 0.5,
    unrealizedPnl: 0.5,
    positions: [{ desk: "j", symbol: "ACME", side: "Long", quantity: 1, accountingScope: "stage0", dayPnl: null, currency: "USD", mark: 11, updatedAt: args.observedAt }],
    accounting: { periodStart: args.periodStart, method: "execution-fifo-net-current-fx", detail: "Synthetic test result." },
    observedAt: args.observedAt,
    executionCount: args.executions.length,
  };
}

function setup({
  at = "2026-09-10T12:00:00Z",
  store = memoryStore(),
  calculate = calculator,
  familyClientIds = FAMILY_IDS,
  excludedSymbols = ["SXR8", "TSLA"],
  retryBaseMs = 5_000,
  retryMaxMs = 20_000,
  getVerifiedHistoryState = null,
} = {}) {
  let current = at;
  const timers = fakeTimers();
  const unavailable = [];
  const adapter = createFamilySessionAdapter({
    targetAccount: ACCOUNT,
    familyClientIds,
    excludedSymbols,
    periodStart: FAMILY_BASELINE_PERIOD_START,
    calculateFamily: calculate,
    eventNames: EVENTS,
    store,
    pollIntervalMs: 30_000,
    requestTimeoutMs: 20_000,
    retryBaseMs,
    retryMaxMs,
    retryJitterRatio: 0,
    fxFreshMs: 120_000,
    fxRefreshIntervalMs: 60_000,
    now: () => current,
    random: () => 0.5,
    setTimer: timers.set,
    clearTimer: timers.clear,
    hooks: { onUnavailable: (reason) => unavailable.push(reason) },
    getVerifiedHistoryState,
  });
  return {
    adapter,
    store,
    timers,
    unavailable,
    setNow(value) { current = value; },
  };
}

function verifiedHistory(executions = [], commissions = []) {
  return reconcileExecutionCapture({
    capture: {
      schema: EXECUTION_CAPTURE_SCHEMA,
      account: ACCOUNT,
      classifier: CLASSIFIER,
      source: {
        kind: "paper-api",
        id: "synthetic-official-window",
        sha256: "f".repeat(64),
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
      capturedAt: "2026-09-11T08:00:00Z",
      window: { fromInclusive: FAMILY_BASELINE_PERIOD_START, toExclusive: "2026-09-11T04:00:00Z" },
      coverageStatus: "complete",
      completenessAssertion: { provider: "ibkr-official-sdk-execution-window-v1", assertionId: "synthetic-proof" },
      executions,
      commissions,
    },
    target: { fromInclusive: FAMILY_BASELINE_PERIOD_START, toExclusive: "2026-09-11T04:00:00Z" },
  });
}

function connect(session, api = new FakeApi()) {
  session.adapter.attach(api);
  api.emit(EVENTS.connected);
  api.emit(EVENTS.managedAccounts, ACCOUNT);
  return api;
}

function requestId(api) {
  return api.requests.findLast((row) => row[0] === "executions")?.[1];
}

function complete(api, rows, reports = rows.map((row) => commission(row.execution.execId))) {
  const id = requestId(api);
  for (const row of rows) api.emit(EVENTS.execDetails, id, row.contract, row.execution);
  for (const report of reports) api.emit(EVENTS.commissionReport, report);
  api.emit(EVENTS.execDetailsEnd, id);
}

function fxRequestId(api) {
  return api.requests.findLast((row) => row[0] === "accountUpdatesMulti")?.[1];
}

function emitFx(api, currency, value, requestId = fxRequestId(api)) {
  api.emit(EVENTS.accountUpdateMulti, requestId, ACCOUNT, "", "ExchangeRate", String(value), currency);
}

function book(observedAt = "2026-09-10T12:00:01Z") {
  return {
    summary: { NetLiquidation: { account: ACCOUNT, value: "10000", currency: "EUR" } },
    portfolio: [{ contract: contract(), pos: 1, marketPrice: 11, observedAt }],
    positionsCoverage: { status: "complete", rows: [{ contract: contract(), pos: 1, observedAt }] },
  };
}

test("adapter uses only bounded read requests and waits for all family commissions", () => {
  const session = setup();
  const api = connect(session);
  assert.deepEqual(api.requests.slice(0, 3), [
    ["managedAccounts"],
    ["accountUpdatesMulti", 9701, ACCOUNT, "", true],
    ["executions", 9600, { acctCode: ACCOUNT }],
  ]);

  const family = FAMILY_IDS.map((clientId, index) => execution(`family.${index}.01`, clientId, { conId: 100 + index }));
  const external = execution("external.1.01", 22);
  const id = requestId(api);
  for (const row of [...family, external]) api.emit(EVENTS.execDetails, id, row.contract, row.execution);
  api.emit(EVENTS.execDetailsEnd, id);
  assert.equal(session.adapter.requestInFlight, true);
  for (const row of family.slice(0, -1)) api.emit(EVENTS.commissionReport, commission(row.execution.execId));
  assert.equal(session.adapter.requestInFlight, true);
  api.emit(EVENTS.commissionReport, commission(family.at(-1).execution.execId));

  assert.equal(session.adapter.requestInFlight, false);
  assert.equal(session.store.state.executions.length, FAMILY_IDS.length + 1);
  assert.equal(session.store.state.commissions.length, FAMILY_IDS.length);
  assert.equal(session.timers.count(30_000), 1);
});

test("final runtime registry counts a client-52 family close and excludes Joe client 22", () => {
  let classified = [];
  let configured = [];
  const session = setup({
    calculate: (args) => {
      configured = args.familyClientIds;
      classified = args.executions
        .filter((row) => args.familyClientIds.includes(row.execution.clientId))
        .map((row) => row.execution.clientId);
      return { ...calculator(args), positions: [], executionCount: classified.length };
    },
  });
  const api = connect(session);
  const familyOpen = execution("registry.open.01", 50, { side: "BOT" });
  const familyClose = execution("registry.close.01", 52, { side: "SLD" });
  const joe = execution("registry.joe.01", 22, { symbol: "INTC", conId: 202 });
  complete(api, [familyOpen, familyClose, joe], [
    commission(familyOpen.execution.execId),
    commission(familyClose.execution.execId),
  ]);
  emitFx(api, "EUR", 1);
  emitFx(api, "USD", 0.86);
  const result = session.adapter.project(book());
  assert.equal(result.ok, true);
  assert.deepEqual(configured, FAMILY_IDS);
  assert.deepEqual(classified, [50, 52]);
  assert.equal(classified.includes(22), false);
});

test("request and missing-fee transients share one capped retry policy", () => {
  const session = setup();
  const api = connect(session);
  assert.equal(session.adapter.pollNow(), false);
  const row = execution("wait.1.01", 27);
  const id = requestId(api);
  api.emit(EVENTS.execDetails, id, row.contract, row.execution);
  api.emit(EVENTS.execDetailsEnd, id);
  session.timers.runDelay(20_000);
  assert.equal(session.adapter.requestInFlight, false);
  assert.match(session.unavailable.at(-1), /missing commissions for 1 family fills/);
  assert.equal(session.timers.count(5_000), 1);
  assert.equal(session.adapter.pollNow(), false);
  session.timers.runDelay(5_000);
  assert.equal(api.requests.filter((item) => item[0] === "executions").length, 2);

  session.timers.runDelay(20_000);
  assert.equal(session.timers.count(10_000), 1);
  session.timers.runDelay(10_000);
  session.timers.runDelay(20_000);
  assert.equal(session.timers.count(20_000), 1);
  session.timers.runDelay(20_000);
  session.timers.runDelay(20_000);
  assert.equal(session.timers.count(20_000), 1);
});

test("disconnect and reconnect require fresh data, remove listeners, and ignore an old generation", () => {
  const session = setup();
  const oldApi = connect(session);
  const retained = execution("old.1.01", 27);
  complete(oldApi, [retained]);
  assert.equal(session.adapter.inspectState().executions.length, 1);
  oldApi.emit(EVENTS.disconnected);
  assert.match(session.adapter.project(book()).reason, /fresh complete execution/);

  const nextApi = connect(session);
  assert.equal(oldApi.listenerCount(EVENTS.execDetails), 0);
  const nextId = requestId(nextApi);
  oldApi.emit(EVENTS.execDetails, nextId, contract("STALE", 999), execution("stale.1.01", 27).execution);
  complete(nextApi, [retained]);
  assert.equal(session.adapter.inspectState().executions.length, 1);
});

test("upstream loss suspends family readiness until a fresh adapter generation completes", () => {
  const session = setup();
  const api = connect(session);
  complete(api, [execution("retained.1.01", 27)]);
  emitFx(api, "EUR", 1);
  emitFx(api, "USD", 0.86);
  assert.equal(session.adapter.project(book()).ok, true);

  const requestCount = api.requests.length;
  assert.equal(session.adapter.upstreamUnavailable("synthetic 2110"), true);
  assert.match(session.adapter.project(book()).reason, /fresh complete execution cycle unavailable/);
  assert.equal(session.timers.count(30_000), 0);

  api.emit(EVENTS.managedAccounts, ACCOUNT);
  api.emit(EVENTS.execDetailsEnd, requestId(api));
  emitFx(api, "EUR", 1);
  assert.equal(api.requests.length, requestCount + 1);
  assert.match(session.adapter.project(book()).reason, /fresh complete execution cycle unavailable/);

  session.adapter.retire("synthetic restoration retires old generation");
  const nextApi = connect(session, new FakeApi());
  assert.equal(api.listenerCount(EVENTS.execDetails), 0);
  api.emit(EVENTS.execDetails, requestId(nextApi), contract("STALE", 999), execution("stale.1.01", 27).execution);
  complete(nextApi, [execution("retained.1.01", 27)]);
  emitFx(nextApi, "EUR", 1);
  emitFx(nextApi, "USD", 0.86);
  assert.equal(session.adapter.project(book()).ok, true);
  assert.deepEqual(session.adapter.inspectState().queryExecutionIdentities, ["retained.1.01"]);
});

test("corrupt persistence fails closed and is never overwritten", () => {
  let saves = 0;
  const store = {
    load: () => ({ ok: false, reason: "family ledger state is corrupt JSON" }),
    save: () => { saves += 1; },
  };
  const session = setup({ store });
  const api = connect(session);
  assert.match(session.adapter.blockedReason, /corrupt JSON/);
  assert.equal(api.requests.some((row) => row[0] === "executions"), false);
  assert.equal(saves, 0);
});

test("missing state after the baseline day requires backfill", () => {
  const session = setup({ at: "2026-09-11T12:00:00Z" });
  const api = connect(session);
  complete(api, []);
  assert.match(session.adapter.blockedReason, /backfill required/);
  assert.equal(session.store.state, null);
});

test("persisted coverage resumes ingestion after midnight but stays partial without authoritative continuity", () => {
  const shared = memoryStore();
  const beforeMidnight = setup({ store: shared, at: "2026-09-11T03:59:00Z" });
  complete(connect(beforeMidnight), []);
  assert.equal(shared.state.coverageTradingDay, "2026-09-10");

  const afterMidnight = setup({ store: shared, at: "2026-09-11T04:01:00Z" });
  const api = connect(afterMidnight);
  assert.equal(api.requests.some((row) => row[0] === "executions"), true);
  complete(api, []);
  emitFx(api, "EUR", 1);
  const partial = afterMidnight.adapter.project(book("2026-09-11T04:01:01Z"));
  assert.equal(afterMidnight.adapter.blockedReason, null);
  assert.equal(afterMidnight.store.state.requiresVerifiedHistory, true);
  assert.equal(partial.ok, false);
  assert.equal(partial.partialAccounting.status, "CAPTURED_ESTIMATE");
  assert.equal(partial.partialAccounting.equity, null);
  assert.equal(partial.partialAccounting.dayPnl, null);
  assert.equal(partial.partialAccounting.coverage.status, "partial");
});

test("official complete prior-day receipt plus current-day cycle restores full accounting", () => {
  const shared = memoryStore();
  const beforeMidnight = setup({ store: shared, at: "2026-09-11T03:59:00Z" });
  complete(connect(beforeMidnight), []);
  const history = verifiedHistory();
  const current = setup({
    store: shared,
    at: "2026-09-11T04:01:00Z",
    getVerifiedHistoryState: () => history,
  });
  const api = connect(current);
  complete(api, []);
  emitFx(api, "EUR", 1);
  const result = current.adapter.project(book("2026-09-11T04:01:01Z"));
  assert.equal(result.ok, true);
  assert.equal(result.equity, 5001);
  assert.equal(current.adapter.blockedReason, null);
});

test("retained fills expose current-book partial economics, then trusted continuity restores idempotent full accounting", () => {
  const shared = memoryStore();
  const retained = execution("retained.open.01", 27);
  retained.contract.multiplier = 0;
  const retainedFee = commission(retained.execution.execId);
  const beforeMidnight = setup({
    store: shared,
    at: "2026-09-11T03:59:00Z",
    calculate: calculateFamily,
  });
  complete(connect(beforeMidnight), [retained], [retainedFee]);

  let history = null;
  const afterMidnight = setup({
    store: shared,
    at: "2026-09-11T04:01:00Z",
    calculate: calculateFamily,
    getVerifiedHistoryState: () => history,
  });
  const api = connect(afterMidnight);
  complete(api, []);
  emitFx(api, "EUR", 1);
  emitFx(api, "USD", 0.8);
  const currentBook = book("2026-09-11T04:01:01Z");
  currentBook.portfolio[0].contract.multiplier = 0;
  currentBook.positionsCoverage.rows[0].contract.multiplier = 0;

  const sparse = afterMidnight.adapter.project({ ...currentBook, portfolio: [] });
  assert.equal(sparse.ok, false);
  assert.equal(Object.hasOwn(sparse, "partialAccounting"), false);
  const wrongAccount = structuredClone(currentBook);
  wrongAccount.summary.NetLiquidation.account = "SYNTHETIC-OTHER";
  assert.equal(Object.hasOwn(afterMidnight.adapter.project(wrongAccount), "partialAccounting"), false);

  const partial = afterMidnight.adapter.project(currentBook);
  assert.equal(partial.ok, false);
  assert.equal(partial.partialAccounting.capturedRealizedPnl, -0.2);
  assert.equal(partial.partialAccounting.estimatedOpenPnl, 0.8);
  assert.equal(partial.partialAccounting.capturedTotalPnl, 0.6);
  assert.equal(partial.partialAccounting.equity, null);
  assert.equal(partial.partialAccounting.dayPnl, null);
  assert.equal(partial.partialAccounting.positions[0].accountingScope, "captured-estimate");

  history = verifiedHistory([retained], [retainedFee]);
  const full = afterMidnight.adapter.project(currentBook);
  assert.equal(full.ok, true);
  assert.equal(full.equity, 5000.6);
  assert.deepEqual(afterMidnight.adapter.project(currentBook), full);

  const restarted = setup({
    store: shared,
    at: "2026-09-11T04:01:02Z",
    calculate: calculateFamily,
    getVerifiedHistoryState: () => history,
  });
  const restartedApi = connect(restarted);
  complete(restartedApi, []);
  emitFx(restartedApi, "EUR", 1);
  emitFx(restartedApi, "USD", 0.8);
  assert.equal(restarted.adapter.project(currentBook).equity, 5000.6);
});

test("trusted official history durably adds a recovered closed roundtrip before full projection", () => {
  const shared = memoryStore();
  const firstOpen = execution("captured.first.open.01", 27, { price: 10, time: "20260910 09:30:00 US/Eastern" });
  const firstClose = execution("captured.first.close.01", 27, { side: "SLD", price: 11, time: "20260910 09:31:00 US/Eastern" });
  const recoveredOpen = execution("recovered.second.open.01", 27, { price: 20, time: "20260910 10:30:00 US/Eastern" });
  const recoveredClose = execution("recovered.second.close.01", 27, { side: "SLD", price: 22, time: "20260910 10:31:00 US/Eastern" });
  const rows = [firstOpen, firstClose, recoveredOpen, recoveredClose];
  for (const row of rows) row.contract.multiplier = 0;
  const fees = rows.map((row) => commission(row.execution.execId));

  const beforeMidnight = setup({ store: shared, at: "2026-09-11T03:59:00Z", calculate: calculateFamily });
  complete(connect(beforeMidnight), rows.slice(0, 2), fees.slice(0, 2));
  assert.equal(shared.state.executions.length, 2);

  const history = verifiedHistory(rows, fees);
  const afterMidnight = setup({
    store: shared,
    at: "2026-09-11T04:01:00Z",
    calculate: calculateFamily,
    getVerifiedHistoryState: () => history,
  });
  const api = connect(afterMidnight);
  complete(api, []);
  emitFx(api, "EUR", 1);
  emitFx(api, "USD", 0.8);
  const flatBook = {
    summary: { NetLiquidation: { account: ACCOUNT, value: "10000", currency: "EUR" } },
    portfolio: [],
    positionsCoverage: { status: "complete", rows: [] },
  };
  const result = afterMidnight.adapter.project(flatBook);
  assert.equal(result.ok, true);
  assert.equal(result.executionCount, 4);
  assert.equal(result.realizedPnl, 1.6);
  assert.equal(result.unrealizedPnl, 0);
  assert.equal(result.equity, 5001.6);
  assert.equal(shared.state.executions.length, 4);
  assert.equal(shared.state.commissions.length, 4);

  const restarted = setup({
    store: shared,
    at: "2026-09-11T04:02:00Z",
    calculate: calculateFamily,
    getVerifiedHistoryState: () => history,
  });
  const restartedApi = connect(restarted);
  complete(restartedApi, []);
  emitFx(restartedApi, "EUR", 1);
  emitFx(restartedApi, "USD", 0.8);
  assert.equal(restarted.adapter.project(flatBook).executionCount, 4);
  assert.equal(shared.state.executions.length, 4);
});

test("a conflicting official history identity fails closed without changing the durable ledger", () => {
  const shared = memoryStore();
  const open = execution("history.conflict.open.01", 27, { price: 10 });
  const close = execution("history.conflict.close.01", 27, { side: "SLD", price: 11, time: "20260910 09:31:00 US/Eastern" });
  open.contract.multiplier = 0;
  close.contract.multiplier = 0;
  const before = setup({ store: shared, at: "2026-09-11T03:59:00Z" });
  complete(connect(before), [open, close]);

  const conflicting = structuredClone(open);
  conflicting.execution.price = 99;
  const history = verifiedHistory([conflicting, close], [
    commission(conflicting.execution.execId),
    commission(close.execution.execId),
  ]);
  const after = setup({
    store: shared,
    at: "2026-09-11T04:01:00Z",
    getVerifiedHistoryState: () => history,
  });
  const api = connect(after);
  complete(api, []);
  const durableBefore = shared.state;
  const result = after.adapter.project(book("2026-09-11T04:01:01Z"));
  assert.equal(result.ok, false);
  assert.match(result.reason, /conflicting official history execution/);
  assert.deepEqual(shared.state, durableBefore);
  assert.match(after.adapter.blockedReason, /conflicting official history execution/);
});

test("official current-day evidence stays out of the ledger until legacy replay, then normalizes safely after restart", () => {
  const shared = memoryStore();
  const before = setup({ store: shared, at: "2026-09-11T03:59:00Z" });
  complete(connect(before), []);

  const raw = execution("official.first.legacy.later.01", 27, {
    time: "20260911 09:30:00 US/Eastern",
  });
  raw.contract.multiplier = 0;
  const rawFee = commission(raw.execution.execId);
  const normalized = normalizeEconomicExecution(raw);
  const normalizedFee = normalizeEconomicCommission(rawFee);
  const prior = verifiedHistory();
  const todayPartial = reconcileExecutionCapture({
    prior,
    capture: {
      schema: EXECUTION_CAPTURE_SCHEMA,
      account: ACCOUNT,
      classifier: CLASSIFIER,
      source: {
        kind: "paper-api",
        id: "synthetic-official-current-partial",
        sha256: "d".repeat(64),
        metadata: prior.receipts[0].source.metadata,
      },
      capturedAt: "2026-09-11T14:00:01Z",
      window: { fromInclusive: "2026-09-11T04:00:00Z", toExclusive: "2026-09-11T14:00:00Z" },
      coverageStatus: "complete",
      completenessAssertion: { provider: "ibkr-official-sdk-execution-window-v1", assertionId: "synthetic-current-proof" },
      executions: [normalized],
      commissions: [normalizedFee],
    },
    target: { fromInclusive: FAMILY_BASELINE_PERIOD_START, toExclusive: "2026-09-11T14:00:00Z" },
  });
  const current = setup({
    store: shared,
    at: "2026-09-11T14:01:00Z",
    getVerifiedHistoryState: () => todayPartial,
  });
  const currentApi = connect(current);
  complete(currentApi, []);
  emitFx(currentApi, "EUR", 1);
  assert.equal(current.adapter.project(book("2026-09-11T14:01:01Z")).ok, true);
  assert.equal(shared.state.executions.length, 0);

  current.timers.runDelay(30_000);
  complete(currentApi, [raw], [rawFee]);
  assert.equal(current.adapter.blockedReason, null);
  assert.equal(shared.state.executions.length, 1);
  assert.equal(shared.state.executions[0].execution.side, "BOT");

  const fullToday = reconcileExecutionCapture({
    prior,
    capture: {
      schema: EXECUTION_CAPTURE_SCHEMA,
      account: ACCOUNT,
      classifier: CLASSIFIER,
      source: {
        kind: "paper-api",
        id: "synthetic-official-current-full",
        sha256: "c".repeat(64),
        metadata: prior.receipts[0].source.metadata,
      },
      capturedAt: "2026-09-12T04:00:01Z",
      window: { fromInclusive: "2026-09-11T04:00:00Z", toExclusive: "2026-09-12T04:00:00Z" },
      coverageStatus: "complete",
      completenessAssertion: { provider: "ibkr-official-sdk-execution-window-v1", assertionId: "synthetic-full-day-proof" },
      executions: [normalized],
      commissions: [normalizedFee],
    },
    target: { fromInclusive: FAMILY_BASELINE_PERIOD_START, toExclusive: "2026-09-12T04:00:00Z" },
  });
  const restarted = setup({
    store: shared,
    at: "2026-09-12T04:01:00Z",
    getVerifiedHistoryState: () => fullToday,
  });
  const restartedApi = connect(restarted);
  complete(restartedApi, []);
  emitFx(restartedApi, "EUR", 1);
  emitFx(restartedApi, "USD", 0.8);
  assert.equal(restarted.adapter.project(book("2026-09-12T04:01:01Z")).ok, true);
  assert.equal(restarted.adapter.blockedReason, null);
  assert.equal(shared.state.executions.length, 1);
  assert.equal(shared.state.executions[0].execution.side, "BOT");
});

test("a partial trusted receipt cannot borrow known sidecar identities to prove completeness", () => {
  const rows = Array.from({ length: 78 }, (_, index) => {
    const row = execution(`known.sidecar.${index}.01`, 27, { conId: 1000 + index });
    row.contract.multiplier = 0;
    return normalizeEconomicExecution(row);
  });
  const fees = rows.map((row) => normalizeEconomicCommission(commission(row.execution.execId)));
  let history = verifiedHistory(rows.slice(0, 7), fees.slice(0, 7));
  history = reconcileExecutionCapture({
    prior: history,
    capture: {
      schema: EXECUTION_CAPTURE_SCHEMA,
      account: ACCOUNT,
      classifier: CLASSIFIER,
      source: {
        kind: "persisted-ledger",
        id: "synthetic-known-78",
        sha256: "b".repeat(64),
        metadata: {},
      },
      capturedAt: "2026-09-11T08:01:00Z",
      window: { fromInclusive: FAMILY_BASELINE_PERIOD_START, toExclusive: "2026-09-11T04:00:00Z" },
      coverageStatus: "known",
      completenessAssertion: null,
      executions: rows,
      commissions: fees,
    },
    target: { fromInclusive: FAMILY_BASELINE_PERIOD_START, toExclusive: "2026-09-11T04:00:00Z" },
  });
  const shared = memoryStore();
  const before = setup({ store: shared, at: "2026-09-11T03:59:00Z" });
  complete(connect(before), []);
  const after = setup({
    store: shared,
    at: "2026-09-11T04:01:00Z",
    getVerifiedHistoryState: () => history,
  });
  const api = connect(after);
  complete(api, []);
  emitFx(api, "EUR", 1);
  const result = after.adapter.project(book("2026-09-11T04:01:01Z"));
  assert.equal(result.ok, false);
  assert.match(result.reason, /complete receipts omit a retained execution identity/);
  assert.equal(shared.state.executions.length, 0);
});

test("a same-trading-day restart accepts a complete current-day resync", () => {
  const shared = memoryStore();
  const first = setup({ store: shared, at: "2026-09-10T12:00:00Z" });
  const row = execution("same-day.1.01", 27);
  complete(connect(first), [row]);

  const restarted = setup({ store: shared, at: "2026-09-10T13:00:00Z" });
  const api = connect(restarted);
  complete(api, [row]);
  assert.equal(restarted.adapter.blockedReason, null);
  assert.equal(shared.state.coverageThrough, "2026-09-10T13:00:00.000Z");
  assert.equal(shared.state.ledgerObservedAt, "2026-09-10T12:00:00.000Z");
});

test("a shortened replay retries without changing durable evidence, then a full replay recovers", () => {
  const session = setup();
  const api = connect(session);
  const retained = execution("retained.1.01", 27);
  complete(api, [retained]);
  const before = session.store.state;
  const beforeBytes = JSON.stringify(before);
  const saves = session.store.saves;
  session.timers.runDelay(30_000);
  complete(api, []);
  assert.equal(session.adapter.blockedReason, null);
  assert.match(session.adapter.retryReason, /temporarily omitted 1/);
  assert.deepEqual(session.store.state, before);
  assert.equal(JSON.stringify(session.store.state), beforeBytes);
  assert.equal(session.store.saves, saves);
  assert.match(session.adapter.project(book()).reason, /temporarily omitted 1/);
  assert.equal(session.timers.count(5_000), 1);

  session.timers.runDelay(5_000);
  complete(api, [retained]);
  assert.equal(session.adapter.retryReason, null);
  assert.equal(session.adapter.blockedReason, null);
  emitFx(api, "EUR", 1);
  emitFx(api, "USD", 0.86);
  assert.equal(session.adapter.project(book()).ok, true);
  assert.deepEqual(session.store.state.queryExecutionIdentities, ["retained.1.01"]);
  assert.deepEqual(session.store.state.executions, before.executions);
  assert.deepEqual(session.store.state.commissions, before.commissions);

  session.timers.runDelay(30_000);
  complete(api, []);
  assert.equal(session.timers.count(5_000), 1);
});

test("execution query coverage survives restart and truncated replay remains retryable", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "family-state-test-"));
  const disk = createFileFamilyStateStore(path.join(directory, "family-ledger.json"));
  const retained = execution("restart-retained.1.01", 27);
  const first = setup({ store: disk });
  complete(connect(first), [retained]);

  const restarted = setup({ store: disk, at: "2026-09-10T12:01:00Z" });
  complete(connect(restarted), []);
  assert.equal(restarted.adapter.blockedReason, null);
  assert.match(restarted.adapter.retryReason, /temporarily omitted/);
  assert.deepEqual(restarted.adapter.inspectState().queryExecutionIdentities, ["restart-retained.1.01"]);
});

test("retry survives reconnect without accepting stale-generation execution callbacks", () => {
  const session = setup();
  const retained = execution("generation-retained.1.01", 27);
  const oldApi = connect(session);
  complete(oldApi, [retained]);
  session.timers.runDelay(30_000);
  complete(oldApi, []);
  assert.equal(session.timers.count(5_000), 1);

  oldApi.emit(EVENTS.disconnected);
  assert.equal(session.timers.count(5_000), 0);
  const nextApi = connect(session, new FakeApi());
  assert.equal(nextApi.requests.some((row) => row[0] === "executions"), false);
  assert.equal(session.timers.count(10_000), 1);
  const nextId = 9604;
  oldApi.emit(EVENTS.execDetails, nextId, retained.contract, retained.execution);
  oldApi.emit(EVENTS.commissionReport, commission(retained.execution.execId));
  oldApi.emit(EVENTS.execDetailsEnd, nextId);
  assert.equal(session.adapter.requestInFlight, false);

  session.timers.runDelay(10_000);
  complete(nextApi, [retained]);
  emitFx(nextApi, "EUR", 1);
  emitFx(nextApi, "USD", 0.86);
  assert.equal(session.adapter.retryReason, null);
  assert.equal(session.adapter.project(book()).ok, true);
});

test("a higher correction without its actual fee retries and preserves the prior watermark", () => {
  const session = setup();
  const api = connect(session);
  const original = execution("correction-fee.1.01", 27, { price: 10 });
  const corrected = execution("correction-fee.1.02", 27, { price: 11 });
  complete(api, [original]);
  const before = session.store.state;
  session.timers.runDelay(30_000);
  complete(api, [corrected], []);
  session.timers.runDelay(20_000);

  assert.match(session.adapter.retryReason, /missing commissions for 1 family fills/);
  assert.deepEqual(session.store.state, before);
  assert.equal(session.timers.count(5_000), 1);

  session.timers.runDelay(5_000);
  complete(api, [corrected]);
  assert.equal(session.adapter.retryReason, null);
  assert.deepEqual(session.store.state.queryExecutionIdentities, ["correction-fee.1.02"]);
  assert.deepEqual(
    session.store.state.executions.map((row) => row.execution.execId),
    ["correction-fee.1.01", "correction-fee.1.02"]
  );
});

test("a lower correction replay is transient and cannot advance durable coverage", () => {
  const session = setup();
  const api = connect(session);
  const current = execution("lower.1.02", 27, { price: 11 });
  complete(api, [current]);
  const before = session.store.state;
  session.setNow("2026-09-10T12:01:00Z");
  session.timers.runDelay(30_000);
  complete(api, [execution("lower.1.01", 27, { price: 10 })]);

  assert.match(session.adapter.retryReason, /temporarily omitted 1/);
  assert.deepEqual(session.store.state, before);
  assert.equal(session.store.state.coverageThrough, before.coverageThrough);
});

test("a regressed execution clock is terminal and cannot advance durable coverage", () => {
  const session = setup();
  const api = connect(session);
  const retained = execution("clock.1.01", 27);
  complete(api, [retained]);
  const before = session.store.state;
  session.setNow("2026-09-10T11:59:00Z");
  session.timers.runDelay(30_000);
  complete(api, [retained]);

  assert.match(session.adapter.blockedReason, /timestamp regressed; backfill required/);
  assert.equal(session.adapter.retryReason, null);
  assert.deepEqual(session.store.state, before);
  assert.equal(session.timers.count(5_000), 0);
});

test("a running publisher pauses only until a fresh current-day cycle, without a permanent latch", () => {
  const session = setup({ at: "2026-09-11T03:59:00Z" });
  const api = connect(session);
  complete(api, []);
  session.setNow("2026-09-11T04:01:00Z");
  assert.match(session.adapter.project(book()).reason, /fresh current-day execution cycle/);
  session.timers.runDelay(30_000);
  complete(api, []);
  emitFx(api, "EUR", 1);
  const partial = session.adapter.project(book("2026-09-11T04:01:01Z"));
  assert.equal(partial.partialAccounting.status, "CAPTURED_ESTIMATE");
  assert.equal(session.adapter.blockedReason, null);
  assert.equal(session.timers.count(5_000), 0);
  assert.equal(session.timers.count(30_000), 1);
});

test("persisted classifier identity rejects a changed family or exclusion set", () => {
  const shared = memoryStore();
  const first = setup({ store: shared });
  complete(connect(first), []);

  const changedIds = setup({ store: shared, familyClientIds: FAMILY_IDS.slice(0, -1) });
  assert.match(changedIds.adapter.blockedReason, /classifier does not match/);
  const changedExclusions = setup({ store: shared, excludedSymbols: ["SXR8"] });
  assert.match(changedExclusions.adapter.blockedReason, /classifier does not match/);
});

test("durable ledger survives restart and merges the next day without truncating closed history", () => {
  const shared = memoryStore();
  const first = setup({ store: shared });
  complete(connect(first), [execution("day1.1.01", 27)]);
  assert.equal(shared.state.executions.length, 1);

  const second = setup({ store: shared, at: "2026-09-11T00:01:00Z" });
  const api = connect(second);
  complete(api, [execution("day1.1.01", 27), execution("day2.1.01", 28)]);
  assert.deepEqual(shared.state.executions.map((row) => row.execution.execId), ["day1.1.01", "day2.1.01"]);
  assert.equal(shared.state.commissions.length, 2);
});

test("identical replays deduplicate while exact-id conflicts fail closed", () => {
  const session = setup();
  const api = connect(session);
  const row = execution("same.1.01", 27);
  complete(api, [row]);
  session.timers.runDelay(30_000);
  complete(api, [row]);
  assert.equal(session.store.state.executions.length, 1);

  session.timers.runDelay(30_000);
  const conflict = execution("same.1.01", 27, { price: 99 });
  complete(api, [conflict]);
  assert.match(session.adapter.blockedReason, /conflicting replay/);
  assert.equal(session.adapter.retryReason, null);
  assert.equal(session.timers.count(5_000), 0);
  assert.equal(session.store.state.executions[0].execution.price, 10);
});

test("non-finite live broker numbers remain rejected", () => {
  const session = setup();
  const api = connect(session);
  const invalid = execution("nonfinite.1.01", 27);
  invalid.execution.price = Number.NaN;
  const id = requestId(api);
  api.emit(EVENTS.execDetails, id, invalid.contract, invalid.execution);
  assert.match(session.adapter.blockedReason, /non-finite broker number/);
  assert.equal(session.store.state, null);
});

test("correction revisions are durably merged without truncating their raw predecessors", () => {
  const session = setup();
  const api = connect(session);
  complete(api, [execution("correction.1.01", 27, { price: 10 })]);
  session.timers.runDelay(30_000);
  complete(api, [execution("correction.1.02", 27, { price: 11 })]);
  assert.deepEqual(
    session.store.state.executions.map((row) => row.execution.execId),
    ["correction.1.01", "correction.1.02"]
  );
  assert.deepEqual(session.store.state.queryExecutionIdentities, ["correction.1.02"]);
  assert.deepEqual(
    session.store.state.commissions.map((row) => row.execId),
    ["correction.1.01", "correction.1.02"]
  );
});

test("projection proves same-account EUR, fresh explicit FX, and complete positions", () => {
  let captured;
  const session = setup({ calculate: (args) => { captured = args; return calculator(args); } });
  const api = connect(session);
  complete(api, [execution("project.1.01", 27)]);
  assert.match(session.adapter.project(book()).reason, /EUR→EUR FX/);
  emitFx(api, "EUR", 1);
  emitFx(api, "USD", 0.86);

  const wrongAccount = book();
  wrongAccount.summary.NetLiquidation.account = "OTHER";
  assert.match(session.adapter.project(wrongAccount).reason, /base currency/);
  const partial = book();
  partial.positionsCoverage.status = "partial";
  assert.match(session.adapter.project(partial).reason, /positions are incomplete/);

  const result = session.adapter.project(book());
  assert.equal(result.ok, true);
  assert.deepEqual(captured.fx.rates, { EUR: 1, USD: 0.86 });
  assert.deepEqual(captured.familyClientIds, FAMILY_IDS);
  assert.equal(captured.account, ACCOUNT);
});

test("ledger revisions and economic observations advance source time; heartbeats do not", () => {
  const session = setup();
  const api = connect(session);
  complete(api, [execution("revision.1.01", 27)]);
  emitFx(api, "EUR", 1);
  emitFx(api, "USD", 0.86);
  const first = session.adapter.project(book("2026-09-10T12:00:01Z"));
  const saves = session.store.saves;

  session.setNow("2026-09-10T12:00:10Z");
  const heartbeat = session.adapter.project(book("2026-09-10T12:00:01Z"));
  assert.equal(heartbeat.observedAt, first.observedAt);
  assert.equal(session.store.saves, saves);

  session.timers.runDelay(30_000);
  session.setNow("2026-09-10T12:00:20Z");
  complete(api, [execution("revision.1.01", 27), execution("revision.2.01", 28)]);
  const advanced = session.adapter.project(book("2026-09-10T12:00:01Z"));
  assert.equal(advanced.observedAt, "2026-09-10T12:00:20.000Z");
});

test("a restart rejects source observations older than its persisted family projection", () => {
  const original = setup();
  const firstApi = connect(original);
  const row = execution("regression.1.01", 27);
  complete(firstApi, [row]);
  emitFx(firstApi, "EUR", 1);
  emitFx(firstApi, "USD", 0.86);
  original.adapter.project(book("2026-09-10T12:00:01Z"));
  const persisted = original.store.state;
  persisted.family.observedAt = "2026-09-10T12:05:00.000Z";

  const restarted = setup({ store: memoryStore(persisted), at: "2026-09-10T12:03:00Z" });
  const nextApi = connect(restarted);
  complete(nextApi, [row]);
  emitFx(nextApi, "EUR", 1);
  emitFx(nextApi, "USD", 0.86);
  assert.match(restarted.adapter.project(book("2026-09-10T12:02:00Z")).reason, /regressed behind persisted state/);
});

test("FX is unavailable after disconnect until every required rate is freshly observed", () => {
  const session = setup();
  const api = connect(session);
  const retained = execution("fx.1.01", 27);
  complete(api, [retained]);
  emitFx(api, "EUR", 1);
  emitFx(api, "USD", 0.86);
  assert.equal(session.adapter.project(book()).ok, true);
  api.emit(EVENTS.disconnected);

  const next = connect(session, new FakeApi());
  complete(next, [retained]);
  emitFx(next, "EUR", 1);
  assert.match(session.adapter.project(book()).reason, /USD→EUR/);
  emitFx(next, "USD", 0.85);
  assert.equal(session.adapter.project(book()).ok, true);
});

test("a new bounded FX request refreshes an unchanged broker rate and ignores old request callbacks", () => {
  const session = setup();
  const api = connect(session);
  complete(api, [execution("refresh-fx.1.01", 27)]);
  emitFx(api, "EUR", 1);
  emitFx(api, "USD", 0.86);
  assert.equal(session.adapter.project(book()).ok, true);

  session.setNow("2026-09-10T12:01:00Z");
  session.timers.runDelay(60_000);
  assert.deepEqual(api.requests.slice(-2), [
    ["cancelAccountUpdatesMulti", 9701],
    ["accountUpdatesMulti", 9703, ACCOUNT, "", true],
  ]);
  emitFx(api, "EUR", 9, 9701);
  emitFx(api, "USD", 9, 9701);
  emitFx(api, "EUR", 1, 9703);
  emitFx(api, "USD", 0.86, 9703);
  session.setNow("2026-09-10T12:02:01Z");
  assert.equal(session.adapter.project(book()).ok, true);
});

test("a requested FX refresh with no broker response ages out instead of fabricating freshness", () => {
  const session = setup();
  const api = connect(session);
  complete(api, [execution("stale-fx.1.01", 27)]);
  emitFx(api, "EUR", 1);
  emitFx(api, "USD", 0.86);
  assert.equal(session.adapter.project(book()).ok, true);
  session.setNow("2026-09-10T12:01:00Z");
  session.timers.runDelay(60_000);
  session.setNow("2026-09-10T12:02:01Z");
  assert.match(session.adapter.project(book()).reason, /fresh explicit EUR→EUR FX rate unavailable/);
});

test("file store rejects corrupt JSON without replacing it", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "family-state-test-"));
  const file = path.join(directory, "family-ledger.json");
  fs.writeFileSync(file, "not-json", { mode: 0o600 });
  const store = createFileFamilyStateStore(file);
  const loaded = store.load({ account: ACCOUNT, periodStart: FAMILY_BASELINE_PERIOD_START, classifier: CLASSIFIER });
  assert.deepEqual(loaded, { ok: false, reason: "family ledger state is corrupt JSON" });
  assert.equal(fs.readFileSync(file, "utf8"), "not-json");
});

test("file store atomically round-trips a bounded durable ledger", () => {
  const source = memoryStore();
  const session = setup({ store: source });
  complete(connect(session), [execution("disk.1.01", 27)]);
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "family-state-test-"));
  const file = path.join(directory, "family-ledger.json");
  const disk = createFileFamilyStateStore(file);
  disk.save(source.state);
  const loaded = disk.load({ account: ACCOUNT, periodStart: FAMILY_BASELINE_PERIOD_START, classifier: CLASSIFIER });
  assert.equal(loaded.ok, true);
  assert.deepEqual(loaded.state, source.state);
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  assert.deepEqual(fs.readdirSync(directory), ["family-ledger.json"]);
});

test("JSON roundtrip accepts real-SDK-shaped undefined keys on the next replay", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "family-state-test-"));
  const file = path.join(directory, "family-ledger.json");
  const disk = createFileFamilyStateStore(file);
  const row = execution("sdk-shape.1.01", 27);
  row.contract.right = undefined;
  row.execution.modelCode = undefined;
  const report = commission(row.execution.execId);
  report.realizedPNL = undefined;
  report.yield = undefined;

  const first = setup({ store: disk });
  complete(connect(first), [row], [report]);
  const persisted = fs.readFileSync(file, "utf8");
  assert.equal(persisted.includes('"right"'), false);
  assert.equal(persisted.includes('"yield"'), false);

  const restarted = setup({ store: disk, at: "2026-09-10T12:01:00Z" });
  complete(connect(restarted), [row], [report]);
  assert.equal(restarted.adapter.blockedReason, null);
  assert.deepEqual(restarted.adapter.inspectState().queryExecutionIdentities, ["sdk-shape.1.01"]);
});


test("file store reads the validated inode if the pathname is replaced", () => {
  const source = memoryStore();
  const session = setup({ store: source });
  complete(connect(session), [execution("race.1.01", 27)]);
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "family-state-test-"));
  const file = path.join(directory, "family-ledger.json");
  createFileFamilyStateStore(file).save(source.state);
  const racingFs = { ...fs, fstatSync(handle) {
    const stat = fs.fstatSync(handle);
    fs.renameSync(file, path.join(directory, "original.json"));
    fs.writeFileSync(file, "replacement-is-not-a-ledger");
    return stat;
  } };
  const loaded = createFileFamilyStateStore(file, racingFs).load({
    account: ACCOUNT, periodStart: FAMILY_BASELINE_PERIOD_START, classifier: CLASSIFIER,
  });
  assert.equal(loaded.ok, true);
  assert.deepEqual(loaded.state, source.state);
});
