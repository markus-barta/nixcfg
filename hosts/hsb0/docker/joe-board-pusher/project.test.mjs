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
const OBS_B = "2026-09-10T08:00:05.000Z";
const OBS_C = "2026-09-10T08:10:00.000Z";
const OBS_RECONNECT = "2026-09-10T09:30:00.000Z";
const SUMMARY_REQ_ID = 9501;
const EVENTS = Object.fromEntries([
  "connected",
  "disconnected",
  "error",
  "info",
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
  reqAllOpenOrders() { this.requests.push(["openOrders"]); }
  reqAccountSummary(...args) { this.requests.push(["accountSummary", ...args]); }
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
    summary: { NetLiquidation: { value: "12000" } },
    portfolio: [],
    positions: [],
    ...overrides,
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
  oldApi.emit(EVENTS.error, new Error("stale connection failure"), 502);
  oldApi.emit(EVENTS.managedAccounts, TARGET);
  oldApi.emit(EVENTS.accountSummary, SUMMARY_REQ_ID, TARGET, "NetLiquidation", "999999", "EUR");
  oldApi.emit(EVENTS.accountSummaryEnd, SUMMARY_REQ_ID);
  oldApi.emit(EVENTS.position, TARGET, stockContract("INTC", { conId: 2 }), 99, 1);
  oldApi.emit(EVENTS.positionEnd);
  oldApi.emit(EVENTS.updatePortfolio, stockContract("INTC", { conId: 2 }), 99, 99, 999, 1, 9, 9, TARGET);
  oldApi.emit(EVENTS.accountDownloadEnd, TARGET);
  oldApi.emit(EVENTS.openOrder, 1, stockContract("INTC"), { account: TARGET }, {});
  assert.equal(adapter.connected, true);
  assert.equal(adapter.snapshot().lastError, null);

  currentApi.emit(EVENTS.managedAccounts, TARGET);
  finishInitialSync(currentApi, { summaryValue: "13000" });
  const snapshot = adapter.snapshot();
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
  assert.equal(partial.positionsCoverage.status, "partial");
  assert.deepEqual(partial.positionsCoverage.rows, []);
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

test("invalid live quantity requests resync without replacing the last valid snapshot", () => {
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
  assert.equal(after.positionsCoverage.status, "partial");
  assert.equal(after.positions[0].pos, valid.positions[0].pos);
  assert.equal(after.ts, valid.ts);
});

test("repeated invalid-data resyncs cannot bypass the positive retry delay", () => {
  const timers = [];
  const delays = [];
  let retryAttempts = 0;
  const scheduler = createReconnectScheduler({
    retryMs: 5000,
    onRetry: () => { retryAttempts += 1; },
    setTimer(callback, delay) {
      timers.push(callback);
      delays.push(delay);
    },
  });
  let adapter;
  adapter = createBrokerSessionAdapter({
    targetAccount: TARGET,
    eventNames: EVENTS,
    now: () => OBS_A,
    hooks: {
      onResyncNeeded() {
        adapter.retire("synthetic invalid quantity");
        scheduler.schedule();
      },
    },
  });

  const first = new FakeApi("synthetic-A");
  adapter.attach(first);
  first.emit(EVENTS.connected);
  first.emit(EVENTS.position, TARGET, stockContract("INTC"), null, 10);
  first.emit(EVENTS.position, TARGET, stockContract("INTC"), null, 10);
  assert.deepEqual(delays, [5000]);
  assert.equal(scheduler.pending, true);

  timers.shift()();
  assert.equal(retryAttempts, 1);
  assert.equal(scheduler.pending, false);
  const second = new FakeApi("synthetic-B");
  adapter.attach(second);
  second.emit(EVENTS.connected);
  second.emit(EVENTS.position, TARGET, stockContract("INTC"), Number.MAX_VALUE, 10);
  assert.deepEqual(delays, [5000, 5000]);
  assert.equal(delays.every((delay) => delay > 0), true);
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
  assert.equal(joel.positions[0].accountingScope, "legacy");
  assert.equal(joel.money.totalPnl, 0);
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
  for (const desk of snapshot.desks) {
    assert.equal(desk.heartbeatAt, "2026-09-10T10:10:00+02:00");
  }
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
  assert.equal(isConnectionFailure(200, "ECONNREFUSED"), true);
  assert.equal(isConnectionFailure(101, "data farm"), false);
  assert.equal(isConnectionFailure(2104, "Market data farm connection is OK"), false);

  const { adapter } = createHarness();
  const api = new FakeApi("synthetic-A");
  adapter.attach(api);
  connectRecognized(api);
  finishInitialSync(api);
  api.emit(EVENTS.error, new Error("connection refused"), 502);
  assert.equal(adapter.connected, false);
  assert.equal(adapter.snapshot().positionsCoverage.status, "unavailable");
});

test("SDK info 2110 preserves the accepted book and recovers through one positive retry", () => {
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
  first.emit(EVENTS.position, TARGET, stockContract("INTC"), 99, 10);
  first.emit(EVENTS.positionEnd);

  const unavailable = adapter.snapshot();
  assert.equal(adapter.connected, false);
  assert.equal(unavailable.gateway, false);
  assert.equal(unavailable.positionsCoverage.status, "unavailable");
  assert.equal(unavailable.positions[0].pos, accepted.positions[0].pos);
  assert.equal(unavailable.ts, accepted.ts);
  assert.equal(unavailable.lastError, "broker upstream_lost (code 2110)");
  assert.deepEqual(delays, [5000]);
  assert.equal(delays.every((delay) => delay > 0), true);
  assert.deepEqual(notices[0], {
    route: "info",
    code: 2110,
    state: "upstream_lost",
    action: "fresh_session_scheduled",
  });
  assert.equal("message" in notices[0], false);

  timers.shift()();
  assert.equal(retryAttempts, 1);
  const second = new FakeApi("synthetic-B");
  adapter.attach(second);
  connectRecognized(second);
  setInstant(OBS_C);
  finishInitialSync(second);
  first.emit(EVENTS.managedAccounts, TARGET);
  first.emit(EVENTS.accountSummary, SUMMARY_REQ_ID, TARGET, "NetLiquidation", "999999", "EUR");
  first.emit(EVENTS.accountSummaryEnd, SUMMARY_REQ_ID);
  first.emit(EVENTS.accountDownloadEnd, TARGET);

  const recovered = adapter.snapshot();
  assert.equal(adapter.connected, true);
  assert.equal(recovered.gateway, true);
  assert.equal(recovered.positionsCoverage.status, "complete");
  assert.deepEqual(recovered.positions, []);
  assert.equal(recovered.summary.NetLiquidation.value, "12000");
  assert.equal(recovered.ts, OBS_C);
});

test("SDK error 1100 uses the same sanitized upstream-loss path", () => {
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
  assert.equal(adapter.snapshot().lastError, "broker upstream_lost (code 1100)");
  assert.equal(reconnects, 1);
  assert.deepEqual(notices, [{
    route: "error",
    code: 1100,
    state: "upstream_lost",
    action: "fresh_session_scheduled",
  }]);
});

test("1101 and 1102 explicitly require a fresh complete session", () => {
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

    assert.equal(brokerConnectivityState(code), state);
    assert.equal(adapter.connected, false);
    assert.equal(adapter.snapshot().positionsCoverage.status, "unavailable");
    assert.equal(reconnects, 1);
    assert.deepEqual(notices, [{
      route: "info",
      code,
      state,
      action: "fresh_session_scheduled",
    }]);
  }
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
