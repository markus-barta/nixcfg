import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { Readable } from "node:stream";
import test from "node:test";

import { createMarketData, MARKET_DATA_CLIENT_ID } from "./market-data.mjs";
import { assertContract, resolveStock } from "./ib.mjs";
import { DESKS } from "./policy.mjs";
import { createServer } from "./server.mjs";

const events = Object.fromEntries([
  "error", "connected", "disconnected", "nextValidId", "contractDetails", "contractDetailsEnd",
  "marketDataType", "tickPrice", "tickSnapshotEnd", "historicalData", "historicalDataEnd",
].map((name) => [name, name]));
const OPEN_TIME = Date.parse("2026-10-12T18:00:00Z");
const defaults = [[66, 100], [67, 101], [68, 100.5], [75, 99]];
const READ_ONLY_METHODS = new Set([
  "on", "off", "connect", "disconnect", "reqContractDetails", "reqMarketDataType",
  "reqMktData", "cancelMktData", "reqHistoricalData", "cancelHistoricalData",
]);
async function flushMicrotasks() {
  for (let index = 0; index < 20; index += 1) await Promise.resolve();
}
function bars(count = 30) {
  const start = Date.parse("2026-10-12T13:30:00Z") / 1000;
  return Array.from({ length: count }, (_, index) => [String(start + index * 300), 100 + index, 102 + index, 99 + index, 101 + index, 10 + index]);
}

function fakeRuntime(options = {}) {
  const broker = {
    connections: [], instances: [], live: new Set(), forbidden: [], lookups: [], types: [], quotes: [], histories: [],
    cancelledQuotes: [], cancelledHistories: [], connectionTimes: [], disconnectionTimes: [],
    maxLive: 0, contractIds: new Map(), ...options,
  };
  class FakeIB extends EventEmitter {
    constructor({ clientId, host, port }) {
      super();
      assert.equal(host, "100.64.0.6"); assert.equal(port, 4002);
      this.clientId = clientId;
      broker.instances.push(this);
      // Bind allowed methods to the emitter so test callbacks can simulate IB;
      // the production-facing proxy rejects every other property/method.
      return new Proxy(this, {
        get(target, name) {
          if (!READ_ONLY_METHODS.has(name)) {
            broker.forbidden.push(String(name));
            assert.fail(`read-only runtime accessed unapproved IB method ${String(name)}`);
          }
          return target[name].bind(target);
        },
      });
    }
    connect() {
      assert.equal(broker.live.has(this.clientId), false, "duplicate live client ID");
      broker.connections.push(this.clientId); broker.live.add(this.clientId);
      broker.connectionTimes.push(Date.now());
      broker.maxLive = Math.max(broker.maxLive, broker.live.size);
      broker.onConnect?.(this);
      const code = broker.connectErrors?.shift();
      if (code) { this.emit(events.error, new Error("connection diagnostic"), code, -1); return; }
      this.emit(events.connected);
      if (!broker.noReady) this.emit(events.nextValidId, 9000);
    }
    disconnect() {
      broker.disconnectionTimes.push(Date.now());
      broker.live.delete(this.clientId); this.emit(events.disconnected);
    }
    reqContractDetails(id, request) {
      broker.lookups.push({ id, request });
      if (broker.lookupError) { this.emit(events.error, new Error("contract diagnostic"), broker.lookupError, id); return; }
      if (broker.noLookupEnd) return;
      if (request.symbol !== "UNKNOWN" && !broker.noContract) {
        if (!broker.contractIds.has(request.symbol)) broker.contractIds.set(request.symbol, broker.contractIds.size + 1);
        const contract = { ...request, conId: broker.contractIds.get(request.symbol), ...broker.contractOverride };
        const value = { contract, stockType: "COMMON", timeZoneId: "US/Eastern", liquidHours: broker.liquidHours || "" };
        this.emit(events.contractDetails, id, value);
        if (broker.ambiguous) this.emit(events.contractDetails, id, value);
      }
      this.emit(events.contractDetailsEnd, id);
    }
    reqMarketDataType(type) { this.dataType = type; broker.types.push(type); }
    reqMktData(id, contract, genericTicks, snapshot, regulatorySnapshot) {
      assert.equal(snapshot, true, "data path must never stream");
      assert.equal(regulatorySnapshot, false, "no regulatory snapshots");
      assert.equal(genericTicks, "");
      broker.quotes.push({ id, contract, type: this.dataType });
      broker.onQuote?.(this, id);
      if (broker.hungQuote) return;
      this.emit(events.marketDataType, id + 99, 1); // Ignore another request's callback.
      if (!broker.noType) this.emit(events.marketDataType, id, broker.actualType ?? this.dataType);
      if (broker.quoteError) this.emit(events.error, new Error(broker.errorMessage || "broker diagnostic"), broker.quoteError, id);
      const prices = broker.pricesForType ? broker.pricesForType(this.dataType) : broker.prices ?? defaults;
      for (const [field, value] of prices) this.emit(events.tickPrice, id, field, value);
      if (!broker.noQuoteEnd) this.emit(events.tickSnapshotEnd, id);
    }
    cancelMktData(id) { broker.cancelledQuotes.push(id); this.emit(events.error, new Error("finished snapshot"), 300, id); }
    reqHistoricalData(id, contract, end, duration, size, what, rth, format, keepUpToDate) {
      assert.equal(end, ""); assert.equal(size, "5 mins"); assert.equal(what, "TRADES");
      assert.equal(rth, 1); assert.equal(format, 2); assert.equal(keepUpToDate, false);
      broker.histories.push({ id, contract, duration, size, what, rth, format, keepUpToDate });
      broker.onHistory?.(this, id);
      if (broker.historyError) { this.emit(events.error, new Error(broker.errorMessage || "historical data unavailable"), broker.historyError, id); return; }
      for (const row of broker.bars ?? bars()) this.emit(events.historicalData, id, ...row);
      if (!broker.noHistoryEnd) {
        if (broker.legacyHistory) this.emit(events.historicalData, id, "finished-start-end", -1, -1, -1, -1, -1, -1, -1, false);
        else this.emit(events.historicalDataEnd, id, "start", "end");
      }
    }
    cancelHistoricalData(id) { broker.cancelledHistories.push(id); this.emit(events.error, new Error("finished history"), 366, id); }
  }
  const names = { ...events };
  if (broker.legacyHistory) delete names.historicalDataEnd;
  return { broker, runtime: { IBApi: FakeIB, EventName: names } };
}

function fixture(options = {}) {
  const { broker, runtime } = fakeRuntime(options.broker);
  let time = options.time ?? OPEN_TIME;
  const audit = [];
  const app = createServer({
    testMode: true, listenHost: "127.0.0.1", listenPort: 0, gatewayPort: 4002, gatewayHost: "100.64.0.6",
    allowlist: ["127.0.0.1"], stateDir: mkdtempSync(path.join(tmpdir(), "ops311-market-data-")),
    marketData: { runtime, now: () => time, timeoutMs: 250, reconnectDelayMs: 0, ...options.marketData },
    marketDataAudit: (row) => audit.push(row), ...options.server,
  });
  async function request(url, { method = "GET", body, peer = "127.0.0.1", onResponse } = {}) {
    const req = Readable.from(body ? [Buffer.from(JSON.stringify(body))] : []);
    req.method = method; req.url = url; req.headers = { "x-forwarded-for": "127.0.0.1" }; req.socket = { remoteAddress: peer };
    let status; let result;
    const response = Object.assign(new EventEmitter(), {
      destroyed: false, writableEnded: false,
      writeHead(code) { status = code; },
      end(value) { result = JSON.parse(value); this.writableEnded = true; this.emit("close"); },
    });
    onResponse?.(response, req);
    await app.handle(req, response);
    // A forbidden call must fail the test even if the API maps it to a 503.
    assert.deepEqual(broker.forbidden, []);
    return { status, body: result };
  }
  return { app, broker, runtime, audit, request, advance: (ms) => { time += ms; } };
}
const quoteUrl = (symbol = "AAPL", desk = "j") => `/v1/quote?symbol=${symbol}&desk=${desk}`;
const barsUrl = (symbol = "AAPL", count = 24, desk = "j") => `/v1/bars?symbol=${symbol}&desk=${desk}&count=${count}`;
function reconIntent(id = "j-data-isolation") {
  return { schema: "barta.paper-desk-intent.v2", intentId: id, desk: "j", action: "recon", createdAt: new Date(Date.now() - 1000).toISOString(), expiresAt: new Date(Date.now() + 60_000).toISOString() };
}

test("read-only proxy rejects unlisted and future IB methods", () => {
  const { broker, runtime } = fakeRuntime();
  const api = new runtime.IBApi({ host: "100.64.0.6", port: 4002, clientId: 707 });
  for (const name of ["placeOrder", "reqPositions", "futureBrokerWrite"]) {
    assert.throws(() => api[name](), /unapproved IB method/);
  }
  assert.deepEqual(broker.forbidden, ["placeOrder", "reqPositions", "futureBrokerWrite"]);
  assert.equal(broker.connections.length, 0);
});

test("quote returns an isolated delayed snapshot and releases the IB request", async () => {
  const h = fixture();
  assert.deepEqual(await h.request(quoteUrl()), { status: 200, body: {
    symbol: "AAPL", conId: 1, bid: 100, ask: 101, last: 100.5, close: 99,
    marketDataType: "delayed", observedAt: new Date(OPEN_TIME).toISOString(), source: "ib", cached: false,
  } });
  assert.deepEqual(h.broker.connections, [MARKET_DATA_CLIENT_ID]);
  assert.deepEqual(h.broker.lookups[0].request, { symbol: "AAPL", secType: "STK", exchange: "SMART", currency: "USD" });
  assert.equal(h.broker.cancelledQuotes.length, 1); assert.equal(h.broker.live.size, 0);
  assert.deepEqual(h.broker.forbidden, []);
  const api = h.broker.instances[0];
  for (const name of Object.values(events).filter((name) => name !== "error")) assert.equal(api.listenerCount(name), 0, name);
});

test("bars return the newest N sorted, deduplicated five-minute UTC bars", async () => {
  const rows = bars(5);
  const h = fixture({ broker: { bars: [rows[4], rows[1], rows[0], rows[3], rows[2], rows[4]] } });
  const result = await h.request(barsUrl("AAPL", 3));
  assert.equal(result.status, 200); assert.equal(result.body.barSize, "5m"); assert.equal(result.body.cached, false);
  assert.deepEqual(result.body.bars, rows.slice(-3).map(([t, o, high, l, c, v]) => ({ t: new Date(Number(t) * 1000).toISOString(), o, h: high, l, c, v })));
  assert.deepEqual(h.broker.connections, [707]); assert.equal(h.broker.cancelledHistories.length, 1);
  assert.deepEqual(h.broker.types, [], "historical requests do not set a market data type");
  assert.deepEqual(h.broker.forbidden, []);
});

test("history without a data-type call fails closed on IB 162 and does not cache the failure", async () => {
  const h = fixture({ broker: { historyError: 162, errorMessage: "no market data permissions" } });
  const failed = await h.request(barsUrl());
  assert.equal(failed.status, 503); assert.match(failed.body.reason, /historical data permissions.*162/);
  assert.deepEqual(h.broker.types, []);
  assert.deepEqual(h.broker.cancelledHistories, [h.broker.histories[0].id]);
  assert.equal(h.broker.live.size, 0);
  h.advance(15_000);
  h.broker.historyError = null;
  const fresh = await h.request(barsUrl());
  assert.equal(fresh.status, 200); assert.equal(fresh.body.cached, false);
  assert.equal(h.broker.histories.length, 2); assert.deepEqual(h.broker.types, []);
});

test("legacy finished rows complete history without an exported historicalDataEnd event", async () => {
  const h = fixture({ broker: { legacyHistory: true } });
  const result = await h.request(barsUrl("AAPL", 3));
  assert.equal(result.status, 200); assert.equal(result.body.bars.length, 3);
  assert.equal(h.broker.live.size, 0); assert.equal(h.broker.cancelledHistories.length, 1);
});

test("bars default to 24, allow 78 and choose a duration including session gaps", async () => {
  const standard = fixture({ broker: { bars: bars(90) } });
  const result = await standard.request("/v1/bars?symbol=AAPL&desk=j");
  assert.equal(result.body.bars.length, 24); assert.equal(standard.broker.histories[0].duration, "7200 S");
  const fullSession = fixture({ broker: { bars: bars(90) } });
  assert.equal((await fullSession.request(barsUrl("AAPL", 78))).body.bars.length, 78);
  assert.equal(fullSession.broker.histories[0].duration, "3 D"); // Monday needs Friday's remaining bars.
  const weekend = fixture({ time: Date.parse("2026-10-11T18:00:00Z") });
  assert.equal((await weekend.request(barsUrl("AAPL", 24))).status, 200);
  assert.equal(weekend.broker.histories[0].duration, "2 D");
});

test("IB can return fewer bars without inventing any", async () => {
  const h = fixture({ broker: { bars: bars(2) } });
  assert.equal((await h.request(barsUrl())).body.bars.length, 2);
  assert.equal((await h.request(barsUrl("AAPL", 20))).body.cached, true);
  assert.equal(h.broker.histories.length, 1);
});

test("quote cache is per symbol across desks and expires at 15 seconds", async () => {
  const h = fixture();
  const first = await h.request(quoteUrl());
  h.advance(14_999);
  const hit = await h.request(quoteUrl("AAPL", "joe"));
  assert.equal(hit.body.cached, true); assert.equal(hit.body.observedAt, first.body.observedAt);
  assert.equal(h.broker.quotes.length, 1);
  h.advance(1);
  assert.equal((await h.request(quoteUrl())).body.cached, false); assert.equal(h.broker.quotes.length, 2);
});

test("bars cache serves smaller counts across desks and expires at 60 seconds", async () => {
  const h = fixture();
  await h.request(barsUrl());
  h.advance(59_999);
  const hit = await h.request(barsUrl("AAPL", 2, "joel"));
  assert.equal(hit.body.cached, true); assert.equal(hit.body.bars.length, 2);
  assert.equal(h.broker.histories.length, 1);
  h.advance(1);
  assert.equal((await h.request(barsUrl())).body.cached, false); assert.equal(h.broker.histories.length, 2);
});

test("forming bars are marked at receipt and cached snapshots preserve the flag", async () => {
  const rows = [OPEN_TIME - 300_000, OPEN_TIME].map((time) => [String(time / 1000), 100, 102, 99, 101, 10]);
  const h = fixture({ time: OPEN_TIME + 270_000, broker: { bars: rows } });
  const first = await h.request(barsUrl("AAPL", 2));
  assert.equal(first.status, 200);
  assert.equal(Object.hasOwn(first.body.bars[0], "partial"), false);
  assert.equal(first.body.bars[1].partial, true);
  h.advance(30_000);
  const cached = await h.request(barsUrl("AAPL", 1));
  assert.equal(cached.body.cached, true); assert.equal(cached.body.bars[0].partial, true);
  h.advance(30_000);
  const completed = await h.request(barsUrl("AAPL", 2));
  assert.equal(completed.body.cached, false);
  assert.equal(Object.hasOwn(completed.body.bars[1], "partial"), false);
});

test("a forming snapshot stays partial when historicalDataEnd crosses a bar boundary", async () => {
  let ready; let held;
  const started = new Promise((resolve) => { ready = resolve; });
  const h = fixture({ time: OPEN_TIME + 299_000, broker: {
    bars: [[String(OPEN_TIME / 1000), 100, 102, 99, 101, 10]], noHistoryEnd: true,
    onHistory: (api, id) => { held = { api, id }; ready(); },
  } });
  const request = h.request(barsUrl("AAPL", 1));
  await started;
  h.advance(1000);
  held.api.emit(events.historicalDataEnd, held.id);
  const result = await request;
  assert.equal(result.status, 200); assert.equal(result.body.bars[0].partial, true);
});

test("contract cache spans quote and history requests and expires after one hour", async () => {
  const h = fixture();
  await h.request(quoteUrl());
  h.advance(15_000);
  assert.equal((await h.request(quoteUrl())).body.cached, false);
  assert.equal((await h.request(barsUrl("AAPL", 1))).status, 200);
  assert.equal(h.broker.lookups.length, 1);
  assert.equal(h.broker.connections.length, 3);
  h.advance(3_600_000 - 15_000 - 1);
  assert.equal((await h.request(quoteUrl())).status, 200);
  assert.equal(h.broker.lookups.length, 1);
  h.advance(1);
  assert.equal((await h.request(barsUrl("AAPL", 2))).status, 200);
  assert.equal(h.broker.lookups.length, 2);
});

test("global bucket protects both endpoints; cache hits do not consume tokens", async () => {
  const h = fixture();
  for (const symbol of ["AAPL", "MSFT", "IBM"]) assert.equal((await h.request(quoteUrl(symbol))).status, 200);
  const denied = await h.request(barsUrl("NVDA"));
  assert.deepEqual(denied, { status: 429, body: { status: "rate_limited", retry_after_s: 1 } });
  assert.equal(h.broker.connections.length, 3);
  assert.equal((await h.request(quoteUrl())).body.cached, true);
  h.advance(2000);
  assert.equal((await h.request(barsUrl("NVDA"))).status, 200);
});

test("a denied contract-lookup reservation refunds its first data token", async () => {
  const h = fixture();
  for (const symbol of ["AAPL", "MSFT"]) assert.equal((await h.request(quoteUrl(symbol))).status, 200);
  assert.equal((await h.request(barsUrl("AAPL", 1))).status, 200);
  // One token remains: an unknown contract needs two, but a known one needs one.
  for (let index = 0; index < 3; index += 1) assert.equal((await h.request(quoteUrl("NVDA"))).status, 429);
  assert.equal(h.broker.connections.length, 3); assert.equal(h.broker.lookups.length, 2);
  assert.equal((await h.request(barsUrl("MSFT", 1))).status, 200);
  assert.equal((await h.request(quoteUrl("IBM"))).status, 429);
  assert.equal(h.broker.connections.length, 4); assert.equal(h.broker.lookups.length, 2);
});

test("historical budget enforces a rolling 60 requests per ten minutes", async () => {
  const h = fixture({ broker: { bars: bars(1) } });
  for (let index = 0; index < 60; index += 1) {
    assert.equal((await h.request(barsUrl(`S${index}`, 1))).status, 200, String(index));
    h.advance(9000);
  }
  const limit = await h.request(barsUrl("NEW", 1));
  assert.deepEqual(limit, { status: 429, body: { status: "rate_limited", retry_after_s: 60 } });
  assert.equal(h.broker.histories.length, 60);
  assert.equal(h.broker.connections.length, 60); assert.equal(h.broker.lookups.length, 60);
  h.advance(60_000);
  assert.equal((await h.request(barsUrl("NEW", 1))).status, 200);
  assert.equal(h.broker.histories.length, 61);
});

test("failed historical requests cannot repeat for 15 seconds, across counts and desks", async () => {
  const h = fixture({ broker: { historyError: 162 } });
  assert.equal((await h.request(barsUrl())).status, 503);
  h.broker.historyError = null;
  assert.deepEqual(await h.request(barsUrl("AAPL", 25, "joe")), { status: 429, body: { status: "rate_limited", retry_after_s: 15 } });
  h.advance(14_000);
  assert.equal((await h.request(barsUrl())).body.retry_after_s, 1);
  assert.equal(h.broker.connections.length, 1); assert.equal(h.broker.lookups.length, 1);
  h.advance(1000);
  assert.equal((await h.request(barsUrl())).status, 200); assert.equal(h.broker.histories.length, 2);
  assert.equal(h.broker.lookups.length, 1);
});

test("increasing a cached bar count cannot bypass contract pacing", async () => {
  const h = fixture();
  await h.request(barsUrl("AAPL", 2));
  assert.equal((await h.request(barsUrl("AAPL", 3))).status, 429);
  assert.equal((await h.request(barsUrl("AAPL", 1))).body.cached, true);
  assert.equal(h.broker.connections.length, 1); assert.equal(h.broker.lookups.length, 1);
  h.advance(15_000);
  assert.equal((await h.request(barsUrl("AAPL", 3))).status, 200);
});

test("invalid symbols, desks and counts fail before connecting, including on a cache hit", async () => {
  const h = fixture();
  for (const url of [
    quoteUrl("aapl"), quoteUrl("1ABC"), quoteUrl("ABCDEFGHIJK"), quoteUrl("A%20B"), quoteUrl("AAPL%0A"), quoteUrl(""),
    quoteUrl("AAPL", ""), quoteUrl("AAPL", "J"), quoteUrl("AAPL", "unknown"),
    "/v1/quote?symbol=AAPL", "/v1/bars?desk=j", quoteUrl() + "&symbol=MSFT", quoteUrl() + "&desk=joe",
    ...["", "0", "79", "-1", "1.5", "001", "24x", "24%0A", "Infinity"].map((count) => barsUrl("AAPL", count)),
  ]) assert.equal((await h.request(url)).status, 400, url);
  assert.equal(h.broker.connections.length, 0);
  await h.request(quoteUrl());
  assert.equal((await h.request(quoteUrl("AAPL", "not-a-desk"))).status, 400);
  for (const desk of DESKS) assert.equal((await h.request(quoteUrl("AAPL", desk))).status, 200);
});

test("unknown, ambiguous and non-USD-stock contracts are 404", async (t) => {
  for (const [name, broker] of [
    ["empty contract list", { noContract: true }], ["error 200 without end", { lookupError: 200 }],
    ["ambiguous", { ambiguous: true }], ["non-stock", { contractOverride: { secType: "OPT" } }],
    ["currency", { contractOverride: { currency: "EUR" } }], ["bad conId", { contractOverride: { conId: 0 } }],
    ["wrong symbol", { contractOverride: { symbol: "MSFT" } }],
  ]) await t.test(name, async () => {
    const h = fixture({ broker });
    for (const url of [quoteUrl(), barsUrl()]) assert.equal((await h.request(url)).status, 404);
    assert.equal(h.broker.quotes.length, 0); assert.equal(h.broker.histories.length, 0); assert.equal(h.broker.live.size, 0);
  });
});

test("both data routes use the common peer check and ignore forwarded addresses", async () => {
  const h = fixture();
  for (const url of [quoteUrl(), barsUrl()]) assert.equal((await h.request(url, { peer: "127.0.0.2" })).status, 403);
  assert.equal(h.broker.connections.length, 0);
  assert.deepEqual(h.audit.map((row) => row.outcome), ["forbidden", "forbidden"]);
});

test("HALT and KEEP do not block reads, which never access intent or ownership state", async (t) => {
  const h = fixture({ server: { execute: () => assert.fail("data path reached intent executor") } });
  h.app.ledger.save(h.app.ledger.load());
  h.app.ledger.setHalt("operator stop");
  const ledgerBefore = readFileSync(h.app.ledger.statePath);
  for (const name of ["load", "save", "audit", "haltBody", "setHalt"]) t.mock.method(h.app.ledger, name, () => assert.fail(`data path accessed ledger ${name}`));
  assert.equal((await h.request(quoteUrl("TSLA"))).status, 200);
  assert.equal((await h.request(barsUrl("TSLA"))).status, 200);
  assert.equal((await h.request(quoteUrl("SXR8"))).status, 200);
  assert.deepEqual(readFileSync(h.app.ledger.statePath), ledgerBefore);
  assert.deepEqual(h.broker.forbidden, []);
  assert.throws(() => assertContract({ symbol: "TSLA", conId: 1 }, { symbol: "TSLA", conId: 1 }), /KEEP/);
});

test("market closed selects delayed-frozen while missing and IB sentinel fields stay null", async () => {
  const h = fixture({ time: Date.parse("2026-10-12T22:00:00Z"), broker: { prices: [[66, -1], [67, NaN], [68, undefined], [75, 99]] } });
  const result = await h.request(quoteUrl());
  assert.equal(result.status, 200); assert.equal(result.body.marketDataType, "delayed-frozen");
  assert.deepEqual([result.body.bid, result.body.ask, result.body.last, result.body.close], [null, null, null, 99]);
  assert.deepEqual(h.broker.types, [4]); assert.equal(h.broker.quotes[0].type, 4);
});

test("IB CLOSED days and short liquid sessions override normal weekday hours", async () => {
  for (const liquidHours of ["20261012:CLOSED", "20261012:0930-20261012:1300"]) {
    const h = fixture({ broker: { liquidHours } });
    assert.equal((await h.request(quoteUrl())).body.marketDataType, "delayed-frozen");
    assert.deepEqual(h.broker.types, [4]);
  }
});

test("empty delayed snapshot returns null fields without a second snapshot", async () => {
  const h = fixture({ broker: { pricesForType: (type) => type === 3 ? [] : [[75, 99]] } });
  const result = await h.request(quoteUrl());
  assert.equal(result.status, 200); assert.equal(result.body.marketDataType, "delayed");
  assert.deepEqual([result.body.bid, result.body.ask, result.body.last, result.body.close], [null, null, null, null]);
  assert.deepEqual(h.broker.quotes.map((row) => row.type), [3]); assert.equal(h.broker.cancelledQuotes.length, 1);
});

test("an eleven-second empty delayed snapshot completes without a fallback budget", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: OPEN_TIME });
  let held;
  const h = fixture({ broker: { hungQuote: true, onQuote: (api, id) => { held = { api, id }; } },
    marketData: { timeoutMs: undefined, monotonicNow: () => Date.now() } });
  const request = h.request(quoteUrl());
  await flushMicrotasks();
  assert.ok(held);
  t.mock.timers.tick(11_000);
  held.api.emit(events.marketDataType, held.id, 3);
  held.api.emit(events.tickSnapshotEnd, held.id);
  const result = await request;
  assert.equal(result.status, 200); assert.equal(result.body.marketDataType, "delayed");
  assert.deepEqual([result.body.bid, result.body.ask, result.body.last, result.body.close], [null, null, null, null]);
  assert.deepEqual(h.broker.types, [3]); assert.equal(h.broker.quotes.length, 1);
  assert.equal(h.broker.cancelledQuotes.length, 1); assert.equal(h.broker.live.size, 0);
});

test("actual realtime entitlement is reported even when delayed data was requested", async () => {
  const h = fixture({ broker: { actualType: 1, prices: [[1, 100], [2, 101], [4, 100.5]] } });
  const result = await h.request(quoteUrl());
  assert.equal(result.body.marketDataType, "realtime"); assert.equal(result.body.close, null);
  assert.ok(h.broker.types.every((type) => type === 3));
});

test("after-hours type 4 requests accept entitled frozen type 2 quotes", async () => {
  const h = fixture({ time: Date.parse("2026-10-12T22:00:00Z"), broker: { actualType: 2, prices: [[1, 100], [2, 101], [4, 100.5], [9, 99]] } });
  const result = await h.request(quoteUrl());
  assert.equal(result.status, 200); assert.equal(result.body.marketDataType, "frozen");
  assert.deepEqual([result.body.bid, result.body.ask, result.body.last, result.body.close], [100, 101, 100.5, 99]);
  assert.deepEqual(h.broker.types, [4]); assert.equal(h.broker.cancelledQuotes.length, 1);
  assert.equal(h.broker.live.size, 0);
});

test("IB warnings that precede usable delayed ticks are informational", async () => {
  for (const quoteError of [354, 10089, 10167]) {
    const h = fixture({ broker: { quoteError } });
    assert.equal((await h.request(quoteUrl())).status, 200, String(quoteError));
  }
});

test("permissions warnings remain visible when IB never ends the failed snapshot", async () => {
  const h = fixture({ broker: { quoteError: 354, prices: [], noQuoteEnd: true }, marketData: { timeoutMs: 30 } });
  const result = await h.request(quoteUrl());
  assert.equal(result.status, 503); assert.match(result.body.reason, /permissions warning.*354/);
  assert.equal(h.broker.live.size, 0); assert.equal(h.broker.cancelledQuotes.length, 1);
});

test("IB pacing and permission codes give bounded reasons without raw diagnostics", async (t) => {
  for (const [endpoint, code, expected] of [
    ["bars", 162, /historical data.*162/], ["quote", 354, /permissions.*354/],
    ["quote", 10167, /delayed data.*10167/], ["quote", 10168, /not enabled.*10168/],
    ["quote", 100, /pacing.*100/], ["quote", 420, /pacing.*420/],
  ]) await t.test(`${endpoint} ${code}`, async () => {
    const h = fixture({ broker: { [`${endpoint === "bars" ? "history" : "quote"}Error`]: code, prices: [], errorMessage: "internal broker diagnostic" } });
    const result = await h.request(endpoint === "quote" ? quoteUrl() : barsUrl());
    assert.equal(result.status, 503); assert.match(result.body.reason, expected);
    assert.equal(JSON.stringify(result).includes("internal broker diagnostic"), false);
    assert.equal(h.broker.live.size, 0);
  });
  const paced = fixture({ broker: { historyError: 162, errorMessage: "historical pacing violation" } });
  assert.match((await paced.request(barsUrl())).body.reason, /pacing limit/);
  assert.equal((await paced.request(quoteUrl("MSFT"))).body.retry_after_s, 600);
});

test("connection, lookup, quote and history timeouts return 503, disconnect and release the data lock", async (t) => {
  for (const [name, broker, url] of [
    ["connect", { noReady: true }, quoteUrl()], ["lookup", { noLookupEnd: true }, quoteUrl()],
    ["quote", { noQuoteEnd: true }, quoteUrl()], ["history", { noHistoryEnd: true }, barsUrl()],
  ]) await t.test(name, async () => {
    const h = fixture({ broker, marketData: { timeoutMs: 30 } });
    const result = await h.request(url);
    assert.equal(result.status, 503); assert.match(result.body.reason, /timed out/);
    assert.equal(h.broker.live.size, 0);
    if (name === "history") assert.deepEqual(h.broker.cancelledHistories, [h.broker.histories[0].id]);
    if (name === "quote") assert.deepEqual(h.broker.cancelledQuotes, [h.broker.quotes[0].id]);
    Object.assign(h.broker, { noReady: false, noLookupEnd: false, noQuoteEnd: false, noHistoryEnd: false });
    h.advance(15_000);
    assert.equal((await h.request(quoteUrl("MSFT"))).status, 200);
  });
});

test("a hung data call does not block an intent", async () => {
  let ready;
  const started = new Promise((resolve) => { ready = resolve; });
  let finished = false;
  let intents = 0;
  const h = fixture({ broker: { hungQuote: true, onQuote: () => ready() }, marketData: { timeoutMs: 200 }, server: { execute: async (intent) => { intents += 1; return { status: "ok", intentId: intent.intentId, desk: intent.desk, action: intent.action }; } } });
  const data = h.request(quoteUrl()).then((value) => { finished = true; return value; });
  await started;
  const intent = await h.request("/v1/intents", { method: "POST", body: reconIntent() });
  assert.equal(intent.status, 200); assert.equal(intents, 1); assert.equal(finished, false);
  assert.equal((await data).status, 503);
});

test("a hung intent does not block data", async () => {
  let ready; let release;
  const started = new Promise((resolve) => { ready = resolve; });
  const blocked = new Promise((resolve) => { release = resolve; });
  let finished = false;
  const h = fixture({ server: { execute: async (intent) => { ready(); await blocked; return { status: "ok", intentId: intent.intentId }; } } });
  const intent = h.request("/v1/intents", { method: "POST", body: reconIntent() }).then((value) => { finished = true; return value; });
  await started;
  try { assert.equal((await h.request(quoteUrl())).status, 200); assert.equal(finished, false); }
  finally { release(); }
  assert.equal((await intent).status, 200);
});

test("data requests serialize, coalesce cache hits and release the queue after an active timeout", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  let ready; let held;
  const started = new Promise((resolve) => { ready = resolve; });
  const h = fixture({ broker: { hungQuote: true, onQuote: (api, id) => { held = { api, id }; ready(); } }, marketData: { timeoutMs: 150 } });
  const first = h.request(quoteUrl());
  await started;
  const second = h.request(quoteUrl("AAPL", "joe"));
  assert.equal(h.broker.connections.length, 1);
  for (const [field, value] of defaults) held.api.emit(events.tickPrice, held.id, field, value);
  held.api.emit(events.tickSnapshotEnd, held.id);
  assert.equal((await first).status, 200); assert.equal((await second).body.cached, true);
  assert.equal(h.broker.maxLive, 1); assert.equal(h.broker.connections.length, 1);

  let nextReady;
  const nextStarted = new Promise((resolve) => { nextReady = resolve; });
  h.broker.onQuote = () => nextReady();
  const hung = h.request(quoteUrl("MSFT"));
  await nextStarted;
  t.mock.timers.tick(1);
  const queued = h.request(barsUrl("IBM"));
  t.mock.timers.tick(149);
  assert.equal((await hung).status, 503); assert.equal((await queued).status, 200);
  assert.equal(h.broker.histories.length, 1); assert.equal(h.broker.maxLive, 1);
});

test("a slow snapshot does not consume the next queued request's deadline", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  let firstReady; let secondReady;
  const firstStarted = new Promise((resolve) => { firstReady = resolve; });
  const secondStarted = new Promise((resolve) => { secondReady = resolve; });
  const held = [];
  const h = fixture({ broker: { hungQuote: true, onQuote: (api, id) => {
    held.push({ api, id });
    if (held.length === 1) firstReady(); else secondReady();
  } }, marketData: { timeoutMs: 150 } });
  const first = h.request(quoteUrl());
  await firstStarted;
  let secondFinished = false;
  const second = h.request(quoteUrl("MSFT")).then((result) => { secondFinished = true; return result; });
  t.mock.timers.tick(140);
  for (const [field, value] of defaults) held[0].api.emit(events.tickPrice, held[0].id, field, value);
  held[0].api.emit(events.tickSnapshotEnd, held[0].id);
  assert.equal((await first).status, 200);
  await secondStarted;
  t.mock.timers.tick(140);
  await flushMicrotasks();
  assert.equal(secondFinished, false, "queued request has its own full broker deadline");
  for (const [field, value] of defaults) held[1].api.emit(events.tickPrice, held[1].id, field, value);
  held[1].api.emit(events.tickSnapshotEnd, held[1].id);
  assert.equal((await second).status, 200);
  assert.equal(h.broker.maxLive, 1); assert.equal(h.broker.cancelledQuotes.length, 2);
});

test("queue waits expire at timeoutMs and queue-full replies cover the outstanding broker budgets", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: OPEN_TIME });
  const h = fixture({ marketData: { reconnectDelayMs: undefined, timeoutMs: 50, monotonicNow: () => Date.now() } });
  assert.equal((await h.request(quoteUrl())).status, 200);
  let activeFinished = false;
  const active = h.request(quoteUrl("MSFT")).then((result) => { activeFinished = true; return result; });
  await flushMicrotasks(); // Active request is waiting for the reconnect gap.
  const queued = Array.from({ length: 15 }, (_, index) => h.request(quoteUrl(`S${index}`)));
  const full = await h.request(quoteUrl("OVERFLOW"));
  assert.deepEqual(full, { status: 429, body: { status: "rate_limited", retry_after_s: 33 } }); // 16 × (50 + 2 × 1000) ms.
  t.mock.timers.tick(49);
  await flushMicrotasks();
  assert.equal(h.audit.filter((row) => row.outcome === "rate_limited").length, 1);
  t.mock.timers.tick(1);
  for (const result of await Promise.all(queued)) {
    assert.deepEqual(result, { status: 429, body: { status: "rate_limited", retry_after_s: 31 } }); // 15 requests ahead.
  }
  assert.equal(activeFinished, false);
  assert.equal(h.broker.connections.length, 1); assert.equal(h.broker.lookups.length, 1);
  t.mock.timers.tick(950);
  assert.equal((await active).status, 200);
  await flushMicrotasks();
  assert.equal(h.broker.connections.length, 2); assert.equal(h.broker.lookups.length, 2);
  assert.deepEqual(h.broker.quotes.map((row) => row.contract.symbol), ["AAPL", "MSFT"]);
  assert.equal(h.broker.live.size, 0); assert.equal(h.broker.maxLive, 1);
});

test("disconnected clients leave the queue before any IB call and release their listeners", async (t) => {
  for (const event of ["close", "aborted"]) await t.test(event, async () => {
    let held;
    const h = fixture({ broker: { hungQuote: true, onQuote: (api, id) => { held = { api, id }; } } });
    const first = h.request(quoteUrl());
    await flushMicrotasks();
    let response; let req;
    const queued = h.request(quoteUrl("MSFT"), { onResponse: (res, request) => { response = res; req = request; } });
    await flushMicrotasks();
    assert.equal(response.listenerCount("close"), 1); assert.equal(req.listenerCount("aborted"), 1);
    if (event === "close") { response.destroyed = true; response.emit("close"); }
    else { req.aborted = true; req.emit("aborted"); }
    assert.deepEqual(await queued, { status: undefined, body: undefined });
    assert.equal(response.listenerCount("close"), 0); assert.equal(req.listenerCount("aborted"), 0);
    assert.equal(h.broker.connections.length, 1); assert.equal(h.broker.lookups.length, 1);
    for (const [field, value] of defaults) held.api.emit(events.tickPrice, held.id, field, value);
    held.api.emit(events.tickSnapshotEnd, held.id);
    assert.equal((await first).status, 200);
    h.broker.hungQuote = false;
    assert.equal((await h.request(quoteUrl("IBM"))).status, 200);
    assert.deepEqual(h.broker.quotes.map((row) => row.contract.symbol), ["AAPL", "IBM"]);
    assert.equal(h.broker.live.size, 0); assert.equal(h.broker.maxLive, 1);
  });
});

test("disconnect during a reconnect gap cancels the wait before opening another IB session", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: OPEN_TIME });
  const h = fixture({ marketData: { reconnectDelayMs: undefined, timeoutMs: undefined, monotonicNow: () => Date.now() } });
  assert.equal((await h.request(quoteUrl())).status, 200);
  let response;
  const request = h.request(quoteUrl("MSFT"), { onResponse: (res) => { response = res; } });
  await flushMicrotasks();
  response.destroyed = true; response.emit("close");
  assert.deepEqual(await request, { status: undefined, body: undefined });
  t.mock.timers.tick(1000);
  await flushMicrotasks();
  assert.equal(h.broker.connections.length, 1); assert.equal(h.broker.lookups.length, 1);
  assert.equal(h.broker.live.size, 0); assert.equal(response.listenerCount("close"), 0);
});

test("disconnect during an active snapshot cancels the IB request and closes the session", async () => {
  const h = fixture({ broker: { hungQuote: true } });
  let response;
  const request = h.request(quoteUrl(), { onResponse: (res) => { response = res; } });
  await flushMicrotasks();
  assert.equal(h.broker.quotes.length, 1);
  response.destroyed = true; response.emit("close");
  assert.deepEqual(await request, { status: undefined, body: undefined });
  assert.deepEqual(h.broker.cancelledQuotes, [h.broker.quotes[0].id]);
  assert.equal(h.broker.live.size, 0); assert.equal(response.listenerCount("close"), 0);
});

test("default reconnect gap gives the Gateway one second to release clientId 707", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: OPEN_TIME });
  const h = fixture({ marketData: { reconnectDelayMs: undefined, timeoutMs: 12_000, monotonicNow: () => Date.now() } });
  assert.equal((await h.request(quoteUrl())).status, 200);
  const second = h.request(quoteUrl("MSFT"));
  await flushMicrotasks();
  t.mock.timers.tick(999);
  await flushMicrotasks();
  assert.equal(h.broker.connections.length, 1);
  t.mock.timers.tick(1);
  assert.equal((await second).status, 200);
  assert.equal(h.broker.connectionTimes[1] - h.broker.disconnectionTimes[0], 1000);
  assert.equal(h.broker.maxLive, 1); assert.equal(h.broker.live.size, 0);
});

test("a queued quote with the default one-second gap and an eleven-second snapshot succeeds", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: OPEN_TIME });
  const held = [];
  const h = fixture({ broker: { hungQuote: true, onQuote: (api, id) => held.push({ api, id }) },
    marketData: { reconnectDelayMs: undefined, timeoutMs: undefined, monotonicNow: () => Date.now() } });
  const first = h.request(quoteUrl());
  await flushMicrotasks();
  assert.equal(held.length, 1);
  let finished = false;
  const queued = h.request(quoteUrl("MSFT")).then((result) => { finished = true; return result; });
  t.mock.timers.tick(100);
  for (const [field, value] of defaults) held[0].api.emit(events.tickPrice, held[0].id, field, value);
  held[0].api.emit(events.tickSnapshotEnd, held[0].id);
  assert.equal((await first).status, 200);
  t.mock.timers.tick(1000);
  await flushMicrotasks();
  assert.equal(held.length, 2);
  assert.equal(h.broker.connectionTimes[1] - h.broker.disconnectionTimes[0], 1000);
  t.mock.timers.tick(11_100);
  await flushMicrotasks();
  assert.equal(finished, false, "reconnect wait must leave the full snapshot budget available");
  for (const [field, value] of defaults) held[1].api.emit(events.tickPrice, held[1].id, field, value);
  held[1].api.emit(events.tickSnapshotEnd, held[1].id);
  assert.equal((await queued).status, 200);
  assert.equal(h.broker.maxLive, 1); assert.equal(h.broker.live.size, 0);
  assert.equal(h.broker.cancelledQuotes.length, 2);
});

test("a 326 retry gap leaves time for a handshake and an eleven-second snapshot", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: OPEN_TIME });
  let held;
  const h = fixture({ broker: { connectErrors: [326], noReady: true, hungQuote: true,
    onConnect: (api) => { if (h.broker.connections.length === 2) setTimeout(() => api.emit(events.nextValidId, 9000), 100); },
    onQuote: (api, id) => { held = { api, id }; },
  }, marketData: { reconnectDelayMs: undefined, timeoutMs: undefined, monotonicNow: () => Date.now() } });
  let finished = false;
  const request = h.request(quoteUrl()).then((result) => { finished = true; return result; });
  await flushMicrotasks();
  t.mock.timers.tick(1000);
  await flushMicrotasks();
  t.mock.timers.tick(100);
  await flushMicrotasks();
  assert.ok(held);
  t.mock.timers.tick(11_000);
  await flushMicrotasks();
  assert.equal(finished, false, "retry gap must not consume the broker deadline");
  for (const [field, value] of defaults) held.api.emit(events.tickPrice, held.id, field, value);
  held.api.emit(events.tickSnapshotEnd, held.id);
  assert.equal((await request).status, 200);
  assert.equal(h.broker.connections.length, 2); assert.equal(h.broker.lookups.length, 1);
  assert.equal(h.broker.live.size, 0); assert.equal(h.broker.cancelledQuotes.length, 1);
});

test("IB error 326 retries once after a gap; other connection errors do not retry", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: OPEN_TIME });
  for (const errors of [[326], [326, 326], [502]]) {
    const h = fixture({ broker: { connectErrors: [...errors] }, marketData: { reconnectDelayMs: undefined, timeoutMs: 12_000, monotonicNow: () => Date.now() } });
    const request = h.request(quoteUrl());
    await flushMicrotasks();
    assert.equal(h.broker.connections.length, 1);
    if (errors[0] === 326) {
      t.mock.timers.tick(999);
      await flushMicrotasks();
      assert.equal(h.broker.connections.length, 1);
      t.mock.timers.tick(1);
    }
    const result = await request;
    assert.equal(result.status, errors.length === 1 && errors[0] === 326 ? 200 : 503);
    assert.equal(h.broker.connections.length, errors[0] === 326 ? 2 : 1);
    assert.equal(h.broker.lookups.length, result.status === 200 ? 1 : 0);
    assert.equal(h.broker.live.size, 0);
    if (errors[0] === 326) assert.equal(h.broker.connectionTimes[1] - h.broker.disconnectionTimes[0], 1000);
  }
});

test("a 326 gap pauses the deadline while preserving the budget spent on the first handshake", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: OPEN_TIME });
  const h = fixture({ broker: { noReady: true, onConnect: (api) => {
    if (h.broker.connections.length === 1) setTimeout(() => api.emit(events.error, new Error("client ID in use"), 326, -1), 40);
  } }, marketData: { reconnectDelayMs: undefined, timeoutMs: 50, monotonicNow: () => Date.now() } });
  let finished = false;
  const request = h.request(quoteUrl()).then((result) => { finished = true; return result; });
  await flushMicrotasks();
  t.mock.timers.tick(40);
  await flushMicrotasks();
  t.mock.timers.tick(999);
  await flushMicrotasks();
  assert.equal(finished, false); assert.equal(h.broker.connections.length, 1);
  t.mock.timers.tick(1);
  await flushMicrotasks();
  assert.equal(h.broker.connections.length, 2);
  t.mock.timers.tick(9);
  await flushMicrotasks();
  assert.equal(finished, false);
  t.mock.timers.tick(1);
  const result = await request;
  assert.equal(result.status, 503); assert.match(result.body.reason, /timed out/);
  t.mock.timers.tick(1000);
  await flushMicrotasks();
  assert.equal(h.broker.connections.length, 2); assert.equal(h.broker.lookups.length, 0);
  assert.equal(h.broker.live.size, 0);
});

test("market data client IDs are disjoint from configured placing, legacy and pusher clients", () => {
  for (const clientId of [92, 94, 700, 701, 702, 703, 704, 705, 706]) assert.throws(() => createMarketData({ clientId }), /distinct/);
  assert.throws(() => createMarketData({ orderClientIds: { executor: 707, recon: 800 } }), /distinct/);
  assert.throws(() => createMarketData({ ownershipClientIds: { j: [707] } }), /distinct/);
  assert.throws(() => createMarketData({ clientId: 0 }), /distinct/);
});

test("each data request audits exactly six allowed fields, including cache and errors", async () => {
  const h = fixture();
  await h.request(quoteUrl()); await h.request(quoteUrl("AAPL", "joe"));
  await h.request(quoteUrl("UNKNOWN")); await h.request(quoteUrl("aapl"));
  await h.request(barsUrl(), { peer: "127.0.0.2" });
  assert.equal(h.audit.length, 5);
  assert.deepEqual(h.audit.map((row) => [row.cached, row.outcome]), [[false, "ok"], [true, "ok"], [false, "not_found"], [false, "rejected"], [false, "forbidden"]]);
  for (const row of h.audit) {
    assert.deepEqual(Object.keys(row), ["desk", "symbol", "endpoint", "cached", "outcome", "duration"]);
    assert.ok(Number.isFinite(row.duration) && row.duration >= 0);
  }
});

test("malformed historical bars fail clearly and are never cached", async () => {
  for (const row of [
    ["20261012 14:00:00", 100, 102, 99, 101, 10], ["1791811800", 100, 102, 99, 101, undefined],
    ["1791811800", 100, 102, 99, Infinity, 10], ["1791811800", 100, 90, 99, 101, 10],
  ]) {
    const h = fixture({ broker: { bars: [row] } });
    assert.equal((await h.request(barsUrl())).status, 503);
    assert.equal(h.broker.live.size, 0);
  }
});

test("order stock resolution still rejects KEEP by default", async () => {
  const { broker, runtime } = fakeRuntime();
  const api = new runtime.IBApi({ host: "100.64.0.6", port: 4002, clientId: 707 });
  const session = { api, events };
  await assert.rejects(resolveStock(session, "TSLA"), /KEEP/);
  assert.equal((await resolveStock(session, "TSLA", 881002, { readOnly: true })).contract.symbol, "TSLA");
  assert.deepEqual(broker.forbidden, []);
});

test("order stock resolution uses a real ten-second timer and fails fast on error 200", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const timed = fakeRuntime({ noLookupEnd: true });
  const api = new timed.runtime.IBApi({ host: "100.64.0.6", port: 4002, clientId: 707 });
  const session = { api, events, wait: () => assert.fail("contract lookup must not poll session.wait") };
  let finished = false;
  const lookup = resolveStock(session, "AAPL").then(() => assert.fail("lookup should time out"), (error) => { finished = true; return error; });
  t.mock.timers.tick(9999);
  await flushMicrotasks();
  assert.equal(finished, false);
  t.mock.timers.tick(1);
  assert.equal((await lookup).code, "market_data_timeout");
  for (const name of ["contractDetails", "contractDetailsEnd", "error"]) assert.equal(timed.broker.instances[0].listenerCount(name), 0);
  const missing = fakeRuntime({ lookupError: 200 });
  const missingApi = new missing.runtime.IBApi({ host: "100.64.0.6", port: 4002, clientId: 707 });
  await assert.rejects(resolveStock({ ...session, api: missingApi }, "AAPL"), { code: "contract_not_found" });
  assert.deepEqual(timed.broker.forbidden, []); assert.deepEqual(missing.broker.forbidden, []);
});
