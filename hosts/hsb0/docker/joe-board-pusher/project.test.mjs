#!/usr/bin/env node
/** Synthetic replay tests — not live broker evidence. */
import assert from "node:assert/strict";
import test from "node:test";
import {
  createPositionTracker,
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

function deskById(snap, id) {
  return snap.desks.find((d) => d.id === id);
}

test("desk mapping keeps unknown symbols off Joe", () => {
  assert.equal(deskForSymbol("INTC"), "j");
  assert.equal(deskForSymbol("SXR8"), "joel");
  assert.equal(deskForSymbol("TSLA"), "joel");
  assert.equal(deskForSymbol("AAPL"), null);
});

test("strictFinite rejects null empty and NaN but accepts real zero", () => {
  assert.equal(strictFinite(null), undefined);
  assert.equal(strictFinite(""), undefined);
  assert.equal(strictFinite("   "), undefined);
  assert.equal(strictFinite("not-a-number"), undefined);
  assert.equal(strictFinite(0), 0);
  assert.equal(strictFinite(-3.5), -3.5);
});

test("invalid qty callbacks do not erase prior holdings", () => {
  const tracker = createPositionTracker(TARGET);
  const session = tracker.onConnected();
  tracker.onPosition(session, TARGET, stockContract("INTC"), 5, 20, OBS_A);
  tracker.onPosition(session, TARGET, stockContract("INTC"), null, 20, OBS_B);
  tracker.onPosition(session, TARGET, stockContract("INTC"), "", 20, OBS_B);
  tracker.onPositionEnd(session);
  assert.equal(tracker.listRows().length, 1);
  assert.equal(tracker.listRows()[0].pos, 5);
});

test("real zero qty removes a holding", () => {
  const tracker = createPositionTracker(TARGET);
  const session = tracker.onConnected();
  tracker.onPosition(session, TARGET, stockContract("INTC"), 5, 20, OBS_A);
  tracker.onPosition(session, TARGET, stockContract("INTC"), 0, 20, OBS_B);
  tracker.onPositionEnd(session);
  assert.equal(tracker.listRows().length, 0);
});

test("stale session callbacks cannot contaminate a new generation", () => {
  const tracker = createPositionTracker(TARGET);
  const oldSession = tracker.onConnected();
  tracker.onPosition(oldSession, TARGET, stockContract("INTC"), 9, 1, OBS_A);
  tracker.onDisconnected();
  const newSession = tracker.onConnected();
  tracker.onPositionEnd(newSession);
  assert.equal(tracker.listRows().length, 0);
  const built = buildDeskPositions(tracker.snapshot());
  assert.deepEqual(built.j, []);
});

test("partial subscription omits per-desk positions keys", () => {
  const tracker = createPositionTracker(TARGET);
  const session = tracker.onConnected();
  tracker.onPosition(session, TARGET, stockContract("INTC"), 10, 25, OBS_A);
  const snap = projectBook(baseBook({ positionsCoverage: tracker.snapshot() }), { now: new Date("2026-09-10T08:00:00Z") });
  for (const desk of snap.desks) {
    assert.equal("positions" in desk, false);
  }
});

test("completed empty subscription covers mapped desks only, not Joe", () => {
  const tracker = createPositionTracker(TARGET);
  const session = tracker.onConnected();
  tracker.onPositionEnd(session);
  const snap = projectBook(baseBook({ positionsCoverage: tracker.snapshot() }), { now: new Date("2026-09-10T08:00:00Z") });
  assert.deepEqual(deskById(snap, "j").positions, []);
  assert.deepEqual(deskById(snap, "joel").positions, []);
  assert.equal("positions" in deskById(snap, "joe"), false);
});

test("disconnect invalidates coverage until resync completes", () => {
  const tracker = createPositionTracker(TARGET);
  const session = tracker.onConnected();
  tracker.onPosition(session, TARGET, stockContract("INTC"), 5, 20, OBS_A);
  tracker.onPositionEnd(session);
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
  let session = tracker.onConnected();
  tracker.onPosition(session, TARGET, stockContract("INTC"), 5, 20, OBS_A);
  tracker.onPositionEnd(session);
  tracker.onDisconnected();
  session = tracker.onConnected();
  tracker.onPosition(session, TARGET, stockContract("INTC"), 5, 20, OBS_B);
  const partial = projectBook(baseBook({ positionsCoverage: tracker.snapshot() }), { now: new Date("2026-09-10T08:00:00Z") });
  assert.equal("positions" in deskById(partial, "j"), false);
  tracker.onPositionEnd(session);
  const complete = projectBook(baseBook({ positionsCoverage: tracker.snapshot() }), { now: new Date("2026-09-10T08:00:00Z") });
  assert.equal(deskById(complete, "j").positions.length, 1);
  assert.equal(deskById(complete, "j").positions[0].updatedAt, OBS_B);
});

test("account mismatch position events are ignored", () => {
  const tracker = createPositionTracker(TARGET);
  const session = tracker.onConnected();
  tracker.onPosition(session, "OTHER-ACCT", stockContract("INTC"), 99, 1, OBS_A);
  tracker.onPositionEnd(session);
  const built = buildDeskPositions(tracker.snapshot());
  assert.deepEqual(built.j, []);
  assert.equal("joe" in built, false);
});

test("portfolio events filter on accountName and ignore missing account", () => {
  const tracker = createPositionTracker(TARGET);
  const session = tracker.onConnected();
  tracker.onPosition(session, TARGET, stockContract("INTC"), 4, 30, OBS_A);
  tracker.onPortfolio(session, "OTHER-ACCT", stockContract("INTC"), 4, 99, 999, 30, 1, 0, OBS_B);
  tracker.onPortfolio(session, undefined, stockContract("INTC"), 4, 88, 888, 30, 2, 0, OBS_B);
  tracker.onPositionEnd(session);
  const row = tracker.listRows()[0];
  assert.equal(row.marketPrice, undefined);
  const snap = projectBook(baseBook({ positionsCoverage: tracker.snapshot() }), { now: new Date("2026-09-10T08:00:00Z") });
  assert.equal(deskById(snap, "j").positions[0].mark, undefined);
});

test("target-account portfolio updates mark but not unverified marketValue/openPnl", () => {
  const tracker = createPositionTracker(TARGET);
  const session = tracker.onConnected();
  tracker.onPosition(session, TARGET, stockContract("INTC", { currency: "EUR" }), 4, 30, OBS_A);
  tracker.onPortfolio(session, TARGET, stockContract("INTC", { currency: "EUR" }), 4, 31, 124, 30, 4, 0, OBS_B);
  tracker.onPositionEnd(session);
  const snap = projectBook(baseBook({ positionsCoverage: tracker.snapshot() }), { now: new Date("2026-09-10T08:00:00Z") });
  const jRow = deskById(snap, "j").positions[0];
  assert.equal(jRow.symbol, "INTC");
  assert.equal(jRow.updatedAt, OBS_B);
  assert.equal(jRow.currency, "EUR");
  assert.equal(jRow.mark, 31);
  assert.equal(jRow.marketValue, undefined);
  assert.equal(jRow.openPnl, undefined);
  assert.equal(jRow.dayPnl, null);
  assert.equal(jRow.accountingScope, "stage0");
});

test("unknown symbols never imply an empty Joe sleeve", () => {
  const tracker = createPositionTracker(TARGET);
  const session = tracker.onConnected();
  tracker.onPosition(session, TARGET, stockContract("AAPL"), 3, 150, OBS_A);
  tracker.onPositionEnd(session);
  const snap = projectBook(baseBook({ positionsCoverage: tracker.snapshot() }), { now: new Date("2026-09-10T08:00:00Z") });
  assert.equal("positions" in deskById(snap, "joe"), false);
  assert.equal(deskById(snap, "j").positions.length, 0);
});

test("serializePositionRow preserves signed quantity and emits currency", () => {
  const row = serializePositionRow(
    {
      symbol: "INTC",
      pos: -2,
      currency: "usd",
      marketPrice: 40,
      marketValue: 80,
      unrealizedPNL: 3,
      observedAt: OBS_A,
    },
    "j"
  );
  assert.equal(row.quantity, -2);
  assert.equal(row.side, "Short");
  assert.equal(row.currency, "USD");
  assert.equal(row.mark, 40);
  assert.equal(row.marketValue, undefined);
  assert.equal(row.openPnl, undefined);
  assert.equal(row.accountingScope, "stage0");
});

test("legacy TSLA×1 is visible with accountingScope legacy", () => {
  const tracker = createPositionTracker(TARGET);
  const session = tracker.onConnected();
  tracker.onPosition(session, TARGET, stockContract("TSLA", { currency: "USD" }), 1, 200, OBS_A);
  tracker.onPositionEnd(session);
  const snap = projectBook(
    baseBook({
      positionsCoverage: tracker.snapshot(),
      positions: [{ symbol: "TSLA", pos: 1 }],
      portfolio: [{ symbol: "TSLA", pos: 1, marketValue: 210, unrealizedPNL: 10, realizedPNL: 0 }],
    }),
    { now: new Date("2026-09-10T08:00:00Z") }
  );
  const joel = deskById(snap, "joel");
  assert.equal(joel.positions.length, 1);
  assert.equal(joel.positions[0].accountingScope, "legacy");
  assert.equal(isGrandfathered({ symbol: "TSLA", pos: 1 }), true);
});

test("contract identity keeps distinct instruments with the same symbol", () => {
  const tracker = createPositionTracker(TARGET);
  const session = tracker.onConnected();
  tracker.onPosition(session, TARGET, stockContract("INTC", { conId: 1, exchange: "NASDAQ" }), 1, 10, OBS_A);
  tracker.onPosition(session, TARGET, stockContract("INTC", { conId: 2, exchange: "IBIS2", currency: "EUR" }), 2, 20, OBS_A);
  tracker.onPositionEnd(session);
  const rows = buildDeskPositions(tracker.snapshot()).j;
  assert.equal(rows.length, 2);
});

test("day P&L is null, not fabricated zero", () => {
  const tracker = createPositionTracker(TARGET);
  const session = tracker.onConnected();
  tracker.onPositionEnd(session);
  const snap = projectBook(baseBook({ positionsCoverage: tracker.snapshot() }), { now: new Date("2026-09-10T08:00:00Z") });
  for (const desk of snap.desks) {
    assert.equal(desk.money.dayPnl, null);
  }
  assert.equal(snap.totals.dayPnl, null);
});

test("connection failure helper matches gateway loss codes", () => {
  assert.equal(isConnectionFailure(502, "Couldn't connect"), true);
  assert.equal(isConnectionFailure(200, "ECONNREFUSED"), true);
  assert.equal(isConnectionFailure(101, "data farm"), false);
});
