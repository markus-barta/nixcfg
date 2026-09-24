#!/usr/bin/env node
/** Synthetic flat-net mark tests. No account, journal, or live broker records. */
import assert from "node:assert/strict";
import test from "node:test";
import { calculateFamily, VIRTUAL_SHARED_ACCOUNT_OWNERSHIP } from "./family-ledger.mjs";
import {
  contractsNeedingFlatNetMarks,
  createFlatNetMarkController,
  mergeFlatNetMarks,
} from "./flat-net-marks.mjs";

const ACCOUNT = "SYNTHETIC-PAPER-ACCOUNT";
const PERIOD_START = "2026-09-10T04:00:00Z";
const OBSERVED_AT = "2026-09-10T16:00:00Z";
const MARK_AT = "2026-09-10T15:30:00Z";
const FAMILY_IDS = [27];

function stock(symbol, conId) {
  return { conId, symbol, secType: "STK", currency: "USD", exchange: "SMART", multiplier: 1 };
}

function execution(contract, execId, clientId, side, shares, price) {
  return {
    contract,
    execution: {
      execId,
      clientId,
      side,
      shares,
      price,
      time: "20260910 10:00:00 US/Eastern",
      acctNumber: ACCOUNT,
    },
  };
}

function familyInput(contract, portfolio) {
  const familyLong = execution(contract, "FLATNET.FAMILY.01", 27, "BOT", 4, 10);
  const joeShort = execution(contract, "FLATNET.JOE.01", 119, "SLD", 4, 12);
  return {
    executions: [familyLong, joeShort],
    commissions: [
      { execId: familyLong.execution.execId, commission: 0.1, currency: "USD" },
      { execId: joeShort.execution.execId, commission: 0.1, currency: "USD" },
    ],
    positions: [],
    portfolio,
    fx: { baseCurrency: "EUR", rates: { EUR: 1, USD: 0.8 }, observedAt: "2026-09-10T15:59:00Z" },
    account: ACCOUNT,
    familyClientIds: FAMILY_IDS,
    excludedSymbols: ["SXR8", "TSLA"],
    periodStart: PERIOD_START,
    observedAt: OBSERVED_AT,
    ownershipMode: VIRTUAL_SHARED_ACCOUNT_OWNERSHIP,
  };
}

test("shared-account open lot with a flat broker net uses an explicit mark and stays fail-closed without one", () => {
  const contract = stock("NVDA", 5001);
  const familyLong = execution(contract, "FLATNET.FAMILY.01", 27, "BOT", 4, 10);
  const joeShort = execution(contract, "FLATNET.JOE.01", 119, "SLD", 4, 12);
  const executions = [familyLong, joeShort];
  const needed = contractsNeedingFlatNetMarks({
    executions,
    positions: [],
    portfolio: [],
    account: ACCOUNT,
    familyClientIds: FAMILY_IDS,
    excludedSymbols: ["SXR8", "TSLA"],
  });
  assert.deepEqual(needed.map((row) => row.key), ["conId:5001"]);

  const keep = stock("SXR8", 1401);
  const keepNeeded = contractsNeedingFlatNetMarks({
    executions: [
      execution(keep, "KEEP.LONG.01", 27, "BOT", 1401, 500),
      execution(keep, "KEEP.SHORT.01", 119, "SLD", 1401, 500),
    ],
    positions: [],
    portfolio: [],
    account: ACCOUNT,
    familyClientIds: FAMILY_IDS,
    excludedSymbols: ["SXR8", "TSLA"],
  });
  assert.deepEqual(keepNeeded, []);

  const missing = calculateFamily(familyInput(contract, []));
  assert.equal(missing.ok, false);
  assert.match(missing.reason, /missing portfolio mark for open family lot/);

  let now = MARK_AT;
  const requests = [];
  const controller = createFlatNetMarkController({
    request(tickerId, requested) { requests.push([tickerId, requested.symbol]); },
    cancel() {},
    setMarketDataType(type) { requests.push(["type", type]); },
    now: () => now,
  });
  controller.sync(needed);
  assert.equal(controller.onTick(requests[1][0], 1, 99), false);
  assert.equal(controller.onTick(requests[1][0], 4, Number.MAX_VALUE), false);
  assert.deepEqual(controller.marks(), []);
  assert.equal(calculateFamily(familyInput(contract, mergeFlatNetMarks([], controller.marks()))).ok, false);

  assert.equal(controller.onTick(requests[1][0], 68, 12), true);
  const merged = mergeFlatNetMarks([], controller.marks());
  assert.equal(merged[0].pos, 0);
  assert.equal(merged[0].marketPrice, 12);
  assert.equal(merged[0].markObservedAt, MARK_AT);
  const valued = calculateFamily(familyInput(contract, merged));
  assert.equal(valued.ok, true, valued.reason);
  assert.equal(valued.positions[0].quantity, 4);
  assert.equal(valued.positions[0].mark, 12);
  assert.equal(valued.positions[0].updatedAt, MARK_AT);
  assert.ok(valued.equity > 5000);

  const exclusive = calculateFamily({
    ...familyInput(contract, merged),
    ownershipMode: undefined,
  });
  assert.equal(exclusive.ok, false);
  assert.match(exclusive.reason, /ambiguous cross-family ownership/);

  const alreadyMarked = contractsNeedingFlatNetMarks({
    executions,
    positions: [],
    portfolio: merged,
    account: ACCOUNT,
    familyClientIds: FAMILY_IDS,
  });
  assert.deepEqual(alreadyMarked, []);
});
