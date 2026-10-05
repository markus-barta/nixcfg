import assert from "node:assert/strict";
import test from "node:test";

import {
  activeHalt,
  evaluatePlacement,
  newYorkDay,
  ownedPositions,
  parseIntent,
  placementBudget,
} from "./policy.mjs";

function valid(overrides = {}) {
  const now = Date.now();
  return {
    schema: "barta.paper-desk-intent.v1",
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
  assert.throws(() => parseIntent(valid({ order: { ...valid().order, currency: "EUR" } })), /only USD/);
  assert.throws(() => parseIntent(valid({ order: { ...valid().order, stopPrice: 99.75 } })), /at least 0.5%/);
  assert.throws(() => parseIntent(valid({ expiresAt: new Date(Date.now() - 1_000).toISOString() })), /expired/);
});

test("host-side Stage-0 brakes reject HALT, ETF, risk, notional, daily and concurrent overflow", () => {
  const intent = parseIntent(valid());
  assert.throws(() => evaluatePlacement(intent, emptySnapshot, { initializedAt: new Date().toISOString(), placements: [] }, { stockType: "COMMON", usdToEur: 0.9 }), /initialization day/);
  assert.throws(() => evaluatePlacement(intent, emptySnapshot, emptyState(), { halt: true, stockType: "COMMON", usdToEur: 0.9 }), /HALT/);
  assert.throws(() => evaluatePlacement(intent, emptySnapshot, emptyState(), { stockType: "ETF", usdToEur: 0.9 }), /non-ETF/);
  const highRisk = parseIntent(valid({ order: { ...valid().order, quantity: 30 } }));
  assert.throws(() => evaluatePlacement(highRisk, emptySnapshot, emptyState(), { stockType: "COMMON", usdToEur: 0.9 }), /per-name risk|notional/);
  const highNotional = parseIntent(valid({ order: { ...valid().order, limitPrice: 900, stopPrice: 895.5 } }));
  assert.throws(() => evaluatePlacement(highNotional, emptySnapshot, emptyState(), { stockType: "COMMON", usdToEur: 0.9 }), /notional/);
  const day = newYorkDay();
  const placements = [
    { day, riskEur: 20, status: "submitted" },
    { day, riskEur: 20, status: "submitted" },
  ];
  assert.throws(() => evaluatePlacement(intent, emptySnapshot, { ...emptyState(), placements }, { stockType: "COMMON", usdToEur: 0.9 }), /daily new-order/);
  const crowded = {
    positions: [
      { symbol: "MSFT", position: 1 },
      { symbol: "NVDA", position: 1 },
      { symbol: "META", position: 1 },
      { symbol: "SXR8", position: 1401 },
    ],
    openOrders: [],
  };
  assert.throws(() => evaluatePlacement(intent, crowded, emptyState(), { stockType: "COMMON", usdToEur: 0.9 }), /concurrent-name/);
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

test("non-empty local or authenticated remote HALT is active", () => {
  assert.deepEqual(activeHalt("STOP", []), { active: true, source: "local" });
  assert.deepEqual(activeHalt("", [{ number: 42, body: "halt desks" }]), { active: true, source: "github-issue-42" });
  assert.deepEqual(activeHalt("", [{ number: 42, body: "" }]), { active: false, source: null });
});
