import assert from "node:assert/strict";
import test from "node:test";

import {
  activeHalt,
  belongsToDesk,
  brakeUsage,
  evaluatePlacement,
  newYorkDay,
  mergeExecutions,
  ownedPositions,
  parseIntent,
  placementBudget,
  thesisKey,
} from "./policy.mjs";

function valid(overrides = {}) {
  const now = Date.now();
  return {
    schema: "barta.paper-desk-intent.v2",
    intentId: "j-20261005-001",
    desk: "j",
    action: "place",
    createdAt: new Date(now - 10_000).toISOString(),
    expiresAt: new Date(now + 5 * 60_000).toISOString(),
    order: {
      symbol: "AAPL",
      side: "BUY",
      quantity: 2,
      limitPrice: 100,
      stopPrice: 99,
      currency: "USD",
    },
    ...overrides,
  };
}

const emptySnapshot = { positions: [], openOrders: [] };
const emptyState = () => ({ initializedAt: new Date(Date.now() - 48 * 60 * 60_000).toISOString(), placements: [] });

test("accepts a bounded protective paper bracket", () => {
  const intent = parseIntent(valid());
  assert.deepEqual(placementBudget(intent.order, 0.9), { riskEur: 1.84, notionalEur: 183.6 });
  assert.equal(evaluatePlacement(intent, emptySnapshot, emptyState(), { stockType: "COMMON", usdToEur: 0.9 }).riskEur, 1.84);
});

test("desk identity normalizes any case without changing date or thesis", () => {
  for (const desk of ["J", "J2", "J3", "J4", "J5", "JoE", "JoEl"]) {
    const parsed = parseIntent(valid({ desk, orderRef: `${desk}|261006|S1-AVGO` }));
    assert.equal(parsed.desk, desk.toLowerCase());
    assert.equal(parsed.orderRef, `${desk.toLowerCase()}|261006|S1-AVGO`);
    assert.ok(parseIntent(valid({ desk })).orderRef.startsWith(`${desk.toLowerCase()}|`));
  }
  assert.equal(parseIntent(valid({ desk: "J", orderRef: "j|261006|S1-AVGO" })).orderRef, "j|261006|S1-AVGO");
  assert.equal(parseIntent(valid({ desk: "j", orderRef: "J|261006|S1-AVGO" })).desk, "j");
  assert.throws(() => parseIntent(valid({ desk: "UNKNOWN" })), /not authorized/);
  assert.throws(() => parseIntent(valid({ orderRef: "UNKNOWN|261006|S1-AVGO" })), /invalid/);
  assert.throws(() => parseIntent(valid({ orderRef: "JOE|261006|S1-AVGO" })), /another desk/);
  assert.equal(thesisKey("J|261006|S1-AVGO"), "j|S1-AVGO");
  assert.notEqual(thesisKey("J|261006|S1-AVGO"), thesisKey("j|261006|s1-avgo"));
});

test("uppercase broker tags preserve desk and client ownership boundaries", () => {
  for (const clientId of [702, 705]) {
    const row = { clientId, orderRef: "J|261006|S1-AVGO" };
    assert.equal(belongsToDesk(row, "j", [702], 705), true);
    assert.equal(belongsToDesk(row, "joe", [702], 705), false);
    assert.equal(belongsToDesk({ ...row, orderRef: "UNKNOWN|261006|S1-AVGO" }, "j", [702], 705), false);
  }
  assert.equal(belongsToDesk({ clientId: 999, orderRef: "J|261006|S1-AVGO" }, "j", [702], 705), false);
  assert.equal(belongsToDesk({ clientId: 702, orderRef: "UNKNOWN|261006|S1-AVGO" }, "unknown", [702], 705), false);
  assert.equal(belongsToDesk({ clientId: 702 }, "unknown", [702], 705), false);
});

test("j2, j3 and j4 receive independent daily and concurrent brakes", () => {
  const opts = { stockType: "COMMON", usdToEur: 0.9 };
  for (const desk of ["j2", "j3", "j4"]) {
    const parsed = parseIntent(valid({ desk: desk.toUpperCase() }));
    const state = { ...emptyState(), placements: [1, 2].map(() => ({ desk, day: newYorkDay(), riskEur: 1, status: "submitted" })) };
    assert.throws(() => evaluatePlacement(parsed, emptySnapshot, state, opts), /daily new-order/);
    assert.equal(brakeUsage(state).perDesk[desk].newToday, 2);
    assert.equal(evaluatePlacement(parseIntent(valid()), emptySnapshot, state, opts).riskEur, 1.84);
    const deskPositions = ["MSFT", "NVDA", "META"].map((symbol) => ({ desk, symbol, quantity: 1 }));
    assert.throws(() => evaluatePlacement(parsed, { ...emptySnapshot, deskPositions }, emptyState(), opts), /desk concurrent/);
  }
});

test("KEEP, stale, live-like, and weak-stop intents fail closed", () => {
  assert.throws(() => parseIntent(valid({ order: { ...valid().order, symbol: "TSLA" } })), /KEEP/);
  assert.throws(() => parseIntent(valid({ order: { ...valid().order, symbol: "SXR8" } })), /KEEP/);
  assert.throws(() => parseIntent(valid({ order: { ...valid().order, currency: "EUR" } })), /only USD/);
  assert.throws(() => parseIntent(valid({ order: { ...valid().order, stopPrice: 99.75 } })), /at least 0.5%/);
  assert.throws(() => parseIntent(valid({ expiresAt: new Date(Date.now() - 1_000).toISOString() })), /expired/);
  assert.throws(() => parseIntent(valid({ schema: "barta.paper-desk-intent.v1" })), /schema must be/);
});

test("optional symbol is bounded to flatten/cancel and cannot select KEEP", () => {
  for (const action of ["flatten", "cancel"]) {
    const request = valid({ action, order: undefined, ...(action === "cancel" ? { orderId: 30 } : {}) });
    assert.equal(parseIntent({ ...request, symbol: "KO" }).symbol, "KO");
    assert.equal(parseIntent(request).symbol, undefined);
    for (const symbol of ["TSLA", "SXR8", "ko", "", "bad/symbol"]) assert.throws(() => parseIntent({ ...request, symbol }), /KEEP|invalid/);
  }
  for (const action of ["place", "recon"]) assert.throws(() => parseIntent(valid({ action, order: action === "place" ? valid().order : undefined, symbol: "KO" })), /symbol is allowed only/);
});

test("host-side Stage-0 brakes reject HALT, ETF, risk, notional, daily and concurrent overflow", () => {
  const intent = parseIntent(valid());
  assert.throws(() => evaluatePlacement(intent, emptySnapshot, { initializedAt: new Date().toISOString(), placements: [] }, { stockType: "COMMON", usdToEur: 0.9, blockOnInitDay: true }), /initialization day/);
  assert.throws(() => evaluatePlacement(intent, emptySnapshot, emptyState(), { halt: true, stockType: "COMMON", usdToEur: 0.9 }), /HALT/);
  assert.throws(() => evaluatePlacement(intent, emptySnapshot, emptyState(), { stockType: "ETF", usdToEur: 0.9 }), /non-ETF/);
  const highRisk = parseIntent(valid({ order: { ...valid().order, quantity: 30 } }));
  assert.throws(() => evaluatePlacement(highRisk, emptySnapshot, emptyState(), { stockType: "COMMON", usdToEur: 0.9 }), /per-name risk|notional/);
  const highNotional = parseIntent(valid({ order: { ...valid().order, limitPrice: 900, stopPrice: 895.5 } }));
  assert.throws(() => evaluatePlacement(highNotional, emptySnapshot, emptyState(), { stockType: "COMMON", usdToEur: 0.9 }), /notional/);
  const day = newYorkDay();
  const placements = [
    { day, desk: "j", riskEur: 20, status: "submitted" },
    { day, desk: "j", riskEur: 20, status: "submitted" },
  ];
  assert.throws(() => evaluatePlacement(intent, emptySnapshot, { ...emptyState(), placements }, { stockType: "COMMON", usdToEur: 0.9 }), /daily new-order/);
  const nearDailyCap = [{ day, riskEur: 49, status: "submitted" }];
  assert.throws(() => evaluatePlacement(intent, emptySnapshot, { ...emptyState(), placements: nearDailyCap }, { stockType: "COMMON", usdToEur: 0.9 }), /daily risk/);
  const crowded = {
    positions: [
      { symbol: "MSFT", position: 1 },
      { symbol: "NVDA", position: 1 },
      { symbol: "META", position: 1 },
      { symbol: "SXR8", position: 1401 },
    ],
    openOrders: [],
    deskPositions: ["MSFT", "NVDA", "META"].map((symbol) => ({ desk: "j", symbol, quantity: 1 })),
  };
  assert.throws(() => evaluatePlacement(intent, crowded, emptyState(), { stockType: "COMMON", usdToEur: 0.9 }), /concurrent-name/);
  const piled = { positions: [{ symbol: "AAPL", position: 1 }], openOrders: [] };
  assert.throws(() => evaluatePlacement(intent, piled, emptyState(), { stockType: "ADR", usdToEur: 0.9 }), /piling/);
  const rejectedOnly = [
    { day, riskEur: 25, status: "rejected" },
    { day, riskEur: 25, status: "rejected" },
  ];
  assert.equal(
    evaluatePlacement(intent, emptySnapshot, { ...emptyState(), placements: rejectedOnly }, { stockType: "COMMON", usdToEur: 0.9 }).riskEur,
    1.84,
  );
});

test("owned flatten derives quantities from client IDs and always excludes KEEP", () => {
  const executions = [
    { contract: { conId: 1, symbol: "AAPL", secType: "STK", currency: "USD" }, execution: { execId: "a.1", acctNumber: "DUR970597", clientId: 702, side: "BOT", shares: 3 } },
    { contract: { conId: 1, symbol: "AAPL", secType: "STK", currency: "USD" }, execution: { execId: "b.1", acctNumber: "DUR970597", clientId: 702, side: "SLD", shares: 1 } },
    { contract: { conId: 2, symbol: "SXR8", secType: "STK", currency: "EUR" }, execution: { execId: "c.1", acctNumber: "DUR970597", clientId: 702, side: "BOT", shares: 1401 } },
    { contract: { conId: 3, symbol: "NVDA", secType: "STK", currency: "USD" }, execution: { execId: "d.1", acctNumber: "DUR970597", clientId: 999, side: "BOT", shares: 10 } },
  ];
  assert.deepEqual(ownedPositions(executions, [702]), [{ conId: 1, symbol: "AAPL", currency: "USD", secType: "STK", quantity: 2 }]);
});

test("non-empty local HALT is active and there is no remote halt", () => {
  assert.deepEqual(activeHalt("STOP"), { active: true, source: "local" });
  assert.deepEqual(activeHalt("  halt desks  "), { active: true, source: "local" });
  assert.deepEqual(activeHalt(""), { active: false, source: null });
  assert.deepEqual(activeHalt("   "), { active: false, source: null });
  assert.deepEqual(activeHalt(undefined), { active: false, source: null });
});

test("corrections use numeric revisions and conflicting duplicates refuse", () => {
  const row = (execId, shares) => ({ contract: { conId: 1, symbol: "AAPL", secType: "STK", currency: "USD" }, execution: { execId, shares, acctNumber: "DUR970597", clientId: 702, side: "BOT" } });
  const one = row("fill.1", 10);
  const ten = row("fill.10", 2);
  assert.deepEqual(mergeExecutions([one, ten, row("fill.2", 5)]), [ten]);
  assert.deepEqual(mergeExecutions([ten, one]), [ten]);
  assert.deepEqual(mergeExecutions([ten, ten]), [ten]);
  assert.throws(() => mergeExecutions([ten, row("fill.10", 3)]), /conflicting duplicate/);
  assert.equal(ownedPositions([one, ten], [702])[0].quantity, 2);
});

const pusherFill = () => ({
  contract: { conId: 15124833, symbol: "NFLX", secType: "STK", currency: "USD", multiplier: 1 },
  execution: { execId: "00025b45.6ac62f7e.01.01", time: "2026-10-06T15:41:49.000Z", clientId: 55, side: "SELL", shares: 14, price: 68.14 },
});
const liveFill = () => ({
  contract: { conId: 15124833, symbol: "NFLX", secType: "STK", currency: "USD", exchange: "SMART" },
  execution: { ...pusherFill().execution, time: "20261006  11:41:49 US/Eastern", side: "SLD", shares: "14", price: "68.1400001", clientId: "55", orderRef: "j|261006|test", permId: 100, orderId: 20, acctNumber: "DUR970597", exchange: "ISLAND", cumQty: 14, avgPrice: 68.14, liquidation: 0, commission: 1 },
});

test("pusher and live duplicates merge economic identity and retain live ownership fields", () => {
  const history = pusherFill(), live = liveFill();
  const [merged] = mergeExecutions([history], [live]);
  assert.deepEqual(merged, { contract: { ...history.contract, ...live.contract }, execution: live.execution });
  assert.equal(ownedPositions([merged], [55])[0].quantity, -14);
  assert.equal(history.execution.orderRef, undefined, "input history is not mutated");
  assert.equal(mergeExecutions([live], [history])[0].execution.orderRef, live.execution.orderRef);
  assert.equal(mergeExecutions([history], [live], [live]).length, 1);
});

test("duplicate times normalize ISO offsets, fractional seconds and IB UTC formats", () => {
  for (const time of ["2026-10-06T11:41:49-04:00", "2026-10-06T15:41:49.999Z", "20261006-15:41:49", "20261006 15:41:49 UTC", "20261006 11:41:49"]) {
    const live = liveFill(); live.execution.time = time;
    assert.equal(mergeExecutions([pusherFill()], [live]).length, 1, time);
  }
});

test("duplicate contract identity falls back to symbol, security type and currency", () => {
  for (const missing of ["history", "live"]) {
    const history = pusherFill(), live = liveFill();
    delete (missing === "history" ? history : live).contract.conId;
    delete history.execution.clientId;
    assert.equal(mergeExecutions([history], [live])[0].contract.conId, 15124833);
  }
});

test("economic conflicts fail closed and log field names without execution values", (t) => {
  const log = t.mock.method(console, "error", () => {});
  for (const [section, field, value] of [
    ["contract", "conId", 999], ["execution", "side", "BOT"], ["execution", "shares", 15],
    ["execution", "price", 68.140002], ["execution", "clientId", 56],
    ["execution", "time", "2026-10-06T15:41:50Z"], ["execution", "time", "invalid"],
  ]) {
    const live = liveFill(); live[section][field] = value;
    assert.throws(() => mergeExecutions([pusherFill()], [live]), /conflicting duplicate execution revision/);
    assert.deepEqual(log.mock.calls.at(-1).arguments, [`conflicting duplicate execution revision fields: ${field}`]);
  }
  for (const field of ["symbol", "secType", "currency"]) {
    const live = liveFill(); delete live.contract.conId; live.contract[field] = "OTHER";
    assert.throws(() => mergeExecutions([pusherFill()], [live]), /conflicting duplicate/);
    assert.deepEqual(log.mock.calls.at(-1).arguments, [`conflicting duplicate execution revision fields: ${field}`]);
  }
});

test("higher economic correction revision wins over richer old duplicates", () => {
  const correction = pusherFill();
  correction.execution.execId = "00025b45.6ac62f7e.01.02";
  correction.execution.shares = 12;
  assert.deepEqual(mergeExecutions([pusherFill(), liveFill(), correction]), [correction]);
  assert.deepEqual(mergeExecutions([correction, liveFill(), pusherFill()]), [correction]);
});

test("per-desk admission leaves fleet risk and concurrent caps intact", () => {
  const intent = parseIntent(valid());
  const opts = { stockType: "COMMON", usdToEur: 0.9 };
  const other = [{ day: newYorkDay(), desk: "joe", riskEur: 1, status: "submitted" }, { day: newYorkDay(), desk: "joe", riskEur: 1, status: "submitted" }];
  assert.equal(evaluatePlacement(intent, emptySnapshot, { initializedAt: new Date().toISOString(), placements: other }, opts).riskEur, 1.84);
  const fleet = { positions: ["MSFT", "NVDA", "META", "AMD", "INTC", "ORCL"].map((symbol) => ({ symbol, position: 1 })), openOrders: [] };
  assert.throws(() => evaluatePlacement(intent, fleet, emptyState(), opts), /fleet concurrent/);
  const unresolved = { ...emptyState(), placements: [{ orderRef: intent.orderRef, status: "uncertain", symbol: "AMD" }] };
  assert.throws(() => evaluatePlacement(intent, emptySnapshot, unresolved, opts), /unresolved/);
});

test("uncertain placement blocks its symbol and thesis across New York days", () => {
  const intent = parseIntent(valid({ orderRef: "j|261006|thesis-1" }));
  const state = { ...emptyState(), placements: [{ desk: "j", symbol: "AAPL", orderRef: "j|261005|different-thesis", status: "uncertain" }] };
  assert.throws(() => evaluatePlacement(intent, emptySnapshot, state, { stockType: "COMMON", usdToEur: 0.9 }), /piling/);
  state.placements[0].symbol = "AMD";
  state.placements[0].orderRef = "J|261005|thesis-1";
  assert.throws(() => evaluatePlacement(intent, emptySnapshot, state, { stockType: "COMMON", usdToEur: 0.9 }), /unresolved/);
});
