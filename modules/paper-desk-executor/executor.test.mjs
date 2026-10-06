import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { Readable } from "node:stream";
import { createServer } from "./server.mjs";
import { executeIntent } from "./executor.mjs";
import { flattenOwned, openSession, readPusherExecutions } from "./ib.mjs";
import { parseIntent, newYorkDay } from "./policy.mjs";

const ACCOUNT = "DUR970597";
const events = Object.fromEntries(["error", "connected", "disconnected", "managedAccounts", "position", "positionEnd", "openOrder", "openOrderEnd", "execDetails", "execDetailsEnd", "nextValidId", "orderStatus", "contractDetails", "contractDetailsEnd", "accountUpdateMulti", "accountUpdateMultiEnd", "commissionReport", "tickPrice", "tickSnapshotEnd"].map((key) => [key, key]));
const contract = (symbol = "AAPL", conId = 1) => ({ symbol, conId, secType: "STK", currency: "USD", exchange: "SMART" });
const ref = (desk = "j", thesis = "test") => `${desk}|261006|${thesis}`;
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
  const broker = { positions: [], orders: [], executions: [], commissions: [], placed: [], cancelled: [], connections: [], executionRequests: [], live: new Set(), ...options };
  class FakeIB extends EventEmitter {
    constructor({ clientId }) { super(); this.clientId = clientId; }
    connect() {
      assert.equal(broker.live.has(this.clientId), false, "duplicate client session");
      broker.live.add(this.clientId); broker.connections.push(this.clientId);
      this.emit(events.connected);
    }
    disconnect() { broker.live.delete(this.clientId); this.emit(events.disconnected); }
    reqManagedAccts() { this.emit(events.managedAccounts, ACCOUNT); }
    reqPositions() { for (const row of broker.positions) this.emit(events.position, ACCOUNT, row, row.position, row.averageCost || 100); this.emit(events.positionEnd); }
    reqAllOpenOrders() { for (const row of broker.orders) { this.emit(events.openOrder, row.orderId, row, { ...row, totalQuantity: row.quantity }, { status: row.status }); if (!broker.noOrderEvidence) this.emit(events.orderStatus, row.orderId, row.status, row.filled || 0, row.quantity - (row.filled || 0), 0); } this.emit(events.openOrderEnd); }
    reqExecutions(id, filter) {
      broker.executionRequests.push({ id, filter });
      if (broker.executionError) this.emit(events.error, new Error("execution snapshot failed"), 201, id);
      for (const row of broker.executions) this.emit(events.execDetails, id, row.contract, row.execution);
      for (const fee of broker.commissions) this.emit(events.commissionReport, fee);
      this.emit(events.execDetailsEnd, broker.wrongExecutionRequest ? id + 1 : id);
    }
    reqIds() { this.emit(events.nextValidId, 100 + broker.placed.length); }
    reqContractDetails(id, request) { this.emit(events.contractDetails, id, { contract: broker.resolve ? broker.resolve(request) : contract(request.symbol, request.symbol === "AAPL" ? 1 : 2), stockType: "COMMON" }); this.emit(events.contractDetailsEnd, id); broker.onContractDetails?.(this); }
    reqAccountUpdatesMulti(id) { this.emit(events.accountUpdateMulti, id, ACCOUNT, "", "ExchangeRate", "1", "EUR"); this.emit(events.accountUpdateMulti, id, ACCOUNT, "", "ExchangeRate", "0.9", "USD"); this.emit(events.accountUpdateMultiEnd, id); broker.onFx?.(); }
    cancelAccountUpdatesMulti() {}
    reqMktData(id) { this.emit(events.tickPrice, id, 4, 101); this.emit(events.tickSnapshotEnd, id); }
    cancelMktData() {}
    placeOrder(id, c, value) {
      broker.placed.push({ id, contract: { ...c }, order: { ...value }, clientId: this.clientId });
      if (broker.errorOnPlace) this.emit(events.error, new Error("paper rejection"), 201, id);
      if (!broker.noAck && !(broker.missingStopAck && value.orderType === "STP")) this.emit(events.orderStatus, id, broker.partial ? "Submitted" : value.orderType === "MKT" ? "Filled" : "Submitted", broker.badQuantity ? 0 : broker.partial ? 1 : value.orderType === "MKT" ? value.totalQuantity : 0, broker.badQuantity ? 0 : broker.partial ? 1 : value.orderType === "MKT" ? 0 : value.totalQuantity, 100);
      broker.afterPlace?.(broker.placed.length);
    }
    cancelOrder(id) {
      broker.cancelled.push(id); broker.orders = broker.orders.filter((row) => row.orderId !== id);
      if (broker.errorOnCancel) this.emit(events.error, new Error("cancel rejection"), 201, id);
      this.emit(events.orderStatus, id, "Cancelled", 0, 0, 0);
      broker.afterCancel?.();
    }
  }
  const connect = async (id, sessionOptions) => {
    const session = await openSession(id, broker.wrongExecutionRequest ? 5 : 1000, { ...sessionOptions, IBApi: FakeIB, EventName: events, wait: async () => {} });
    if (!sessionOptions?.ordersOnly) broker.onSnapshot?.(session);
    return session;
  };
  const history = { schema: "inspr.joe.best-available-history.v1", version: 1, account: ACCOUNT, executions: options.history || [], coverage: { status: "complete", gaps: [], target: { fromInclusive: new Date(Date.now() - 40 * 86400000).toISOString(), toExclusive: new Date().toISOString() } } };
  if (options.coverage) history.coverage = options.coverage;
  const readHistory = (file, now = Date.now(), _readFile, historyOptions) => readPusherExecutions(file, now, () => { if (options.missingHistory) throw new Error("ENOENT"); return JSON.stringify(history); }, historyOptions);
  const config = { clientIds: { executor: 705, recon: 700 }, ownership: { j: [702], j5: [703], joe: [701], joel: [704] }, ownershipLedger: "/pusher-state/family-history.json", blockOnInitDay: false };
  const run = (value, state = ledger(), context = {}) => executeIntent(value, state, { halt: { active: false }, saveState: () => {}, ...context }, { config, connect, readHistory });
  return { broker, run, connect, readHistory, config, runtime: { config, connect, readHistory } };
}

test("executeIntent places accepted tagged bracket on initialization day using distinct sequential sessions", async () => {
  const h = harness(); const state = ledger();
  const result = await h.run(intent(), state);
  assert.equal(result.status, "ok"); assert.deepEqual(h.broker.connections, [700, 705]);
  assert.equal(h.broker.placed.length, 2); assert.ok(h.broker.placed.every((row) => row.order.orderRef === ref()));
  assert.equal(state.placements[0].status, "submitted"); assert.equal(h.broker.live.size, 0);
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
  const opening = fill({ execId: "executor-opening.1", shares: 3, time: "20261005 15:00:00" });
  const stop = fill({ execId: "executor-stop.1", shares: 3, side: "SLD", orderId: 21, time: "20261005 16:00:00" });
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
