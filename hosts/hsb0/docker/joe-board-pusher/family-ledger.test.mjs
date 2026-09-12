#!/usr/bin/env node
/** Synthetic family-ledger tests. No account, journal, or live broker records. */
import assert from "node:assert/strict";
import test from "node:test";
import { calculateFamily, mergeExecutionRecords } from "./family-ledger.mjs";

const ACCOUNT = "SYNTHETIC-PAPER-ACCOUNT";
const OTHER_ACCOUNT = "SYNTHETIC-OTHER-ACCOUNT";
const PERIOD_START = "2026-09-10T04:00:00Z";
const OBSERVED_AT = "2026-09-10T16:00:00Z";
const MARK_AT = "2026-09-10T15:30:00Z";
const FAMILY_IDS = [27, 28, 29, 51, 53, 54, 55];

function stock(symbol, conId, currency = "USD", multiplier = 0) {
  return { conId, symbol, secType: "STK", currency, multiplier };
}

function execution({
  contract,
  execId,
  clientId = FAMILY_IDS[0],
  side = "BOT",
  shares = 1,
  price = 10,
  time = "20260910 10:00:00 US/Eastern",
  account = ACCOUNT,
  ...extra
}) {
  return {
    contract,
    execution: {
      execId,
      clientId,
      side,
      shares,
      price,
      time,
      acctNumber: account,
      ...extra,
    },
  };
}

function commission(record, amount = 0.1, currency = "USD", extra = {}) {
  return {
    execId: record.execution.execId,
    commission: amount,
    currency,
    ...extra,
  };
}

function position(contract, pos) {
  return { contract, pos };
}

function quote(contract, pos, marketPrice, observedAt = MARK_AT, extra = {}) {
  return {
    contract,
    symbol: contract.symbol,
    pos,
    marketPrice,
    observedAt,
    ...extra,
  };
}

function input(overrides = {}) {
  return {
    executions: [],
    commissions: [],
    portfolio: [],
    positions: [],
    fx: {
      baseCurrency: "EUR",
      rates: { EUR: 1, USD: 0.8, GBP: 1.2 },
      observedAt: "2026-09-10T15:59:00Z",
    },
    account: ACCOUNT,
    familyClientIds: FAMILY_IDS,
    excludedSymbols: [],
    periodStart: PERIOD_START,
    observedAt: OBSERVED_AT,
    ...overrides,
  };
}

function ok(result) {
  assert.equal(result.ok, true, result.reason);
  return result;
}

function reason(result, pattern) {
  assert.equal(result.ok, false);
  assert.match(result.reason, pattern);
}

test("a complete flat ledger adds virtual capital exactly once and labels its bounded method", () => {
  const result = ok(calculateFamily(input()));
  assert.deepEqual(
    {
      equity: result.equity,
      totalPnl: result.totalPnl,
      realizedPnl: result.realizedPnl,
      unrealizedPnl: result.unrealizedPnl,
      positions: result.positions,
      observedAt: result.observedAt,
      executionCount: result.executionCount,
    },
    {
      equity: 5000,
      totalPnl: 0,
      realizedPnl: 0,
      unrealizedPnl: 0,
      positions: [],
      observedAt: OBSERVED_AT,
      executionCount: 0,
    }
  );
  assert.deepEqual(result.accounting, {
    periodStart: PERIOD_START,
    method: "execution-fifo-net-current-fx",
    detail: "Net of recorded fees; converted at observed FX. Earlier results unavailable.",
  });
});

test("five family members aggregate into one book with one virtual-capital allocation", () => {
  const contract = stock("MSFT", 1001);
  const records = FAMILY_IDS.slice(0, 5).map((clientId, index) => execution({
    contract,
    execId: `FIVE.${index}.01`,
    clientId,
  }));
  const result = ok(calculateFamily(input({
    executions: records,
    commissions: records.map((record) => commission(record)),
    positions: [position(contract, 5)],
    portfolio: [quote(contract, 5, 12)],
  })));
  assert.equal(result.executionCount, 5);
  assert.equal(result.realizedPnl, -0.4);
  assert.equal(result.unrealizedPnl, 8);
  assert.equal(result.totalPnl, 7.6);
  assert.equal(result.equity, 5007.6);
  assert.deepEqual(result.positions, [{
    desk: "j",
    symbol: "MSFT",
    side: "Long",
    quantity: 5,
    accountingScope: "stage0",
    dayPnl: null,
    openPnl: 8,
    currency: "USD",
    mark: 12,
    updatedAt: MARK_AT,
  }]);
});

test("FIFO handles partial long closes, partial short covers, and every fill fee", () => {
  const long = stock("NVDA", 1002);
  const short = stock("PATH", 1003);
  const records = [
    execution({ contract: long, execId: "FIFO.LONG.01", shares: 10, price: 10, time: "20260910 09:30:00 US/Eastern" }),
    execution({ contract: long, execId: "FIFO.LONGCLOSE.01", side: "SLD", shares: 4, price: 15, time: "20260910 10:00:00 US/Eastern", clientId: FAMILY_IDS[1] }),
    execution({ contract: short, execId: "FIFO.SHORT.01", side: "SLD", shares: 5, price: 20, time: "20260910 10:30:00 US/Eastern" }),
    execution({ contract: short, execId: "FIFO.COVER.01", shares: 2, price: 15, time: "20260910 11:00:00 US/Eastern", clientId: FAMILY_IDS[2] }),
  ];
  const result = ok(calculateFamily(input({
    executions: records,
    commissions: [
      commission(records[0], 1),
      commission(records[1], 1),
      commission(records[2], 0.5),
      commission(records[3], 0.5),
    ],
    positions: [position(long, 6), position(short, -3)],
    portfolio: [quote(long, 6, 12), quote(short, -3, 18)],
  })));
  assert.equal(result.realizedPnl, 21.6);
  assert.equal(result.unrealizedPnl, 14.4);
  assert.equal(result.totalPnl, 36);
  assert.deepEqual(result.positions.map(({ symbol, side, quantity }) => ({ symbol, side, quantity })), [
    { symbol: "NVDA", side: "Long", quantity: 6 },
    { symbol: "PATH", side: "Short", quantity: -3 },
  ]);
  assert.equal(Math.round(result.positions.reduce((sum, row) => sum + row.openPnl, 0) * 100) / 100, result.unrealizedPnl);
});

test("commission currency converts independently and opening fees remain an expense", () => {
  const contract = stock("MSFT", 1004);
  const record = execution({ contract, execId: "EURFEE.OPEN.01", price: 10 });
  const result = ok(calculateFamily(input({
    executions: [record],
    commissions: [commission(record, 1, "EUR", { realizedPNL: 99999 })],
    positions: [position(contract, 1)],
    portfolio: [quote(contract, 1, 10, MARK_AT, { unrealizedPNL: 555, realizedPNL: 777 })],
  })));
  assert.equal(result.realizedPnl, -1);
  assert.equal(result.unrealizedPnl, 0);
  assert.equal(result.totalPnl, -1);
});

test("family may close before foreign Joe opens the same contract; broker callback P&L is ignored", () => {
  const contract = stock("INTC", 1005);
  const buy = execution({ contract, execId: "INTC.FAMILYBUY.01", price: 10, time: "20260910 09:30:00 US/Eastern" });
  const sell = execution({ contract, execId: "INTC.FAMILYSELL.01", side: "SLD", price: 12, time: "20260910 10:00:00 US/Eastern", clientId: FAMILY_IDS[4] });
  const joe = execution({ contract, execId: "INTC.JOEOPEN.01", clientId: 22, shares: 3, price: 50, time: "20260910 10:30:00 US/Eastern" });
  const result = ok(calculateFamily(input({
    executions: [joe, sell, buy],
    commissions: [commission(buy), commission(sell)],
    positions: [position(contract, 3)],
    portfolio: [quote(contract, 3, 500, MARK_AT, { unrealizedPNL: 100000, realizedPNL: 200000 })],
  })));
  assert.equal(result.executionCount, 2);
  assert.equal(result.realizedPnl, 1.44);
  assert.equal(result.unrealizedPnl, 0);
  assert.equal(result.totalPnl, 1.44);
  assert.deepEqual(result.positions, []);
  assert.deepEqual(result.openPnlEvidence.residualNonKeepPositions, [
    { contractKey: "conId:1005", symbol: "INTC", quantity: 3 },
  ]);
});

test("cross-family offset and same-direction overlap both fail despite quantity parity", () => {
  const contract = stock("INTC", 1006);
  const familyShort = execution({ contract, execId: "OWNER.FAMILYSHORT.01", side: "SLD", time: "20260910 09:30:00 US/Eastern" });
  const joeBuy = execution({ contract, execId: "OWNER.JOEBUY.01", clientId: 22, time: "20260910 10:00:00 US/Eastern" });
  reason(calculateFamily(input({
    executions: [familyShort, joeBuy],
    commissions: [commission(familyShort)],
    positions: [],
  })), /ambiguous cross-family ownership/);

  const familyBuy = execution({ contract, execId: "OWNER.FAMILYBUY.01", time: "20260910 09:30:00 US/Eastern" });
  const joeAlsoBuy = execution({ contract, execId: "OWNER.JOEALSOBUY.01", clientId: 22, time: "20260910 10:00:00 US/Eastern" });
  reason(calculateFamily(input({
    executions: [familyBuy, joeAlsoBuy],
    commissions: [commission(familyBuy)],
    positions: [position(contract, 2)],
    portfolio: [quote(contract, 2, 10)],
  })), /ambiguous cross-family ownership/);
});

test("SXR8 and TSLA are always excluded from replay and accounting", () => {
  const sxr8 = stock("SXR8", 1007, "EUR", 99);
  const tsla = stock("TSLA", 1008, "USD", 99);
  const records = [
    execution({ contract: sxr8, execId: "KEEP.SXR8.01", shares: 20, price: 500 }),
    execution({ contract: tsla, execId: "KEEP.TSLA.01", shares: 1, price: 200 }),
  ];
  const result = ok(calculateFamily(input({
    executions: records,
    positions: [position(sxr8, 20), position(tsla, 1)],
    portfolio: [quote(sxr8, 20, 600), quote(tsla, 1, 300)],
  })));
  assert.equal(result.totalPnl, 0);
  assert.equal(result.executionCount, 0);
  assert.deepEqual(result.positions, []);
  assert.deepEqual(result.openPnlEvidence.excludedPositions, [
    { contractKey: "conId:1007", symbol: "SXR8", quantity: 20 },
    { contractKey: "conId:1008", symbol: "TSLA", quantity: 1 },
  ]);
});

test("replay merge deduplicates repeats and replaces a lower correction revision", () => {
  const contract = stock("MSFT", 1009);
  const original = execution({ contract, execId: "CORRECTION.TRADE.01", shares: 1, price: 10 });
  const duplicate = structuredClone(original);
  const corrected = execution({ contract, execId: "CORRECTION.TRADE.02", shares: 2, price: 11 });
  assert.deepEqual(mergeExecutionRecords([original], [duplicate, corrected]), [corrected]);

  const result = ok(calculateFamily(input({
    executions: [corrected, duplicate, original],
    commissions: [commission(corrected, 0.2)],
    positions: [position(contract, 2)],
    portfolio: [quote(contract, 2, 11)],
  })));
  assert.equal(result.executionCount, 1);
  assert.equal(result.realizedPnl, -0.16);
});

test("conflicting duplicate execution or commission IDs fail closed", () => {
  const contract = stock("MSFT", 1010);
  const first = execution({ contract, execId: "CONFLICT.TRADE.01", price: 10 });
  const conflicting = structuredClone(first);
  conflicting.execution.price = 11;
  reason(calculateFamily(input({ executions: [first, conflicting] })), /conflicting duplicate execution ID/);

  const sameRevision = execution({ contract, execId: "CONFLICT.TRADE.1", price: 10 });
  reason(calculateFamily(input({ executions: [first, sameRevision] })), /conflicting execution correction revision/);

  const record = execution({ contract, execId: "CONFLICT.COMMISSION.01" });
  reason(calculateFamily(input({
    executions: [record],
    commissions: [commission(record, 0.1), commission(record, 0.2)],
    positions: [position(contract, 1)],
    portfolio: [quote(contract, 1, 10)],
  })), /conflicting duplicate commission report/);
});

test("missing commission, FX, mark, or quantity reconciliation fails closed", () => {
  const contract = stock("NVDA", 1011);
  const record = execution({ contract, execId: "MISSING.INPUT.01" });
  reason(calculateFamily(input({
    executions: [record],
    positions: [position(contract, 1)],
    portfolio: [quote(contract, 1, 10)],
  })), /missing commission/);

  reason(calculateFamily(input({
    executions: [record],
    commissions: [commission(record)],
    positions: [position(contract, 1)],
    portfolio: [quote(contract, 1, 10)],
    fx: { baseCurrency: "EUR", rates: { EUR: 1 }, observedAt: OBSERVED_AT },
  })), /missing FX rate for USD/);

  reason(calculateFamily(input({
    executions: [record],
    commissions: [commission(record)],
    positions: [position(contract, 1)],
  })), /missing portfolio mark/);

  reason(calculateFamily(input({
    executions: [record],
    commissions: [commission(record)],
    positions: [position(contract, 2)],
    portfolio: [quote(contract, 2, 10)],
  })), /does not reconcile/);
});

test("marks must be actual ISO observations no older than the latest fill", () => {
  const contract = stock("PATH", 1012);
  const record = execution({
    contract,
    execId: "STALE.MARK.01",
    time: "20260910 10:00:00 US/Eastern",
  });
  reason(calculateFamily(input({
    executions: [record],
    commissions: [commission(record)],
    positions: [position(contract, 1)],
    portfolio: [quote(contract, 1, 10, "2026-09-10T13:59:59Z")],
  })), /predates the latest execution/);
  reason(calculateFamily(input({
    executions: [record],
    commissions: [commission(record)],
    positions: [position(contract, 1)],
    portfolio: [quote(contract, 1, 10, "2026-09-10 15:00:00")],
  })), /unambiguous ISO timestamp/);
});

test("US/Eastern and America/New_York use IANA DST while ambiguous or unsupported times fail", () => {
  const contract = stock("MSFT", 1013);
  const buy = execution({
    contract,
    execId: "DST.WINTERBUY.01",
    time: "20261201 09:30:00 US/Eastern",
  });
  const sell = execution({
    contract,
    execId: "DST.WINTERSELL.01",
    side: "SLD",
    price: 11,
    time: "20261201 10:00:00 America/New_York",
  });
  const winterInput = input({
    executions: [sell, buy],
    commissions: [commission(buy, 0), commission(sell, 0)],
    observedAt: "2026-12-01T16:00:00Z",
    positions: [],
  });
  winterInput.fx.observedAt = "2026-12-01T15:59:00Z";
  const winter = ok(calculateFamily(winterInput));
  assert.equal(winter.realizedPnl, 0.8);

  const ambiguous = execution({
    contract,
    execId: "DST.AMBIGUOUS.01",
    time: "20261101 01:30:00 US/Eastern",
  });
  reason(calculateFamily(input({
    executions: [ambiguous],
    observedAt: "2026-11-01T08:00:00Z",
  })), /unsupported or ambiguous/);

  const unsupported = execution({
    contract,
    execId: "DST.UNSUPPORTED.01",
    time: "20260910 10:00:00 EST",
  });
  reason(calculateFamily(input({ executions: [unsupported] })), /unsupported or ambiguous timezone/);

  const invalid = execution({
    contract,
    execId: "DST.INVALIDDATE.01",
    time: "20260931 10:00:00 US/Eastern",
  });
  reason(calculateFamily(input({ executions: [invalid] })), /execution time is invalid/);
});

test("the fixed initial boundary excludes earlier unverified fills and rejects another baseline", () => {
  const contract = stock("MSFT", 1014);
  const earlier = execution({
    contract,
    execId: "EARLIER.UNVERIFIED.01",
    time: "20260903 10:00:00 US/Eastern",
  });
  const result = ok(calculateFamily(input({ executions: [earlier] })));
  assert.equal(result.executionCount, 0);
  assert.equal(result.totalPnl, 0);

  reason(calculateFamily(input({ periodStart: "2026-09-10T05:00:00Z" })), /periodStart must equal/);
  reason(calculateFamily(input({ observedAt: "2026-09-10T03:59:59Z" })), /observedAt predates/);
});

test("STK decoder multiplier zero and explicit one are standard; other or missing values fail", () => {
  for (const multiplier of [0, 1]) {
    const contract = stock(`OK${multiplier}`, 1020 + multiplier, "USD", multiplier);
    const record = execution({ contract, execId: `MULTIPLIER.OK${multiplier}.01` });
    ok(calculateFamily(input({
      executions: [record],
      commissions: [commission(record)],
      positions: [position(contract, 1)],
      portfolio: [quote(contract, 1, 10)],
    })));
  }

  for (const multiplier of [2, undefined]) {
    const contract = stock("BAD", 1022, "USD", multiplier);
    if (multiplier === undefined) delete contract.multiplier;
    const record = execution({ contract, execId: `MULTIPLIER.BAD${String(multiplier)}.01` });
    reason(calculateFamily(input({ executions: [record] })), /STK multiplier/);
  }
});

test("FX base and every supplied rate must be explicit, positive, and finite", () => {
  reason(calculateFamily(input({
    fx: { baseCurrency: "USD", rates: { USD: 1, EUR: 1.2 }, observedAt: OBSERVED_AT },
  })), /not proven EUR/);

  for (const badRate of [0, -1, NaN, Infinity, Number.MAX_VALUE]) {
    reason(calculateFamily(input({
      fx: { baseCurrency: "EUR", rates: { EUR: 1, USD: badRate }, observedAt: OBSERVED_AT },
    })), /FX rate for USD/);
  }
  reason(calculateFamily(input({
    fx: { baseCurrency: "EUR", rates: { EUR: 0.99, USD: 0.8 }, observedAt: OBSERVED_AT },
  })), /EUR rate must equal 1/);
});

test("unsupported securities, sentinels, wrong accounts, and empty non-flat ledgers cannot fabricate completeness", () => {
  const option = { ...stock("MSFT", 1030), secType: "OPT" };
  const optionFill = execution({ contract: option, execId: "INVALID.OPTION.01" });
  reason(calculateFamily(input({ executions: [optionFill] })), /unsupported family secType/);

  const stockContract = stock("MSFT", 1031);
  const sentinel = execution({ contract: stockContract, execId: "INVALID.SENTINEL.01", shares: Number.MAX_VALUE });
  reason(calculateFamily(input({ executions: [sentinel] })), /execution quantity/);

  const foreignAccountFill = execution({
    contract: stockContract,
    execId: "ACCOUNT.OTHER.01",
    account: OTHER_ACCOUNT,
  });
  const foreignIgnored = ok(calculateFamily(input({ executions: [foreignAccountFill] })));
  assert.equal(foreignIgnored.executionCount, 0);

  const joeOpen = execution({
    contract: stockContract,
    execId: "EMPTY.JOEOPEN.01",
    clientId: 22,
  });
  reason(calculateFamily(input({
    executions: [joeOpen],
    positions: [position(stockContract, 1)],
  })), /empty family ledger requires/);
});
