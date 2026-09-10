#!/usr/bin/env node
/** Synthetic replay tests — not live broker evidence. */
import assert from "node:assert/strict";
import test from "node:test";
import { createPositionTracker, deskForSymbol } from "./positions-state.mjs";
import {
  buildDeskPositions,
  isGrandfathered,
  projectBook,
  serializePositionRow,
} from "./project.mjs";

const TARGET = "PAPER-ACCT-01";
const OBS_A = "2026-09-10T10:00:00+02:00";
const OBS_B = "2026-09-10T10:00:05+02:00";

function baseBook(overrides = {}) {
  return {
    ts: "2026-09-10T10:01:00+02:00",
    gateway: true,
    summary: { NetLiquidation: { value: "12000" } },
    portfolio: [],
    positions: [],
    ...overrides,
  };
}

function stockContract(symbol, extra = {}) {
  return { conId: extra.conId ?? symbol.length * 1000, symbol, secType: "STK", currency: extra.currency ?? "USD", ...extra };
}

test("desk mapping keeps unknown symbols off Joe", () => {
  assert.equal(deskForSymbol("INTC"), "j");
  assert.equal(deskForSymbol("SXR8"), "joel");
  assert.equal(deskForSymbol("TSLA"), "joel");
  assert.equal(deskForSymbol("AAPL"), null);
});

test("partial subscription omits per-desk positions keys", () => {
  const tracker = createPositionTracker(TARGET);
  tracker.onConnected();
  tracker.onPosition(TARGET, stockContract("INTC"), 10, 25, OBS_A);
  const snap = projectBook(baseBook({ positionsCoverage: tracker.snapshot() }), { now: new Date("2026-09-10T08:00:00Z") });
  for (const desk of snap.desks) {
    assert.equal("positions" in desk, false);
  }
});

test("completed empty subscription yields known-empty arrays on all desks", () => {
  const tracker = createPositionTracker(TARGET);
  tracker.onConnected();
  tracker.onPositionEnd();
  const snap = projectBook(baseBook({ positionsCoverage: tracker.snapshot() }), { now: new Date("2026-09-10T08:00:00Z") });
  for (const desk of snap.desks) {
    assert.deepEqual(desk.positions, []);
  }
});

test("disconnect invalidates coverage until resync completes", () => {
  const tracker = createPositionTracker(TARGET);
  tracker.onConnected();
  tracker.onPosition(TARGET, stockContract("INTC"), 5, 20, OBS_A);
  tracker.onPositionEnd();
  tracker.onDisconnected();
  const snap = projectBook(baseBook({ positionsCoverage: tracker.snapshot(), gateway: false }), {
    now: new Date("2026-09-10T08:00:00Z"),
  });
  for (const desk of snap.desks) {
    assert.equal("positions" in desk, false);
  }
});

test("reconnect requires a fresh completed subscription", () => {
  const tracker = createPositionTracker(TARGET);
  tracker.onConnected();
  tracker.onPosition(TARGET, stockContract("INTC"), 5, 20, OBS_A);
  tracker.onPositionEnd();
  tracker.onDisconnected();
  tracker.onConnected();
  tracker.onPosition(TARGET, stockContract("INTC"), 5, 20, OBS_B);
  const partial = projectBook(baseBook({ positionsCoverage: tracker.snapshot() }), { now: new Date("2026-09-10T08:00:00Z") });
  assert.equal("positions" in partial.desks[0], false);
  tracker.onPositionEnd();
  const complete = projectBook(baseBook({ positionsCoverage: tracker.snapshot() }), { now: new Date("2026-09-10T08:00:00Z") });
  assert.equal(complete.desks[0].positions.length, 1);
  assert.equal(complete.desks[0].positions[0].updatedAt, OBS_B);
});

test("account mismatch events are ignored", () => {
  const tracker = createPositionTracker(TARGET);
  tracker.onConnected();
  tracker.onPosition("OTHER-ACCT", stockContract("INTC"), 99, 1, OBS_A);
  tracker.onPositionEnd();
  const snap = projectBook(baseBook({ positionsCoverage: tracker.snapshot() }), { now: new Date("2026-09-10T08:00:00Z") });
  for (const desk of snap.desks) {
    assert.deepEqual(desk.positions, []);
  }
});

test("unknown symbols never appear on Joe desk", () => {
  const tracker = createPositionTracker(TARGET);
  tracker.onConnected();
  tracker.onPosition(TARGET, stockContract("AAPL"), 3, 150, OBS_A);
  tracker.onPositionEnd();
  const snap = projectBook(baseBook({ positionsCoverage: tracker.snapshot() }), { now: new Date("2026-09-10T08:00:00Z") });
  assert.deepEqual(snap.desks.find((d) => d.id === "joe").positions, []);
  assert.equal(snap.desks.find((d) => d.id === "j").positions.length, 0);
});

test("mapped desks receive serialized rows with broker observation time", () => {
  const tracker = createPositionTracker(TARGET);
  tracker.onConnected();
  tracker.onPosition(TARGET, stockContract("INTC", { currency: "EUR" }), 4, 30, OBS_A);
  tracker.onPortfolio(stockContract("INTC", { currency: "EUR" }), 4, 31, 124, 30, 4, 0, OBS_B);
  tracker.onPosition(TARGET, stockContract("SXR8", { currency: "EUR", conId: 9001 }), 2, 500, OBS_A);
  tracker.onPositionEnd();
  const snap = projectBook(baseBook({ positionsCoverage: tracker.snapshot() }), { now: new Date("2026-09-10T08:00:00Z") });
  const jRow = snap.desks.find((d) => d.id === "j").positions[0];
  assert.equal(jRow.symbol, "INTC");
  assert.equal(jRow.updatedAt, OBS_B);
  assert.equal(jRow.mark, 31);
  assert.equal(jRow.marketValue, 124);
  assert.equal(jRow.openPnl, 4);
  assert.equal(jRow.dayPnl, null);
  assert.equal(snap.desks.find((d) => d.id === "joel").positions[0].symbol, "SXR8");
});

test("non-EUR currency suppresses unproven monetary fields", () => {
  const row = serializePositionRow(
    {
      symbol: "INTC",
      pos: 2,
      currency: "USD",
      marketPrice: 40,
      marketValue: 80,
      unrealizedPNL: 3,
      observedAt: OBS_A,
    },
    "j"
  );
  assert.equal(row.mark, undefined);
  assert.equal(row.marketValue, undefined);
  assert.equal(row.openPnl, undefined);
  assert.equal(row.quantity, 2);
});

test("legacy TSLA×1 remains visible on Joel desk when complete", () => {
  const tracker = createPositionTracker(TARGET);
  tracker.onConnected();
  tracker.onPosition(TARGET, stockContract("TSLA", { currency: "USD" }), 1, 200, OBS_A);
  tracker.onPositionEnd();
  const snap = projectBook(
    baseBook({
      positionsCoverage: tracker.snapshot(),
      positions: [{ symbol: "TSLA", pos: 1 }],
      portfolio: [{ symbol: "TSLA", pos: 1, marketValue: 210, unrealizedPNL: 10, realizedPNL: 0 }],
    }),
    { now: new Date("2026-09-10T08:00:00Z") }
  );
  const joel = snap.desks.find((d) => d.id === "joel");
  assert.equal(joel.positions.length, 1);
  assert.equal(isGrandfathered({ symbol: "TSLA", pos: 1 }), true);
});

test("contract identity keeps distinct instruments with the same symbol", () => {
  const tracker = createPositionTracker(TARGET);
  tracker.onConnected();
  tracker.onPosition(TARGET, stockContract("INTC", { conId: 1, exchange: "NASDAQ" }), 1, 10, OBS_A);
  tracker.onPosition(TARGET, stockContract("INTC", { conId: 2, exchange: "IBIS2", currency: "EUR" }), 2, 20, OBS_A);
  tracker.onPositionEnd();
  const rows = buildDeskPositions(tracker.snapshot()).j;
  assert.equal(rows.length, 2);
});

test("zeroed position removes stale row before completion", () => {
  const tracker = createPositionTracker(TARGET);
  tracker.onConnected();
  tracker.onPosition(TARGET, stockContract("INTC"), 5, 20, OBS_A);
  tracker.onPosition(TARGET, stockContract("INTC"), 0, 20, OBS_B);
  tracker.onPositionEnd();
  const snap = projectBook(baseBook({ positionsCoverage: tracker.snapshot() }), { now: new Date("2026-09-10T08:00:00Z") });
  assert.deepEqual(snap.desks.find((d) => d.id === "j").positions, []);
});

test("day P&L is null, not fabricated zero", () => {
  const tracker = createPositionTracker(TARGET);
  tracker.onConnected();
  tracker.onPositionEnd();
  const snap = projectBook(baseBook({ positionsCoverage: tracker.snapshot() }), { now: new Date("2026-09-10T08:00:00Z") });
  for (const desk of snap.desks) {
    assert.equal(desk.money.dayPnl, null);
  }
  assert.equal(snap.totals.dayPnl, null);
});
