import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";
import { createPortfolioRefreshController } from "./portfolio-refresh.mjs";
import { createBrokerSessionAdapter } from "./pusher-state.mjs";

const START = Date.parse("2026-09-14T14:00:00.000Z");
const iso = (at) => new Date(at).toISOString();
const contract = (symbol, conId = 101) => ({ symbol, conId, secType: "STK", currency: "USD" });

function snapshot(rows = [{ contract: contract("INTC"), pos: 4 }], markedAt = START) {
  return {
    gateway: true,
    ts: iso(START),
    positionsCoverage: { status: "complete", rows },
    portfolio: rows.map((row) => ({ ...row, marketPrice: 20, markObservedAt: iso(markedAt) })),
  };
}

function harness(options = {}) {
  let at = START;
  const requests = [];
  const events = [];
  const controller = createPortfolioRefreshController({
    nowMs: () => at,
    refresh: () => { requests.push(at); return true; },
    onEvent: (event) => events.push(event),
    ...options,
  });
  return { controller, requests, events, set: (elapsed) => { at = START + elapsed; } };
}

test("fresh socket timestamps cannot conceal stale portfolio marks; refresh preserves snapshot", () => {
  const h = harness();
  const source = snapshot();
  for (let elapsed = 0; elapsed < 240_000; elapsed += 20_000) {
    h.set(elapsed);
    source.ts = iso(START + elapsed);
    h.controller.tick(source);
  }
  assert.equal(h.requests.length, 0);
  h.set(240_000);
  source.ts = iso(START + 240_000);
  const before = structuredClone(source);
  h.controller.tick(source);
  assert.equal(h.requests.length, 1);
  assert.deepEqual(source, before);
  for (let elapsed = 241_000; elapsed < 270_000; elapsed += 1_000) {
    h.set(elapsed);
    h.controller.tick(source);
  }
  assert.equal(h.requests.length, 1, "ticks while pending must not create a request storm");
  assert.equal(source.portfolio[0].markObservedAt, iso(START));
});

test("missing working-lot marks refresh, but KEEP and closed rows do not", () => {
  const h = harness();
  const source = snapshot([
    { contract: contract("SXR8", 1), pos: 5 },
    { contract: contract("TSLA", 2), pos: 2 },
    { contract: contract("INTC", 3), pos: 0 },
  ]);
  source.portfolio = [];
  h.set(900_000);
  h.controller.tick(source);
  assert.equal(h.requests.length, 0);
  source.positionsCoverage.rows.push({ contract: contract("AAPL", 4), pos: -2 });
  h.controller.tick(source);
  assert.equal(h.requests.length, 1, "an unmarked short lot also requires a real mark");
});

test("gateway down or incomplete positions coverage cannot request refresh", () => {
  const h = harness();
  const source = snapshot();
  h.set(300_000);
  source.gateway = false;
  h.controller.tick(source);
  source.gateway = true;
  source.positionsCoverage.status = "unavailable";
  h.controller.tick(source);
  assert.equal(h.requests.length, 0);
  source.positionsCoverage.status = "complete";
  h.controller.tick(source);
  assert.equal(h.requests.length, 1);
});

test("recovery needs real valid marks for every targeted lot after the request", () => {
  const h = harness();
  const source = snapshot([
    { contract: contract("INTC", 1), pos: 4 },
    { contract: contract("AAPL", 2), pos: 3 },
  ]);
  h.set(240_000);
  h.controller.tick(source);
  h.set(241_000);
  source.portfolio[0].markObservedAt = iso(START + 241_000);
  source.portfolio[1].observedAt = iso(START + 241_000);
  h.controller.tick(source);
  assert.equal(h.events.some((e) => e.event === "portfolio_refresh_recovered"), false);
  source.portfolio[1].markObservedAt = iso(START + 241_000);
  source.portfolio[1].marketPrice = Number.MAX_VALUE;
  h.controller.tick(source);
  assert.equal(h.events.some((e) => e.event === "portfolio_refresh_recovered"), false);
  source.portfolio[1].marketPrice = 21;
  h.controller.tick(source);
  assert.equal(h.events.filter((e) => e.event === "portfolio_refresh_recovered").length, 1);
  assert.equal(h.requests.length, 1);
});

test("future and invalid mark timestamps cannot be accepted as refreshed data", () => {
  for (const mark of ["invalid", iso(START + 500_000)]) {
    const h = harness();
    const source = snapshot();
    h.set(240_000);
    h.controller.tick(source);
    source.portfolio[0].markObservedAt = mark;
    h.set(241_000);
    h.controller.tick(source);
    assert.equal(h.events.some((e) => e.event === "portfolio_refresh_recovered"), false);
  }
});

test("timeout retry delay doubles and caps at fifteen minutes", () => {
  const h = harness();
  const source = snapshot();
  let elapsed = 240_000;
  for (const delay of [60_000, 120_000, 240_000, 480_000, 900_000, 900_000]) {
    h.set(elapsed);
    h.controller.tick(source);
    const count = h.requests.length;
    elapsed += 30_000;
    h.set(elapsed);
    h.controller.tick(source);
    assert.equal(h.events.at(-1).delayMs, delay);
    h.set(elapsed + delay - 1);
    h.controller.tick(source);
    assert.equal(h.requests.length, count);
    elapsed += delay;
  }
  assert.equal(h.requests.length, 6);
});

test("subscription conflict cools down instead of continuously taking over the account", () => {
  const h = harness();
  const source = snapshot();
  h.set(240_000);
  h.controller.tick(source);
  h.controller.subscriptionConflict();
  for (let elapsed = 241_000; elapsed < 1_140_000; elapsed += 1_000) {
    h.set(elapsed);
    h.controller.tick(source);
  }
  assert.equal(h.requests.length, 1);
  h.set(1_140_000);
  h.controller.tick(source);
  assert.equal(h.requests.length, 2);
});

test("own 2100 cancellation acknowledgement waits for all finite marks after acknowledgement", () => {
  const h = harness();
  const source = snapshot([
    { contract: contract("INTC", 1), pos: 4 },
    { contract: contract("AAPL", 2), pos: 3 },
  ]);
  h.set(240_000);
  h.controller.tick(source);
  source.portfolio[0].markObservedAt = iso(START + 241_000);
  source.portfolio[1].markObservedAt = iso(START + 241_000);
  h.set(242_000);
  h.controller.subscriptionConflict(2100);
  h.controller.tick(source);
  assert.equal(h.events.some((event) => event.event === "portfolio_refresh_recovered"), false);
  assert.equal(h.events.some((event) => event.event === "portfolio_refresh_deferred"), false);
  h.set(243_000);
  source.portfolio[0].markObservedAt = iso(START + 243_000);
  h.controller.tick(source);
  assert.equal(h.events.some((event) => event.event === "portfolio_refresh_recovered"), false);
  source.portfolio[1].markObservedAt = iso(START + 243_000);
  source.portfolio[1].marketPrice = Number.MAX_VALUE;
  h.controller.tick(source);
  assert.equal(h.events.some((event) => event.event === "portfolio_refresh_recovered"), false);
  source.portfolio[1].marketPrice = 21;
  h.controller.tick(source);
  assert.equal(h.events.at(-1).event, "portfolio_refresh_recovered");
  assert.equal(h.events.at(-1).elapsedMs, 3_000);
  assert.equal(h.requests.length, 1);
});

test("missing callbacks after repeated 2100 acknowledgements keep the original deadline then cool down", () => {
  const h = harness();
  const source = snapshot();
  h.set(240_000);
  h.controller.tick(source);
  for (const elapsed of [241_000, 255_000, 269_999]) {
    h.set(elapsed);
    h.controller.subscriptionConflict(2100);
    h.controller.tick(source);
    assert.equal(h.events.some((event) => event.event === "portfolio_refresh_deferred"), false);
  }
  h.set(270_000);
  h.controller.tick(source);
  assert.equal(h.events.at(-1).reason, "mark_callbacks_missing_after_cancel");
  assert.equal(h.events.at(-1).delayMs, 900_000);
  h.set(1_169_999);
  h.controller.tick(source);
  assert.equal(h.requests.length, 1);
  h.set(1_170_000);
  h.controller.tick(source);
  assert.equal(h.requests.length, 2);
  assert.equal(source.portfolio[0].markObservedAt, iso(START));
});

test("2101 always imposes full conflict cooldown, including during a pending refresh", () => {
  for (const pending of [false, true]) {
    const h = harness();
    const source = snapshot();
    h.set(240_000);
    if (pending) h.controller.tick(source);
    h.set(241_000);
    h.controller.subscriptionConflict(2101);
    const before = h.requests.length;
    assert.equal(h.events.at(-1).reason, "account_subscription_conflict");
    for (const elapsed of [242_000, 270_000, 1_140_999]) {
      h.set(elapsed);
      h.controller.tick(source);
      assert.equal(h.requests.length, before);
    }
    h.set(1_141_000);
    h.controller.tick(source);
    assert.equal(h.requests.length, before + 1);
  }
});

test("unsolicited 2100 with no pending request receives the full conflict cooldown", () => {
  const h = harness();
  const source = snapshot();
  h.set(240_000);
  h.controller.subscriptionConflict(2100);
  h.controller.tick(source);
  assert.equal(h.events.at(-1).reason, "account_subscription_conflict");
  h.set(1_139_999);
  h.controller.tick(source);
  assert.equal(h.requests.length, 0);
  h.set(1_140_000);
  h.controller.tick(source);
  assert.equal(h.requests.length, 1);
});

test("closed or removed targets do not keep a refresh pending", () => {
  for (const removed of [false, true]) {
    const h = harness();
    const source = snapshot();
    h.set(240_000);
    h.controller.tick(source);
    source.positionsCoverage.rows = removed ? [] : [{ contract: contract("INTC"), pos: 0 }];
    h.set(241_000);
    h.controller.tick(source);
    assert.equal(h.events.at(-1).event, "portfolio_refresh_recovered");
    source.positionsCoverage.rows.push({ contract: contract("AAPL", 2), pos: 1 });
    h.controller.tick(source);
    assert.equal(h.requests.length, 2, "a new unmarked lot can refresh without an old pending latch");
  }
});

test("reset releases a retired generation's pending request and conflict cooldown", () => {
  const h = harness();
  const source = snapshot();
  h.set(240_000);
  h.controller.tick(source);
  h.controller.subscriptionConflict();
  h.controller.reset();
  h.set(241_000);
  h.controller.tick(source);
  assert.equal(h.requests.length, 2);
});

test("refresh failure is bounded and cannot fabricate a callback", () => {
  for (const refresh of [() => false, () => { throw new Error("synthetic refresh failure"); }]) {
    const h = harness({ refresh });
    const source = snapshot();
    const before = structuredClone(source);
    h.set(240_000);
    h.controller.tick(source);
    const events = h.events.length;
    for (let elapsed = 241_000; elapsed < 300_000; elapsed += 1_000) {
      h.set(elapsed);
      h.controller.tick(source);
    }
    assert.equal(h.events.length, events);
    assert.deepEqual(source, before);
    assert.equal(h.events.at(-1).delayMs, 60_000);
  }
});

class FakeApi extends EventEmitter {
  requests = [];
  reqManagedAccts() {}
  reqPositions() {}
  reqAllOpenOrders() {}
  reqAccountSummary() {}
  reqAccountUpdates(...args) { this.requests.push(args); }
}

test("adapter forwards the actual 2100 and 2101 code on info and error notices", () => {
  const codes = [];
  const notices = [];
  const eventNames = Object.fromEntries([
    "connected", "disconnected", "connectionClosed", "error", "info", "currentTime",
    "managedAccounts", "accountSummary", "accountSummaryEnd", "position", "positionEnd",
    "updatePortfolio", "accountDownloadEnd", "openOrder",
  ].map((name) => [name, name]));
  const adapter = createBrokerSessionAdapter({
    targetAccount: "PAPER-ACCT-01",
    eventNames,
    now: () => iso(START),
    hooks: {
      onAccountSubscriptionConflict: (code) => codes.push(code),
      onBrokerNotice: (notice) => notices.push(notice),
    },
  });
  const api = new FakeApi();
  adapter.attach(api);
  api.emit("connected");
  for (const route of ["info", "error"]) {
    for (const code of [2100, 2101]) api.emit(route, "synthetic broker notice", code);
  }
  assert.deepEqual(codes, [2100, 2101, 2100, 2101]);
  assert.deepEqual(notices.map(({ route, code }) => ({ route, code })), [
    { route: "info", code: 2100 }, { route: "info", code: 2101 },
    { route: "error", code: 2100 }, { route: "error", code: 2101 },
  ]);
  assert.equal(adapter.socketConnected, true, "account notices must not reconnect the broker socket");
});

test("adapter refresh uses the same session and preserves prices, coverage and mark clock", () => {
  const targetAccount = "PAPER-ACCT-01";
  let now = iso(START);
  const eventNames = Object.fromEntries([
    "connected", "disconnected", "connectionClosed", "error", "info", "currentTime",
    "managedAccounts", "accountSummary", "accountSummaryEnd", "position", "positionEnd",
    "updatePortfolio", "accountDownloadEnd", "openOrder",
  ].map((name) => [name, name]));
  const adapter = createBrokerSessionAdapter({ targetAccount, eventNames, now: () => now });
  const api = new FakeApi();
  assert.equal(adapter.refreshPortfolio(), false);
  adapter.attach(api);
  api.emit("connected");
  api.emit("managedAccounts", targetAccount);
  const stock = contract("INTC");
  api.emit("position", targetAccount, stock, 4, 30);
  api.emit("updatePortfolio", stock, 4, 20, 80, 30, 1, 0, targetAccount);
  api.emit("positionEnd");
  api.emit("accountSummary", 9501, targetAccount, "NetLiquidation", "12000", "EUR");
  api.emit("accountSummaryEnd", 9501);
  api.emit("accountDownloadEnd", targetAccount);
  const before = adapter.snapshot();
  assert.equal(before.positionsCoverage.status, "complete");
  now = iso(START + 240_000);
  api.requests.length = 0;
  assert.equal(adapter.refreshPortfolio(), true);
  assert.deepEqual(api.requests, [[false, targetAccount], [true, targetAccount]]);
  assert.deepEqual(adapter.snapshot(), before);
  api.emit("updatePortfolio", stock, 4, undefined, undefined, undefined, undefined, undefined, targetAccount);
  assert.equal(adapter.snapshot().portfolio[0].markObservedAt, iso(START));
  now = iso(START + 241_000);
  api.emit("updatePortfolio", stock, 4, 21, 84, 30, 2, 0, targetAccount);
  assert.equal(adapter.snapshot().portfolio[0].markObservedAt, now);
  assert.equal(adapter.snapshot().portfolio[0].marketPrice, 21);
  assert.equal(adapter.snapshot().positionsCoverage.status, "complete");
});
