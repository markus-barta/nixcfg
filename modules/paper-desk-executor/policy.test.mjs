import assert from "node:assert/strict";
import test from "node:test";

import {
  activeHalt,
  evaluatePlacement,
  newYorkDay,
  mergeExecutions,
  ownedPositions,
  parseIntent,
  placementBudget,
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

test("KEEP, stale, live-like, and weak-stop intents fail closed", () => {
  assert.throws(() => parseIntent(valid({ order: { ...valid().order, symbol: "TSLA" } })), /KEEP/);
  assert.throws(() => parseIntent(valid({ order: { ...valid().order, symbol: "SXR8" } })), /KEEP/);
  assert.throws(() => parseIntent(valid({ order: { ...valid().order, currency: "EUR" } })), /only USD/);
  assert.throws(() => parseIntent(valid({ order: { ...valid().order, stopPrice: 99.75 } })), /at least 0.5%/);
  assert.throws(() => parseIntent(valid({ expiresAt: new Date(Date.now() - 1_000).toISOString() })), /expired/);
  assert.throws(() => parseIntent(valid({ schema: "barta.paper-desk-intent.v1" })), /schema must be/);
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
  state.placements[0].orderRef = "j|261005|thesis-1";
  assert.throws(() => evaluatePlacement(intent, emptySnapshot, state, { stockType: "COMMON", usdToEur: 0.9 }), /unresolved/);
});
