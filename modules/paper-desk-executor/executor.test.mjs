import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";
import { mkdtempSync } from "node:fs";
import fs from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import { Readable } from "node:stream";
import { createServer } from "./server.mjs";
import { executeIntent } from "./executor.mjs";
import { deskPositions, flattenOwned, freshMarks, openSession, readPusherExecutions, reconcileDeskPositions } from "./ib.mjs";
import { brakeUsage, parseIntent, newYorkDay } from "./policy.mjs";
import { runClient } from "./client/paper-intent.mjs";

const ACCOUNT = "DUR970597";
const events = Object.fromEntries(["error", "connected", "disconnected", "managedAccounts", "position", "positionEnd", "openOrder", "openOrderEnd", "execDetails", "execDetailsEnd", "nextValidId", "orderStatus", "contractDetails", "contractDetailsEnd", "accountUpdateMulti", "accountUpdateMultiEnd", "commissionReport", "tickPrice", "tickString", "tickSnapshotEnd"].map((key) => [key, key]));
const contract = (symbol = "AAPL", conId = 1) => ({ symbol, conId, secType: "STK", currency: "USD", exchange: "SMART" });
// Keep order dates on the same New York clock as fills and history coverage,
// including tests that freeze Date themselves.
const ref = (desk = "j", thesis = "test", now = Date.now()) => `${desk}|${newYorkDay(now).slice(2).replaceAll("-", "")}|${thesis}`;
const fill = (overrides = {}) => ({ contract: contract(), execution: { execId: "fill.1", acctNumber: ACCOUNT, clientId: 705, orderRef: ref(), side: "BOT", shares: 2, price: 100, time: `${newYorkDay().replaceAll("-", "")} 15:00:00`, orderId: 20, ...overrides } });
const order = (overrides = {}) => ({ ...contract(), orderId: 30, clientId: 705, action: "BUY", orderType: "LMT", quantity: 2, orderRef: ref(), parentId: 0, status: "Submitted", ...overrides });
function intent(action = "place", overrides = {}) {
  return parseIntent({ schema: "barta.paper-desk-intent.v2", intentId: "j-executor-test", desk: "j", action, createdAt: new Date(Date.now() - 1000).toISOString(), expiresAt: new Date(Date.now() + 300000).toISOString(), ...(action === "place" ? { orderRef: ref(), order: { symbol: "AAPL", side: "BUY", quantity: 2, limitPrice: 100, stopPrice: 99, currency: "USD" } } : {}), ...overrides });
}
function ledger() { return { initializedAt: new Date().toISOString(), intents: new Map(), placements: [], executions: [] }; }
function intradayCoverage() {
  const now = Date.now();
  let midnight = Math.floor(now / 3600000) * 3600000;
  while (newYorkDay(midnight - 3600000) === newYorkDay(now)) midnight -= 3600000;
  return { status: "known", gaps: [{ fromInclusive: new Date(midnight).toISOString(), toExclusive: new Date(now).toISOString(), reason: "no authoritative completeness receipt" }], target: { fromInclusive: new Date(midnight - 86400000).toISOString(), toExclusive: new Date(now).toISOString() } };
}
function harness(options = {}) {
  const broker = { positions: [], orders: [], executions: [], commissions: [], placed: [], cancelled: [], connections: [], executionRequests: [], marketDataTypes: [], markRequests: [], live: new Set(), ...options };
  class FakeIB extends EventEmitter {
    constructor({ clientId }) { super(); this.clientId = clientId; this.autoCancelled = new Set(); }
    connect() {
      assert.equal(broker.live.has(this.clientId), false, "duplicate client session");
      broker.live.add(this.clientId); broker.connections.push(this.clientId);
      this.emit(events.connected);
    }
    disconnect() { broker.live.delete(this.clientId); this.emit(events.disconnected); }
    reqManagedAccts() { this.emit(events.managedAccounts, ACCOUNT); }
    reqPositions() { for (const row of broker.positions) this.emit(events.position, ACCOUNT, row, row.position, row.averageCost || 100); this.emit(events.positionEnd); }
    reqAllOpenOrders() { for (const row of broker.orders) { this.emit(events.openOrder, row.orderId, row, { ...row, totalQuantity: row.quantity }, { status: row.status }); if (!broker.noOrderEvidence) this.emit(events.orderStatus, row.orderId, row.status, row.filled || 0, row.quantity - (row.filled || 0), 0, 0, row.parentId, 0, row.clientId); } if (!broker.noCancelOrdersEnd || !broker.cancelled.length) this.emit(events.openOrderEnd); }
    reqExecutions(id, filter) {
      broker.executionRequests.push({ id, filter });
      if (broker.executionError) this.emit(events.error, new Error("execution snapshot failed"), 201, id);
      for (const row of broker.executions) this.emit(events.execDetails, id, row.contract, row.execution);
      for (const fee of broker.commissions) this.emit(events.commissionReport, fee);
      if (!broker.noCancelExecutionsEnd || !broker.cancelled.length) this.emit(events.execDetailsEnd, broker.wrongExecutionRequest ? id + 1 : id);
      broker.onExecutionRequest?.(this, id);
    }
    reqIds() { this.emit(events.nextValidId, 100 + broker.placed.length); }
    reqContractDetails(id, request) { this.emit(events.contractDetails, id, { contract: broker.resolve ? broker.resolve(request) : contract(request.symbol, request.symbol === "AAPL" ? 1 : 2), stockType: "COMMON" }); this.emit(events.contractDetailsEnd, id); broker.onContractDetails?.(this); }
    reqAccountUpdatesMulti(id) { this.emit(events.accountUpdateMulti, id, ACCOUNT, "", "ExchangeRate", "1", "EUR"); this.emit(events.accountUpdateMulti, id, ACCOUNT, "", "ExchangeRate", "0.9", "USD"); this.emit(events.accountUpdateMultiEnd, id); broker.onFx?.(); }
    cancelAccountUpdatesMulti() {}
    reqMarketDataType(type) { broker.marketDataTypes.push(type); this.marketDataType = type; }
    reqMktData(id, c) {
      assert.equal(this.marketDataType, 3, "delayed data must be selected before requesting quotes");
      broker.markRequests.push({ id, contract: c });
      broker.onMarkRequest?.(this, id, c);
      if (broker.mark354) this.emit(events.error, new Error("Requested market data is not subscribed; delayed data is available"), 354, id);
      if (broker.mark10089) this.emit(events.error, new Error("Requested market data is not subscribed"), 10089, id);
      if (broker.mark10167) this.emit(events.error, new Error("Requested market data is not subscribed. Displaying delayed market data."), 10167, id);
      if (!broker.noMark && !broker.noMarkSymbols?.includes(c.symbol)) for (const [field, price] of broker.quotes || [[4, broker.mark ?? 101]]) this.emit(events.tickPrice, id, field, price);
      if (broker.delayedLastTimestamp !== undefined) this.emit(events.tickString, id, 88, String(broker.delayedLastTimestamp));
      if (!broker.noMarkEnd) this.emit(events.tickSnapshotEnd, id);
      broker.onMark?.(this);
    }
    cancelMktData(id) { if (broker.markCancel300) this.emit(events.error, new Error("Can't find EId with tickerId"), 300, id); }
    placeOrder(id, c, value) {
      broker.placed.push({ id, contract: { ...c }, order: { ...value }, clientId: this.clientId });
      if (broker.errorOnPlace) this.emit(events.error, new Error("paper rejection"), 201, id);
      if (!broker.noAck && !broker.noStatusAck && !(broker.missingStopAck && value.orderType === "STP")) this.emit(events.orderStatus, id, broker.partial ? "Submitted" : value.orderType === "MKT" ? "Filled" : "Submitted", broker.badQuantity ? 0 : broker.partial ? 1 : value.orderType === "MKT" ? value.totalQuantity : 0, broker.badQuantity ? 0 : broker.partial ? 1 : value.orderType === "MKT" ? 0 : value.totalQuantity, 100, 0, value.parentId, 0, this.clientId);
      if (broker.ackModification && broker.orders.some((row) => row.orderId === id && row.clientId === this.clientId)) {
        broker.orders = broker.orders.map((row) => row.orderId === id && row.clientId === this.clientId ? { ...row, ...value, quantity: value.totalQuantity } : row);
        if (!broker.noAck && !broker.noPriceAck) this.emit(events.openOrder, id, c, { ...value, clientId: this.clientId, ...broker.modificationAck }, { status: "Submitted" });
      }
      broker.afterPlace?.(broker.placed.length);
    }
    cancelOrder(id) {
      if (broker.autoCancelChildren) {
        for (const row of broker.orders.filter((row) => row.parentId === id && row.clientId === this.clientId)) this.autoCancelled.add(row.orderId);
        broker.orders = broker.orders.filter((row) => !this.autoCancelled.has(row.orderId));
      }
      broker.cancelled.push(id); if (!broker.keepCancelledOrder) broker.orders = broker.orders.filter((row) => row.orderId !== id);
      if (broker.errorOnCancel) this.emit(events.error, new Error("cancel rejection"), 201, id);
      if (broker.cancelErrorCode || this.autoCancelled.has(id)) this.emit(events.error, new Error("order is not cancellable or not found"), broker.cancelErrorCode || 161, broker.cancelErrorOrderId ?? id);
      if (broker.cancel202) this.emit(events.error, new Error("Order Canceled"), 202, broker.cancel202OrderId ?? id);
      if (!broker.noCancelAck && (!this.autoCancelled.has(id) || broker.autoCancelChildAck)) this.emit(events.orderStatus, id, broker.cancelStatus || "Cancelled", broker.cancelFilled || 0, 0, 0, 0, 0, 0, this.clientId);
      broker.afterCancel?.();
    }
  }
  const connect = async (id, sessionOptions) => {
    const session = await openSession(id, broker.wrongExecutionRequest ? 5 : 1000, { ...sessionOptions, IBApi: FakeIB, EventName: events, wait: broker.wait || (async () => {}) });
    if (!sessionOptions?.ordersOnly) await broker.onSnapshot?.(session);
    return session;
  };
  const history = { schema: "inspr.joe.best-available-history.v1", version: 1, account: ACCOUNT, executions: options.history || [], coverage: { status: "complete", gaps: [], target: { fromInclusive: new Date(Date.now() - 40 * 86400000).toISOString(), toExclusive: new Date().toISOString() } } };
  if (options.coverage) history.coverage = options.coverage;
  const readHistory = (file, now = Date.now(), _readFile, historyOptions) => readPusherExecutions(file, now, () => { if (options.missingHistory) throw new Error("ENOENT"); return JSON.stringify(history); }, historyOptions);
  const config = { clientIds: { executor: 705, recon: 700 }, ownership: { j: [702], j2: [706], j5: [703], joe: [701], joel: [704] }, ownershipLedger: "/pusher-state/family-history.json", blockOnInitDay: false };
  const run = (value, state = ledger(), context = {}) => executeIntent(value, state, { halt: { active: false }, saveState: () => {}, ...context }, { config, connect, readHistory });
  return { broker, run, connect, readHistory, config, runtime: { config, connect, readHistory } };
}

test("pusher history accepts files up to 32 MiB (the pusher writer cap) and refuses larger files before reading", (t) => {
  const now = Date.now();
  const ledgerPath = "/pusher-state/family-history.json";
  const history = { schema: "inspr.joe.best-available-history.v1", version: 1, account: ACCOUNT, executions: [fill()], coverage: { status: "complete", gaps: [], target: { fromInclusive: new Date(now - 40 * 86400000).toISOString(), toExclusive: new Date(now).toISOString() } } };
  let size = 20 * 1024 * 1024;
  t.mock.method(fs, "statSync", (file) => { assert.equal(file, ledgerPath); return { size }; });
  const read = t.mock.method(fs, "readFileSync", (file, encoding) => { assert.equal(file, ledgerPath); assert.equal(encoding, "utf8"); return JSON.stringify(history); });
  syncBuiltinESMExports();
  try {
    for (size of [20 * 1024 * 1024, 32 * 1024 * 1024]) {
      const rows = readPusherExecutions(ledgerPath, now);
      assert.equal(rows.length, 1);
      assert.equal(rows[0].execution.execId, history.executions[0].execution.execId);
    }
    size = 32 * 1024 * 1024 + 1;
    assert.throws(() => readPusherExecutions(ledgerPath, now), /durable ownership ledger unavailable: ownership history exceeds size limit/);
    assert.equal(read.mock.callCount(), 2, "oversized history must be refused before reading");
  } finally {
    t.mock.restoreAll();
    syncBuiltinESMExports();
  }
});

test("executeIntent places accepted tagged bracket on initialization day using distinct sequential sessions", async () => {
  const h = harness(); const state = ledger();
  const result = await h.run(intent(), state);
  assert.equal(result.status, "ok"); assert.deepEqual(h.broker.connections, [700, 705]);
  assert.equal(h.broker.placed.length, 2); assert.ok(h.broker.placed.every((row) => row.order.orderRef === ref()));
  assert.equal(state.placements[0].status, "submitted"); assert.equal(h.broker.live.size, 0);
});

const liveOwnership = { j: [27, 28, 29, 50, 51, 52, 53, 54, 55, 56, 76, 78, 79, 80, 83, 702], j2: [706], j5: [703], joe: [22, 89, 90, 91, 119, 130, 131, 148, 151, 152, 701], joel: [704] };
const flatContracts = [contract("AMD", 2), contract("AVGO", 3), contract("NVDA", 4)];
const keptPositions = () => [{ ...contract("SXR8", 5), currency: "EUR", position: 1401 }, { ...contract("TSLA", 6), position: 1 }, { ...contract("MU", 7), position: 0 }, { ...contract("AMZN", 8), position: 0 }];
function accountFlatHistory() {
  const rows = flatContracts.flatMap((c, index) => [
    { contract: c, execution: fill({ execId: `${c.symbol}-buy.1`, clientId: [27, 76, 79][index], shares: [1, 2, 4][index], time: "2026-09-22T15:00:00Z", orderRef: undefined, orderId: undefined }).execution },
    { contract: c, execution: fill({ execId: `${c.symbol}-sell.1`, clientId: [119, 130, 131][index], shares: [1, 2, 4][index], side: "SLD", time: "2026-09-23T15:00:00Z", orderRef: undefined, orderId: undefined }).execution },
  ]);
  return [...rows, ...[229, 28].map((clientId, index) => ({ contract: flatContracts[2], execution: fill({ execId: `NVDA-unmapped-${index}.1`, clientId, shares: 1, side: index ? "SLD" : "BOT", time: `2026-10-06T16:0${index}:00Z`, orderRef: undefined, orderId: undefined }).execution }))];
}
const newNvdaFill = () => ({ contract: flatContracts[2], execution: fill({ execId: "NVDA-new.1", shares: 2, time: "2026-10-07T19:00:00Z", orderRef: "j|261007|new" }).execution });
function flatHarness(options = {}) {
  const h = harness({ history: accountFlatHistory(), positions: keptPositions(), resolve: (request) => flatContracts.find((row) => row.symbol === request.symbol) || contract(request.symbol), ...options });
  h.config.ownership = liveOwnership;
  return h;
}

test("live cross-desk and unmapped closes clear ownership, concurrency, place, recon and flatten", async (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: Date.parse("2026-10-07T20:03:00Z") });
  const history = accountFlatHistory(), snapshot = { account: ACCOUNT, positions: keptPositions() };
  assert.deepEqual(deskPositions(history, liveOwnership, 705).map((row) => [row.desk, row.symbol, row.quantity]), [["j", "AMD", 1], ["j", "AVGO", 2], ["j", "NVDA", 3], ["joe", "AMD", -1], ["joe", "AVGO", -2], ["joe", "NVDA", -4]]);
  assert.deepEqual(deskPositions(history, liveOwnership, 705, snapshot), []);
  assert.doesNotThrow(() => reconcileDeskPositions(history, snapshot, liveOwnership, 705));
  for (const desk of ["j", "joe"]) for (const action of ["place", "recon", "flatten"]) {
    const h = flatHarness(), state = ledger();
    const result = await h.run(intent(action, { desk, ...(action === "place" ? { orderRef: ref(desk) } : {}) }), state);
    assert.equal(result.status, "ok"); assert.deepEqual(state.deskPositions, []);
    assert.equal(result.ownershipSnapshot, undefined);
    if (action === "place") { assert.equal(h.broker.placed.length, 2); assert.equal(result.budget.concurrentBefore, 0); }
    else {
      assert.deepEqual(h.broker.placed, []);
      for (const name of ["j", "joe"]) assert.equal(brakeUsage(state).perDesk[name].concurrent, 0);
      if (action === "recon") { assert.deepEqual(result.deskPositions, []); assert.ok(result.positions.filter((row) => ["SXR8", "TSLA"].includes(row.symbol)).every((row) => row.keep)); }
      else assert.deepEqual(result.flattened, []);
    }
    assert.deepEqual(h.broker.cancelled, []); assert.equal(h.broker.live.size, 0);
  }
});

test("new tagged ownership after flat is exactly two shares for place, recon and flatten", async (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: Date.parse("2026-10-07T20:03:00Z") });
  for (const action of ["place", "recon", "flatten"]) {
    const state = ledger();
    const h = flatHarness({ executions: [newNvdaFill()], positions: [...keptPositions(), { ...flatContracts[2], position: 2 }] });
    const result = await h.run(intent(action), state);
    assert.deepEqual(state.deskPositions.map((row) => [row.desk, row.symbol, row.quantity]), [["j", "NVDA", 2]]);
    if (action === "flatten") { assert.equal(result.flattened[0].quantity, 2); assert.equal(h.broker.placed[0].order.totalQuantity, 2); }
    if (action === "recon") { assert.equal(result.deskPositions[0].quantity, 2); assert.equal(brakeUsage(state).perDesk.j.concurrent, 1); assert.equal(brakeUsage(state).perDesk.joe.concurrent, 0); }
    assert.equal(h.broker.live.size, 0);
  }
});

test("a mismatched contract retains its old ownership and names the symbol before effects", async (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: Date.parse("2026-10-07T20:03:00Z") });
  for (const action of ["place", "flatten", "cancel"]) {
    const h = flatHarness({ positions: [...keptPositions(), { ...flatContracts[2], position: 1 }], orders: action === "cancel" ? [order({ ...flatContracts[2], clientId: 28, orderRef: "legacy" })] : [] });
    const snapshot = { account: ACCOUNT, positions: h.broker.positions };
    assert.deepEqual(deskPositions(accountFlatHistory(), liveOwnership, 705, snapshot).map((row) => [row.desk, row.symbol, row.quantity]), [["j", "NVDA", 3], ["joe", "NVDA", -4]]);
    await assert.rejects(h.run(intent(action, action === "cancel" ? { orderId: 30 } : {})), /desk ownership does not reconcile with broker position for NVDA/);
    assert.deepEqual(h.broker.placed, []); assert.deepEqual(h.broker.cancelled, []);
  }
});

test("legacy cancel shares the flat reset and clears saved phantom ownership", async (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: Date.parse("2026-10-07T20:03:00Z") });
  const h = flatHarness({ orders: [order({ ...flatContracts[1], clientId: 76, orderRef: "legacy" })] }), state = ledger();
  const result = await h.run(intent("cancel", { orderId: 30 }), state);
  assert.deepEqual(h.broker.cancelled, [30]); assert.deepEqual(h.broker.placed, []);
  assert.deepEqual(state.deskPositions, []); assert.equal(result.ownershipSnapshot, undefined);
});

test("recon gates the reset against the session supplying its latest execution replay", async (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: Date.parse("2026-10-07T20:03:00Z") });
  const h = flatHarness({ executions: [newNvdaFill()], positions: [...keptPositions(), { ...flatContracts[2], position: 2 }], onSnapshot: (session) => {
    if (session.state.executionSnapshot.requestId === 880700) { session.state.executions = []; session.state.positions = keptPositions(); }
  } });
  const result = await h.run(intent("recon"));
  assert.deepEqual(result.deskPositions.map((row) => [row.desk, row.symbol, row.quantity]), [["j", "NVDA", 2]]);
});

test("saved ownership after bracket submission uses the placing session's new fills and positions", async (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: Date.parse("2026-10-07T20:03:00Z") });
  let placing;
  const h = flatHarness({ onSnapshot: (session) => { if (session.state.executionSnapshot.requestId === 880705) placing = session.state; }, afterPlace: (count) => {
    if (count === 2) { placing.executions.push(newNvdaFill()); placing.positions.push({ ...flatContracts[2], position: 2 }); }
  } });
  const state = ledger();
  await h.run(intent("place", { order: { ...intent().order, symbol: "NVDA" } }), state);
  assert.deepEqual(state.deskPositions.map((row) => [row.desk, row.symbol, row.quantity]), [["j", "NVDA", 2]]);
});

test("flatten returns same-session ownership evidence after its closing fill makes the account flat", async (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: Date.parse("2026-10-07T20:03:00Z") });
  let placing;
  const h = flatHarness({ executions: [newNvdaFill()], positions: [...keptPositions(), { ...flatContracts[2], position: 2 }], onSnapshot: (session) => { if (session.state.executionSnapshot.requestId === 880705) placing = session.state; }, afterPlace: () => {
    placing.executions.push({ contract: flatContracts[2], execution: fill({ execId: "NVDA-close.1", orderId: h.broker.placed[0].id, shares: 2, side: "SLD", time: new Date().toISOString() }).execution });
    placing.positions.find((row) => row.conId === 4).position = 0;
  } });
  const state = ledger(), result = await h.run(intent("flatten"), state);
  assert.equal(result.flattened[0].quantity, 2); assert.deepEqual(state.deskPositions, []);
  assert.equal(result.ownershipSnapshot, undefined); assert.equal(h.broker.live.size, 0);
});

test("pusher history stays strict by default for today's ownership gap", () => {
  const h = harness({ coverage: intradayCoverage() });
  assert.throws(() => h.readHistory(h.config.ownershipLedger), /coverage is incomplete|gaps require a fresh same-session/);
  assert.equal(h.readHistory(h.config.ownershipLedger, Date.now(), undefined, { allowIntradayGaps: true }).coverage.status, "known");
});

test("place accepts today's ownership gap with the recon session's fresh execution snapshot", async (t) => {
  const now = Date.parse("2026-10-07T19:13:00Z");
  t.mock.timers.enable({ apis: ["Date"], now });
  const coverage = intradayCoverage();
  coverage.target.toExclusive = coverage.gaps[0].toExclusive = new Date(now - 30000).toISOString();
  const executions = ["MSFT", "NVDA", "META"].map((symbol, index) => ({ contract: contract(symbol, index + 2), execution: fill({ execId: `other-${index}.1`, clientId: [701, 703, 704][index], orderRef: ref(["joe", "j5", "joel"][index]) }).execution }));
  for (const desk of ["j", "j2", "j5"]) {
    const state = ledger();
    const h = harness({ coverage, executions, positions: executions.map((row) => ({ ...row.contract, position: 2 })) });
    const result = await h.run(intent("place", { desk, orderRef: ref(desk) }), state);
    assert.deepEqual(result.ownershipHistory, { status: "complete" });
    assert.equal(state.ownershipComplete, true); assert.equal(state.deskPositions.length, 3);
    assert.equal(h.broker.placed.length, 2); assert.equal(state.placements[0].status, "submitted");
    assert.deepEqual(h.broker.connections, [700, 705]);
    assert.deepEqual(h.broker.executionRequests[0], { id: 880700, filter: { acctCode: ACCOUNT } });
    assert.equal(h.broker.live.size, 0);
  }
});

test("place and recon refuse missing, stale, wrong-account and uncovered recon execution snapshots", async (t) => {
  const now = Date.parse("2026-10-07T19:13:00Z");
  t.mock.timers.enable({ apis: ["Date"], now });
  const coverage = intradayCoverage();
  coverage.target.toExclusive = coverage.gaps[0].toExclusive = new Date(now - 30000).toISOString();
  for (const fault of ["missing", "incomplete", "stale", "wrong-account", "uncovered"]) for (const action of ["place", "recon"]) {
    const state = ledger();
    const h = harness({ coverage, executions: [fill({ clientId: 702 })], onSnapshot: (session) => {
      if (session.state.executionSnapshot.requestId !== 880700) return;
      if (fault === "missing") session.state.executionSnapshot = null;
      if (fault === "incomplete") session.state.executionSnapshot.completedAt = null;
      if (fault === "stale") session.state.executionSnapshot = { ...session.state.executionSnapshot, requestedAt: new Date(now - 120001).toISOString(), completedAt: new Date(now - 120001).toISOString() };
      if (fault === "wrong-account") session.state.executionSnapshot.account = "not-paper";
      if (fault === "uncovered") session.state.executionSnapshot.requestedAt = new Date(now - 30001).toISOString();
    } });
    const reason = fault === "uncovered" ? /gap is not covered by the same-session execution snapshot/ : /fresh same-session paper-account execution snapshot is missing or stale/;
    if (action === "place") {
      await assert.rejects(h.run(intent(), state), reason);
      assert.deepEqual(h.broker.connections, [700]); assert.deepEqual(state.placements, []);
    } else {
      const result = await h.run(intent("recon"), state);
      assert.equal(result.ownershipHistory.status, "unavailable"); assert.match(result.ownershipHistory.reason, reason);
      assert.equal(result.ownershipComplete, false); assert.deepEqual(result.deskPositions, []);
      assert.deepEqual(h.broker.connections, [700, 705]);
    }
    assert.equal(state.ownershipComplete, false); assert.deepEqual(state.deskPositions, []);
    assert.deepEqual(h.broker.placed, []); assert.deepEqual(h.broker.cancelled, []);
    assert.equal(h.broker.live.size, 0);
  }
});

test("recon accepts today's ownership gap only after the same session's execution request completed", async (t) => {
  const now = Date.parse("2026-10-07T19:13:00Z");
  t.mock.timers.enable({ apis: ["Date"], now });
  const coverage = intradayCoverage();
  coverage.target.toExclusive = coverage.gaps[0].toExclusive = new Date(now - 30000).toISOString();
  const bought = fill({ clientId: 702 }); const state = ledger();
  const h = harness({ coverage, executions: [bought], positions: [{ ...contract(), position: 2 }], onSnapshot: (session) => {
    assert.ok(session.state.executionSnapshot.completedAt);
    assert.ok(Date.parse(session.state.executionSnapshot.requestedAt) > Date.parse(coverage.gaps[0].toExclusive));
  } });
  const result = await h.run(intent("recon"), state);
  assert.deepEqual(result.ownershipHistory, { status: "complete" }); assert.equal(result.ownershipComplete, true);
  assert.equal(state.ownershipComplete, true); assert.equal(result.deskPositions[0].quantity, 2);
  assert.equal(state.executions[0].execution.execId, bought.execution.execId);
  assert.deepEqual(h.broker.placed, []); assert.equal(h.broker.live.size, 0);
});

test("previous-day ownership gaps remain unavailable for place and recon despite fresh execution snapshots", async (t) => {
  const now = Date.parse("2026-10-07T19:13:00Z");
  t.mock.timers.enable({ apis: ["Date"], now });
  const coverage = intradayCoverage();
  coverage.gaps[0] = { fromInclusive: new Date(now - 86400000 - 60000).toISOString(), toExclusive: new Date(now - 86400000).toISOString() };
  for (const action of ["place", "recon"]) {
    const state = ledger();
    const h = harness({ coverage, positions: ["MSFT", "NVDA", "META"].map((symbol, index) => ({ ...contract(symbol, index + 2), position: 1 })) });
    if (action === "place") await assert.rejects(h.run(intent(), state), /desk concurrent/);
    else {
      const result = await h.run(intent("recon"), state);
      assert.equal(result.ownershipHistory.status, "unavailable"); assert.match(result.ownershipHistory.reason, /outside today's New York/);
      assert.equal(result.ownershipComplete, false); assert.deepEqual(result.deskPositions, []);
    }
    assert.equal(state.ownershipComplete, false); assert.deepEqual(state.deskPositions, []);
    assert.deepEqual(h.broker.placed, []); assert.equal(h.broker.live.size, 0);
  }
});

test("uppercase intents stamp lowercase desk segments on new orders", async () => {
  const h = harness();
  const result = await h.run(intent("place", { desk: "J", orderRef: "J|261006|S1-AVGO" }));
  assert.equal(result.desk, "j");
  assert.equal(h.broker.placed.length, 2);
  assert.ok(h.broker.placed.every((row) => row.order.orderRef === "j|261006|S1-AVGO"));
});

test("recon attributes J|261006|S1-AVGO orders and positions to j", async () => {
  for (const clientId of [702, 705]) {
    const bought = { ...fill({ clientId, orderRef: "J|261006|S1-AVGO" }), contract: contract("AVGO") };
    const h = harness({ history: [bought], executions: [bought], positions: [{ ...contract("AVGO"), position: 2 }], orders: [order({ ...contract("AVGO"), clientId, orderRef: "J|261006|S1-AVGO" })] });
    const result = await h.run(intent("recon", { desk: "J" }));
    assert.equal(result.deskPositions[0].desk, "j");
    assert.equal(result.deskPositions[0].quantity, 2);
    assert.equal(result.positions[0].desks[0].desk, "j");
    assert.equal(result.openOrders[0].desk, "j");
    assert.equal(result.executions[0].desk, "j");
  }
});

test("recon attributes untagged client 706 fills to j2", async () => {
  const bought = fill({ clientId: 706, orderRef: undefined });
  const h = harness({ history: [bought], executions: [bought], positions: [{ ...contract(), position: 2 }] });
  const result = await h.run(intent("recon", { desk: "j2" }));
  assert.equal(result.status, "ok");
  assert.equal(result.desk, "j2");
  assert.equal(result.deskPositions.length, 1);
  assert.equal(result.deskPositions[0].desk, "j2");
  assert.equal(result.deskPositions[0].quantity, 2);
  assert.equal(result.executions[0].desk, "j2");
});

test("cancel matches only the desk segment case-insensitively", async () => {
  for (const brokerDesk of ["J", "j"]) for (const requestDesk of ["J", "j"]) {
    const h = harness({ orders: [order({ orderRef: `${brokerDesk}|261006|S1-AVGO` })] });
    const result = await h.run(intent("cancel", { desk: requestDesk, orderRef: `${requestDesk}|261006|S1-AVGO` }));
    assert.equal(result.status, "ok");
    assert.deepEqual(h.broker.cancelled, [30]);
    assert.deepEqual(h.broker.placed, []);
  }
  for (const orderRef of ["JOE|261006|S1-AVGO", "UNKNOWN|261006|S1-AVGO", "J|261006|s1-avgo", "J|261005|S1-AVGO"]) {
    const h = harness({ orders: [order({ orderRef })] });
    await assert.rejects(h.run(intent("cancel", { orderRef: "j|261006|S1-AVGO" })), /cancel target/);
    if (orderRef.startsWith("JOE|") || orderRef.startsWith("UNKNOWN|")) await assert.rejects(h.run(intent("cancel", { orderId: 30 })), /cancel target/);
    assert.deepEqual(h.broker.cancelled, []);
  }
});

test("flatten owns uppercase tags and leaves another desk's orders and shares alone", async () => {
  for (const clientId of [702, 705]) {
    const bought = fill({ clientId, orderRef: ref("J", "S1-AVGO") });
    const other = fill({ execId: "joe.1", orderId: 21, orderRef: ref("JOE", "S1-AVGO"), shares: 3 });
    const h = harness({ history: [bought, other], positions: [{ ...contract(), position: 5 }], orders: [order({ clientId, orderRef: bought.execution.orderRef, action: "SELL", orderType: "STP" }), order({ orderId: 31, orderRef: other.execution.orderRef, action: "SELL", orderType: "STP", quantity: 3 })] });
    const result = await h.run(intent("flatten", { desk: "J", orderRef: ref("J", "close-AVGO") }));
    assert.equal(result.status, "ok");
    assert.deepEqual(h.broker.cancelled, [30]);
    assert.equal(h.broker.placed.length, 1);
    assert.equal(h.broker.placed[0].order.totalQuantity, 2);
    assert.equal(h.broker.placed[0].order.orderRef, ref("j", "close-AVGO"));
    assert.deepEqual(h.broker.orders.map((row) => row.orderId), [31]);
  }
});

test("case variants of cached and fresh ownership references do not conflict", async () => {
  const bought = fill({ orderRef: ref("j", "S1-AVGO") });
  const state = ledger(); state.executions = [{ ...bought, execution: { ...bought.execution, orderRef: ref("J", "S1-AVGO") } }];
  const h = harness({ history: [bought], executions: [bought], positions: [{ ...contract(), position: 2 }] });
  assert.equal((await h.run(intent("flatten"), state)).status, "ok");
  assert.equal(h.broker.placed[0].order.totalQuantity, 2);
});

test("flatten attributes earlier-day executor fills from identifier-free history through the executor's own execId", async () => {
  // OPS-266 2026-10-07: pusher history rows carry no orderId/orderRef; yesterday's
  // executor KO buy and sell made every flatten fail with "attribution is missing".
  const previousDay = Date.now() - 86400000;
  const yesterday = `${newYorkDay(previousDay).replaceAll("-", "")} 15:00:00`;
  const strip = (row) => ({ ...row, execution: { ...row.execution, orderRef: "", orderId: 0 } });
  const koBuy = fill({ execId: "ko.buy.01", time: yesterday, orderRef: ref("j", "ko-test", previousDay), orderId: 40, shares: 1 });
  koBuy.contract = contract("KO", 3);
  const koSell = fill({ execId: "ko.sell.01", time: yesterday, orderRef: ref("j", "ko-flat", previousDay), orderId: 41, side: "SLD", shares: 1 });
  koSell.contract = contract("KO", 3);
  const bought = fill();
  const state = ledger(); state.executions = [koBuy, koSell];
  const h = harness({ history: [strip(koBuy), strip(koSell), bought], executions: [bought], positions: [{ ...contract(), position: 2 }] });
  const result = await h.run(intent("flatten"), state);
  assert.equal(result.status, "ok");
  assert.equal(h.broker.placed.length, 1);
  assert.equal(h.broker.placed[0].order.totalQuantity, 2);
  // The saved state keeps the attribution, so the next flatten still passes.
  assert.ok(state.executions.some((row) => row.execution.execId === "ko.buy.01" && row.execution.orderRef === ref("j", "ko-test", previousDay) && row.execution.orderId === 40));
  h.broker.positions = [{ ...contract(), position: 2 }];
  assert.equal((await h.run(intent("flatten", { intentId: "j-executor-test-2" }), state)).status, "ok");

  // Without the executor's own record the same history still fails closed.
  const bare = harness({ history: [strip(koBuy), strip(koSell), bought], executions: [bought], positions: [{ ...contract(), position: 2 }] });
  await assert.rejects(bare.run(intent("flatten"), ledger()), /ownership attribution is missing/);
  assert.deepEqual(bare.broker.placed, []);
});

test("flatten refuses unknown shared-client desk tags before any side effect", async () => {
  const unknown = fill({ orderRef: "UNKNOWN|261006|S1-AVGO" });
  const h = harness({ history: [unknown], positions: [{ ...contract(), position: 2 }], orders: [order({ orderRef: unknown.execution.orderRef })] });
  await assert.rejects(h.run(intent("flatten")), /ownership attribution/);
  assert.deepEqual(h.broker.cancelled, []);
  assert.deepEqual(h.broker.placed, []);
});

test("recon resolves lowercase uncertain references against uppercase broker evidence", async () => {
  for (const evidence of ["fill", "order"]) {
    const state = ledger(); const id = "j-case-uncertain";
    state.intents.set(id, { status: "uncertain", action: "place", claimedAt: new Date().toISOString(), orderRef: "j|261006|S1-AVGO", result: { status: "uncertain" } });
    state.placements.push({ intentId: id, orderRef: "j|261006|S1-AVGO", desk: "j", symbol: "AAPL", status: "uncertain", side: "BUY", quantity: 2, day: newYorkDay(), reservedAt: new Date().toISOString() });
    const bought = fill({ orderRef: "J|261006|S1-AVGO" });
    const h = harness(evidence === "fill" ? { executions: [bought], positions: [{ ...contract(), position: 2 }] } : { orders: [order({ orderRef: "J|261006|S1-AVGO" })] });
    await h.run(intent("recon"), state);
    assert.equal(state.intents.get(id).resolution.status, evidence === "fill" ? "filled" : "partial");
  }
});

test("place reconciles overlapping pusher and live fills without losing live ownership metadata", async () => {
  const time = new Date().toISOString();
  const history = {
    contract: { conId: 15124833, symbol: "NFLX", secType: "STK", currency: "USD", multiplier: 1 },
    execution: { execId: "nflx.01", time, clientId: 702, side: "SELL", shares: 14, price: 68.14 },
  };
  const live = {
    contract: { ...history.contract, exchange: "SMART" },
    execution: { ...history.execution, time: `${time.slice(0, 10).replaceAll("-", "")}-${time.slice(11, 19)}`, side: "SLD", shares: "14", acctNumber: ACCOUNT, orderId: 20, permId: 100, orderRef: ref() },
  };
  const h = harness({ history: [history], executions: [live], positions: [{ ...live.contract, position: -14 }] });
  const state = ledger();
  const result = await h.run(intent(), state);
  assert.equal(result.status, "ok");
  assert.equal(h.broker.placed.length, 2);
  assert.equal(state.executions.length, 1);
  assert.equal(state.executions[0].execution.orderRef, live.execution.orderRef);
  assert.equal(state.executions[0].execution.acctNumber, ACCOUNT);
  assert.equal(state.deskPositions.find((row) => row.symbol === "NFLX").quantity, -14);
  assert.equal(h.broker.live.size, 0);
});

test("missing, incomplete, invalid-gapped and stale history refuse legacy flatten/cancel before any mutation", async () => {
  for (const options of [ { missingHistory: true }, { coverage: { status: "partial", gaps: [] } }, { coverage: { status: "complete", gaps: [{}] } }, { coverage: { status: "complete", gaps: [], target: { fromInclusive: "2026-01-01T00:00:00Z", toExclusive: "2026-01-02T00:00:00Z" } } } ]) {
    for (const action of ["flatten", "cancel"]) {
      const h = harness({ ...options, orders: [order({ clientId: 702 })] });
      await assert.rejects(h.run(intent(action, action === "cancel" ? { orderId: 30 } : {})), /ownership|coverage/);
      assert.equal(h.broker.cancelled.length, 0); assert.equal(h.broker.placed.length, 0);
    }
  }
});

test("trailing-today history gap is covered by account-scoped executions and closes the corrected legacy quantity", async () => {
  const opening = fill({ execId: "legacy-buy.1", clientId: 702, shares: 5 });
  const corrected = fill({ ...opening.execution, execId: "legacy-buy.2", shares: 4 });
  const sold = fill({ execId: "legacy-sell.1", clientId: 702, side: "SLD", shares: 1 });
  const h = harness({ coverage: intradayCoverage(), history: [opening], executions: [corrected, sold], positions: [{ ...contract(), position: 3 }], orders: [order({ clientId: 702, action: "SELL", orderType: "STP" })] });
  const result = await h.run(intent("flatten"));
  assert.equal(result.status, "ok");
  assert.deepEqual(h.broker.cancelled, [30]);
  assert.equal(h.broker.placed[0].order.totalQuantity, 3);
  assert.equal(h.broker.placed[0].order.action, "SELL");
  assert.ok(h.broker.executionRequests.every((row) => row.filter.acctCode === ACCOUNT));
  assert.deepEqual(h.broker.connections, [700, 702, 700, 705]);
  assert.equal(h.broker.live.size, 0);
});

test("twenty-minute-old history uses fresh execution coverage for the trailing span", async (t) => {
  const now = Date.parse("2026-10-06T18:54:00Z");
  t.mock.timers.enable({ apis: ["Date"], now });
  for (const gapped of [false, true]) for (const clientId of [702, 705]) for (const action of ["flatten", "cancel"]) {
    const coverage = intradayCoverage();
    coverage.target.toExclusive = new Date(now - 20 * 60000).toISOString();
    coverage.gaps[0].toExclusive = coverage.target.toExclusive;
    if (!gapped) { coverage.status = "complete"; coverage.gaps = []; }
    const opening = fill({ clientId, time: "20261006 14:00:00" });
    const sold = fill({ clientId, execId: "trailing-sale.1", side: "SLD", shares: 1, time: "20261006 14:50:00", orderId: 21 });
    const h = harness({ coverage, history: [opening], executions: [sold], positions: [{ ...contract(), position: 1 }], orders: [order({ clientId })] });
    const result = await h.run(intent(action, action === "cancel" ? { orderId: 30 } : {}));
    assert.equal(result.status, "ok");
    assert.deepEqual(h.broker.cancelled, [30]);
    if (action === "flatten") {
      assert.equal(h.broker.placed.length, 1);
      assert.equal(h.broker.placed[0].order.totalQuantity, 1);
      assert.equal(h.broker.placed[0].order.action, "SELL");
    } else assert.deepEqual(h.broker.placed, []);
    assert.equal(h.broker.live.size, 0);
  }
});

test("lagging history still refuses invalid targets and missing or stale execution receipts before mutation", async (t) => {
  const now = Date.parse("2026-10-06T18:54:00Z");
  t.mock.timers.enable({ apis: ["Date"], now });
  for (const fault of ["yesterday", "future", "invalid", "missing-receipt", "stale-receipt"]) {
    const coverage = { status: "complete", gaps: [], target: { fromInclusive: new Date(now - 40 * 86400000).toISOString(), toExclusive: new Date(now - 20 * 60000).toISOString() } };
    if (fault === "yesterday") coverage.target.toExclusive = new Date(now - 86400000).toISOString();
    if (fault === "future") coverage.target.toExclusive = new Date(now + 1).toISOString();
    if (fault === "invalid") coverage.target.toExclusive = "invalid";
    for (const clientId of [702, 705]) for (const action of ["flatten", "cancel"]) {
      // Own unfilled cancellation deliberately needs no ownership history.
      if (clientId === 705 && action === "cancel") continue;
      const h = harness({ coverage, history: [fill({ clientId })], positions: [{ ...contract(), position: 2 }], orders: [order({ clientId })], onSnapshot: (session) => {
        if (fault === "missing-receipt") session.state.executionSnapshot = null;
        if (fault === "stale-receipt") session.state.executionSnapshot = { ...session.state.executionSnapshot, requestedAt: new Date(now - 120001).toISOString(), completedAt: new Date(now - 120001).toISOString() };
      } });
      await assert.rejects(h.run(intent(action, action === "cancel" ? { orderId: 30 } : {})), /ownership history target|snapshot.*missing or stale/);
      assert.deepEqual(h.broker.cancelled, []);
      assert.deepEqual(h.broker.placed, []);
      assert.equal(h.broker.live.size, 0);
    }
  }
});

test("a gap crossing New York midnight refuses legacy flatten/cancel with no broker mutation", async () => {
  const coverage = intradayCoverage();
  coverage.gaps[0].fromInclusive = new Date(Date.parse(coverage.gaps[0].fromInclusive) - 1).toISOString();
  for (const action of ["flatten", "cancel"]) {
    const h = harness({ coverage, history: [fill({ clientId: 702 })], positions: [{ ...contract(), position: 2 }], orders: [order({ clientId: 702 })] });
    await assert.rejects(h.run(intent(action, action === "cancel" ? { orderId: 30 } : {})), /outside today's New York/);
    assert.deepEqual(h.broker.cancelled, []); assert.deepEqual(h.broker.placed, []);
  }
});

test("missing, stale, wrong-account, uncovered and errored execution snapshots cannot bridge today's gap", async () => {
  for (const options of [
    { onSnapshot: (session) => { session.state.executionSnapshot = null; } },
    { onSnapshot: (session) => { session.state.executionSnapshot = { ...session.state.executionSnapshot, requestedAt: new Date(Date.now() - 180000).toISOString(), completedAt: new Date(Date.now() - 180000).toISOString() }; } },
    { onSnapshot: (session) => { session.state.executionSnapshot.account = "not-paper"; } },
    { onSnapshot: (session) => { session.state.executionSnapshot.requestedAt = new Date(Date.now() - 60000).toISOString(); } },
    { executionError: true },
    { wrongExecutionRequest: true },
  ]) {
    const h = harness({ ...options, coverage: intradayCoverage(), history: [fill({ clientId: 702 })], positions: [{ ...contract(), position: 2 }], orders: [order({ clientId: 702 })] });
    await assert.rejects(h.run(intent("flatten")), /snapshot|reconciliation/);
    assert.deepEqual(h.broker.cancelled, []); assert.deepEqual(h.broker.placed, []);
    assert.equal(h.broker.live.size, 0);
  }
});

test("cached BUY 3 and a missed prior-day stop cannot flatten another owner's account position", async () => {
  const previousDay = Date.now() - 86400000;
  const date = newYorkDay(previousDay).replaceAll("-", "");
  const orderRef = ref("j", "test", previousDay);
  const opening = fill({ execId: "executor-opening.1", shares: 3, orderRef, time: `${date} 15:00:00` });
  const stop = fill({ execId: "executor-stop.1", shares: 3, side: "SLD", orderId: 21, orderRef, time: `${date} 16:00:00` });
  for (const missingHistory of [false, true]) {
    const state = ledger(); state.executions = [opening];
    const h = harness({ missingHistory, history: [opening, stop], positions: [{ ...contract(), position: 3 }] });
    if (missingHistory) await assert.rejects(h.run(intent("flatten"), state), /ownership.*unavailable/);
    else {
      const result = await h.run(intent("flatten"), state);
      assert.equal(result.status, "ok"); assert.equal(result.ownershipComplete, true);
      assert.deepEqual(result.flattened, []); assert.deepEqual(state.deskPositions, []);
    }
    assert.deepEqual(h.broker.placed, []); assert.deepEqual(h.broker.cancelled, []);
  }
});

test("cached execution quantities never independently establish executor ownership", async () => {
  const state = ledger(); state.executions = [fill({ shares: 3 })];
  const h = harness({ positions: [{ ...contract(), position: 3 }] });
  assert.deepEqual((await h.run(intent("flatten"), state)).flattened, []);
  assert.deepEqual(h.broker.placed, []);
});

test("today's executor fill comes only from fresh reqExecutions and bridges today's history gap", async () => {
  const h = harness({ coverage: intradayCoverage(), executions: [fill({ shares: 3 })], positions: [{ ...contract(), position: 3 }] });
  const result = await h.run(intent("flatten"));
  assert.equal(result.ownershipComplete, true);
  assert.equal(h.broker.placed[0].order.totalQuantity, 3); assert.equal(h.broker.placed[0].order.action, "SELL");
  assert.ok(h.broker.executionRequests.every((row) => row.filter.acctCode === ACCOUNT));
});

test("cached orderRef and placement linkage attribute evidence without supplying cached quantities", async () => {
  for (const linkage of ["execution", "placement"]) {
    const state = ledger();
    if (linkage === "execution") state.executions = [fill({ shares: 100 })];
    else state.placements = [{ desk: "j", symbol: "AAPL", reservedAt: new Date().toISOString(), orderRef: ref(), orderIds: [20, 21] }];
    const h = harness({ executions: [fill({ orderRef: "", shares: 2 })], positions: [{ ...contract(), position: 2 }] });
    await h.run(intent("flatten"), state);
    assert.equal(h.broker.placed[0].order.totalQuantity, 2);
  }
  const unknown = harness({ executions: [fill({ orderRef: "" })], positions: [{ ...contract(), position: 2 }] });
  await assert.rejects(unknown.run(intent("flatten")), /ownership attribution/);
  assert.deepEqual(unknown.broker.placed, []);
});

test("executor history gaps, stale history and bad execution snapshots refuse before protective cancellation", async () => {
  const coverage = intradayCoverage();
  coverage.gaps[0].fromInclusive = new Date(Date.parse(coverage.gaps[0].fromInclusive) - 1).toISOString();
  for (const options of [
    { missingHistory: true },
    { coverage: { status: "partial", gaps: [] } },
    { coverage },
    { coverage: { status: "complete", gaps: [], target: { fromInclusive: "2026-01-01T00:00:00Z", toExclusive: "2026-01-02T00:00:00Z" } } },
    { onSnapshot: (session) => { session.state.executionSnapshot = null; } },
    { coverage: intradayCoverage(), onSnapshot: (session) => { session.state.executionSnapshot.requestedAt = new Date(Date.now() - 60000).toISOString(); } },
    { executionError: true },
    { wrongExecutionRequest: true },
  ]) {
    const state = ledger(); state.executions = [fill()];
    const h = harness({ ...options, history: [fill()], positions: [{ ...contract(), position: 2 }], orders: [order({ action: "SELL", orderType: "STP" })] });
    await assert.rejects(h.run(intent("flatten"), state), /ownership|snapshot|reconciliation/);
    assert.deepEqual(h.broker.cancelled, []); assert.deepEqual(h.broker.placed, []);
    assert.equal(h.broker.live.size, 0);
  }
});

test("a complete target starting after the desk's first-order day refuses flatten", async () => {
  for (const origin of ["placement", "retained-date", "cached-fill", "pruned-legacy-ledger"]) {
    const first = new Date(Date.now() - 3 * 86400000).toISOString();
    const state = ledger();
    if (origin === "placement") state.placements = [{ desk: "j", symbol: "AAPL", reservedAt: first, orderRef: ref() }];
    if (origin === "retained-date") state.firstOrders = new Map([["j", new Map([["AAPL", newYorkDay(Date.parse(first))]])]]);
    if (origin === "cached-fill") state.executions = [fill({ time: first })];
    if (origin === "pruned-legacy-ledger") {
      state.initializedAt = first;
      state.placements = [{ desk: "j", symbol: "AAPL", reservedAt: new Date().toISOString(), orderRef: ref() }];
    }
    const h = harness({ coverage: { status: "complete", gaps: [], target: { fromInclusive: new Date(Date.now() - 86400000).toISOString(), toExclusive: new Date().toISOString() } }, executions: [fill()], positions: [{ ...contract(), position: 2 }], orders: [order({ action: "SELL", orderType: "STP" })] });
    await assert.rejects(h.run(intent("flatten"), state), /every day since first order.*j\//);
    assert.deepEqual(h.broker.placed, []); assert.deepEqual(h.broker.cancelled, []);
  }
});

test("unknown legacy shares refuse a mixed flatten before cancelling an executor protective order", async () => {
  const state = ledger(); state.executions = [fill({ shares: 1 }), fill({ execId: "legacy-opening.1", clientId: 702, shares: 1 })];
  const h = harness({ missingHistory: true, positions: [{ ...contract(), position: 2 }], orders: [order({ action: "SELL", orderType: "STP" })] });
  await assert.rejects(h.run(intent("flatten"), state), /ownership/);
  assert.deepEqual(h.broker.cancelled, []); assert.deepEqual(h.broker.placed, []);
});

test("own working unfilled cancel ignores partial/missing history and does not request executions", async () => {
  for (const options of [{ missingHistory: true }, { coverage: { status: "partial", gaps: [{}] } }]) {
    const h = harness({ ...options, executionError: true, orders: [order()], positions: [{ ...contract(), position: 100 }] });
    const result = await executeIntent(intent("cancel", { orderId: 30 }), ledger(), {}, { ...h.runtime, readHistory: () => assert.fail("own cancellation must not read pusher history") });
    assert.equal(result.status, "ok"); assert.deepEqual(h.broker.cancelled, [30]);
    assert.deepEqual(h.broker.placed, []); assert.deepEqual(h.broker.executionRequests, []);
  }
});

test("own cancellation rechecks zero-filled status after contract lookup", async () => {
  const h = harness({ missingHistory: true, orders: [order()], onContractDetails: (api) => {
    if (api.clientId === 705) api.emit(events.orderStatus, 30, "Submitted", 1, 1, 100);
  } });
  await assert.rejects(h.run(intent("cancel", { orderId: 30 })), /unfilled/);
  assert.deepEqual(h.broker.cancelled, []); assert.deepEqual(h.broker.placed, []);
});

test("legacy unfilled cancel accepts a trailing-today gap only with fresh execution coverage", async () => {
  const h = harness({ coverage: intradayCoverage(), orders: [order({ clientId: 702 })] });
  const result = await h.run(intent("cancel", { orderId: 30 }));
  assert.equal(result.status, "ok"); assert.deepEqual(h.broker.cancelled, [30]);
  assert.deepEqual(h.broker.placed, []);
});

test("KEEP stays excluded from unified legacy and executor ownership evidence", async () => {
  for (const symbol of ["TSLA", "SXR8"]) for (const own of [false, true]) {
    const kept = fill({ clientId: own ? 705 : 702 }); kept.contract = contract(symbol, 3);
    const state = ledger(); if (own) state.executions = [kept];
    const h = harness({ coverage: intradayCoverage(), history: [kept], executions: [kept], positions: [{ ...kept.contract, position: 2 }], orders: [order({ symbol, conId: 3, clientId: own ? 705 : 702 })] });
    assert.deepEqual((await h.run(intent("flatten"), state)).flattened, []);
    await assert.rejects(h.run(intent("cancel", { orderId: 30 }), state), /KEEP/);
    assert.deepEqual(h.broker.cancelled, []); assert.deepEqual(h.broker.placed, []);
  }
});

test("KEEP and contract mismatches fail at the real place/cancel/flatten boundary", async () => {
  for (const symbol of ["TSLA", "SXR8", "", "MSFT"]) {
    const h = harness({ resolve: () => contract(symbol, 1) });
    await assert.rejects(h.run(intent()), /KEEP|unknown|mismatch/);
    assert.equal(h.broker.placed.length, 0);
  }
  for (const symbol of ["TSLA", "SXR8", ""]) {
    const h = harness({ orders: [order({ symbol })] });
    await assert.rejects(h.run(intent("cancel", { orderId: 30 })), /KEEP|unknown/);
    assert.equal(h.broker.cancelled.length, 0);
  }
  const kept = fill(); kept.contract = contract("TSLA", 3);
  const h = harness({ history: [kept], positions: [{ ...kept.contract, position: 2 }], orders: [order({ symbol: "TSLA", conId: 3 })] });
  const result = await h.run(intent("flatten"));
  assert.deepEqual(result.flattened, []); assert.deepEqual(result.cancelled, []);
});

test("broker errors, absent acknowledgement and partial bracket persist uncertain", async () => {
  for (const options of [{ errorOnPlace: true }, { noAck: true }, { missingStopAck: true }, { partial: true }, { badQuantity: true }]) {
    const h = harness(options); const state = ledger();
    await assert.rejects(h.run(intent(), state), { code: "uncertain" });
    assert.equal(state.placements[0].status, "uncertain"); assert.ok(h.broker.placed.length > 0);
  }
});

test("HALT and expiry races refuse before the first leg and mark a sent first leg uncertain", async () => {
  for (const race of ["halt", "expiry"]) {
    let active = false; let epoch = Date.now();
    const h = harness({ onFx: () => { active = true; epoch += 600000; } });
    await assert.rejects(h.run(intent(), ledger(), { getHalt: () => ({ active: race === "halt" && active }), now: () => epoch }), /HALT|expired/);
    assert.equal(h.broker.placed.length, 0);
    active = false; epoch = Date.now();
    const second = harness({ afterPlace: () => { active = true; epoch += 600000; } });
    const state = ledger();
    await assert.rejects(second.run(intent(), state, { getHalt: () => ({ active: race === "halt" && active }), now: () => epoch }), { code: "uncertain" });
    assert.equal(second.broker.placed.length, 1); assert.equal(state.placements[0].status, "uncertain");
  }
});

test("flatten uses corrected ownership, cancels then reconnects recon, and broker errors become uncertain", async () => {
  const first = fill({ execId: "buy.1", clientId: 702, shares: 10 }); const corrected = fill({ execId: "buy.2", clientId: 702, shares: 2 });
  const h = harness({ history: [first, corrected], positions: [{ ...contract(), position: 2 }], orders: [order({ action: "SELL", orderType: "STP" })] });
  const result = await h.run(intent("flatten"));
  assert.equal(result.status, "ok"); assert.deepEqual(h.broker.cancelled, [30]); assert.equal(h.broker.placed[0].order.totalQuantity, 2);
  assert.deepEqual(h.broker.connections, [700, 705, 700, 705]); assert.equal(h.broker.live.size, 0);
  const bad = harness({ history: [corrected], positions: [{ ...contract(), position: 2 }], errorOnPlace: true });
  await assert.rejects(bad.run(intent("flatten")), { code: "uncertain" });
});

test("opposite-sign ownership reconciliation never cancels a protective order", async () => {
  const h = harness({ history: [fill({ clientId: 702 })], positions: [{ ...contract(), position: -1 }], orders: [order()] });
  await assert.rejects(h.run(intent("flatten")), /does not reconcile|exceeds broker/);
  assert.deepEqual(h.broker.cancelled, []); assert.deepEqual(h.broker.placed, []);
});

test("closing size is capped at the matching live conId and cannot reverse the account position", async () => {
  for (const side of ["BOT", "SLD"]) {
    const h = harness({ history: [fill({ shares: 5, side })], positions: [{ ...contract(), position: side === "BOT" ? 3 : -3 }, { ...contract("MSFT", 2), position: 100 }] });
    await h.run(intent("flatten"));
    assert.equal(h.broker.placed.length, 1); assert.equal(h.broker.placed[0].contract.conId, 1);
    assert.equal(h.broker.placed[0].order.totalQuantity, 3);
    assert.equal(h.broker.placed[0].order.action, side === "BOT" ? "SELL" : "BUY");
  }
});

test("cancel is desk-owned, working, unfilled and allowed during HALT", async () => {
  const h = harness({ orders: [order()] });
  const result = await h.run(intent("cancel", { orderRef: ref() }), ledger(), { getHalt: () => ({ active: true }) });
  assert.equal(result.status, "ok"); assert.deepEqual(h.broker.cancelled, [30]); assert.deepEqual(h.broker.placed, []);
  for (const options of [{ orders: [order({ orderRef: ref("joe") })] }, { orders: [order({ status: "Filled" })] }, { orders: [order({ filled: 1 })], executions: [fill({ orderId: 30 })], positions: [{ ...contract(), position: 2 }] }]) {
    const denied = harness(options);
    await assert.rejects(denied.run(intent("cancel", { orderId: 30 })), /working|unfilled/);
    assert.deepEqual(denied.broker.cancelled, []);
  }
  const error = harness({ orders: [order()], errorOnCancel: true });
  await assert.rejects(error.run(intent("cancel", { orderId: 30 })), { code: "uncertain" });
});

test("cancel acknowledges working PreSubmitted, Submitted and PendingSubmit via status or IB 202", async (t) => {
  for (const status of ["PreSubmitted", "Submitted", "PendingSubmit"]) for (const ack of ["Cancelled", "ApiCancelled", "202"]) await t.test(`${status}: ${ack}`, async () => {
    const h = harness({ orders: [order({ status })], missingHistory: true, ...(ack === "202" ? { cancel202: true, noCancelAck: true } : { cancelStatus: ack }) });
    const result = await h.run(intent("cancel", { orderRef: ref() }));
    assert.equal(result.status, "ok"); assert.deepEqual(h.broker.cancelled, [30]);
    assert.deepEqual(h.broker.executionRequests, []);
    assert.equal(h.broker.live.size, 0);
  });
});

test("cancel without explicit acknowledgement proves absence using completed open orders and executions", async () => {
  const h = harness({ orders: [order()], noCancelAck: true, missingHistory: true });
  assert.equal((await h.run(intent("cancel", { orderId: 30 }))).status, "ok");
  assert.deepEqual(h.broker.cancelled, [30]);
  assert.equal(h.broker.executionRequests.length, 1);
  assert.equal(h.broker.executionRequests[0].filter.acctCode, ACCOUNT);
});

test("cancel by orderRef confirms a child auto-cancelled with its parent despite IB 161 or 10147", async (t) => {
  for (const code of [161, 10147]) for (const ack of ["absence", "status", "202"]) await t.test(`${code}: ${ack}`, async () => {
    const h = harness({ orders: [order(), order({ orderId: 31, parentId: 30, action: "SELL", orderType: "STP" })], autoCancelChildren: true, autoCancelChildAck: ack === "status", cancel202: ack === "202" });
    // Only the second request fails: IB already removed the child with its parent.
    if (code === 10147) h.broker.afterCancel = () => { h.broker.cancelErrorCode = 10147; };
    assert.equal((await h.run(intent("cancel", { orderRef: ref() }))).status, "ok");
    assert.deepEqual(h.broker.cancelled, [30, 31]); assert.deepEqual(h.broker.orders, []);
    assert.equal(h.broker.executionRequests.length, ack === "absence" ? 1 : 0);
    assert.equal(h.broker.live.size, 0);
  });
});

test("cancel keeps unconfirmed and unrelated IB 161 or 10147 uncertain", async (t) => {
  for (const code of [161, 10147]) for (const [name, options] of [
    ["still working", { noCancelAck: true, keepCancelledOrder: true }],
    ["unrelated request ID", { cancelErrorOrderId: 99 }],
    ["fill", { cancelFilled: 1 }],
    ["incomplete snapshot", { noCancelAck: true, noCancelExecutionsEnd: true }],
  ]) await t.test(`${code}: ${name}`, async (t) => {
    t.mock.timers.enable({ apis: ["Date"], now: Date.now() });
    const h = harness({ orders: [order()], cancelErrorCode: code, wait: async (ms) => { t.mock.timers.tick(ms); }, ...options });
    await assert.rejects(h.run(intent("cancel", { orderId: 30 })), { code: "uncertain" });
    assert.deepEqual(h.broker.cancelled, [30]); assert.equal(h.broker.live.size, 0);
  });
});

test("a cancellation confirmation arriving during the fallback replay resolves the outcome", async (t) => {
  for (const ack of ["202", "Cancelled"]) await t.test(ack, async () => {
    const h = harness({ orders: [order()], noCancelAck: true, noCancelExecutionsEnd: true, onExecutionRequest: (api) => {
      if (ack === "202") api.emit(events.error, new Error("Order Canceled"), 202, 30);
      else api.emit(events.orderStatus, 30, "Cancelled", 0, 0, 0, 0, 0, 0, 705);
    } });
    assert.equal((await h.run(intent("cancel", { orderId: 30 }))).status, "ok");
    assert.deepEqual(h.broker.cancelled, [30]); assert.equal(h.broker.live.size, 0);
  });
});

test("cancel cannot use another order's 202 or absence with a fill, working order or incomplete replay", async (t) => {
  for (const [name, options] of [
    ["still working", { keepCancelledOrder: true }],
    ["wrong 202", { cancel202: true, cancel202OrderId: 99, keepCancelledOrder: true }],
    ["execution proves fill", { afterCancel: (broker) => { broker.executions.push(fill({ orderId: 30 })); } }],
    ["202 with filled status", { cancel202: true, cancelFilled: 1, noCancelAck: false }],
    ["open orders incomplete", { noCancelOrdersEnd: true }],
    ["executions incomplete", { noCancelExecutionsEnd: true }],
    ["execution error", { executionError: true }],
  ]) await t.test(name, async (t) => {
    t.mock.timers.enable({ apis: ["Date"], now: Date.now() });
    const h = harness({ orders: [order()], noCancelAck: true, wait: async (ms) => { t.mock.timers.tick(ms); }, ...options });
    if (options.afterCancel) h.broker.afterCancel = () => options.afterCancel(h.broker);
    await assert.rejects(h.run(intent("cancel", { orderId: 30 })), { code: "uncertain" });
    assert.deepEqual(h.broker.cancelled, [30]); assert.equal(h.broker.live.size, 0);
  });
});

test("expiry is rechecked before cancellation", async () => {
  const h = harness({ orders: [order()] });
  await assert.rejects(h.run(intent("cancel", { orderId: 30 }), ledger(), { now: () => Date.now() + 600000 }), /expired/);
  assert.deepEqual(h.broker.cancelled, []);
});

test("recon resolves uncertain thesis to absent, partial or filled by tag and placing client", async () => {
  for (const resolution of ["absent", "partial", "filled"]) {
    const state = ledger(); const id = "old-uncertain";
    state.intents.set(id, { status: "uncertain", action: "place", claimedAt: new Date().toISOString(), orderRef: ref(), result: { status: "uncertain", intentId: id } });
    state.placements.push({ intentId: id, orderRef: ref(), desk: "j", symbol: "AAPL", status: "uncertain", side: "BUY", quantity: 2, day: newYorkDay(), reservedAt: new Date().toISOString() });
    const executions = resolution === "absent" ? [] : [fill({ shares: resolution === "filled" ? 2 : 1 })];
    const h = harness({ executions, positions: executions.length ? [{ ...contract(), position: executions[0].execution.shares }] : [] });
    const result = await h.run(intent("recon"), state);
    assert.equal(result.status, "ok"); assert.equal(state.intents.get(id).resolution.status, resolution);
    assert.equal(state.intents.get(id).status, resolution === "partial" ? "uncertain" : "done");
  }
});

test("executeIntent enforces per-desk daily and concurrent brakes", async () => {
  const h = harness(); const state = ledger();
  state.placements = [1, 2].map(() => ({ desk: "j", day: newYorkDay(), riskEur: 1, status: "submitted", reservedAt: new Date().toISOString() }));
  await assert.rejects(h.run(intent(), state), /daily new-order/);
  assert.equal(h.broker.placed.length, 0);
  const crowded = ["MSFT", "NVDA", "META"].map((symbol, index) => ({ contract: contract(symbol, index + 2), execution: { ...fill().execution, execId: `crowd${index}.1`, shares: 1 } }));
  const other = harness({ history: crowded, positions: crowded.map((row) => ({ ...row.contract, position: 1 })) });
  await assert.rejects(other.run(intent()), /desk concurrent/);
  assert.equal(other.broker.placed.length, 0);
});

// Explicitly exercise the exported flatten entry point with the same fake IB
// transport; no stub replaces executeIntent, flattenOwned or order submission.
test("flattenOwned independently refuses unknown ownership when history is missing", async () => {
  const h = harness({ missingHistory: true });
  await assert.rejects(flattenOwned({ desk: "j", clientId: 705, reconClientId: 700, ownershipClientIds: [702], stateExecutions: [], ownershipLedgerFile: h.config.ownershipLedger, intent: intent("flatten"), connect: h.connect, readHistory: h.readHistory }), /ownership/);
  assert.deepEqual(h.broker.connections, [700]);
  assert.equal(h.broker.live.size, 0);
});


test("cancel resolves the contract and refuses missing unfilled evidence", async () => {
  for (const options of [{ resolve: () => contract("AAPL", 99) }, { resolve: () => contract("TSLA", 1) }, { noOrderEvidence: true }]) {
    const h = harness({ orders: [order()], ...options });
    await assert.rejects(h.run(intent("cancel", { orderId: 30 })), /mismatch|KEEP|evidence/);
    assert.deepEqual(h.broker.cancelled, []);
  }
});

test("aggregate ownership cannot flatten another desk's shares", async () => {
  const other = fill({ execId: "other.1", clientId: 701, orderRef: ref("joe"), shares: 2 });
  const h = harness({ history: [fill({ clientId: 702 }), other], positions: [{ ...contract(), position: 3 }], orders: [order()] });
  await assert.rejects(h.run(intent("flatten")), /aggregate desk ownership/);
  assert.deepEqual(h.broker.cancelled, []); assert.deepEqual(h.broker.placed, []);
});

test("symbol flatten closes KO despite unrelated mismatches and leaves unrelated orders and positions alone", async () => {
  for (const unrelatedDesk of ["j", "joe"]) {
    const ko = { ...fill({ execId: "ko.1", shares: 1, orderRef: ref("joe") }), contract: contract("KO", 2) };
    const unrelated = fill({ orderRef: ref(unrelatedDesk), shares: 7 });
    const h = harness({ history: [ko, unrelated], positions: [{ ...ko.contract, position: 1 }], orders: [order({ ...ko.contract, orderRef: ref("joe"), action: "SELL", orderType: "STP" }), order({ orderId: 31, orderRef: ref("joe") })] });
    const result = await h.run(intent("flatten", { desk: "joe", symbol: "KO" }));
    assert.equal(result.status, "ok");
    assert.deepEqual(h.broker.cancelled, [30]);
    assert.equal(h.broker.placed.length, 1);
    assert.equal(h.broker.placed[0].contract.symbol, "KO");
    assert.equal(h.broker.placed[0].order.totalQuantity, 1);
    assert.equal(h.broker.placed[0].order.action, "SELL");
    assert.deepEqual(h.broker.orders.map((row) => row.orderId), [31]);
    assert.equal(h.broker.live.size, 0);
  }
});

test("symbol flatten refuses missing or opposite-sign target broker positions before any mutation", async () => {
  const ko = { ...fill({ execId: "ko.1", shares: 1, orderRef: ref("joe") }), contract: contract("KO", 2) };
  for (const position of [undefined, 0, -1]) {
    const h = harness({ history: [ko], positions: position === undefined ? [] : [{ ...ko.contract, position }], orders: [order({ ...ko.contract, orderRef: ref("joe") })] });
    await assert.rejects(h.run(intent("flatten", { desk: "joe", symbol: "KO" })), /desk ownership does not reconcile with broker position for KO/);
    assert.deepEqual(h.broker.cancelled, []); assert.deepEqual(h.broker.placed, []);
  }
});

test("flatten-all retains strict reconciliation of unrelated mismatches", async () => {
  const ko = { ...fill({ execId: "ko.1", shares: 1, orderRef: ref("joe") }), contract: contract("KO", 2) };
  const h = harness({ history: [ko, fill()], positions: [{ ...ko.contract, position: 1 }], orders: [order({ ...ko.contract, orderRef: ref("joe") })] });
  await assert.rejects(h.run(intent("flatten", { desk: "joe" })), /desk ownership does not reconcile with broker position for AAPL/);
  assert.deepEqual(h.broker.cancelled, []); assert.deepEqual(h.broker.placed, []);
});

test("symbol flatten retains aggregate ownership checks across all desks on the target conId", async () => {
  const own = { ...fill({ execId: "ko-own.1", shares: 1, orderRef: ref("joe") }), contract: contract("KO", 2) };
  const other = { ...fill({ execId: "ko-other.1", clientId: 702, shares: 1 }), contract: own.contract };
  const h = harness({ history: [own, other], positions: [{ ...own.contract, position: 1 }], orders: [order({ ...own.contract, orderRef: ref("joe") })] });
  await assert.rejects(h.run(intent("flatten", { desk: "joe", symbol: "KO" })), /aggregate desk ownership exceeds broker position for KO/);
  assert.deepEqual(h.broker.cancelled, []); assert.deepEqual(h.broker.placed, []);
});

test("symbol legacy cancel scopes reconciliation and refuses a mismatched symbol selector", async () => {
  const ko = { ...fill({ execId: "ko.1", clientId: 701, shares: 1, orderRef: ref("joe") }), contract: contract("KO", 2) };
  const h = harness({ history: [ko, fill()], positions: [{ ...ko.contract, position: 1 }], orders: [order({ ...ko.contract, clientId: 701, orderRef: ref("joe") })] });
  await assert.rejects(h.run(intent("cancel", { desk: "joe", orderId: 30, symbol: "AAPL" })), /cancel target/);
  assert.deepEqual(h.broker.cancelled, []);
  assert.equal((await h.run(intent("cancel", { desk: "joe", orderId: 30, symbol: "KO" }))).status, "ok");
  assert.deepEqual(h.broker.cancelled, [30]); assert.deepEqual(h.broker.placed, []);
});

test("CLI carries optional flatten/cancel symbol into the validated intent", async () => {
  for (const action of ["flatten", "cancel"]) {
    let received;
    const code = await runClient([action, "--desk", "joe", "--intent-id", "joe-scope-test", "--symbol", "ko", ...(action === "cancel" ? ["--order-id", "30"] : [])], {
      fetch: async (_url, request) => { received = parseIntent(JSON.parse(request.body)); return { ok: true, text: async () => JSON.stringify({ status: "ok" }) }; },
      write: () => {},
    });
    assert.equal(code, 0); assert.equal(received.symbol, "KO");
  }
});

test("flatten partial/missing fills and expiry after cancellation stay uncertain", async () => {
  for (const options of [{ noAck: true }, { partial: true }, { badQuantity: true }]) {
    const h = harness({ history: [fill({ clientId: 702 })], positions: [{ ...contract(), position: 2 }], ...options });
    await assert.rejects(h.run(intent("flatten")), { code: "uncertain" });
  }
  let expired = false;
  const h = harness({ history: [fill({ clientId: 702 })], positions: [{ ...contract(), position: 2 }], orders: [order({ action: "SELL", orderType: "STP" })], afterCancel: () => { expired = true; } });
  await assert.rejects(h.run(intent("flatten"), ledger(), { now: () => Date.now() + (expired ? 600000 : 0) }), { code: "uncertain" });
  assert.deepEqual(h.broker.cancelled, [30]); assert.deepEqual(h.broker.placed, []);
});

test("recon includes tagged positions, order legs, FX time, executions and desk PnL", async () => {
  const bought = fill(); const sold = fill({ execId: "sold.1", side: "SLD", shares: 1, price: 102 });
  const h = harness({ history: [bought, sold], executions: [bought, sold], commissions: [ { execId: "fill.1", commission: 0.1, currency: "USD" }, { execId: "sold.1", commission: 0.1, currency: "USD" } ], positions: [{ ...contract(), position: 1 }, { ...contract("TSLA", 3), position: 1 }], orders: [order(), order({ orderId: 31, parentId: 30, orderType: "STP", action: "SELL" })] });
  const result = await h.run(intent("recon"));
  assert.ok(result.fxObservedAt); assert.equal(result.positions[1].keep, true);
  assert.deepEqual(result.deskPositions[0].orderRefs, [ref()]);
  assert.equal(result.openOrders[0].legs.length, 1); assert.equal(result.executions[0].desk, "j");
  assert.equal(result.pnlPerDesk.j.realized, 1.8); assert.equal(result.pnlPerDesk.j.unrealized, 1);
});

test("HTTP stores the real executor's uncertain result and GET exposes recon resolution", async () => {
  const h = harness({ noAck: true });
  const stateDir = mkdtempSync(path.join(tmpdir(), "ops266-real-http-"));
  const app = createServer({ testMode: true, listenHost: "127.0.0.1", listenPort: 0, gatewayPort: 4002, gatewayHost: "100.64.0.6", allowlist: ["127.0.0.1"], stateDir, execute: (value, state, context) => executeIntent(value, state, context, h.runtime) });
  async function request(method, url, body) {
    const req = Readable.from(body ? [Buffer.from(JSON.stringify(body))] : []);
    req.method = method; req.url = url; req.socket = { remoteAddress: "127.0.0.1" };
    let status; let result;
    await app.handle(req, { writeHead(code) { status = code; }, end(value) { result = JSON.parse(value); } });
    return { status, result };
  }
  const value = intent();
  assert.equal((await request("POST", "/v1/intents", value)).result.status, "uncertain");
  const stored = app.ledger.load();
  assert.equal(stored.intents.get(value.intentId).status, "uncertain"); assert.equal(stored.placements[0].status, "uncertain");
  h.broker.noAck = false;
  assert.equal((await request("POST", "/v1/intents", intent("recon", { intentId: "j-real-http-recon" }))).status, 200);
  const lookup = await request("GET", `/v1/intents/${value.intentId}`);
  assert.equal(lookup.status, 200); assert.equal(lookup.result.resolution.status, "absent");
});

test("a later contract mismatch refuses the entire cancellation batch", async () => {
  const h = harness({ orders: [order(), order({ orderId: 31, conId: 999 })] });
  await assert.rejects(h.run(intent("cancel", { orderRef: ref() })), /mismatch/);
  assert.deepEqual(h.broker.cancelled, []);
});

test("placement re-evaluates account brakes on the placing client's fresh snapshot", async () => {
  const h = harness();
  h.broker.onFx = () => { h.broker.positions = [{ ...contract(), position: 1 }]; };
  await assert.rejects(h.run(intent()), /piling/);
  assert.deepEqual(h.broker.placed, []);
});

test("first-day paper place uses broker reconciliation and conservative concurrency when history is incomplete", async () => {
  const h = harness({ missingHistory: true });
  const result = await h.run(intent());
  assert.equal(result.status, "ok"); assert.equal(result.ownershipHistory.status, "unavailable");
  assert.equal(h.broker.placed.length, 2);
  const crowded = harness({ coverage: { status: "known", gaps: [{}] }, positions: ["MSFT", "NVDA", "META"].map((symbol, index) => ({ ...contract(symbol, index + 2), position: 1 })) });
  await assert.rejects(crowded.run(intent()), /desk concurrent/);
  assert.deepEqual(crowded.broker.placed, []);
});

test("recon resolves uncertain cancellation and flatten plans to filled, partial or absent", async () => {
  for (const action of ["cancel", "flatten"]) for (const resolution of ["filled", "partial", "absent"]) {
    const state = ledger();
    const refs = ref("j", "uncertain-plan");
    const quantity = resolution === "filled" ? 2 : resolution === "partial" ? 1 : 0;
    const executions = quantity ? [fill({ execId: "outcome.1", orderRef: refs, side: action === "flatten" ? "SLD" : "BOT", shares: quantity, orderId: 30 })] : [];
    state.intents.set("uncertain-plan", { status: "uncertain", action, claimedAt: new Date().toISOString(), orderRef: refs, result: { status: "uncertain" }, brokerPlan: { clientId: 705, orderRef: refs, closing: action === "flatten" ? [{ conId: 1, quantity: 2, side: "SELL" }] : [], cancellationTargets: action === "cancel" ? [{ clientId: 705, orderId: 30, quantity: 2 }] : [] } });
    const positions = quantity ? [{ ...contract(), position: action === "flatten" ? 2 - quantity : quantity }].filter((row) => row.position) : [];
    const h = harness({ executions, history: action === "flatten" ? [fill({ execId: "opening.1" })] : [], positions });
    await h.run(intent("recon"), state);
    assert.equal(state.intents.get("uncertain-plan").resolution.status, resolution);
    assert.equal(state.intents.get("uncertain-plan").status, resolution === "partial" ? "uncertain" : "done");
  }
});

function modifyFixture(options = {}) {
  const short = options.short === true;
  const protective = order({ orderId: 21, parentId: 20, action: short ? "BUY" : "SELL", orderType: "STP", auxPrice: short ? 120 : 95, account: ACCOUNT, tif: "DAY", outsideRth: false, triggerMethod: 2, ...options.stop });
  const execution = fill({ side: short ? "SLD" : "BOT", ...options.fill });
  const state = ledger();
  state.placements.push({ intentId: "original-bracket", desk: "j", symbol: "AAPL", clientId: 705, orderRef: ref(), side: short ? "SELL" : "BUY", quantity: 2, orderIds: [20, 21], day: newYorkDay(), reservedAt: new Date().toISOString(), status: "submitted", riskEur: 1, notionalEur: 200 });
  const value = intent("modify-stop", { symbol: "AAPL", orderId: 21, order: { stopPrice: short ? 115 : 100 } });
  state.intents.set(value.intentId, { action: value.action, status: "claimed", orderId: 21, claimedAt: new Date().toISOString() });
  const h = harness({ orders: [protective], executions: [execution], positions: [{ ...contract(), position: short ? -2 : 2 }], mark: 110, ackModification: true, ...options });
  return { ...h, state, value };
}

test("modify-stop tightens long and short brackets with one same-ID update and durable history", async (t) => {
  for (const short of [false, true]) await t.test(short ? "BUY stop moves down" : "SELL stop moves up", async () => {
    const h = modifyFixture({ short }); const saved = []; const originalContract = { ...h.broker.orders[0] };
    const result = await h.run(h.value, h.state, { saveState: (state) => saved.push(structuredClone(state)) });
    assert.equal(result.status, "ok"); assert.deepEqual(h.broker.connections, [705]);
    assert.equal(h.broker.placed.length, 1); assert.deepEqual(h.broker.cancelled, []);
    const placed = h.broker.placed[0];
    assert.equal(placed.id, 21); assert.equal(placed.clientId, 705); assert.deepEqual(placed.contract, originalContract);
    assert.equal(placed.order.auxPrice, short ? 115 : 100);
    for (const [field, expected] of Object.entries({ totalQuantity: 2, parentId: 20, orderRef: ref(), action: short ? "BUY" : "SELL", account: ACCOUNT, tif: "DAY", orderType: "STP", outsideRth: false, triggerMethod: 2, transmit: true })) assert.equal(placed.order[field], expected);
    assert.equal(saved[0].placements[0].stopHistory[0].status, "reserved");
    assert.equal(saved[0].intents.get(h.value.intentId).brokerPlan.modification.to, h.value.order.stopPrice);
    const change = h.state.placements[0].stopHistory[0];
    assert.equal(change.from, short ? 120 : 95); assert.equal(change.to, short ? 115 : 100); assert.equal(change.intentId, h.value.intentId); assert.ok(change.at);
    assert.equal(change.status, "submitted"); assert.equal(h.state.intents.get(h.value.intentId).modification.status, "submitted");
    assert.equal(h.state.placements[0].currentStopPrice, h.value.order.stopPrice);
    assert.equal(h.state.activeOrders[0].auxPrice, h.value.order.stopPrice);
    assert.equal(h.state.placements.length, 1); assert.equal(brakeUsage(h.state).newToday, 1); assert.equal(h.broker.live.size, 0);
  });
});

test("modify-stop orderRef selects the child and preserves the original uppercase broker tag", async () => {
  const h = modifyFixture({ stop: { orderRef: ref("J") } });
  h.broker.orders.push(order({ orderId: 20, orderRef: ref("J") }));
  const result = await h.run(intent("modify-stop", { symbol: "AAPL", orderRef: ref("J"), order: { stopPrice: 100 } }), h.state);
  assert.equal(result.status, "ok"); assert.equal(h.broker.placed[0].id, 21); assert.equal(h.broker.placed[0].order.orderRef, ref("J"));
});

test("modify-stop uses recent delayed last despite subscription warnings and quote-cleanup 300", async (t) => {
  for (const warning of ["mark354", "mark10089", "mark10167"]) for (const short of [false, true]) await t.test(`${warning}: ${short ? "short" : "long"} tick 68`, async () => {
    const field = 68;
    const h = modifyFixture({ short, quotes: [[field, 110]], delayedLastTimestamp: Math.floor(Date.now() / 1000) - 900, [warning]: true, markCancel300: true });
    h.value.order.stopPrice = 110 * (short ? 1.005 : 0.995);
    const result = await h.run(h.value, h.state);
    assert.equal(result.status, "ok"); assert.equal(result.modification.mark.field, field);
    assert.equal(result.modification.mark.delayed, true);
    assert.equal(result.modification.mark.source, "delayed");
    assert.equal(result.modification.mark.symbol, "AAPL");
    assert.ok(result.modification.mark.dataAgeSeconds >= 900 && result.modification.mark.dataAgeSeconds < 902);
    assert.equal(result.modification.mark.receivedAt, result.modification.mark.observedAt);
    assert.equal(h.broker.placed.length, 1); assert.deepEqual(h.broker.marketDataTypes, [3]);
    assert.ok(result.modification.mark.observedAt);
  });
});

test("modify-stop refuses old or unknown delayed data ages before any broker side effect", async (t) => {
  const timestamp = Math.floor(Date.now() / 1000);
  for (const [name, options] of [
    ["last older than 20 minutes", { quotes: [[68, 110]], delayedLastTimestamp: timestamp - 1201 }],
    ["last without tick 88", { quotes: [[68, 110]] }],
    ["close only", { quotes: [[75, 110]] }],
    ["close cannot borrow last timestamp", { quotes: [[75, 110]], delayedLastTimestamp: timestamp - 900 }],
    ["invalid timestamp", { quotes: [[68, 110]], delayedLastTimestamp: "invalid" }],
    ["future timestamp", { quotes: [[68, 110]], delayedLastTimestamp: timestamp + 60 }],
    ["zero timestamp", { quotes: [[68, 110]], delayedLastTimestamp: 0 }],
    ["wrong request timestamp", { quotes: [[68, 110]], onMarkRequest: (api, id) => api.emit(events.tickString, id + 1, 88, String(timestamp - 900)) }],
    ["live timestamp is not delayed timestamp", { quotes: [[68, 110]], onMarkRequest: (api, id) => api.emit(events.tickString, id, 45, String(timestamp - 900)) }],
  ]) await t.test(name, async () => {
    const h = modifyFixture(options);
    await assert.rejects(h.run(h.value, h.state), (error) => error.publicCode === "modify_stop_refused" && /mark too old or age unknown/.test(error.publicReason));
    assert.deepEqual(h.broker.placed, []); assert.deepEqual(h.broker.cancelled, []);
    assert.equal(h.broker.live.size, 0);
  });
});

test("modify-stop supports tick 88 before the price and a configurable delayed-age limit", async (t) => {
  for (const maxAge of [899, 902]) await t.test(`limit ${maxAge}s`, async () => {
    const timestamp = Math.floor(Date.now() / 1000) - 900;
    const h = modifyFixture({ quotes: [[68, 110]], onMarkRequest: (api, id) => api.emit(events.tickString, id, 88, String(timestamp)) });
    h.config.maxDelayedMarkAgeSeconds = maxAge;
    if (maxAge < 900) {
      await assert.rejects(h.run(h.value, h.state), /mark too old or age unknown/);
      assert.deepEqual(h.broker.placed, []);
    } else assert.equal((await h.run(h.value, h.state)).status, "ok");
  });
});

test("modify-stop rechecks delayed data age immediately before submission", async (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: Math.floor(Date.now() / 1000) * 1000 });
  const h = modifyFixture({ quotes: [[68, 110]], delayedLastTimestamp: Math.floor(Date.now() / 1000) - 1199 });
  await assert.rejects(h.run(h.value, h.state, { saveState: () => t.mock.timers.tick(2000) }), /mark too old or age unknown/);
  assert.deepEqual(h.broker.placed, []);
});

test("live modify-stop behaviour and source reporting stay unchanged without tick 88", async (t) => {
  for (const field of [4, 9]) await t.test(`live tick ${field}`, async () => {
    const h = modifyFixture({ quotes: [[field, 110]] });
    const result = await h.run(h.value, h.state);
    assert.equal(result.status, "ok"); assert.equal(h.broker.placed.length, 1);
    assert.equal(result.modification.mark.source, "live");
    assert.equal(result.modification.mark.field, field);
    assert.equal(result.modification.mark.dataAgeSeconds, null);
    assert.ok(result.modification.mark.receivedAt);
  });
});

test("recon reports mark sources and known or unknown ages without enforcing an age limit", async (t) => {
  for (const [name, quotes, age, source, field] of [
    ["recent delayed last", [[68, 110]], 900, "delayed", 68],
    ["old delayed last", [[68, 110]], 3600, "delayed", 68],
    ["unknown delayed last", [[68, 110]], null, "delayed", 68],
    ["delayed close", [[75, 110]], null, "delayed", 75],
    ["delayed midpoint", [[66, 109], [67, 111]], null, "delayed", "midpoint"],
    ["live last", [[4, 110]], null, "live", 4],
    ["live midpoint", [[1, 109], [2, 111]], null, "live", "midpoint"],
  ]) await t.test(name, async () => {
    const h = harness({ positions: [{ ...contract(), position: 2 }, ...keptPositions()], quotes, ...(age === null ? {} : { delayedLastTimestamp: Math.floor(Date.now() / 1000) - age }), ...(source === "delayed" ? { mark10167: true } : {}) });
    const result = await h.run(intent("recon"));
    assert.equal(result.status, "ok"); assert.equal(result.marks.length, 1);
    const mark = result.marks[0];
    assert.equal(mark.symbol, "AAPL"); assert.equal(mark.conId, 1); assert.equal(mark.price, 110);
    assert.equal(mark.source, source); assert.equal(mark.field, field);
    assert.ok(Number.isFinite(Date.parse(mark.receivedAt)));
    if (age === null) assert.equal(mark.dataAgeSeconds, null);
    else assert.ok(mark.dataAgeSeconds >= age && mark.dataAgeSeconds < age + 2);
    assert.deepEqual(h.broker.placed, []); assert.deepEqual(h.broker.cancelled, []);
  });
});

test("delayed modify-stop retains the 0.5% distance and blocks target mark errors without delayed evidence", async (t) => {
  for (const [name, options, price, reason] of [
    ["distance unchanged", { quotes: [[68, 110]], delayedLastTimestamp: Math.floor(Date.now() / 1000) - 900 }, 109.5, /at least 0.5%/],
    ["no delayed quote", { noMark: true, mark354: true }, 100, /reconciliation|fresh last\/close/],
    ["354 plus live tick only", { quotes: [[4, 110]], mark354: true }, 100, /reconciliation/],
    ["10167 without delayed quote", { noMark: true, mark10167: true }, 100, /reconciliation|fresh last\/close/],
    ["10167 plus live tick only", { quotes: [[4, 110]], mark10167: true }, 100, /reconciliation/],
    ["10089 without delayed quote", { noMark: true, mark10089: true }, 100, /reconciliation|fresh last\/close/],
    ["10168 stays blocking even with delayed quote", { quotes: [[68, 110]], onMarkRequest: (api, id) => api.emit(events.error, new Error("delayed data not enabled"), 10168, id) }, 100, /reconciliation/],
    ["another target quote error", { quotes: [[68, 110]], onMarkRequest: (api, id) => api.emit(events.error, new Error("quote failed"), 200, id) }, 100, /reconciliation/],
  ]) await t.test(name, async () => {
    const h = modifyFixture(options); h.value.order.stopPrice = price;
    await assert.rejects(h.run(h.value, h.state), reason);
    assert.deepEqual(h.broker.placed, []); assert.deepEqual(h.broker.cancelled, []);
  });
});

test("a failed non-desk KO mark does not block AAPL modify-stop; order reconciliation stays strict", async (t) => {
  for (const orderError of [false, true]) await t.test(orderError ? "order errors block" : "unrelated mark errors do not block", async () => {
    const h = modifyFixture({
      positions: [{ ...contract(), position: 2 }, { ...contract("KO", 2), position: 10 }],
      quotes: [[68, 110]], delayedLastTimestamp: Math.floor(Date.now() / 1000) - 900, noMarkSymbols: ["KO"], markCancel300: true,
      onMarkRequest: (api, id, c) => { if (c.symbol === "KO") api.emit(events.error, new Error("KO live data unsubscribed"), 354, id); },
      onSnapshot: async (session) => {
        await freshMarks(session, { conId: 2 });
        assert.equal(session.state.errors[0].scope, "mark"); assert.equal(session.state.errors[0].symbol, "KO");
        if (orderError) session.api.emit(events.error, new Error("order reconciliation failed"), 201, 882000);
      },
    });
    if (orderError) { await assert.rejects(h.run(h.value, h.state), /reconciliation/); assert.deepEqual(h.broker.placed, []); }
    else {
      assert.equal((await h.run(h.value, h.state)).status, "ok");
      assert.deepEqual(h.broker.markRequests.map((row) => row.id), [882000, 882001]);
    }
  });
});

test("fresh marks accept delayed bid/ask and close and never request KEEP symbols", async () => {
  for (const quotes of [[[66, 109], [67, 111]], [[75, 110]]]) {
    const h = harness({ positions: [{ ...contract(), position: 2 }, ...keptPositions()], quotes, mark354: true });
    const session = await h.connect(700);
    try {
      await freshMarks(session);
      assert.equal(session.state.marks[1].price, 110); assert.equal(session.state.marks[1].delayed, true);
      assert.equal(session.state.errors[0].informational, true);
      assert.deepEqual(h.broker.markRequests.map((row) => row.contract.symbol), ["AAPL"]);
    } finally { session.close(); }
  }
});

test("modify-stop refuses unsafe requests before any placeOrder or cancellation", async (t) => {
  const cases = [
    ["equal long stop", {}, (h) => { h.value.order.stopPrice = 95; }, /strictly tighten/],
    ["looser long stop", {}, (h) => { h.value.order.stopPrice = 94; }, /strictly tighten/],
    ["equal short stop", { short: true }, (h) => { h.value.order.stopPrice = 120; }, /strictly tighten/],
    ["looser short stop", { short: true }, (h) => { h.value.order.stopPrice = 121; }, /strictly tighten/],
    ["long inside mark distance", {}, (h) => { h.value.order.stopPrice = 109.5; }, /at least 0.5%/],
    ["long crosses mark", {}, (h) => { h.value.order.stopPrice = 111; }, /at least 0.5%/],
    ["short inside mark distance", { short: true }, (h) => { h.value.order.stopPrice = 110.5; }, /at least 0.5%/],
    ["short crosses mark", { short: true }, (h) => { h.value.order.stopPrice = 109; }, /at least 0.5%/],
    ["no fresh quote", { noMark: true }, () => {}, /fresh last\/close mark/],
    ["bid/ask cannot replace last/close", { quotes: [[1, 109], [2, 111]] }, () => {}, /fresh last\/close mark/],
    ["legacy client 27", { stop: { clientId: 27 } }, () => {}, /executor client/],
    ["unmapped client 229", { stop: { clientId: 229 } }, () => {}, /executor client/],
    ["another desk tag", { stop: { orderRef: ref("joe") } }, () => {}, /requesting desk/],
    ["missing desk tag", { stop: { orderRef: "legacy" } }, () => {}, /requesting desk/],
    ["filled stop", { stop: { status: "Filled" } }, () => {}, /working stop/],
    ["cancelled stop", { stop: { status: "Cancelled" } }, () => {}, /working stop/],
    ["inactive stop", { stop: { status: "Inactive" } }, () => {}, /working stop/],
    ["pending cancellation", { stop: { status: "PendingCancel" } }, () => {}, /working stop/],
    ["non-STP", { stop: { orderType: "LMT" } }, () => {}, /not an STP/],
    ["standalone stop", { stop: { parentId: 0 } }, () => {}, /not a bracket child/],
    ["unrecorded parent", { stop: { parentId: 999 } }, () => {}, /recorded executor protective bracket/],
    ["wrong bracket side", {}, (h) => { h.state.placements[0].side = "SELL"; }, /recorded executor protective bracket/],
    ["wrong bracket ID", {}, (h) => { h.state.placements[0].orderIds = [20, 22]; }, /recorded executor protective bracket/],
    ["KEEP TSLA", { stop: { symbol: "TSLA" } }, () => {}, /KEEP/],
    ["KEEP SXR8", { stop: { symbol: "SXR8" } }, () => {}, /KEEP/],
    ["symbol mismatch", { stop: { symbol: "KO" } }, () => {}, /symbol\/conId mismatch/],
    ["resolved conId mismatch", { resolve: () => contract("AAPL", 999) }, () => {}, /resolved contract does not match/],
    ["wrong account", { stop: { account: "other" } }, () => {}, /paper account/],
    ["missing tif", { stop: { tif: "" } }, () => {}, /stop fields/],
    ["missing stop price", { stop: { auxPrice: undefined } }, () => {}, /stop fields/],
    ["noninteger stop quantity", { stop: { quantity: 1.5 } }, () => {}, /stop fields/],
    ["missing zero-fill status", { noOrderEvidence: true }, () => {}, /explicit evidence/],
    ["partially filled stop", { stop: { filled: 1 } }, () => {}, /explicit evidence/],
    ["missing history", { missingHistory: true }, () => {}, /ownership history/],
    ["unknown coverage", { coverage: { status: "unknown", gaps: [] } }, () => {}, /ownership history/],
    ["no owned position", { executions: [] }, () => {}, /no owned position/],
    ["opposite owned sign", { fill: { side: "SLD" }, positions: [{ ...contract(), position: -2 }] }, () => {}, /stop side/],
    ["quantity exceeds owned shares", { fill: { shares: 1 }, positions: [{ ...contract(), position: 1 }] }, () => {}, /exceeds the desk/],
    ["missing broker position", { positions: [] }, () => {}, /does not reconcile/],
    ["opposite broker sign", { positions: [{ ...contract(), position: -2 }] }, () => {}, /does not reconcile/],
    ["missing order", { orders: [] }, () => {}, /target order is missing/],
    ["already expired", {}, (h) => { h.value.expiresAt = new Date(Date.now() - 1).toISOString(); }, /expired/],
  ];
  for (const [name, options, prepare, reason] of cases) await t.test(name, async () => {
    const h = modifyFixture(options); prepare(h);
    await assert.rejects(h.run(h.value, h.state), reason);
    assert.deepEqual(h.broker.placed, []); assert.deepEqual(h.broker.cancelled, []); assert.equal(h.broker.live.size, 0);
  });
});

test("modify-stop accepts the exact mark-distance boundary and fresh close ticks", async (t) => {
  for (const short of [false, true]) for (const field of [4, 9]) await t.test(`${short ? "BUY" : "SELL"}, tick ${field}`, async () => {
    const h = modifyFixture({ short, quotes: [[field, 110]] });
    h.value.order.stopPrice = 110 * (short ? 1.005 : 0.995);
    assert.equal((await h.run(h.value, h.state)).status, "ok");
  });
});

test("modify-stop uses complete intraday ownership and refuses stale, cached-only or conflicting evidence", async (t) => {
  const coverage = intradayCoverage(); coverage.target.fromInclusive = new Date(Date.now() - 40 * 86400000).toISOString();
  const covered = modifyFixture({ coverage });
  assert.equal((await covered.run(covered.value, covered.state)).status, "ok");
  for (const kind of ["missing-receipt", "stale-receipt", "execution-error", "invalid-execution-date", "cached-only", "attribution-missing", "aggregate-exceeds-position", "older-gap"]) await t.test(kind, async () => {
    const options = kind === "execution-error" ? { executionError: true } : kind === "older-gap" ? { coverage: { status: "known", gaps: [{ fromInclusive: new Date(Date.now() - 86400000).toISOString(), toExclusive: new Date(Date.now() - 86390000).toISOString() }], target: { fromInclusive: new Date(Date.now() - 172800000).toISOString(), toExclusive: new Date().toISOString() } } } : {};
    const h = modifyFixture({ ...options, onSnapshot: (session) => {
      if (kind === "missing-receipt") session.state.executionSnapshot = null;
      if (kind === "stale-receipt") session.state.executionSnapshot.completedAt = new Date(Date.now() - 180000).toISOString();
      if (kind === "invalid-execution-date") session.state.executions[0].execution.time = "invalid";
      if (kind === "cached-only") session.state.executions = [];
      if (kind === "attribution-missing") { session.state.executions[0].execution.orderRef = ""; session.state.executions[0].execution.orderId = 999; }
      if (kind === "aggregate-exceeds-position") session.state.executions.push(fill({ execId: "other-desk.1", clientId: 701, orderRef: ref("joe"), shares: 1 }));
    } });
    if (kind === "cached-only") h.state.executions = [fill()];
    await assert.rejects(h.run(h.value, h.state), /ownership|no owned position|broker reconciliation/);
    assert.deepEqual(h.broker.placed, []); assert.deepEqual(h.broker.cancelled, []);
  });
});

test("modify-stop rechecks price, working status, position, ownership and expiry after fetching the mark", async (t) => {
  for (const race of ["tightened-elsewhere", "filled", "position-gone", "new-close", "expired"]) await t.test(race, async () => {
    let expired = false;
    const h = modifyFixture({ onMark: (api) => {
      const stop = h.broker.orders[0];
      if (race === "tightened-elsewhere") api.emit(events.openOrder, 21, contract(), { ...stop, totalQuantity: 2, auxPrice: 101 }, { status: "Submitted" });
      if (race === "filled") api.emit(events.orderStatus, 21, "Filled", 2, 0, 100);
      if (race === "position-gone") api.emit(events.position, ACCOUNT, contract(), 0, 100);
      if (race === "new-close") api.emit(events.execDetails, -1, contract(), fill({ execId: "closing.1", side: "SLD", shares: 1 }).execution);
      if (race === "expired") expired = true;
    } });
    await assert.rejects(h.run(h.value, h.state, { now: () => Date.now() + (expired ? 600000 : 0) }), /tighten|unfilled|reconcile|quantity|expired/);
    assert.deepEqual(h.broker.placed, []); assert.deepEqual(h.broker.cancelled, []);
  });
});

test("modify-stop accepts HALT while place is refused", async () => {
  const h = modifyFixture(); const context = { getHalt: () => ({ active: true }) };
  assert.equal((await h.run(h.value, h.state, context)).status, "ok");
  const placing = harness();
  await assert.rejects(placing.run(intent(), ledger(), context), /HALT/);
  assert.deepEqual(placing.broker.placed, []);
});

test("modify-stop missing, partial, mismatched-price or errored acknowledgements persist uncertain", async (t) => {
  for (const [name, options] of [
    ["no acknowledgement", { noAck: true }], ["status without price", { noPriceAck: true }], ["price without new status", { noStatusAck: true }],
    ["partial", { partial: true }], ["bad quantity", { badQuantity: true }], ["broker error", { errorOnPlace: true }],
    ["old price", { modificationAck: { auxPrice: 95 } }], ["wrong parent", { modificationAck: { parentId: 999 } }],
    ["wrong desk", { modificationAck: { orderRef: ref("joe") } }], ["wrong quantity", { modificationAck: { totalQuantity: 3 } }],
    ["wrong placing client", { modificationAck: { clientId: 27 } }], ["wrong account", { modificationAck: { account: "other" } }],
    ["changed tif", { modificationAck: { tif: "GTC" } }], ["changed type", { modificationAck: { orderType: "LMT" } }],
  ]) await t.test(name, async () => {
    const h = modifyFixture(options);
    await assert.rejects(h.run(h.value, h.state), { code: "uncertain" });
    assert.equal(h.broker.placed.length, 1); assert.equal(h.state.placements[0].stopHistory[0].status, "uncertain");
    assert.equal(h.state.intents.get(h.value.intentId).modification.status, "uncertain"); assert.equal(h.broker.live.size, 0);
    assert.deepEqual(h.broker.cancelled, []);
  });
});

test("modify-stop recon reports the updated auxPrice and resolves only the exact same live order", async (t) => {
  for (const observed of [100, 95, 101, "absent", "other-client", "other-parent", "other-desk", "partial"]) await t.test(String(observed), async () => {
    const h = modifyFixture({ noPriceAck: true });
    await assert.rejects(h.run(h.value, h.state), { code: "uncertain" });
    h.state.intents.get(h.value.intentId).status = "uncertain";
    if (typeof observed === "number") h.broker.orders[0].auxPrice = observed;
    if (observed === "absent") h.broker.orders = [];
    if (observed === "other-client") h.broker.orders[0].clientId = 27;
    if (observed === "other-parent") h.broker.orders[0].parentId = 999;
    if (observed === "other-desk") h.broker.orders[0].orderRef = ref("joe");
    if (observed === "partial") h.broker.orders[0].filled = 1;
    const result = await h.run(intent("recon", { intentId: "j-modify-recon" }), h.state);
    if (observed === 100) {
      assert.equal(result.openOrders[0].auxPrice, 100); assert.equal(h.state.intents.get(h.value.intentId).resolution.status, "modified");
      assert.equal(h.state.placements[0].stopHistory[0].status, "submitted");
    } else assert.equal(h.state.intents.get(h.value.intentId).status, "uncertain");
  });
});

test("modify-stop blocks another intent while the same stop has an unresolved modification", async () => {
  const h = modifyFixture({ noPriceAck: true });
  await assert.rejects(h.run(h.value, h.state), { code: "uncertain" });
  h.state.intents.get(h.value.intentId).status = "uncertain";
  await assert.rejects(h.run({ ...h.value, intentId: "j-second-modify", order: { stopPrice: 101 } }, h.state), /unresolved modification/);
  assert.equal(h.broker.placed.length, 1);
});

test("HTTP modify-stop stores the result, replays once, conflicts on changed content and permits a new ID", async (t) => {
  const h = modifyFixture();
  const app = createServer({ testMode: true, listenHost: "127.0.0.1", listenPort: 0, gatewayPort: 4002, gatewayHost: "100.64.0.6", allowlist: ["127.0.0.1"], stateDir: mkdtempSync(path.join(tmpdir(), "ops266-modify-http-")), execute: (value, state, context) => executeIntent(value, state, context, h.runtime) });
  const stored = app.ledger.load(); stored.placements = h.state.placements; app.ledger.save(stored);
  async function request(method, url, body) {
    const req = Readable.from(body ? [Buffer.from(JSON.stringify(body))] : []);
    req.method = method; req.url = url; req.socket = { remoteAddress: "127.0.0.1" };
    let status; let result;
    await app.handle(req, { writeHead(code) { status = code; }, end(value) { result = JSON.parse(value); } });
    return { status, result };
  }
  t.mock.method(console, "error", () => {});
  app.ledger.setHalt("operator stop");
  const first = await request("POST", "/v1/intents", h.value);
  const replay = await request("POST", "/v1/intents", h.value);
  assert.equal(first.status, 200); assert.equal(replay.result.idempotentReplay, true); assert.equal(h.broker.placed.length, 1);
  assert.equal((await request("POST", "/v1/intents", { ...h.value, order: { stopPrice: 101 } })).status, 409);
  const again = await request("POST", "/v1/intents", { ...h.value, intentId: "j-next-modify", order: { stopPrice: 101 } });
  assert.equal(again.status, 200); assert.equal(h.broker.placed.length, 2);
  const state = app.ledger.load();
  assert.equal(state.intents.get(h.value.intentId).status, "done"); assert.equal(state.intents.get(h.value.intentId).modification.to, 100);
  assert.deepEqual(state.placements[0].stopHistory.map((row) => [row.from, row.to, row.status]), [[95, 100, "submitted"], [100, 101, "submitted"]]);
  assert.equal((await request("GET", `/v1/intents/${h.value.intentId}`)).result.modification.to, 100);
  const denied = await request("POST", "/v1/intents", { ...h.value, intentId: "j-loose-modify", order: { stopPrice: 99 } });
  assert.equal(denied.status, 422); assert.equal(denied.result.code, "modify_stop_refused"); assert.match(denied.result.reason, /strictly tighten/);
  assert.equal(h.broker.placed.length, 2);
  h.broker.noPriceAck = true;
  const uncertain = { ...h.value, intentId: "j-uncertain-modify", order: { stopPrice: 102 } };
  assert.equal((await request("POST", "/v1/intents", uncertain)).result.status, "uncertain");
  assert.equal(app.ledger.load().intents.get(uncertain.intentId).status, "uncertain");
  assert.equal((await request("POST", "/v1/intents", uncertain)).result.idempotentReplay, true);
  assert.equal(h.broker.placed.length, 3);
  assert.equal((await request("POST", "/v1/intents", intent("recon", { intentId: "j-http-stop-recon" }))).status, 200);
  const reconciled = await request("GET", `/v1/intents/${uncertain.intentId}`);
  assert.equal(reconciled.result.status, "ok"); assert.equal(reconciled.result.resolution.status, "modified");
  assert.equal(app.ledger.load().placements[0].stopHistory[2].status, "submitted");
});

test("modify-stop refuses stale cached marks, invalid ticks and incomplete market snapshots", async (t) => {
  for (const [name, options] of [
    ["cached-only mark", { noMark: true, onSnapshot: (session) => { session.state.marks[1] = { price: 110, field: 4, currency: "USD", observedAt: new Date().toISOString() }; } }],
    ["zero mark", { quotes: [[4, 0]] }], ["non-finite mark", { quotes: [[4, Infinity]] }],
    ["snapshot not completed", { noMarkEnd: true }],
  ]) await t.test(name, async () => {
    const h = modifyFixture(options);
    await assert.rejects(h.run(h.value, h.state), /fresh last\/close mark/);
    assert.deepEqual(h.broker.placed, []); assert.deepEqual(h.broker.cancelled, []);
  });
});

test("modify-stop attributes complete earlier-day history from cached fills without using their quantities", async () => {
  const known = fill({ time: new Date(Date.now() - 86400000).toISOString() });
  const history = { ...known, execution: { ...known.execution, orderRef: undefined, orderId: undefined, shares: 1 } };
  const h = modifyFixture({ history: [history], executions: [], stop: { quantity: 1 }, positions: [{ ...contract(), position: 1 }] });
  h.state.executions = [known]; h.state.placements[0].quantity = 1;
  assert.equal((await h.run(h.value, h.state)).status, "ok");
  assert.equal(h.broker.placed[0].order.totalQuantity, 1); assert.equal(h.state.deskPositions[0].quantity, 1);
});

test("modify-stop fails closed on reservation failure and retains uncertainty on post-send persistence failure", async () => {
  const before = modifyFixture(); let saves = 0;
  await assert.rejects(before.run(before.value, before.state, { saveState: () => { if (++saves === 1) throw new Error("reservation save failed"); } }), /reservation save failed/);
  assert.deepEqual(before.broker.placed, []); assert.equal(before.state.placements[0].stopHistory[0].status, "rejected");
  const after = modifyFixture(); saves = 0;
  await assert.rejects(after.run(after.value, after.state, { saveState: () => { if (++saves === 2) throw new Error("ack save failed"); } }), { code: "uncertain" });
  assert.equal(after.broker.placed.length, 1); assert.equal(after.state.placements[0].stopHistory[0].status, "uncertain");
});

test("HTTP modify-stop validation explains missing selector, extra order fields and expiry", async (t) => {
  t.mock.method(console, "error", () => {});
  const h = modifyFixture();
  const app = createServer({ testMode: true, listenHost: "127.0.0.1", listenPort: 0, gatewayPort: 4002, gatewayHost: "100.64.0.6", allowlist: ["127.0.0.1"], stateDir: mkdtempSync(path.join(tmpdir(), "ops266-stop-validation-")), execute: () => assert.fail("invalid intent reached executor") });
  for (const [body, reason] of [
    [{ ...h.value, orderId: undefined }, /exactly one/],
    [{ ...h.value, order: { stopPrice: 100, quantity: 3 } }, /unsupported field/],
    [{ ...h.value, expiresAt: new Date(Date.now() - 1000).toISOString() }, /expired/],
  ]) {
    const req = Readable.from([Buffer.from(JSON.stringify(body))]);
    req.method = "POST"; req.url = "/v1/intents"; req.socket = { remoteAddress: "127.0.0.1" };
    let result; let status;
    await app.handle(req, { writeHead(code) { status = code; }, end(value) { result = JSON.parse(value); } });
    assert.equal(status, 400); assert.equal(result.code, "modify_stop_refused"); assert.match(result.reason, reason);
  }
});
