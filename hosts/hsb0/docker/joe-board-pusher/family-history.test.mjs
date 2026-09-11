#!/usr/bin/env node
/** Synthetic BEST-AVAILABLE history tests. No broker connection or real account data. */
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  EXECUTION_CAPTURE_SCHEMA,
  bestAvailableHistoryDigest,
  effectiveExecutionRecords,
  reconcileExecutionCapture,
} from "./execution-reconciliation.mjs";
import {
  calculateCapturedRealizedSubtotal,
  createFamilyHistoryIngestor,
  createFileFamilyHistoryStore,
  projectBestAvailableHistory,
} from "./family-history.mjs";

const ACCOUNT = "SYNTHETIC-PAPER";
const CLASSIFIER = {
  familyClientIds: [27, 28, 29, 50, 51, 52, 53, 54, 55, 56],
  excludedSymbols: ["SXR8", "TSLA"],
};
const TARGET = { fromInclusive: "2026-09-08T04:00:00Z", toExclusive: "2026-09-11T04:00:00Z" };
const HASH_A = "a".repeat(64);
const HASH_B = "b".repeat(64);

function execution(execId, {
  clientId = 51,
  symbol = "MSFT",
  conId = 1001,
  side = "BOT",
  shares = 1,
  price = 10,
  time = "20260910 12:00:00 US/Eastern",
  currency = "USD",
} = {}) {
  return {
    contract: { conId, symbol, secType: "STK", currency, multiplier: 0 },
    execution: { execId, clientId, side, shares, price, time, acctNumber: ACCOUNT },
  };
}

function commission(execId, amount = 0.1, currency = "USD") {
  return { execId, commission: amount, currency };
}

function capture({
  id = "capture-a",
  sha256 = HASH_A,
  coverageStatus = "known",
  completenessAssertion = null,
  executions = [],
  commissions = [],
  capturedAt = "2026-09-10T20:30:00Z",
  window = { fromInclusive: "2026-09-10T04:00:00Z", toExclusive: "2026-09-10T20:30:00Z" },
} = {}) {
  return {
    schema: EXECUTION_CAPTURE_SCHEMA,
    account: ACCOUNT,
    classifier: CLASSIFIER,
    source: { kind: "persisted-ledger", id, sha256 },
    capturedAt,
    window,
    coverageStatus,
    completenessAssertion,
    executions,
    commissions,
  };
}

test("known captures are durable without being promoted to complete coverage", () => {
  const family = execution("known.family.01");
  const joe = execution("known.joe.01", { clientId: 22, symbol: "INTC", conId: 1002 });
  const state = reconcileExecutionCapture({
    capture: capture({ executions: [family, joe], commissions: [commission(family.execution.execId)] }),
    target: TARGET,
  });

  assert.equal(state.executions.length, 2);
  assert.equal(state.commissions.length, 1);
  assert.equal(state.coverage.status, "known");
  assert.deepEqual(state.coverage.completeIntervals, []);
  assert.deepEqual(state.coverage.gaps, [{
    fromInclusive: "2026-09-08T04:00:00.000Z",
    toExclusive: "2026-09-11T04:00:00.000Z",
    reason: "no authoritative completeness receipt",
  }]);

  const projection = projectBestAvailableHistory({ state });
  assert.equal(projection.status, "BEST_AVAILABLE");
  assert.equal(projection.equity, null);
  assert.equal(projection.capturedSubtotal.executionCount, 1);
  assert.equal(projection.capturedSubtotal.commissionCount, 1);
  assert.equal(projection.capturedSubtotal.realizedPnl, null);
  assert.deepEqual(projection.capturedSubtotal.points, []);
  assert.equal(projection.capturedSubtotal.pointsTruncated, false);
  assert.equal(projection.missingOpeningLots.length, 0);
});

test("higher corrections become effective while every raw revision and orphan fee remains visible", () => {
  const original = execution("corrected.trade.01", { price: 10 });
  const corrected = execution("corrected.trade.02", { price: 11, shares: 2 });
  const first = reconcileExecutionCapture({
    capture: capture({ executions: [original], commissions: [commission(original.execution.execId)] }),
    target: TARGET,
  });
  const state = reconcileExecutionCapture({
    prior: first,
    capture: capture({
      id: "capture-b",
      sha256: HASH_B,
      capturedAt: "2026-09-10T20:31:00Z",
      executions: [original, corrected],
      commissions: [commission(corrected.execution.execId, 0.2), commission("orphan.fee.01", 0.3)],
    }),
    target: TARGET,
  });

  assert.deepEqual(state.executions.map((row) => row.execution.execId), ["corrected.trade.01", "corrected.trade.02"]);
  assert.deepEqual(effectiveExecutionRecords(state).map((row) => row.execution.execId), ["corrected.trade.02"]);
  assert.deepEqual(projectBestAvailableHistory({ state }).orphanCommissionIds, ["orphan.fee.01"]);
});

test("same capture is idempotent and conflicting exact identities fail without changing prior", () => {
  const row = execution("repeat.trade.01");
  const item = capture({ executions: [row], commissions: [commission(row.execution.execId)] });
  const first = reconcileExecutionCapture({ capture: item, target: TARGET });
  const replay = reconcileExecutionCapture({ prior: first, capture: item, target: TARGET });
  assert.deepEqual(replay, first);

  const conflict = structuredClone(item);
  conflict.source = { ...conflict.source, id: "capture-conflict", sha256: HASH_B };
  conflict.executions[0].execution.price = 99;
  assert.throws(
    () => reconcileExecutionCapture({ prior: first, capture: conflict, target: TARGET }),
    /conflicting execution repeat\.trade\.01/
  );
  assert.equal(first.executions[0].execution.price, 10);
});

test("only an explicit provider assertion closes exact gaps", () => {
  const firstWindow = { fromInclusive: TARGET.fromInclusive, toExclusive: "2026-09-09T04:00:00Z" };
  const secondWindow = { fromInclusive: "2026-09-10T04:00:00Z", toExclusive: TARGET.toExclusive };
  const first = reconcileExecutionCapture({
    capture: capture({
      coverageStatus: "complete",
      completenessAssertion: { provider: "synthetic-report", assertionId: "assertion-1" },
      window: firstWindow,
      capturedAt: "2026-09-11T04:00:00Z",
    }),
    target: TARGET,
  });
  const state = reconcileExecutionCapture({
    prior: first,
    capture: capture({
      id: "capture-b",
      sha256: HASH_B,
      coverageStatus: "complete",
      completenessAssertion: { provider: "synthetic-report", assertionId: "assertion-2" },
      window: secondWindow,
      capturedAt: "2026-09-11T04:01:00Z",
    }),
    target: TARGET,
  });
  assert.deepEqual(state.coverage.gaps, [{
    fromInclusive: "2026-09-09T04:00:00.000Z",
    toExclusive: "2026-09-10T04:00:00.000Z",
    reason: "no authoritative completeness receipt",
  }]);
  assert.deepEqual(projectBestAvailableHistory({ state }).latestVerifiedPeriod, {
    fromInclusive: "2026-09-10T04:00:00.000Z",
    toExclusive: "2026-09-11T04:00:00.000Z",
    receiptIds: [state.receipts[1].receiptId],
  });
});

test("captured subtotal is independently calculated in native currency and full equity stays bound", () => {
  const buy = execution("subtotal.buy.01", { price: 10, time: "20260910 12:00:00 US/Eastern" });
  const sell = execution("subtotal.sell.01", { side: "SLD", price: 12, time: "20260910 12:01:00 US/Eastern" });
  const state = reconcileExecutionCapture({
    capture: capture({
      executions: [buy, sell],
      commissions: [commission(buy.execution.execId), commission(sell.execution.execId)],
    }),
    target: TARGET,
  });
  const calculated = calculateCapturedRealizedSubtotal(state);
  assert.equal(calculated.method, "captured-fifo-matched-roundtrips");
  assert.deepEqual(calculated.nativeRealizedPnl, [{ currency: "USD", realizedPnl: 1.7999999999999998 }]);
  assert.deepEqual(calculated.points, [{ at: "2026-09-10T16:01:00.000Z", realizedPnl: 1.7999999999999998 }]);
  assert.equal(calculated.pointsTruncated, false);

  const projection = projectBestAvailableHistory({
    state,
    fullAccounting: { complete: true, equity: 9999, historyDigest: "d".repeat(64) },
  });
  assert.equal(projection.equity, null);
  assert.equal(projection.capturedSubtotal.currency, "USD");
  assert.equal(projection.capturedSubtotal.realizedPnl, 1.7999999999999998);
  assert.equal(projection.capturedSubtotal.method, "captured-fifo-matched-roundtrips");
  assert.equal(projection.capturedSubtotal.points.at(-1).realizedPnl, projection.capturedSubtotal.realizedPnl);

  const changed = structuredClone(state);
  changed.updatedAt = "2026-09-10T20:32:00.000Z";
  assert.notEqual(bestAvailableHistoryDigest(changed), bestAvailableHistoryDigest(state));
});

test("broker realizedPNL can identify an opening gap but never contributes family money", () => {
  const priorLongClose = execution("opening.close.01", { side: "SLD", shares: 3, price: 11 });
  const newBuy = execution("roundtrip.buy.01", { symbol: "NVDA", conId: 1002, shares: 2, price: 10, time: "20260910 12:01:00 US/Eastern" });
  const newSell = execution("roundtrip.sell.01", { symbol: "NVDA", conId: 1002, side: "SLD", shares: 2, price: 12, time: "20260910 12:02:00 US/Eastern" });
  const reports = [
    { ...commission(priorLongClose.execution.execId), realizedPNL: -2.5 },
    { ...commission(newBuy.execution.execId), realizedPNL: 0 },
    { ...commission(newSell.execution.execId), realizedPNL: 3.8 },
  ];
  const state = reconcileExecutionCapture({
    capture: capture({ executions: [priorLongClose, newBuy, newSell], commissions: reports }),
    target: TARGET,
  });
  const subtotal = calculateCapturedRealizedSubtotal(state);
  assert.equal(subtotal.method, "captured-fifo-matched-roundtrips");
  assert.deepEqual(subtotal.nativeRealizedPnl, [{ currency: "USD", realizedPnl: 3.8 }]);
  assert.deepEqual(subtotal.points, [{ at: "2026-09-10T16:02:00.000Z", realizedPnl: 3.8 }]);
  assert.deepEqual(subtotal.missingOpeningLots, [{
    contractKey: "conId:1001",
    quantity: 3,
    firstExecutionId: "opening.close.01",
  }]);
});

test("same-symbol foreign cost basis and broker realizedPNL cannot change family FIFO", () => {
  const foreignBuy = execution("overlap.foreign-buy.01", { clientId: 22, price: 50, time: "20260910 11:59:00 US/Eastern" });
  const familyBuy = execution("overlap.family-buy.01", { price: 100, time: "20260910 12:00:00 US/Eastern" });
  const familySell = execution("overlap.family-sell.01", { side: "SLD", price: 101, time: "20260910 12:01:00 US/Eastern" });
  const rows = [foreignBuy, familyBuy, familySell];
  const oldFees = rows.map((row) => commission(row.execution.execId));
  const oldState = reconcileExecutionCapture({
    capture: capture({ executions: rows, commissions: oldFees }),
    target: TARGET,
  });
  const enrichedFees = [
    { ...commission(foreignBuy.execution.execId), realizedPNL: 0 },
    { ...commission(familyBuy.execution.execId), realizedPNL: 0 },
    { ...commission(familySell.execution.execId), realizedPNL: 77.77 },
  ];
  const enrichedState = reconcileExecutionCapture({
    prior: oldState,
    capture: capture({
      id: "capture-b",
      sha256: HASH_B,
      capturedAt: "2026-09-10T20:31:00Z",
      executions: rows,
      commissions: enrichedFees,
    }),
    target: TARGET,
  });
  const before = calculateCapturedRealizedSubtotal(oldState);
  const after = calculateCapturedRealizedSubtotal(enrichedState);
  assert.deepEqual(after.nativeRealizedPnl, [{ currency: "USD", realizedPnl: 0.8 }]);
  assert.deepEqual(after.points, [{ at: "2026-09-10T16:01:00.000Z", realizedPnl: 0.8 }]);
  assert.deepEqual(after.nativeRealizedPnl, before.nativeRealizedPnl);
  assert.deepEqual(after.points, before.points);
  assert.equal(after.method, "captured-fifo-matched-roundtrips");
});

test("equal-timestamp FIFO results aggregate deterministically and correction replay is idempotent", () => {
  const open = execution("curve.open.01", { shares: 2, price: 10, time: "20260910 11:59:00 US/Eastern" });
  const staleClose = execution("curve.close.01", { side: "SLD", shares: 2, price: 11, time: "20260910 12:00:00 US/Eastern" });
  const correctedClose = execution("curve.close.02", { side: "SLD", shares: 2, price: 12, time: "20260910 12:00:00 US/Eastern" });
  const otherOpen = execution("curve.other-open.01", { symbol: "NVDA", conId: 1002, price: 10, time: "20260910 11:58:00 US/Eastern" });
  const otherClose = execution("curve.other.01", { symbol: "NVDA", conId: 1002, side: "SLD", price: 9, time: "20260910 12:00:00 US/Eastern" });
  const initial = reconcileExecutionCapture({
    capture: capture({
      executions: [staleClose, open],
      commissions: [
        { ...commission(open.execution.execId), realizedPNL: 0 },
        { ...commission(staleClose.execution.execId), realizedPNL: 1.8 },
      ],
    }),
    target: TARGET,
  });
  const reports = [
    { ...commission(open.execution.execId), realizedPNL: 0 },
    { ...commission(staleClose.execution.execId), realizedPNL: 1.8 },
    { ...commission(correctedClose.execution.execId), realizedPNL: 3.8 },
    { ...commission(otherOpen.execution.execId), realizedPNL: 0 },
    { ...commission(otherClose.execution.execId), realizedPNL: -1.2 },
  ];
  const item = capture({ id: "capture-b", sha256: HASH_B, capturedAt: "2026-09-10T20:31:00Z", executions: [otherClose, otherOpen, staleClose, correctedClose, open], commissions: reports });
  const corrected = reconcileExecutionCapture({ prior: initial, capture: item, target: TARGET });
  const replay = reconcileExecutionCapture({ prior: corrected, capture: item, target: TARGET });
  const expected = [{ at: "2026-09-10T16:00:00.000Z", realizedPnl: 2.5999999999999996 }];
  assert.deepEqual(calculateCapturedRealizedSubtotal(initial).points, [{ at: "2026-09-10T16:00:00.000Z", realizedPnl: 1.7999999999999998 }]);
  assert.deepEqual(calculateCapturedRealizedSubtotal(corrected).points, expected);
  assert.deepEqual(calculateCapturedRealizedSubtotal(replay).points, expected);
  assert.deepEqual(replay, corrected);
});

test("missing fees withhold both subtotal and curve", () => {
  const buy = execution("missing-fee.buy.01", { price: 10 });
  const sell = execution("missing-fee.sell.01", { side: "SLD", price: 12, time: "20260910 12:01:00 US/Eastern" });
  const state = reconcileExecutionCapture({
    capture: capture({ executions: [buy, sell], commissions: [commission(buy.execution.execId)] }),
    target: TARGET,
  });
  const subtotal = calculateCapturedRealizedSubtotal(state);
  assert.equal(subtotal.method, "unavailable-missing-fee");
  assert.deepEqual(subtotal.nativeRealizedPnl, []);
  assert.deepEqual(subtotal.points, []);
  assert.equal(subtotal.pointsTruncated, false);
});

test("captured FIFO handles short covers without treating the first sell as a missing opening lot", () => {
  const sell = execution("short.sell.01", { side: "SLD", shares: 2, price: 12 });
  const cover = execution("short.cover.01", { shares: 2, price: 10, time: "20260910 12:01:00 US/Eastern" });
  const state = reconcileExecutionCapture({
    capture: capture({ executions: [sell, cover], commissions: [commission(sell.execution.execId), commission(cover.execution.execId)] }),
    target: TARGET,
  });
  const subtotal = calculateCapturedRealizedSubtotal(state);
  assert.deepEqual(subtotal.nativeRealizedPnl, [{ currency: "USD", realizedPnl: 3.8 }]);
  assert.deepEqual(subtotal.points, [{ at: "2026-09-10T16:01:00.000Z", realizedPnl: 3.8 }]);
  assert.deepEqual(subtotal.missingOpeningLots, []);
  assert.deepEqual(subtotal.endingOpenQuantities, []);
});

test("mixed native currencies keep the single-currency curve unavailable", () => {
  const usdBuy = execution("mixed.usd-buy.01", { price: 10 });
  const usdSell = execution("mixed.usd-sell.01", { side: "SLD", price: 11, time: "20260910 12:01:00 US/Eastern" });
  const gbpBuy = execution("mixed.gbp-buy.01", { symbol: "VOD", conId: 1002, currency: "GBP", price: 20, time: "20260910 12:02:00 US/Eastern" });
  const gbpSell = execution("mixed.gbp-sell.01", { symbol: "VOD", conId: 1002, currency: "GBP", side: "SLD", price: 22, time: "20260910 12:03:00 US/Eastern" });
  const state = reconcileExecutionCapture({
    capture: capture({
      executions: [usdBuy, usdSell, gbpBuy, gbpSell],
      commissions: [
        commission(usdBuy.execution.execId), commission(usdSell.execution.execId),
        commission(gbpBuy.execution.execId, 0.1, "GBP"), commission(gbpSell.execution.execId, 0.1, "GBP"),
      ],
    }),
    target: TARGET,
  });
  const projection = projectBestAvailableHistory({ state });
  assert.equal(projection.capturedSubtotal.currency, null);
  assert.equal(projection.capturedSubtotal.realizedPnl, null);
  assert.equal(projection.capturedSubtotal.nativeRealizedPnl.length, 2);
  assert.deepEqual(projection.capturedSubtotal.points, []);
  assert.equal(projection.capturedSubtotal.pointsTruncated, false);
});

test("captured curve retains the last 2048 actual points with prior cumulative result", () => {
  const executions = [];
  const commissions = [];
  const base = Date.parse("2026-09-10T05:00:00Z");
  for (let index = 0; index < 2050; index += 1) {
    const label = String(index).padStart(4, "0");
    const buy = execution(`bounded.open-${label}.01`, { time: new Date(base + index * 2_000).toISOString() });
    const sell = execution(`bounded.close-${label}.01`, { side: "SLD", price: 11.2, time: new Date(base + index * 2_000 + 1_000).toISOString() });
    executions.push(buy, sell);
    commissions.push(commission(buy.execution.execId, 0.1), commission(sell.execution.execId, 0.1));
  }
  const state = reconcileExecutionCapture({ capture: capture({ executions, commissions }), target: TARGET });
  const subtotal = calculateCapturedRealizedSubtotal(state);
  assert.equal(subtotal.points.length, 2048);
  assert.equal(subtotal.pointsTruncated, true);
  assert.equal(subtotal.points[0].at, new Date(base + 5_000).toISOString());
  assert.ok(Math.abs(subtotal.points[0].realizedPnl - 2.999999999999999) < 1e-9);
  assert.ok(Math.abs(subtotal.points.at(-1).realizedPnl - subtotal.nativeRealizedPnl[0].realizedPnl) < 1e-9);
});

test("file store round-trips sidecar history without touching another ledger", () => {
  const row = execution("disk.trade.01");
  const state = reconcileExecutionCapture({
    capture: capture({ executions: [row], commissions: [commission(row.execution.execId)] }),
    target: TARGET,
  });
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "family-history-test-"));
  const file = path.join(directory, "family-history.json");
  const store = createFileFamilyHistoryStore(file);
  store.save(state);
  assert.deepEqual(store.load(), { ok: true, state });
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  assert.deepEqual(fs.readdirSync(directory), ["family-history.json"]);
});

test("an incomplete or failed async capture remains retryable instead of latching ingestion closed", async () => {
  const stored = { state: null };
  const store = {
    load: () => ({ ok: true, state: stored.state }),
    save: (state) => { stored.state = structuredClone(state); },
  };
  const timers = [];
  let attempt = 0;
  const row = execution("retry.trade.01");
  const ingestor = createFamilyHistoryIngestor({
    store,
    retryMs: 100,
    setTimer: (callback, delay) => { timers.push({ callback, delay }); return timers.length; },
    clearTimer: () => {},
    fetchCapture: async () => {
      attempt += 1;
      if (attempt === 1) throw new Error("temporary capture failure");
      return { capture: capture({ executions: [row], commissions: [commission(row.execution.execId)] }), target: TARGET };
    },
  });

  assert.equal(await ingestor.pollNow(), false);
  assert.match(ingestor.lastError, /temporary/);
  assert.equal(ingestor.fatalReason, null);
  assert.equal(timers.at(-1).delay, 100);
  timers.pop().callback();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(attempt, 2);
  assert.equal(ingestor.lastError, null);
  assert.equal(ingestor.inspectState().coverage.status, "known");
  assert.equal(timers.at(-1).delay, 100);
  ingestor.stop();
});
