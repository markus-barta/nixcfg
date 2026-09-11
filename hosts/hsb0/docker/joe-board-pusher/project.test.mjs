#!/usr/bin/env node
/** Synthetic replay tests — not live broker evidence. */
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";
import {
  brokerConnectivityState,
  createPositionTracker,
  currencyCode,
  deskForSymbol,
  isConnectionFailure,
  strictFinite,
} from "./positions-state.mjs";
import {
  buildDeskPositions,
  isGrandfathered,
  projectBook,
  serializePositionRow,
} from "./project.mjs";
import {
  createBrokerSessionAdapter,
  createReconnectScheduler,
} from "./pusher-state.mjs";

const TARGET = "PAPER-ACCT-01";
const OTHER = "PAPER-ACCT-02";
const OBS_A = "2026-09-10T08:00:00.000Z";
const OBS_A1 = "2026-09-10T08:00:01.000Z";
const OBS_A4 = "2026-09-10T08:00:04.000Z";
const OBS_B = "2026-09-10T08:00:05.000Z";
const OBS_C = "2026-09-10T08:10:00.000Z";
const OBS_D = "2026-09-10T08:20:00.000Z";
const OBS_RECONNECT = "2026-09-10T09:30:00.000Z";
const SUMMARY_REQ_ID = 9501;
const EVENTS = Object.fromEntries([
  "connected",
  "disconnected",
  "connectionClosed",
  "error",
  "info",
  "currentTime",
  "managedAccounts",
  "accountSummary",
  "accountSummaryEnd",
  "position",
  "positionEnd",
  "updatePortfolio",
  "accountDownloadEnd",
  "openOrder",
].map((name) => [name, name]));

class FakeApi extends EventEmitter {
  constructor(name) {
    super();
    this.name = name;
    this.requests = [];
  }

  reqManagedAccts() { this.requests.push(["managedAccounts"]); }
  reqPositions() { this.requests.push(["positions"]); }
  cancelPositions() { this.requests.push(["cancelPositions"]); }
  reqAllOpenOrders() { this.requests.push(["openOrders"]); }
  reqAccountSummary(...args) { this.requests.push(["accountSummary", ...args]); }
  cancelAccountSummary(...args) { this.requests.push(["cancelAccountSummary", ...args]); }
  reqAccountUpdates(...args) { this.requests.push(["accountUpdates", ...args]); }
}

function stockContract(symbol, extra = {}) {
  return {
    conId: extra.conId ?? symbol.length * 1000,
    symbol,
    secType: "STK",
    currency: extra.currency ?? "USD",
    ...extra,
  };
}

function baseBook(overrides = {}) {
  return {
    ts: OBS_A,
    gatewayLastSeenAt: OBS_A,
    gateway: true,
    summary: { NetLiquidation: { value: "12000", currency: "EUR" } },
    portfolio: [],
    positions: [],
    ...overrides,
  };
}

function bestAvailableHistory(overrides = {}) {
  const base = {
    ok: true,
    status: "BEST_AVAILABLE",
    equity: null,
    capturedSubtotal: {
      currency: "USD",
      realizedPnl: -37.125,
      method: "captured-fifo-matched-roundtrips",
      executionCount: 43,
      commissionCount: 42,
      fromInclusive: OBS_A,
      throughInclusive: OBS_B,
    },
    coverage: {
      target: { fromInclusive: OBS_A, toExclusive: OBS_D },
      completeIntervals: [],
      knownIntervals: [{ fromInclusive: OBS_A, toExclusive: OBS_B }],
      gaps: [{ fromInclusive: OBS_B, toExclusive: OBS_D, reason: "synthetic earlier interval unavailable" }],
    },
    missingOpeningLots: [{ synthetic: true }],
    orphanCommissionIds: ["synthetic-hidden-id"],
  };
  return {
    ...base,
    ...overrides,
    capturedSubtotal: { ...base.capturedSubtotal, ...(overrides.capturedSubtotal || {}) },
    coverage: { ...base.coverage, ...(overrides.coverage || {}) },
  };
}

function deskById(snapshot, id) {
  return snapshot.desks.find((desk) => desk.id === id);
}

function createHarness(hooks = {}) {
  let instant = OBS_A;
  const adapter = createBrokerSessionAdapter({
    targetAccount: TARGET,
    eventNames: EVENTS,
    now: () => instant,
    hooks,
  });
  return {
    adapter,
    setInstant(value) { instant = value; },
  };
}

function connectRecognized(api) {
  api.emit(EVENTS.connected);
  api.emit(EVENTS.managedAccounts, `${TARGET},${OTHER}`);
}

function finishInitialSync(api, { positions = [], portfolios = [], summaryValue = "12000" } = {}) {
  for (const row of positions) {
    api.emit(EVENTS.position, TARGET, row.contract, row.pos, row.avgCost);
  }
  for (const row of portfolios) {
    api.emit(
      EVENTS.updatePortfolio,
      row.contract,
      row.pos,
      row.marketPrice,
      row.marketValue,
      row.avgCost,
      row.unrealizedPNL,
      row.realizedPNL,
      TARGET
    );
  }
  api.emit(EVENTS.positionEnd);
  api.emit(EVENTS.accountSummary, SUMMARY_REQ_ID, TARGET, "NetLiquidation", summaryValue, "EUR");
  api.emit(EVENTS.accountSummaryEnd, SUMMARY_REQ_ID);
  api.emit(EVENTS.accountDownloadEnd, TARGET);
}

test("desk mapping keeps unknown symbols off Joe", () => {
  assert.equal(deskForSymbol("INTC"), "j");
  assert.equal(deskForSymbol("SXR8"), "joel");
  assert.equal(deskForSymbol("TSLA"), "joel");
  assert.equal(deskForSymbol("AAPL"), null);
});

test("strictFinite accepts real numbers only and rejects the IB unset sentinel", () => {
  for (const value of [false, true, [], {}, null, undefined, "", "0", NaN, Infinity, Number.MAX_VALUE]) {
    assert.equal(strictFinite(value), undefined);
  }
  assert.equal(strictFinite(0), 0);
  assert.equal(strictFinite(-3.5), -3.5);
});

test("currency codes are normalized only when exactly three letters", () => {
  assert.equal(currencyCode("usd"), "USD");
  assert.equal(currencyCode(" EUR "), "EUR");
  for (const value of ["US", "USDT", "12$", "", false, [], null, undefined]) {
    assert.equal(currencyCode(value), undefined);
  }
});

test("invalid quantities retain holdings and prevent complete coverage", () => {
  for (const invalid of [false, [], null, undefined, "", NaN, Number.MAX_VALUE]) {
    const tracker = createPositionTracker(TARGET);
    const session = tracker.onConnected();
    tracker.onManagedAccounts(session, TARGET);
    tracker.onPosition(session, TARGET, stockContract("INTC"), 5, 20, OBS_A);
    tracker.onPosition(session, TARGET, stockContract("INTC"), invalid, 20, OBS_B);
    tracker.onPositionEnd(session);
    assert.equal(tracker.status, "partial");
    assert.equal(tracker.listRows()[0].pos, 5);
    assert.equal(tracker.listRows()[0].positionObservedAt, OBS_A);
  }
});

test("a genuine zero quantity removes a holding", () => {
  const tracker = createPositionTracker(TARGET);
  const session = tracker.onConnected();
  tracker.onManagedAccounts(session, TARGET);
  tracker.onPosition(session, TARGET, stockContract("INTC"), 5, 20, OBS_A);
  tracker.onPosition(session, TARGET, stockContract("INTC"), 0, 20, OBS_B);
  tracker.onPositionEnd(session);
  assert.equal(tracker.status, "complete");
  assert.deepEqual(tracker.listRows(), []);
});

test("only a recognized managed account can prove a known-empty target book", () => {
  const unknown = createPositionTracker(TARGET);
  const unknownSession = unknown.onConnected();
  unknown.onManagedAccounts(unknownSession, OTHER);
  unknown.onPositionEnd(unknownSession);
  assert.equal(unknown.status, "partial");

  const recognized = createPositionTracker(TARGET);
  const recognizedSession = recognized.onConnected();
  recognized.onPositionEnd(recognizedSession);
  assert.equal(recognized.status, "partial");
  recognized.onManagedAccounts(recognizedSession, `${OTHER}, ${TARGET}`);
  assert.equal(recognized.status, "complete");
  assert.deepEqual(recognized.listRows(), []);
});

test("partial coverage omits positions while complete empty covers mapped desks only", () => {
  const tracker = createPositionTracker(TARGET);
  const session = tracker.onConnected();
  let snapshot = projectBook(baseBook({ positionsCoverage: tracker.snapshot() }), {
    publisherAt: new Date(OBS_B),
  });
  for (const desk of snapshot.desks) assert.equal("positions" in desk, false);

  tracker.onManagedAccounts(session, TARGET);
  tracker.onPositionEnd(session);
  snapshot = projectBook(baseBook({ positionsCoverage: tracker.snapshot() }), {
    publisherAt: new Date(OBS_B),
  });
  assert.deepEqual(deskById(snapshot, "j").positions, []);
  assert.deepEqual(deskById(snapshot, "joel").positions, []);
  assert.equal("positions" in deskById(snapshot, "joe"), false);
});

test("adapter wiring requests read-only streams and waits for every initial completion", () => {
  const { adapter } = createHarness();
  const api = new FakeApi("synthetic-A");
  adapter.attach(api);
  assert.equal(adapter.snapshot(), null);
  connectRecognized(api);
  assert.deepEqual(api.requests.map((request) => request[0]), [
    "managedAccounts",
    "positions",
    "openOrders",
    "accountSummary",
    "accountUpdates",
  ]);
  api.emit(EVENTS.positionEnd);
  assert.equal(adapter.snapshot(), null);
  api.emit(EVENTS.accountSummary, SUMMARY_REQ_ID, TARGET, "NetLiquidation", "12000", "EUR");
  api.emit(EVENTS.accountSummaryEnd, SUMMARY_REQ_ID);
  assert.equal(adapter.snapshot(), null);
  api.emit(EVENTS.accountDownloadEnd, OTHER);
  assert.equal(adapter.snapshot(), null);
  api.emit(EVENTS.accountDownloadEnd, TARGET);
  assert.ok(adapter.snapshot());
});

test("completed streams without valid target net liquidation remain unpublished", () => {
  const { adapter } = createHarness();
  const api = new FakeApi("synthetic-A");
  adapter.attach(api);
  connectRecognized(api);
  api.emit(EVENTS.positionEnd);
  api.emit(EVENTS.accountSummary, SUMMARY_REQ_ID, TARGET, "NetLiquidation", "", "EUR");
  api.emit(EVENTS.accountSummaryEnd, SUMMARY_REQ_ID);
  api.emit(EVENTS.accountDownloadEnd, TARGET);
  assert.equal(adapter.snapshot(), null);
});

test("generation-scoped emitter wiring suppresses every stale API callback", () => {
  const { adapter, setInstant } = createHarness();
  const oldApi = new FakeApi("synthetic-old");
  adapter.attach(oldApi);
  connectRecognized(oldApi);
  finishInitialSync(oldApi, {
    positions: [{ contract: stockContract("INTC", { conId: 1 }), pos: 2, avgCost: 10 }],
  });
  assert.equal(adapter.snapshot().positions[0].pos, 2);

  const currentApi = new FakeApi("synthetic-current");
  adapter.attach(currentApi);
  currentApi.emit(EVENTS.connected);
  setInstant(OBS_C);
  oldApi.emit(EVENTS.connected);
  oldApi.emit(EVENTS.disconnected);
  oldApi.emit(EVENTS.connectionClosed);
  oldApi.emit(EVENTS.error, new Error("stale connection failure"), 502);
  oldApi.emit(EVENTS.managedAccounts, TARGET);
  oldApi.emit(EVENTS.accountSummary, SUMMARY_REQ_ID, TARGET, "NetLiquidation", "999999", "EUR");
  oldApi.emit(EVENTS.accountSummaryEnd, SUMMARY_REQ_ID);
  oldApi.emit(EVENTS.position, TARGET, stockContract("INTC", { conId: 2 }), 99, 1);
  oldApi.emit(EVENTS.positionEnd);
  oldApi.emit(EVENTS.updatePortfolio, stockContract("INTC", { conId: 2 }), 99, 99, 999, 1, 9, 9, TARGET);
  oldApi.emit(EVENTS.accountDownloadEnd, TARGET);
  oldApi.emit(EVENTS.openOrder, 1, stockContract("INTC"), { account: TARGET }, {});
  assert.equal(adapter.socketConnected, true);
  assert.equal(adapter.connected, false);
  assert.equal(adapter.snapshot().lastError, null);

  currentApi.emit(EVENTS.managedAccounts, TARGET);
  finishInitialSync(currentApi, { summaryValue: "13000" });
  const snapshot = adapter.snapshot();
  assert.equal(adapter.connected, true);
  assert.deepEqual(snapshot.positions, []);
  assert.equal(snapshot.summary.NetLiquidation.value, "13000");
  assert.equal(snapshot.ts, OBS_C);
});

test("disconnect preserves the last valid book while broker age advances", () => {
  const { adapter, setInstant } = createHarness();
  const api = new FakeApi("synthetic-A");
  adapter.attach(api);
  connectRecognized(api);
  setInstant(OBS_B);
  const contract = stockContract("INTC");
  finishInitialSync(api, {
    positions: [{ contract, pos: 2, avgCost: 10 }],
    portfolios: [{ contract, pos: 2, marketPrice: 20.123456, marketValue: 40, avgCost: 10, unrealizedPNL: 7, realizedPNL: 1 }],
  });
  const before = projectBook(adapter.snapshot(), { publisherAt: new Date(OBS_B) });
  setInstant(OBS_C);
  api.emit(EVENTS.disconnected);
  const retained = adapter.snapshot();
  const after = projectBook(retained, { publisherAt: new Date(OBS_C) });
  assert.equal(retained.positionsCoverage.status, "unavailable");
  assert.equal(after.generatedAt, before.generatedAt);
  assert.equal(after.safety.gateway.lastSeenAt, OBS_B);
  assert.deepEqual(before.brokerAccount, {
    equity: 12000,
    currency: "EUR",
    observedAt: OBS_B,
    scope: "paper-account-including-keep",
    status: "available",
  });
  assert.deepEqual(after.brokerAccount, {
    ...before.brokerAccount,
    status: "unavailable",
  });
  assert.equal(after.totals.equity, before.totals.equity);
  assert.equal(deskById(after, "j").heartbeatAt, "2026-09-10T10:10:00+02:00");
  assert.equal("positions" in deskById(after, "j"), false);
});

test("a completed reconnect replaces stale removed rows with known-empty coverage", () => {
  const { adapter } = createHarness();
  const first = new FakeApi("synthetic-A");
  adapter.attach(first);
  connectRecognized(first);
  finishInitialSync(first, {
    positions: [{ contract: stockContract("INTC"), pos: 3, avgCost: 10 }],
  });
  first.emit(EVENTS.disconnected);

  const second = new FakeApi("synthetic-B");
  adapter.attach(second);
  connectRecognized(second);
  finishInitialSync(second);
  const snapshot = adapter.snapshot();
  assert.equal(snapshot.positionsCoverage.status, "complete");
  assert.deepEqual(snapshot.positions, []);
  assert.deepEqual(buildDeskPositions(snapshot.positionsCoverage).j, []);
});

test("reconnect keeps position coverage atomic until the full new snapshot is accepted", () => {
  const { adapter, setInstant } = createHarness();
  const first = new FakeApi("synthetic-A");
  const contract = stockContract("INTC");
  adapter.attach(first);
  connectRecognized(first);
  finishInitialSync(first, {
    positions: [{ contract, pos: 2, avgCost: 10 }],
    portfolios: [{
      contract,
      pos: 2,
      marketPrice: 20,
      marketValue: 40,
      avgCost: 10,
      unrealizedPNL: 7,
      realizedPNL: 1,
    }],
  });
  const acceptedFirst = adapter.snapshot();
  const projectedFirst = projectBook(acceptedFirst, { publisherAt: new Date(OBS_A) });

  first.emit(EVENTS.disconnected);
  setInstant(OBS_RECONNECT);
  const second = new FakeApi("synthetic-B");
  adapter.attach(second);
  connectRecognized(second);
  second.emit(EVENTS.position, TARGET, contract, 99, 10);
  second.emit(EVENTS.updatePortfolio, contract, 99, 30, 2970, 10, 80, 20, TARGET);
  second.emit(EVENTS.positionEnd);

  const partial = adapter.snapshot();
  const projectedPartial = projectBook(partial, { publisherAt: new Date(OBS_RECONNECT) });
  assert.equal(partial.ts, acceptedFirst.ts);
  assert.equal(partial.positions[0].pos, 2);
  assert.equal(partial.portfolio[0].unrealizedPNL, 7);
  assert.equal(partial.positionsCoverage.status, "unavailable");
  assert.deepEqual(partial.positionsCoverage.rows, []);
  assert.equal(partial.gatewayLastSeenAt, acceptedFirst.gatewayLastSeenAt);
  assert.equal(projectedPartial.generatedAt, projectedFirst.generatedAt);
  assert.equal(deskById(projectedPartial, "j").money.totalPnl, 8);
  assert.equal("positions" in deskById(projectedPartial, "j"), false);

  second.emit(EVENTS.accountSummary, SUMMARY_REQ_ID, TARGET, "NetLiquidation", "13000", "EUR");
  second.emit(EVENTS.accountSummaryEnd, SUMMARY_REQ_ID);
  second.emit(EVENTS.accountDownloadEnd, TARGET);
  const acceptedSecond = adapter.snapshot();
  const projectedSecond = projectBook(acceptedSecond, { publisherAt: new Date(OBS_RECONNECT) });
  assert.equal(acceptedSecond.ts, OBS_RECONNECT);
  assert.equal(acceptedSecond.positions[0].pos, 99);
  assert.equal(acceptedSecond.positionsCoverage.status, "complete");
  assert.equal(acceptedSecond.positionsCoverage.rows[0].pos, 99);
  assert.equal(deskById(projectedSecond, "j").positions[0].quantity, 99);
  assert.equal(deskById(projectedSecond, "j").money.totalPnl, 100);
});

test("closed-position realized P&L remains in existing Stage-0 accounting", () => {
  const { adapter } = createHarness();
  const api = new FakeApi("synthetic-A");
  adapter.attach(api);
  connectRecognized(api);
  const contract = stockContract("INTC");
  finishInitialSync(api, {
    portfolios: [{
      contract,
      pos: 0,
      marketPrice: 20,
      marketValue: 0,
      avgCost: 10,
      unrealizedPNL: 0,
      realizedPNL: 5,
    }],
  });
  const broker = adapter.snapshot();
  const snapshot = projectBook(broker, { publisherAt: new Date(OBS_B) });
  assert.deepEqual(broker.positions, []);
  assert.equal(broker.portfolio[0].realizedPNL, 5);
  assert.equal(deskById(snapshot, "j").money.totalPnl, 5);
  assert.equal(deskById(snapshot, "j").money.dayPnl, null);
  assert.equal(snapshot.totals.dayPnl, null);
});

test("invalid live quantity retires coverage without replacing the last valid snapshot", () => {
  let resyncs = 0;
  const { adapter, setInstant } = createHarness({ onResyncNeeded: () => { resyncs += 1; } });
  const api = new FakeApi("synthetic-A");
  adapter.attach(api);
  connectRecognized(api);
  finishInitialSync(api, {
    positions: [{ contract: stockContract("INTC"), pos: 4, avgCost: 10 }],
  });
  const valid = adapter.snapshot();
  setInstant(OBS_B);
  api.emit(EVENTS.updatePortfolio, stockContract("INTC"), null, 20, 80, 10, 2, 0, TARGET);
  const after = adapter.snapshot();
  assert.equal(resyncs, 1);
  assert.equal(after.positionsCoverage.status, "unavailable");
  assert.equal(after.positions[0].pos, valid.positions[0].pos);
  assert.equal(after.ts, valid.ts);
});

test("invalid data retires one generation and repeated old callbacks cannot bypass retry", () => {
  let resyncs = 0;
  let reconnects = 0;
  const adapter = createBrokerSessionAdapter({
    targetAccount: TARGET,
    eventNames: EVENTS,
    now: () => OBS_A,
    hooks: {
      onResyncNeeded() { resyncs += 1; },
      onReconnectNeeded() { reconnects += 1; },
    },
  });

  const first = new FakeApi("synthetic-A");
  adapter.attach(first);
  connectRecognized(first);
  finishInitialSync(first);
  first.emit(EVENTS.position, TARGET, stockContract("INTC"), null, 10);
  first.emit(EVENTS.position, TARGET, stockContract("INTC"), null, 10);
  assert.equal(resyncs, 1);
  assert.equal(reconnects, 1);
  assert.equal(adapter.socketConnected, false);
  assert.equal(adapter.connected, false);
  assert.equal(adapter.snapshot().positionsCoverage.status, "unavailable");
});

test("cross-account portfolio and summary events are ignored", () => {
  const { adapter, setInstant } = createHarness();
  const api = new FakeApi("synthetic-A");
  adapter.attach(api);
  connectRecognized(api);
  finishInitialSync(api, {
    positions: [{ contract: stockContract("INTC"), pos: 4, avgCost: 30 }],
  });
  const before = adapter.snapshot();
  setInstant(OBS_C);
  api.emit(EVENTS.updatePortfolio, stockContract("INTC"), 4, 99, 999, 30, 1, 0, OTHER);
  api.emit(EVENTS.updatePortfolio, stockContract("INTC"), 4, 88, 888, 30, 2, 0, undefined);
  api.emit(EVENTS.accountSummary, SUMMARY_REQ_ID, OTHER, "NetLiquidation", "999999", "EUR");
  const after = adapter.snapshot();
  assert.deepEqual(after.positions, before.positions);
  assert.deepEqual(after.summary, before.summary);
  assert.equal(after.ts, before.ts);
});

test("an invalid supplied mark preserves its value and original observation time", () => {
  const tracker = createPositionTracker(TARGET);
  const session = tracker.onConnected();
  tracker.onManagedAccounts(session, TARGET);
  const contract = stockContract("INTC", { currency: "USD" });
  tracker.onPosition(session, TARGET, contract, 4, 30, OBS_A);
  tracker.onPortfolio(session, TARGET, contract, 4, 0.0123456789, 1, 30, 1, 0, OBS_A);
  tracker.onPortfolio(
    session,
    TARGET,
    { ...contract, currency: "not-a-code" },
    4,
    false,
    1,
    30,
    1,
    0,
    OBS_B
  );
  tracker.onPositionEnd(session);
  const row = serializePositionRow(tracker.listRows()[0], "j");
  assert.equal(row.mark, 0.0123456789);
  assert.equal(row.updatedAt, OBS_A);
  assert.equal(row.currency, "USD");
});

test("position serialization preserves sign and raw mark precision", () => {
  const row = serializePositionRow({
    symbol: "INTC",
    pos: -2,
    currency: "usd",
    marketPrice: 0.0123456789,
    marketValue: 80,
    unrealizedPNL: 3,
    positionObservedAt: OBS_A,
    markObservedAt: OBS_B,
  }, "j");
  assert.equal(row.quantity, -2);
  assert.equal(row.side, "Short");
  assert.equal(row.currency, "USD");
  assert.equal(row.mark, 0.0123456789);
  assert.equal(row.updatedAt, OBS_B);
  assert.equal(row.marketValue, undefined);
  assert.equal(row.openPnl, undefined);
  assert.equal(row.accountingScope, "stage0");
});

test("invalid currency suppresses quote-currency mark and unknown symbols are not Stage-0", () => {
  const invalidCurrency = serializePositionRow({
    symbol: "INTC",
    pos: 1,
    currency: "USDT",
    marketPrice: 12,
    positionObservedAt: OBS_A,
    markObservedAt: OBS_B,
  }, "j");
  assert.equal(invalidCurrency.currency, undefined);
  assert.equal(invalidCurrency.mark, undefined);
  assert.equal(invalidCurrency.updatedAt, OBS_A);
  assert.equal(serializePositionRow({ symbol: "AAPL", pos: 1 }, "j"), null);
  assert.equal(serializePositionRow({ symbol: "INTC", pos: false }, "j"), null);
});

test("unknown broker symbols do not create Joe coverage", () => {
  const tracker = createPositionTracker(TARGET);
  const session = tracker.onConnected();
  tracker.onManagedAccounts(session, TARGET);
  tracker.onPosition(session, TARGET, stockContract("AAPL"), 3, 150, OBS_A);
  tracker.onPositionEnd(session);
  const snapshot = projectBook(baseBook({ positionsCoverage: tracker.snapshot() }), {
    publisherAt: new Date(OBS_B),
  });
  assert.deepEqual(deskById(snapshot, "j").positions, []);
  assert.deepEqual(deskById(snapshot, "joel").positions, []);
  assert.equal("positions" in deskById(snapshot, "joe"), false);
});

test("legacy positions stay visible and excluded from Stage-0 accounting", () => {
  const tracker = createPositionTracker(TARGET);
  const session = tracker.onConnected();
  tracker.onManagedAccounts(session, TARGET);
  tracker.onPosition(session, TARGET, stockContract("TSLA"), 1, 200, OBS_A);
  tracker.onPositionEnd(session);
  const snapshot = projectBook(baseBook({
    positionsCoverage: tracker.snapshot(),
    positions: [{ symbol: "TSLA", pos: 1 }],
    portfolio: [{ symbol: "TSLA", pos: 1, marketValue: 210, unrealizedPNL: 10, realizedPNL: 0 }],
  }), { publisherAt: new Date(OBS_B) });
  const joel = deskById(snapshot, "joel");
  assert.equal("historyBasis" in deskById(snapshot, "j"), false);
  assert.equal("historyBasis" in deskById(snapshot, "joe"), false);
  assert.equal(joel.positions[0].accountingScope, "legacy");
  assert.equal(joel.money.totalPnl, 0);
  assert.equal(joel.historyBasis, "joel.stage0-keep-excluded.v1");
  const nextPoll = projectBook(baseBook({
    ts: OBS_B,
    positionsCoverage: tracker.snapshot(),
    positions: [{ symbol: "TSLA", pos: 1 }],
    portfolio: [{ symbol: "TSLA", pos: 1, marketValue: 211, unrealizedPNL: 11, realizedPNL: 0 }],
  }), { publisherAt: new Date(OBS_C) });
  assert.equal(deskById(nextPoll, "joel").historyBasis, joel.historyBasis);
  assert.equal(deskById(nextPoll, "joel").money.totalPnl, 0);
  assert.equal(isGrandfathered({ symbol: "TSLA", pos: 1 }), true);
});

test("contract identity keeps distinct instruments with the same symbol", () => {
  const tracker = createPositionTracker(TARGET);
  const session = tracker.onConnected();
  tracker.onManagedAccounts(session, TARGET);
  tracker.onPosition(session, TARGET, stockContract("INTC", { conId: 1, exchange: "NASDAQ" }), 1, 10, OBS_A);
  tracker.onPosition(session, TARGET, stockContract("INTC", { conId: 2, exchange: "IBIS2", currency: "EUR" }), 2, 20, OBS_A);
  tracker.onPositionEnd(session);
  assert.equal(buildDeskPositions(tracker.snapshot()).j.length, 2);
});

test("publisher heartbeat does not refresh broker observation fields", () => {
  const snapshot = projectBook(baseBook(), { publisherAt: new Date(OBS_C) });
  assert.equal(snapshot.generatedAt, "2026-09-10T10:00:00+02:00");
  assert.equal(snapshot.source.revision, OBS_A);
  assert.equal(snapshot.safety.gateway.lastSeenAt, OBS_A);
  assert.equal(snapshot.brokerAccount.observedAt, OBS_A);
  assert.equal(snapshot.brokerAccount.equity, 12000);
  assert.equal(snapshot.brokerAccount.status, "unavailable");
  for (const desk of snapshot.desks) {
    assert.equal(desk.heartbeatAt, "2026-09-10T10:10:00+02:00");
  }
});

test("complete EUR NetLiquidation stays useful when J family accounting is unavailable", () => {
  const snapshot = projectBook(baseBook(), {
    publisherAt: new Date(OBS_B),
    familyRuntimeEnabled: true,
    family: { ok: false, reason: "synthetic J-family gap" },
  });
  assert.deepEqual(snapshot.brokerAccount, {
    equity: 12000,
    currency: "EUR",
    observedAt: OBS_A,
    scope: "paper-account-including-keep",
    status: "available",
  });
  assert.deepEqual(deskById(snapshot, "j").money, {
    equity: null,
    dayPnl: null,
    totalPnl: null,
  });
  assert.deepEqual(snapshot.totals, { equity: null, dayPnl: null, totalPnl: null });
});

test("missing, invalid, and foreign NetLiquidation never become account equity", () => {
  for (const summary of [
    {},
    { NetLiquidation: { value: "", currency: "EUR" } },
    { NetLiquidation: { value: "not-a-number", currency: "EUR" } },
    { NetLiquidation: { value: false, currency: "EUR" } },
    { NetLiquidation: { value: "12000" } },
    { NetLiquidation: { value: "12000", currency: "USD" } },
    { NetLiquidation: { value: String(Number.MAX_VALUE), currency: "EUR" } },
  ]) {
    const snapshot = projectBook(baseBook({ summary }), { publisherAt: new Date(OBS_B) });
    assert.equal(snapshot.brokerAccount.equity, null, JSON.stringify(summary));
    assert.equal(snapshot.brokerAccount.status, "unavailable", JSON.stringify(summary));
    assert.equal(snapshot.brokerAccount.currency, "EUR");
    assert.equal(snapshot.brokerAccount.observedAt, OBS_A);
  }
});

test("best-available family history projects a bounded J-only native-currency summary", () => {
  const familyHistory = bestAvailableHistory();
  const snapshot = projectBook(baseBook(), {
    publisherAt: new Date(OBS_B),
    familyRuntimeEnabled: true,
    family: { ok: false, reason: "synthetic live J accounting gap" },
    familyHistory,
  });
  assert.deepEqual(deskById(snapshot, "j").backfill, {
    status: "BEST_AVAILABLE",
    fullTotalAvailable: false,
    capturedSubtotal: {
      currency: "USD",
      realizedPnl: -37.125,
      method: "captured-fifo-matched-roundtrips",
      executionCount: 43,
      commissionCount: 42,
      fromInclusive: OBS_A,
      throughInclusive: OBS_B,
    },
    coverage: {
      target: { fromInclusive: OBS_A, toExclusive: OBS_D },
      completeIntervalCount: 0,
      knownIntervalCount: 1,
      gapCount: 1,
      firstGap: { fromInclusive: OBS_B, toExclusive: OBS_D },
    },
    missingOpeningLotCount: 1,
    orphanCommissionCount: 1,
  });
  assert.equal("backfill" in deskById(snapshot, "joe"), false);
  assert.equal("backfill" in deskById(snapshot, "joel"), false);
  assert.deepEqual(deskById(snapshot, "j").money, { equity: null, dayPnl: null, totalPnl: null });
  assert.deepEqual(snapshot.totals, { equity: null, dayPnl: null, totalPnl: null });
  const projectedText = JSON.stringify(deskById(snapshot, "j").backfill);
  assert.equal(projectedText.includes("synthetic-hidden-id"), false);
  assert.equal(projectedText.includes("synthetic earlier interval unavailable"), false);
  assert.equal("points" in deskById(snapshot, "j").backfill.capturedSubtotal, false);
  assert.equal("pointsTruncated" in deskById(snapshot, "j").backfill.capturedSubtotal, false);
});

test("captured subtotal calculation basis is explicit and never inferred", () => {
  const known = projectBook(baseBook(), { familyHistory: bestAvailableHistory() });
  assert.equal(
    deskById(known, "j").backfill.capturedSubtotal.method,
    "captured-fifo-matched-roundtrips",
  );

  const missingHistory = bestAvailableHistory();
  delete missingHistory.capturedSubtotal.method;
  const missing = projectBook(baseBook(), { familyHistory: missingHistory });
  assert.equal(deskById(missing, "j").backfill.capturedSubtotal.method, null);

  const unrelated = projectBook(baseBook(), {
    familyHistory: bestAvailableHistory({
      capturedSubtotal: { method: "account-average-cost-realized" },
    }),
  });
  assert.equal(deskById(unrelated, "j").backfill.capturedSubtotal.method, null);

  const unavailable = projectBook(baseBook(), {
    familyHistory: bestAvailableHistory({
      capturedSubtotal: {
        realizedPnl: null,
        currency: null,
        method: "captured-fifo-matched-roundtrips",
      },
    }),
  });
  assert.equal(deskById(unavailable, "j").backfill.capturedSubtotal.method, null);
});

test("captured history points preserve actual nonuniform times and native realized values", () => {
  const points = [
    { at: OBS_A, realizedPnl: -2.5 },
    { at: OBS_A1, realizedPnl: 3.25 },
    { at: OBS_A4, realizedPnl: 3.25 },
    { at: OBS_B, realizedPnl: -37.125 },
  ];
  const snapshot = projectBook(baseBook(), {
    publisherAt: new Date(OBS_B),
    familyHistory: bestAvailableHistory({
      capturedSubtotal: { points, pointsTruncated: true },
    }),
  });
  assert.deepEqual(deskById(snapshot, "j").backfill.capturedSubtotal.points, points);
  assert.equal(deskById(snapshot, "j").backfill.capturedSubtotal.pointsTruncated, true);
  assert.equal(deskById(snapshot, "j").backfill.capturedSubtotal.currency, "USD");
});

test("singleton and explicitly empty captured histories remain honest", () => {
  const singleton = projectBook(baseBook(), {
    publisherAt: new Date(OBS_B),
    familyHistory: bestAvailableHistory({
      capturedSubtotal: {
        realizedPnl: 8.625,
        points: [{ at: OBS_A4, realizedPnl: 8.625 }],
        pointsTruncated: false,
      },
    }),
  });
  assert.deepEqual(deskById(singleton, "j").backfill.capturedSubtotal.points, [
    { at: OBS_A4, realizedPnl: 8.625 },
  ]);

  const empty = projectBook(baseBook(), {
    publisherAt: new Date(OBS_B),
    familyHistory: bestAvailableHistory({
      capturedSubtotal: {
        realizedPnl: null,
        currency: null,
        executionCount: 0,
        commissionCount: 0,
        points: [],
        pointsTruncated: false,
      },
    }),
  });
  assert.deepEqual(deskById(empty, "j").backfill.capturedSubtotal.points, []);
});

test("malformed captured history points omit the producer backfill", () => {
  const tooMany = Array.from({ length: 2049 }, (_, index) => ({
    at: new Date(Date.parse(OBS_A) + index).toISOString(),
    realizedPnl: index === 2048 ? -37.125 : index / 100,
  }));
  const invalidCaptured = [
    { points: [{ at: OBS_B, realizedPnl: -37.125 }] },
    { pointsTruncated: false },
    { points: [{ at: OBS_B, realizedPnl: -37.125 }], pointsTruncated: "false" },
    { points: tooMany, pointsTruncated: true },
    { points: [{ at: OBS_D, realizedPnl: -37.125 }], pointsTruncated: false },
    { points: [{ at: OBS_A1, realizedPnl: 1 }, { at: OBS_A1, realizedPnl: -37.125 }], pointsTruncated: false },
    { points: [{ at: OBS_A4, realizedPnl: -37.125 }, { at: OBS_A1, realizedPnl: -37.125 }], pointsTruncated: false },
    { points: [{ at: OBS_A4, realizedPnl: Number.NaN }], pointsTruncated: false },
    { points: [{ at: OBS_A4, realizedPnl: -37.12 }], pointsTruncated: false },
    { points: [{ at: OBS_A4, realizedPnl: -37.125, execId: "synthetic-forbidden" }], pointsTruncated: false },
    { points: [{ at: OBS_A4, realizedPnl: -37.125, currency: "USD" }], pointsTruncated: false },
    { realizedPnl: -37.125, points: [], pointsTruncated: false },
    { realizedPnl: null, currency: null, points: [], pointsTruncated: true },
  ];
  for (const capturedSubtotal of invalidCaptured) {
    const snapshot = projectBook(baseBook(), {
      publisherAt: new Date(OBS_B),
      familyHistory: bestAvailableHistory({ capturedSubtotal }),
    });
    assert.equal("backfill" in deskById(snapshot, "j"), false);
  }
});

test("family history preserves USD or EUR subtotal currency without inventing FX", () => {
  const usd = projectBook(baseBook(), {
    publisherAt: new Date(OBS_B),
    familyHistory: bestAvailableHistory(),
  });
  assert.equal(deskById(usd, "j").backfill.capturedSubtotal.currency, "USD");
  assert.equal(deskById(usd, "j").backfill.fullTotalAvailable, false);
  assert.equal("equity" in deskById(usd, "j").backfill, false);

  const eur = projectBook(baseBook(), {
    publisherAt: new Date(OBS_B),
    familyHistory: bestAvailableHistory({
      status: "COMPLETE",
      equity: 6123.45,
      capturedSubtotal: { currency: "EUR", realizedPnl: 18.625, throughInclusive: OBS_D },
      coverage: {
        completeIntervals: [{ fromInclusive: OBS_A, toExclusive: OBS_D }],
        knownIntervals: [{ fromInclusive: OBS_A, toExclusive: OBS_D }],
        gaps: [],
      },
      missingOpeningLots: [],
      orphanCommissionIds: [],
    }),
  });
  assert.equal(deskById(eur, "j").backfill.capturedSubtotal.currency, "EUR");
  assert.equal(deskById(eur, "j").backfill.capturedSubtotal.realizedPnl, 18.625);
  assert.equal(deskById(eur, "j").backfill.fullTotalAvailable, true);
});

test("absent or invalid family history metadata is omitted instead of guessed", () => {
  const absent = projectBook(baseBook(), { publisherAt: new Date(OBS_B) });
  assert.equal("backfill" in deskById(absent, "j"), false);

  const invalidHistories = [
    { ok: true },
    bestAvailableHistory({ status: "PARTIAL" }),
    bestAvailableHistory({ capturedSubtotal: { realizedPnl: "-1" } }),
    bestAvailableHistory({ capturedSubtotal: { currency: null } }),
    bestAvailableHistory({ capturedSubtotal: { executionCount: -1 } }),
    bestAvailableHistory({ capturedSubtotal: { fromInclusive: "2026-09-10" } }),
    bestAvailableHistory({ coverage: { knownIntervals: null } }),
    bestAvailableHistory({ coverage: { gaps: [{ fromInclusive: OBS_B, toExclusive: OBS_D, reason: "" }] } }),
    bestAvailableHistory({ missingOpeningLots: null }),
    bestAvailableHistory({ orphanCommissionIds: null }),
  ];
  for (const familyHistory of invalidHistories) {
    const snapshot = projectBook(baseBook(), { publisherAt: new Date(OBS_B), familyHistory });
    assert.equal("backfill" in deskById(snapshot, "j"), false);
  }
});

test("retained broker data and gateway loss do not erase or promote backfill", () => {
  const familyHistory = bestAvailableHistory({
    capturedSubtotal: {
      points: [
        { at: OBS_A1, realizedPnl: 3.25 },
        { at: OBS_B, realizedPnl: -37.125 },
      ],
      pointsTruncated: false,
    },
  });
  const snapshot = projectBook(baseBook({ gateway: false, lastError: "synthetic upstream loss" }), {
    publisherAt: new Date(OBS_C),
    familyRuntimeEnabled: true,
    family: { ok: false, reason: "synthetic live J accounting gap" },
    familyHistory,
  });
  assert.equal(snapshot.brokerAccount.status, "unavailable");
  assert.equal(deskById(snapshot, "j").backfill.status, "BEST_AVAILABLE");
  assert.equal(deskById(snapshot, "j").backfill.fullTotalAvailable, false);
  assert.deepEqual(deskById(snapshot, "j").backfill.capturedSubtotal.points, familyHistory.capturedSubtotal.points);
  assert.equal(deskById(snapshot, "j").money.equity, null);
  assert.equal(snapshot.totals.equity, null);
});

test("new family history input updates the summary without advancing broker time", () => {
  const first = projectBook(baseBook(), {
    publisherAt: new Date(OBS_B),
    familyHistory: bestAvailableHistory({
      capturedSubtotal: {
        points: [{ at: OBS_B, realizedPnl: -37.125 }],
        pointsTruncated: false,
      },
    }),
  });
  const next = projectBook(baseBook(), {
    publisherAt: new Date(OBS_C),
    familyHistory: bestAvailableHistory({
      capturedSubtotal: {
        realizedPnl: -35.875,
        executionCount: 45,
        commissionCount: 44,
        throughInclusive: OBS_C,
        points: [
          { at: OBS_B, realizedPnl: -37.125 },
          { at: OBS_C, realizedPnl: -35.875 },
        ],
        pointsTruncated: false,
      },
      coverage: {
        knownIntervals: [{ fromInclusive: OBS_A, toExclusive: OBS_C }],
        gaps: [{ fromInclusive: OBS_C, toExclusive: OBS_D, reason: "synthetic remaining interval" }],
      },
    }),
  });
  assert.equal(first.generatedAt, next.generatedAt);
  assert.equal(first.brokerAccount.observedAt, next.brokerAccount.observedAt);
  assert.notDeepEqual(deskById(first, "j").backfill, deskById(next, "j").backfill);
  assert.equal(deskById(next, "j").backfill.capturedSubtotal.executionCount, 45);
  assert.equal(deskById(next, "j").backfill.capturedSubtotal.points.at(-1).at, OBS_C);
});

test("enabled family runtime isolates incomplete J accounting without stopping the household", () => {
  const broker = baseBook({
    portfolio: [{ symbol: "INTC", pos: 10, realizedPNL: 400, unrealizedPNL: 599 }],
    positionsCoverage: { status: "complete", rows: [{ symbol: "INTC", pos: 10 }] },
  });
  for (const family of [
    { ok: false, reason: "family ledger state is corrupt JSON" },
    { ok: false, reason: "unproved execution retrieval gap across America/New_York midnight; backfill required" },
    { ok: true },
  ]) {
    const unavailable = projectBook(broker, { familyRuntimeEnabled: true, family });
    assert.ok(unavailable);
    const j = deskById(unavailable, "j");
    assert.equal(j.state, "stuck");
    assert.deepEqual(j.money, { equity: null, dayPnl: null, totalPnl: null });
    assert.equal("positions" in j, false);
    assert.equal("accounting" in j, false);
    assert.match(j.learning.headline, /unavailable/);
    assert.match(j.issues[0], /accounting unavailable/);
    assert.deepEqual(unavailable.totals, { equity: null, dayPnl: null, totalPnl: null });
  }

  const family = {
    ok: true,
    equity: 5012,
    totalPnl: 12,
    realizedPnl: 7,
    unrealizedPnl: 5,
    positions: [{
      desk: "j",
      symbol: "ACME",
      side: "Long",
      quantity: 2,
      accountingScope: "stage0",
      dayPnl: 123,
      currency: "USD",
      mark: 25,
      updatedAt: OBS_B,
    }],
    accounting: {
      periodStart: "2026-09-10T04:00:00Z",
      method: "execution-fifo-net-current-fx",
      detail: "Synthetic family accounting.",
    },
    observedAt: OBS_B,
    executionCount: 2,
  };
  const legacy = projectBook(broker, { publisherAt: new Date(OBS_C) });
  const snapshot = projectBook(broker, {
    publisherAt: new Date(OBS_C),
    familyRuntimeEnabled: true,
    family,
  });
  const j = deskById(snapshot, "j");
  assert.deepEqual(j.money, { equity: 5012, dayPnl: null, totalPnl: 12 });
  assert.equal(j.positions[0].symbol, "ACME");
  assert.equal(j.positions[0].dayPnl, null);
  assert.equal(j.positions.some((row) => row.symbol === "INTC"), false);
  assert.deepEqual(j.accounting, family.accounting);
  assert.match(j.action, /J \+ J2–J5; verified since 10 Sep; net fees; EUR at observed FX/);
  assert.deepEqual(deskById(snapshot, "joe"), deskById(legacy, "joe"));
  assert.deepEqual(deskById(snapshot, "joel"), deskById(legacy, "joel"));
  assert.notEqual(j.state, "stuck");
  assert.deepEqual(j.issues, []);
});

test("corrupt or midnight J gaps preserve Joe and Joel, and recovery clears J unavailability", () => {
  const joelContract = stockContract("TSLA");
  const broker = baseBook({
    positions: [{ symbol: "TSLA", pos: 2 }],
    portfolio: [{
      contract: joelContract,
      symbol: "TSLA",
      pos: 2,
      marketPrice: 220,
      marketValue: 440,
      unrealizedPNL: 20,
      realizedPNL: 3,
    }],
    positionsCoverage: {
      status: "complete",
      rows: [{ symbol: "TSLA", pos: 2, currency: "USD", marketPrice: 220 }],
    },
  });
  const baseline = projectBook(broker, { publisherAt: new Date(OBS_C) });
  for (const reason of [
    "family ledger state is corrupt JSON",
    "unproved execution retrieval gap across America/New_York midnight; backfill required",
  ]) {
    const unavailable = projectBook(broker, {
      publisherAt: new Date(OBS_C),
      familyRuntimeEnabled: true,
      family: { ok: false, reason },
    });
    assert.deepEqual(deskById(unavailable, "joe"), deskById(baseline, "joe"));
    assert.deepEqual(deskById(unavailable, "joel"), deskById(baseline, "joel"));
    assert.deepEqual(deskById(unavailable, "j").money, {
      equity: null,
      dayPnl: null,
      totalPnl: null,
    });
    assert.equal("positions" in deskById(unavailable, "j"), false);
  }

  const recovered = projectBook(broker, {
    publisherAt: new Date(OBS_C),
    familyRuntimeEnabled: true,
    family: {
      ok: true,
      equity: 5000,
      totalPnl: 0,
      realizedPnl: 0,
      unrealizedPnl: 0,
      positions: [],
      accounting: {
        periodStart: "2026-09-10T04:00:00Z",
        method: "execution-fifo-net-current-fx",
        detail: "Synthetic recovered accounting.",
      },
      observedAt: OBS_B,
      executionCount: 0,
    },
  });
  assert.equal(deskById(recovered, "j").state, "sit-out");
  assert.deepEqual(deskById(recovered, "j").issues, []);
  assert.deepEqual(deskById(recovered, "j").positions, []);
  assert.deepEqual(recovered.totals, { equity: 15023, dayPnl: null, totalPnl: 23 });
});

test("a newer family economic revision advances generatedAt while publisher heartbeats do not", () => {
  const family = {
    ok: true,
    equity: 5000,
    totalPnl: 0,
    realizedPnl: 0,
    unrealizedPnl: 0,
    positions: [],
    accounting: {
      periodStart: "2026-09-10T04:00:00Z",
      method: "execution-fifo-net-current-fx",
      detail: "Synthetic family accounting.",
    },
    observedAt: OBS_B,
    executionCount: 0,
  };
  const first = projectBook(baseBook(), {
    publisherAt: new Date(OBS_B),
    familyRuntimeEnabled: true,
    family,
  });
  const heartbeat = projectBook(baseBook(), {
    publisherAt: new Date(OBS_C),
    familyRuntimeEnabled: true,
    family,
  });
  assert.equal(first.generatedAt, "2026-09-10T10:00:05+02:00");
  assert.equal(heartbeat.generatedAt, first.generatedAt);
  assert.equal(heartbeat.source.revision, OBS_B);
  assert.equal(first.brokerAccount.observedAt, OBS_A);
  assert.equal(heartbeat.brokerAccount.observedAt, OBS_A);
  assert.equal(heartbeat.brokerAccount.equity, first.brokerAccount.equity);
});

test("startup without a valid broker timestamp cannot fabricate a snapshot", () => {
  assert.equal(projectBook(baseBook({ ts: null })), null);
});

test("day P&L stays null even for a flat completed book", () => {
  const snapshot = projectBook(baseBook(), { publisherAt: new Date(OBS_B) });
  for (const desk of snapshot.desks) assert.equal(desk.money.dayPnl, null);
  assert.equal(snapshot.totals.dayPnl, null);
});

test("unrelated orders do not refresh broker snapshot time", () => {
  const { adapter, setInstant } = createHarness();
  const api = new FakeApi("synthetic-A");
  adapter.attach(api);
  connectRecognized(api);
  finishInitialSync(api);
  const before = adapter.snapshot();
  setInstant(OBS_C);
  api.emit(EVENTS.openOrder, 7, stockContract("INTC"), {
    account: TARGET,
    action: "BUY",
    totalQuantity: 1,
    orderType: "LMT",
  }, { status: "Submitted" });
  assert.equal(adapter.snapshot().ts, before.ts);
});

test("connection failures invalidate current coverage", () => {
  assert.equal(isConnectionFailure(502, "Couldn't connect"), true);
  assert.equal(isConnectionFailure(504, "Not connected"), true);
  assert.equal(isConnectionFailure(200, "ECONNREFUSED"), true);
  assert.equal(isConnectionFailure(200, "unexpected EOF"), true);
  assert.equal(isConnectionFailure(101, "data farm"), false);
  assert.equal(isConnectionFailure(2104, "Market data farm connection is OK"), false);

  let reconnects = 0;
  const { adapter } = createHarness({ onReconnectNeeded: () => { reconnects += 1; } });
  const api = new FakeApi("synthetic-A");
  adapter.attach(api);
  connectRecognized(api);
  finishInitialSync(api);
  api.emit(EVENTS.error, new Error("connection refused"), 502);
  assert.equal(adapter.connected, false);
  assert.equal(adapter.snapshot().positionsCoverage.status, "unavailable");
  assert.equal(reconnects, 1);

  const eofApi = new FakeApi("synthetic-EOF");
  adapter.attach(eofApi);
  connectRecognized(eofApi);
  finishInitialSync(eofApi);
  eofApi.emit(EVENTS.connectionClosed);
  assert.equal(adapter.socketConnected, false);
  assert.equal(reconnects, 2);
});

test("2110 retains one socket until first restoration schedules one fresh generation", () => {
  const timers = [];
  const delays = [];
  const notices = [];
  let retryAttempts = 0;
  const scheduler = createReconnectScheduler({
    retryMs: 5000,
    onRetry: () => { retryAttempts += 1; },
    setTimer(callback, delay) {
      timers.push(callback);
      delays.push(delay);
    },
  });
  const { adapter, setInstant } = createHarness({
    onBrokerNotice: (notice) => notices.push(notice),
    onReconnectNeeded: () => scheduler.schedule(),
  });
  const first = new FakeApi("synthetic-A");
  adapter.attach(first);
  connectRecognized(first);
  finishInitialSync(first, {
    positions: [{ contract: stockContract("INTC"), pos: 4, avgCost: 10 }],
  });
  const accepted = adapter.snapshot();

  setInstant(OBS_B);
  first.emit(EVENTS.info, "Connectivity between IBKR and Trader Workstation has been lost", 2110);
  first.emit(EVENTS.info, "Repeated upstream-loss notice", 2110);
  first.emit(EVENTS.currentTime, 1_789_000_000);
  first.emit(EVENTS.position, TARGET, stockContract("INTC"), 99, 10);
  first.emit(EVENTS.positionEnd);

  const unavailable = adapter.snapshot();
  assert.equal(adapter.connected, false);
  assert.equal(adapter.socketConnected, true);
  assert.equal(unavailable.gateway, false);
  assert.equal(unavailable.localSocket, true);
  assert.equal(unavailable.positionsCoverage.status, "unavailable");
  assert.equal(unavailable.positions[0].pos, accepted.positions[0].pos);
  assert.equal(unavailable.ts, accepted.ts);
  assert.equal(unavailable.gatewayLastSeenAt, accepted.gatewayLastSeenAt);
  assert.equal(unavailable.lastError, "broker upstream_lost (code 2110)");
  assert.deepEqual(notices[0], {
    route: "info",
    code: 2110,
    state: "upstream_lost",
    action: "local_socket_retained",
  });
  assert.equal("message" in notices[0], false);

  first.emit(EVENTS.info, "Connectivity restored - data lost", 1101);
  first.emit(EVENTS.info, "Repeated restoration notice", 1101);
  assert.deepEqual(delays, [5000]);
  assert.equal(scheduler.pending, true);
  assert.equal(adapter.socketConnected, false);
  assert.equal(notices.at(-1).action, "fresh_generation_scheduled");
  assert.equal(notices.length, 3);

  timers.shift()();
  assert.equal(retryAttempts, 1);
  const second = new FakeApi("synthetic-B");
  adapter.attach(second);
  connectRecognized(second);
  second.emit(EVENTS.info, "Startup restoration notice without observed loss", 1102);
  assert.deepEqual(delays, [5000]);
  setInstant(OBS_C);

  // A full set of unscoped callbacks from the retired socket cannot complete
  // the new generation's working snapshot.
  first.emit(EVENTS.managedAccounts, TARGET);
  first.emit(EVENTS.position, TARGET, stockContract("INTC"), 999, 1);
  first.emit(EVENTS.positionEnd);
  first.emit(EVENTS.accountSummary, SUMMARY_REQ_ID, TARGET, "NetLiquidation", "999999", "EUR");
  first.emit(EVENTS.accountSummaryEnd, SUMMARY_REQ_ID);
  first.emit(EVENTS.accountDownloadEnd, TARGET);
  const beforeFreshCompletion = adapter.snapshot();
  assert.equal(beforeFreshCompletion.positionsCoverage.status, "unavailable");
  assert.equal(beforeFreshCompletion.ts, accepted.ts);
  assert.equal(beforeFreshCompletion.gatewayLastSeenAt, accepted.gatewayLastSeenAt);

  // Partial callbacks on the fresh generation also cannot advance last-good time.
  second.emit(EVENTS.accountSummary, SUMMARY_REQ_ID, TARGET, "NetLiquidation", "13000", "EUR");
  assert.equal(adapter.snapshot().gatewayLastSeenAt, accepted.gatewayLastSeenAt);
  finishInitialSync(second);

  const recovered = adapter.snapshot();
  assert.equal(adapter.connected, true);
  assert.equal(recovered.gateway, true);
  assert.equal(recovered.positionsCoverage.status, "complete");
  assert.deepEqual(recovered.positions, []);
  assert.equal(recovered.summary.NetLiquidation.value, "12000");
  assert.equal(recovered.ts, OBS_C);
  assert.deepEqual(recovered.positions, []);
});

test("SDK error 1100 uses the same sanitized retained-socket path", () => {
  let reconnects = 0;
  const notices = [];
  const { adapter } = createHarness({
    onBrokerNotice: (notice) => notices.push(notice),
    onReconnectNeeded: () => { reconnects += 1; },
  });
  const api = new FakeApi("synthetic-A");
  adapter.attach(api);
  connectRecognized(api);
  finishInitialSync(api);
  api.emit(EVENTS.error, new Error("raw upstream detail is not propagated"), 1100);

  assert.equal(brokerConnectivityState(1100), "upstream_lost");
  assert.equal(adapter.connected, false);
  assert.equal(adapter.socketConnected, true);
  assert.equal(adapter.snapshot().lastError, "broker upstream_lost (code 1100)");
  assert.equal(reconnects, 0);
  assert.deepEqual(notices, [{
    route: "error",
    code: 1100,
    state: "upstream_lost",
    action: "local_socket_retained",
  }]);
  api.emit(EVENTS.error, new Error("restored"), 1102);
  assert.equal(reconnects, 1);
});

test("1101 and 1102 without an observed loss never start a reconnect loop", () => {
  for (const [code, state] of [
    [1101, "restored_data_lost"],
    [1102, "restored_data_maintained"],
  ]) {
    let reconnects = 0;
    const notices = [];
    const { adapter } = createHarness({
      onBrokerNotice: (notice) => notices.push(notice),
      onReconnectNeeded: () => { reconnects += 1; },
    });
    const api = new FakeApi(`synthetic-${code}`);
    adapter.attach(api);
    connectRecognized(api);
    finishInitialSync(api);
    api.emit(EVENTS.info, "restoration detail is intentionally not propagated", code);
    api.emit(EVENTS.info, "repeated restoration detail", code);

    assert.equal(brokerConnectivityState(code), state);
    assert.equal(adapter.connected, true);
    assert.equal(adapter.socketConnected, true);
    assert.equal(adapter.snapshot().positionsCoverage.status, "complete");
    assert.equal(reconnects, 0);
    assert.deepEqual(notices, [{
      route: "info",
      code,
      state,
      action: "ignored_without_observed_loss",
    }, {
      route: "info",
      code,
      state,
      action: "ignored_without_observed_loss",
    }]);
  }
});

test("a startup restoration notice cannot claim upstream freshness before a complete snapshot", () => {
  let reconnects = 0;
  const { adapter } = createHarness({ onReconnectNeeded: () => { reconnects += 1; } });
  const api = new FakeApi("synthetic-startup");
  adapter.attach(api);
  api.emit(EVENTS.connected);
  api.emit(EVENTS.info, "startup restoration notice", 1102);

  assert.equal(adapter.socketConnected, true);
  assert.equal(adapter.connected, false);
  assert.equal(adapter.snapshot(), null);
  assert.equal(reconnects, 0);
});

test("benign connectivity notices stay visible without reconnecting", () => {
  let reconnects = 0;
  const notices = [];
  const { adapter } = createHarness({
    onBrokerNotice: (notice) => notices.push(notice),
    onReconnectNeeded: () => { reconnects += 1; },
  });
  const api = new FakeApi("synthetic-A");
  adapter.attach(api);
  connectRecognized(api);
  finishInitialSync(api);

  for (const code of [2104, 2106, 2107, 2158]) {
    api.emit(EVENTS.info, "benign connection notice", code);
  }

  assert.equal(reconnects, 0);
  assert.equal(adapter.connected, true);
  assert.equal(adapter.snapshot().positionsCoverage.status, "complete");
  assert.deepEqual(notices.map(({ code, state, action }) => ({ code, state, action })), [
    { code: 2104, state: "informational", action: "none" },
    { code: 2106, state: "informational", action: "none" },
    { code: 2107, state: "informational", action: "none" },
    { code: 2158, state: "informational", action: "none" },
  ]);
});
