import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { calculateFamily } from "./family-ledger.mjs";
import {
  FAMILY_BASELINE_PERIOD_START,
  FAMILY_LEGACY_STATE_SCHEMA,
  FAMILY_STATE_SCHEMA,
  createFamilySessionAdapter,
  createFileFamilyStateStore,
} from "./family-state.mjs";

const ACCOUNT = "DU123456";
const FAMILY_IDS = [27, 28, 29, 50, 51, 52, 53, 54, 55, 56];
const CLASSIFIER = { familyClientIds: FAMILY_IDS, excludedSymbols: ["SXR8", "TSLA"] };
const EVENTS = {
  connected: "connected",
  disconnected: "disconnected",
  managedAccounts: "managedAccounts",
  updateAccountValue: "updateAccountValue",
  accountDownloadEnd: "accountDownloadEnd",
};

class FakeApi extends EventEmitter {
  calls = [];
  reqManagedAccts() { this.calls.push("reqManagedAccts"); }
}

class FakeHistory {
  queries = [];
  pending = [];
  stops = [];
  constructor(sessionId = "helper-a") { this.sessionId = sessionId; }
  query(request) {
    this.queries.push(structuredClone(request));
    return new Promise((resolve, reject) => this.pending.push({ resolve, reject }));
  }
  resolve(result) {
    this.sessionId = result.helperSessionId;
    this.pending.shift().resolve(result);
  }
  reject(error) { this.pending.shift().reject(error); }
  stop(reason) { this.stops.push(reason); }
}

function memoryStore(initial = null, legacy = null) {
  let state = initial ? structuredClone(initial) : null;
  let saves = 0;
  return {
    load() {
      return { ok: true, state: structuredClone(state), legacy: structuredClone(legacy) };
    },
    save(next) { state = structuredClone(next); saves += 1; },
    get state() { return structuredClone(state); },
    get saves() { return saves; },
  };
}

function contract(symbol = "ACME", conId = 101, code = "USD") {
  return { conId, symbol, secType: "STK", currency: code, multiplier: 1 };
}

function execution(execId, overrides = {}) {
  return {
    contract: contract(overrides.symbol, overrides.conId, overrides.currency),
    execution: {
      execId,
      time: overrides.time || "20260910 09:30:00 US/Eastern",
      acctNumber: ACCOUNT,
      clientId: overrides.clientId ?? 27,
      side: overrides.side || "BOT",
      shares: overrides.shares ?? 1,
      price: overrides.price ?? 10,
      pendingPriceRevision: overrides.pendingPriceRevision ?? false,
    },
  };
}

function commission(execId, amount = 0.25, code = "USD") {
  return { execId, commission: amount, currency: code };
}

function reply(request, perDay, options = {}) {
  const requests = request.specificDates.map((date, index) => ({
    date,
    requestedAt: options.requestedAt || `2026-09-${String(10 + index).padStart(2, "0")}T16:00:00Z`,
    endedAt: options.endedAt || `2026-09-${String(10 + index).padStart(2, "0")}T16:00:01Z`,
    executions: structuredClone(perDay[date] || []),
    errors: [],
  }));
  const all = requests.flatMap((item) => item.executions);
  return {
    schema: "inspr.ib.execution-query.result.v1",
    cycleId: request.cycleId,
    account: ACCOUNT,
    sdkVersion: options.sdkVersion || "10.40.01",
    serverVersion: options.serverVersion || 200,
    framing: "jsonl-v1",
    requests,
    commissions: options.commissions || all.map((row) => commission(row.execution.execId)),
    errors: [],
    finishedAt: options.finishedAt || options.endedAt || "2026-09-12T18:00:02Z",
    helperSessionId: options.helperSessionId || "helper-a",
  };
}

function calculator(args) {
  return {
    ok: true,
    equity: 5000 + args.executions.length,
    totalPnl: args.executions.length,
    realizedPnl: args.executions.length,
    unrealizedPnl: 0,
    positions: [],
    accounting: {
      periodStart: args.periodStart,
      method: "execution-fifo-net-current-fx",
      detail: "Net of recorded fees; converted at observed FX. Earlier results unavailable.",
    },
    observedAt: args.observedAt,
    executionCount: args.executions.length,
  };
}

function setup({ at = "2026-09-10T16:00:00Z", store = memoryStore(), calculate = calculator } = {}) {
  let clock = at;
  const history = new FakeHistory();
  const unavailable = [];
  const adapter = createFamilySessionAdapter({
    targetAccount: ACCOUNT,
    familyClientIds: FAMILY_IDS,
    excludedSymbols: ["SXR8", "TSLA"],
    calculateFamily: calculate,
    eventNames: EVENTS,
    store,
    history,
    now: () => clock,
    setTimer: () => 1,
    clearTimer: () => {},
    hooks: { onUnavailable: (reason) => unavailable.push(reason) },
  });
  return { adapter, history, store, unavailable, setNow(value) { clock = value; } };
}

function connect(session) {
  const api = new FakeApi();
  session.adapter.attach(api);
  api.emit(EVENTS.connected);
  api.emit(EVENTS.managedAccounts, ACCOUNT);
  return api;
}

function setFx(api, atValue = 1, usdValue = 0.85) {
  api.emit(EVENTS.updateAccountValue, "ExchangeRate", String(atValue), "EUR", ACCOUNT);
  api.emit(EVENTS.updateAccountValue, "ExchangeRate", String(usdValue), "USD", ACCOUNT);
  api.emit(EVENTS.accountDownloadEnd, ACCOUNT);
}

function book(observedAt = "2026-09-10T16:00:02Z") {
  return {
    summary: { NetLiquidation: { account: ACCOUNT, currency: "EUR", value: "10000" } },
    portfolio: [],
    positionsCoverage: { status: "complete", rows: [] },
    observedAt,
  };
}

async function flush() {
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setImmediate(resolve));
}

async function bootstrap(session, rows = [execution("anchor.01")], options = {}) {
  const api = connect(session);
  const request = session.history.queries.at(-1);
  session.history.resolve(reply(request, { 20260910: rows }, options));
  await flush();
  return api;
}

test("Node requests only official account-scoped history and preserves multiplier normalization", async () => {
  const session = setup();
  const api = connect(session);
  assert.deepEqual(api.calls, ["reqManagedAccts"]);
  assert.equal(typeof api.reqExecutions, "undefined");
  assert.deepEqual(session.history.queries[0], {
    schema: "inspr.ib.execution-query.request.v1",
    cycleId: "family-history-1-1",
    account: ACCOUNT,
    specificDates: ["20260910"],
  });
  const row = execution("anchor.01");
  row.contract.multiplier = 0;
  session.history.resolve(reply(session.history.queries[0], { 20260910: [row] }));
  await flush();
  assert.equal(session.store.state.schema, FAMILY_STATE_SCHEMA);
  assert.equal(session.store.state.executions[0].contract.multiplier, 1);
});

test("unrelated CASH and OPT executions persist and reload without blocking family J", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "family-v2-unrelated-contracts-"));
  const activePath = path.join(directory, "family-ledger-v2.json");
  const store = createFileFamilyStateStore(activePath);
  const session = setup({ store, calculate: calculateFamily });
  const api = connect(session);
  const familyOpen = execution("family-open.01", { side: "BUY" });
  const familyClose = execution("family-close.01", { side: "SELL", price: 11 });
  const cash = execution("joe-cash.01", { clientId: 22 });
  cash.contract = { conId: 202, symbol: "EUR.USD", secType: "CASH", currency: "USD", multiplier: "" };
  const option = execution("joe-option.01", { clientId: 22 });
  option.contract = { conId: 203, symbol: "ACME", secType: "OPT", currency: "USD", multiplier: "not-numeric" };
  const request = session.history.queries[0];
  session.history.resolve(reply(request, {
    20260910: [familyOpen, familyClose, cash, option],
  }));
  await flush();
  setFx(api);
  const projected = session.adapter.project(book());
  assert.equal(projected.ok, true, projected.reason);

  const loaded = store.load({
    account: ACCOUNT, periodStart: FAMILY_BASELINE_PERIOD_START, classifier: CLASSIFIER,
  });
  assert.equal(loaded.ok, true);
  const unrelated = loaded.state.executions
    .filter((row) => row.execution.clientId === 22)
    .map((row) => row.contract);
  assert.deepEqual(unrelated, [cash.contract, option.contract]);
});

test("a non-STK family execution persists but family projection fails closed", async () => {
  let ledgerReason = null;
  const session = setup({ calculate(args) {
    const result = calculateFamily(args);
    ledgerReason = result.reason || null;
    return result;
  } });
  const api = connect(session);
  const familyOpen = execution("family-open.01", { side: "BUY" });
  const familyClose = execution("family-close.01", { side: "SELL", price: 11 });
  const unsupported = execution("family-option.01", { clientId: 27 });
  unsupported.contract = {
    conId: 204, symbol: "ACME", secType: "OPT", currency: "USD", multiplier: "100",
  };
  const request = session.history.queries[0];
  session.history.resolve(reply(request, {
    20260910: [familyOpen, familyClose, unsupported],
  }));
  await flush();
  assert.equal(session.store.state.executions.length, 3);
  setFx(api);
  const projected = session.adapter.project(book());
  assert.equal(projected.ok, false);
  assert.match(ledgerReason, /unsupported family secType/);
});

test("New York dates, not the Vienna calendar day, bound exact-date requests", () => {
  const session = setup({ at: "2026-09-11T03:30:00Z" });
  connect(session);
  assert.deepEqual(session.history.queries[0].specificDates, ["20260910"]);
});

test("cross-midnight replay merges a missed net-zero roundtrip before advancing", async () => {
  const session = setup();
  const api = await bootstrap(session);
  session.setNow("2026-09-11T04:01:00Z");
  assert.equal(session.adapter.pollNow(), true);
  const request = session.history.queries.at(-1);
  assert.deepEqual(request.specificDates, ["20260910", "20260911"]);
  const buy = execution("roundtrip.buy.01", { time: "20260910 20:00:00 US/Eastern" });
  const sell = execution("roundtrip.sell.01", { time: "20260910 20:01:00 US/Eastern", side: "SLD" });
  session.history.resolve(reply(request, {
    20260910: [execution("anchor.01"), buy, sell],
    20260911: [],
  }, { endedAt: "2026-09-11T04:01:02Z" }));
  await flush();
  assert.equal(session.store.state.executions.length, 3);
  assert.equal(session.store.state.coverage.throughDay, "2026-09-11");
  assert.equal(session.store.state.coverage.historyEvidence.status, "cross_midnight");
  setFx(api);
  assert.equal(session.adapter.project(book()).ok, true);
});

test("one helper session carries a returned Friday anchor across empty weekend days", async () => {
  const session = setup();
  await bootstrap(session);
  const friday = execution("friday.01", { time: "20260911 00:00:10 US/Eastern" });

  session.setNow("2026-09-11T04:01:00Z");
  session.adapter.pollNow();
  let request = session.history.queries.at(-1);
  session.history.resolve(reply(request, { 20260910: [execution("anchor.01")], 20260911: [friday] }, {
    requestedAt: "2026-09-11T04:01:00Z", endedAt: "2026-09-11T04:01:01Z",
  }));
  await flush();

  session.setNow("2026-09-12T04:01:00Z");
  session.adapter.pollNow();
  request = session.history.queries.at(-1);
  assert.deepEqual(request.specificDates, ["20260911", "20260912"]);
  session.history.resolve(reply(request, { 20260911: [friday], 20260912: [] }, {
    requestedAt: "2026-09-12T04:01:00Z", endedAt: "2026-09-12T04:01:01Z",
  }));
  await flush();

  session.setNow("2026-09-13T04:01:00Z");
  session.adapter.pollNow();
  request = session.history.queries.at(-1);
  assert.deepEqual(request.specificDates, ["20260911", "20260912", "20260913"]);
  session.history.resolve(reply(request, { 20260911: [friday], 20260912: [], 20260913: [] }, {
    requestedAt: "2026-09-13T04:01:00Z", endedAt: "2026-09-13T04:01:01Z",
  }));
  await flush();
  assert.equal(session.adapter.blockedReason, null);
  assert.equal(session.store.state.coverage.throughDay, "2026-09-13");
});

test("a restarted Monday session anchors on an already accepted Monday fill", async () => {
  const session = setup();
  await bootstrap(session);
  const monday = execution("monday.01", { time: "20260914 09:30:00 US/Eastern" });
  session.setNow("2026-09-14T14:00:00Z");
  session.adapter.pollNow();
  let request = session.history.queries.at(-1);
  session.history.resolve(reply(request, {
    20260910: [execution("anchor.01")],
    20260911: [], 20260912: [], 20260913: [], 20260914: [monday],
  }, { requestedAt: "2026-09-14T14:00:00Z", endedAt: "2026-09-14T14:00:01Z" }));
  await flush();
  assert.equal(session.store.state.coverage.throughDay, "2026-09-14");

  session.history.sessionId = "helper-b";
  session.adapter.pollNow();
  request = session.history.queries.at(-1);
  assert.deepEqual(request.specificDates, ["20260914"]);
  session.history.resolve(reply(request, { 20260914: [monday] }, {
    helperSessionId: "helper-b",
    requestedAt: "2026-09-14T14:01:00Z", endedAt: "2026-09-14T14:01:01Z",
  }));
  await flush();
  assert.equal(session.adapter.blockedReason, null);
  assert.equal(session.store.state.coverage.historyEvidence.helperSessionId, "helper-b");
});

test("missing prior identities, unanchored recovery, and missing family fees fail closed", async () => {
  const seeded = setup();
  await bootstrap(seeded);
  seeded.setNow("2026-09-11T04:01:00Z");
  seeded.adapter.pollNow();
  let request = seeded.history.queries.at(-1);
  seeded.history.resolve(reply(request, { 20260910: [], 20260911: [] }));
  await flush();
  assert.match(seeded.adapter.blockedReason, /retention_loss/);
  assert.equal(seeded.store.state.coverage.throughDay, "2026-09-10");

  const feeSession = setup();
  connect(feeSession);
  request = feeSession.history.queries[0];
  feeSession.history.resolve(reply(request, { 20260910: [execution("anchor.01")] }, { commissions: [] }));
  await flush();
  assert.match(feeSession.unavailable.at(-1), /missing fees/);
  assert.equal(feeSession.store.saves, 0);
});

test("helper or server changes require a replayed pre-gap anchor", async () => {
  const session = setup();
  await bootstrap(session);
  session.adapter.pollNow();
  let request = session.history.queries.at(-1);
  session.history.resolve(reply(request, { 20260910: [execution("later.01", { time: "20260910 15:00:00 US/Eastern" })] }, {
    helperSessionId: "helper-b",
  }));
  await flush();
  assert.match(session.adapter.blockedReason, /retention_loss/);

  const server = setup({ store: memoryStore(session.store.state) });
  connect(server);
  request = server.history.queries[0];
  server.history.resolve(reply(request, { 20260910: [execution("later.01", { time: "20260910 15:00:00 US/Eastern" })] }, {
    helperSessionId: "helper-a",
    serverVersion: 201,
  }));
  await flush();
  assert.match(server.adapter.blockedReason, /retention_loss/);
});

test("a sufficiently old replay anchor closes an over-24-hour exact-date gap", async () => {
  const session = setup();
  await bootstrap(session);
  session.setNow("2026-09-12T18:00:00Z");
  session.adapter.pollNow();
  const request = session.history.queries.at(-1);
  assert.deepEqual(request.specificDates, ["20260910", "20260911", "20260912"]);
  session.history.resolve(reply(request, {
    20260910: [execution("anchor.01")],
    20260911: [],
    20260912: [],
  }, { endedAt: "2026-09-12T18:00:01Z", helperSessionId: "helper-b" }));
  await flush();
  assert.equal(session.store.state.coverage.historyEvidence.status, "over_24h");
  assert.equal(session.store.state.coverage.throughDay, "2026-09-12");
});

test("an outage beyond bounded exact-date capacity leaves durable coverage untouched", async () => {
  const session = setup();
  await bootstrap(session);
  const before = session.store.state;
  session.setNow("2026-10-20T16:00:00Z");
  assert.equal(session.adapter.pollNow(), false);
  assert.match(session.adapter.blockedReason, /retention_loss/);
  assert.equal(session.history.queries.length, 1);
  assert.deepEqual(session.store.state, before);
});

test("higher corrections and their fees merge without dropping prior revisions", async () => {
  const original = execution("correction.01");
  const missingFee = setup();
  await bootstrap(missingFee, [original]);
  missingFee.adapter.pollNow();
  let request = missingFee.history.queries.at(-1);
  const corrected = execution("correction.02", { price: 11 });
  missingFee.history.resolve(reply(request, { 20260910: [corrected] }, { commissions: [] }));
  await flush();
  assert.match(missingFee.unavailable.at(-1), /missing fees/);
  assert.deepEqual(missingFee.store.state.executions.map((row) => row.execution.execId), ["correction.01"]);

  const session = setup();
  await bootstrap(session, [original]);
  session.adapter.pollNow();
  request = session.history.queries.at(-1);
  session.history.resolve(reply(request, { 20260910: [corrected] }, {
    commissions: [commission("correction.02", 0.3)],
  }));
  await flush();
  assert.deepEqual(session.store.state.executions.map((row) => row.execution.execId), [
    "correction.01", "correction.02",
  ]);
  assert.deepEqual(session.store.state.commissions.map((row) => row.execId), [
    "correction.01", "correction.02",
  ]);
});

test("an obsolete pending-price revision does not pin the seven-date recovery window", async () => {
  const pending = execution("px.01", { pendingPriceRevision: true });
  const corrected = execution("px.02", { price: 11, pendingPriceRevision: false });
  const session = setup();
  await bootstrap(session, [pending]);
  session.adapter.pollNow();
  let request = session.history.queries.at(-1);
  session.history.resolve(reply(request, { 20260910: [corrected] }));
  await flush();

  const friday = execution("friday.01", { time: "20260911 09:30:00 US/Eastern" });
  session.setNow("2026-09-11T16:00:00Z");
  session.adapter.pollNow();
  request = session.history.queries.at(-1);
  session.history.resolve(reply(request, { 20260910: [corrected], 20260911: [friday] }));
  await flush();

  const saturday = execution("saturday.01", { time: "20260912 09:30:00 US/Eastern" });
  session.setNow("2026-09-12T16:00:00Z");
  session.adapter.pollNow();
  request = session.history.queries.at(-1);
  session.history.resolve(reply(request, { 20260911: [friday], 20260912: [saturday] }, {
    requestedAt: "2026-09-12T16:00:00Z", endedAt: "2026-09-12T16:00:01Z",
  }));
  await flush();

  session.setNow("2026-09-17T16:00:00Z");
  assert.equal(session.adapter.pollNow(), true);
  request = session.history.queries.at(-1);
  assert.deepEqual(request.specificDates, [
    "20260912", "20260913", "20260914", "20260915", "20260916", "20260917",
  ]);
  session.history.resolve(reply(request, {
    20260912: [saturday],
    20260913: [], 20260914: [], 20260915: [], 20260916: [], 20260917: [],
  }, { requestedAt: "2026-09-17T16:00:00Z", endedAt: "2026-09-17T16:00:01Z" }));
  await flush();
  assert.equal(session.adapter.blockedReason, null);
  assert.equal(session.store.state.coverage.throughDay, "2026-09-17");
});

test("disconnect invalidates helper history while leaving the adapter non-throwing", async () => {
  const session = setup();
  const api = await bootstrap(session);
  api.emit(EVENTS.disconnected);
  assert.equal(session.history.stops.at(-1), "Node broker disconnected");
  assert.equal(session.adapter.project(book()).ok, false);
  assert.match(session.adapter.project(book()).reason, /broker disconnected/);
});

function legacyState(rows, reports = rows.map((row) => commission(row.execution.execId)), family = null) {
  const observedAt = "2026-09-10T16:00:01.000Z";
  const projection = family || calculator({ executions: rows, periodStart: FAMILY_BASELINE_PERIOD_START, observedAt });
  return {
    schema: FAMILY_LEGACY_STATE_SCHEMA,
    version: 1,
    account: ACCOUNT,
    periodStart: FAMILY_BASELINE_PERIOD_START,
    classifier: CLASSIFIER,
    initializedAt: observedAt,
    ledgerObservedAt: observedAt,
    coverageThrough: observedAt,
    coverageTradingDay: "2026-09-10",
    queryExecutionIdentities: rows.map((row) => row.execution.execId).sort(),
    executions: rows,
    commissions: reports,
    family: projection,
  };
}

test("v1 migration preserves bytes, proves official overlap, and detects later backup change", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "family-v2-test-"));
  const legacyPath = path.join(directory, "family-ledger.json");
  const activePath = path.join(directory, "family-ledger-v2.json");
  const row = execution("anchor.01");
  const legacyBytes = `${JSON.stringify(legacyState([row]), null, 2)}\n`;
  fs.writeFileSync(legacyPath, legacyBytes, { mode: 0o600 });
  const store = createFileFamilyStateStore(activePath, { legacyPath });
  const session = setup({ store });
  const api = connect(session);
  const request = session.history.queries[0];
  session.history.resolve(reply(request, { 20260910: [row] }));
  await flush();
  setFx(api);
  assert.equal(session.adapter.project(book()).ok, true);
  assert.equal(fs.readFileSync(legacyPath, "utf8"), legacyBytes);
  assert.equal(store.load({ account: ACCOUNT, periodStart: FAMILY_BASELINE_PERIOD_START, classifier: CLASSIFIER }).ok, true);
  const parkedPath = `${activePath}.parked`;
  fs.renameSync(activePath, parkedPath);
  const missing = store.load({ account: ACCOUNT, periodStart: FAMILY_BASELINE_PERIOD_START, classifier: CLASSIFIER });
  assert.equal(missing.ok, false);
  assert.match(missing.reason, /missing after migration activation/);
  fs.renameSync(parkedPath, activePath);

  fs.appendFileSync(legacyPath, " ");
  const changed = store.load({ account: ACCOUNT, periodStart: FAMILY_BASELINE_PERIOD_START, classifier: CLASSIFIER });
  assert.equal(changed.ok, false);
  assert.match(changed.reason, /changed after migration/);
});

function realFamilyProjection(rows, reports, observedAt) {
  return calculateFamily({
    executions: rows,
    commissions: reports,
    portfolio: [],
    positions: [],
    fx: { baseCurrency: "EUR", rates: { EUR: 1, USD: 0.85 }, observedAt },
    account: ACCOUNT,
    familyClientIds: FAMILY_IDS,
    excludedSymbols: ["SXR8", "TSLA"],
    periodStart: FAMILY_BASELINE_PERIOD_START,
    virtualEquity: 5000,
    observedAt,
  });
}

test("real FIFO migration accepts BUY/SELL aliases plus a new completed roundtrip", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "family-v2-real-"));
  const legacyPath = path.join(directory, "family-ledger.json");
  const activePath = path.join(directory, "family-ledger-v2.json");
  const oldRows = [
    execution("anchor.01", { side: "BOT", time: "20260910 09:30:00 US/Eastern" }),
    execution("old-close.01", { side: "SLD", time: "20260910 09:31:00 US/Eastern", price: 10.5 }),
  ];
  const oldFees = oldRows.map((row) => commission(row.execution.execId));
  const oldFamily = realFamilyProjection(oldRows, oldFees, "2026-09-10T16:00:01.000Z");
  const legacyBytes = `${JSON.stringify(legacyState(oldRows, oldFees, oldFamily), null, 2)}\n`;
  fs.writeFileSync(legacyPath, legacyBytes, { mode: 0o600 });

  const officialOld = oldRows.map((row) => ({
    ...structuredClone(row),
    execution: {
      ...structuredClone(row.execution),
      side: row.execution.side === "BOT" ? "BUY" : "SELL",
    },
  }));
  const newRows = [
    execution("new-open.01", { side: "BUY", time: "20260910 13:00:00 US/Eastern", price: 20 }),
    execution("new-close.01", { side: "SELL", time: "20260910 13:01:00 US/Eastern", price: 21 }),
  ];
  const allRows = [...officialOld, ...newRows];
  const allFees = allRows.map((row) => commission(row.execution.execId));
  const store = createFileFamilyStateStore(activePath, { legacyPath });
  const session = setup({ at: "2026-09-10T20:01:00Z", store, calculate: calculateFamily });
  const api = connect(session);
  const request = session.history.queries[0];
  session.history.resolve(reply(request, { 20260910: allRows }, {
    requestedAt: "2026-09-10T20:00:00Z",
    endedAt: "2026-09-10T20:00:01Z",
    commissions: allFees,
  }));
  await flush();
  setFx(api);
  const projected = session.adapter.project(book("2026-09-10T20:01:00Z"));
  assert.equal(projected.ok, true);
  assert.equal(projected.executionCount, 4);
  assert.equal(store.load({ account: ACCOUNT, periodStart: FAMILY_BASELINE_PERIOD_START, classifier: CLASSIFIER }).state.executions.length, 4);
  assert.equal(fs.readFileSync(legacyPath, "utf8"), legacyBytes);
});

test("v1 migration preserves unrelated non-stock rows without feeding them to family FIFO", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "family-v2-nonstock-migration-"));
  const legacyPath = path.join(directory, "family-ledger.json");
  const activePath = path.join(directory, "family-ledger-v2.json");
  const familyRows = [
    execution("family-open.01", { side: "BUY" }),
    execution("family-close.01", { side: "SELL", price: 11 }),
  ];
  const cash = execution("joe-cash.01", { clientId: 22 });
  cash.contract = { conId: 202, symbol: "EUR.USD", secType: "CASH", currency: "USD", multiplier: "" };
  const option = execution("joe-option.01", { clientId: 22 });
  option.contract = { conId: 203, symbol: "ACME", secType: "OPT", currency: "USD", multiplier: "not-numeric" };
  const legacyRows = [...familyRows, cash, option];
  const reports = legacyRows.map((row) => commission(row.execution.execId));
  const observedAt = "2026-09-10T16:00:01.000Z";
  const family = realFamilyProjection(
    familyRows,
    reports.filter((row) => row.execId.startsWith("family-")),
    observedAt
  );
  const legacyBytes = `${JSON.stringify(legacyState(legacyRows, reports, family), null, 2)}\n`;
  fs.writeFileSync(legacyPath, legacyBytes, { mode: 0o600 });

  const store = createFileFamilyStateStore(activePath, { legacyPath });
  const session = setup({ store, calculate: calculateFamily });
  const api = connect(session);
  const request = session.history.queries[0];
  session.history.resolve(reply(request, { 20260910: legacyRows }, { commissions: reports }));
  await flush();
  setFx(api);
  const projected = session.adapter.project(book());
  assert.equal(projected.ok, true, projected.reason);
  assert.equal(fs.readFileSync(legacyPath, "utf8"), legacyBytes);
  const loaded = store.load({
    account: ACCOUNT, periodStart: FAMILY_BASELINE_PERIOD_START, classifier: CLASSIFIER,
  });
  assert.equal(loaded.ok, true);
  assert.deepEqual(
    loaded.state.executions.filter((row) => row.execution.clientId === 22).map((row) => row.contract),
    [cash.contract, option.contract]
  );
});

test("migration rejects a conflicting official replay of an old legacy execution", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "family-v2-conflict-"));
  const legacyPath = path.join(directory, "family-ledger.json");
  const activePath = path.join(directory, "family-ledger-v2.json");
  const old = execution("anchor.01", { side: "BOT" });
  fs.writeFileSync(legacyPath, `${JSON.stringify(legacyState([old]), null, 2)}\n`, { mode: 0o600 });
  const store = createFileFamilyStateStore(activePath, { legacyPath });
  const session = setup({ store });
  connect(session);
  const conflicting = execution("anchor.01", { side: "BUY", price: 99 });
  const request = session.history.queries[0];
  session.history.resolve(reply(request, { 20260910: [conflicting] }));
  await flush();
  assert.match(session.adapter.blockedReason, /conflicting execution/);
  assert.equal(fs.existsSync(activePath), false);
});

test("malformed active state blocks startup", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "family-v2-bad-"));
  const activePath = path.join(directory, "family-ledger-v2.json");
  fs.writeFileSync(activePath, "{bad json\n", { mode: 0o600 });
  const store = createFileFamilyStateStore(activePath);
  const adapter = setup({ store }).adapter;
  assert.match(adapter.blockedReason, /v2 state is invalid/);
});

test("cached execution-time validation cannot hide changed or corrupt state", async () => {
  const seeded = setup();
  await bootstrap(seeded);
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "family-v2-time-cache-"));
  const activePath = path.join(directory, "family-ledger-v2.json");
  const store = createFileFamilyStateStore(activePath);
  store.save(seeded.store.state);
  const load = () => store.load({
    account: ACCOUNT, periodStart: FAMILY_BASELINE_PERIOD_START, classifier: CLASSIFIER,
  });
  assert.equal(load().ok, true);

  const changed = structuredClone(seeded.store.state);
  changed.executions[0].execution.time = "20260910 10:30:00 US/Eastern";
  fs.writeFileSync(activePath, `${JSON.stringify(changed)}\n`, { mode: 0o600 });
  assert.match(load().reason, /anchor is absent/);

  const corrupt = structuredClone(seeded.store.state);
  corrupt.executions[0].execution.time = "20261101 01:30:00 US/Eastern";
  fs.writeFileSync(activePath, `${JSON.stringify(corrupt)}\n`, { mode: 0o600 });
  assert.match(load().reason, /invalid or ambiguous/);
});
