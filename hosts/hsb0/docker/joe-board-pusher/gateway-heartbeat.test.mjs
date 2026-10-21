import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { readFileSync } from "node:fs";
import test from "node:test";
import { createConnectionSupervisor } from "./pusher-recovery.mjs";
import { createBrokerSessionAdapter } from "./pusher-state.mjs";
import { copyObservation } from "./v2-stage-handoff.mjs";
import { buildCandidate } from "./v2-stage-worker.mjs";

const start = "2026-10-21T11:00:00.000Z";
const account = "DUFIXTURE";
const contract = { conId: 1, symbol: "INTC", secType: "STK", currency: "USD" };
const events = Object.fromEntries([
  "connected", "disconnected", "connectionClosed", "error", "info", "currentTime", "managedAccounts",
  "position", "positionEnd", "accountSummary", "accountSummaryEnd", "accountDownloadEnd",
  "updatePortfolio", "openOrder", "openOrderEnd",
].map(name => [name, name]));
const pusherSource = readFileSync(new URL("./pusher.mjs", import.meta.url), "utf8");
const setting = name => Number(pusherSource.match(new RegExp(`^const ${name} = ([\\d_]+);`, "m"))?.[1].replaceAll("_", ""));
const healthIntervalMs = setting("HEALTH_INTERVAL_MS");
const healthTimeoutMs = setting("HEALTH_TIMEOUT_MS");

function clock() {
  let elapsed = 0, id = 0;
  const pending = new Map();
  return {
    set(callback, delay) { pending.set(++id, { callback, due: elapsed + delay }); return id; },
    clear(key) { pending.delete(key); },
    advance(ms) {
      const end = elapsed + ms;
      for (;;) {
        const next = [...pending.entries()].filter(([, timer]) => timer.due <= end)
          .sort((a, b) => a[1].due - b[1].due || a[0] - b[0])[0];
        if (!next) break;
        pending.delete(next[0]); elapsed = next[1].due; next[1].callback();
      }
      elapsed = end;
    },
    now: () => new Date(Date.parse(start) + elapsed).toISOString(),
    get elapsed() { return elapsed; },
    get pending() { return pending.size; },
  };
}

function session({ supervised = false, replyDelayMs = 1_000 } = {}) {
  const time = clock(), apis = [], requests = [], failures = [];
  let supervisor, inFlight = 0, maximumInFlight = 0;
  function makeApi() {
    const api = Object.assign(new EventEmitter(), Object.fromEntries([
      "reqManagedAccts", "reqPositions", "cancelPositions", "reqAllOpenOrders", "reqAccountSummary", "reqAccountUpdates",
    ].map(method => [method, (...args) => requests.push({ api, method, at: time.elapsed, args })])));
    api.connect = () => api.emit("connected");
    api.disconnect = () => {};
    api.reqCurrentTime = () => {
      requests.push({ api, method: "reqCurrentTime", at: time.elapsed });
      maximumInFlight = Math.max(maximumInFlight, ++inFlight);
      if (replyDelayMs === null) return;
      const reply = () => { --inFlight; api.emit("currentTime", 0); };
      if (replyDelayMs === 0) reply(); else time.set(reply, replyDelayMs);
    };
    apis.push(api);
    return api;
  }
  const adapter = createBrokerSessionAdapter({
    targetAccount: account, eventNames: events, now: time.now,
    hooks: {
      onConnected: ({ api }) => supervisor?.socketConnected(api),
      onSocketActivity: ({ api, event }) => supervisor?.socketActivity(api, event),
      onStableData: ({ api }) => supervisor?.stable(api),
      onReconnectNeeded: ({ api, reason }) => supervisor?.reconnect(api, reason),
      onUpstreamUnavailable: ({ api }) => supervisor?.upstreamUnavailable(api),
    },
  });
  function complete(api) {
    api.emit("managedAccounts", account);
    api.emit("position", account, contract, 3, 10);
    api.emit("positionEnd");
    api.emit("accountSummary", 9501, account, "NetLiquidation", "12345.67000000", "EUR");
    api.emit("accountSummary", 9501, account, "TotalCashValue", "-12.3400", "EUR");
    api.emit("accountSummaryEnd", 9501);
    api.emit("accountDownloadEnd", account);
    api.emit("openOrderEnd");
  }
  if (supervised) {
    supervisor = createConnectionSupervisor({
      createApi: makeApi, attachApi: api => adapter.attach(api), requestHealth: api => api.reqCurrentTime(),
      onAttemptFailure(api, reason) { failures.push(reason); adapter.fail(api, reason); },
      healthIntervalMs, healthTimeoutMs, random: () => 0.5, setTimer: time.set, clearTimer: time.clear,
    });
    supervisor.start();
  } else {
    adapter.attach(makeApi()); apis[0].connect();
  }
  const api = apis[0];
  complete(api);
  return {
    time, api, adapter, supervisor, requests, failures, makeApi, complete,
    candidate: () => buildCandidate(1, time.now(), copyObservation({ book: adapter.snapshot() })),
    get maximumInFlight() { return maximumInFlight; },
  };
}

test("production health settings use 20-second probes with a shorter 15-second deadline", () => {
  assert.equal(healthIntervalMs, 20_000);
  assert.equal(healthTimeoutMs, 15_000);
  assert.match(pusherSource, /healthIntervalMs: HEALTH_INTERVAL_MS/);
  assert.match(pusherSource, /healthTimeoutMs: HEALTH_TIMEOUT_MS/);
});

test("currentTime stamps local receipt and republishes a complete book without renewing its economic clocks", () => {
  const s = session();
  s.api.emit("updatePortfolio", contract, 3, 20, 60, 10, 1, 0, account);
  const before = s.adapter.snapshot(), requests = [...s.requests];
  s.time.advance(20_000); s.api.emit("currentTime", 0);
  const after = s.adapter.snapshot();
  assert.equal(after.apiReplyCheckedAt, s.time.now(), "never use the broker's wire time");
  assert.equal(after.ts, s.time.now(), "use the existing publication path");
  assert.equal(after.gatewayLastSeenAt, s.time.now());
  for (const field of ["positionsCoverage", "positions", "portfolio", "summary", "summaryObservedAt", "ordersObservedAt"]) {
    assert.deepEqual(after[field], before[field], field);
  }
  assert.deepEqual(s.requests, requests, "handling the reply sends no request or account write");
});

for (const transition of ["disconnected", "connectionClosed", "retire", "attach", "upstream loss"]) {
  test(`currentTime cannot revive a cleared check after ${transition}`, () => {
    const s = session(); s.time.advance(20_000);
    if (transition === "retire") s.adapter.retire();
    else if (transition === "attach") s.adapter.attach(s.makeApi());
    else if (transition === "upstream loss") s.api.emit("info", "synthetic outage", 1100);
    else s.api.emit(transition);
    const before = s.adapter.snapshot();
    assert.equal(before.apiReplyCheckedAt, null);
    assert.equal(s.adapter.socketConnected, transition === "upstream loss");
    s.api.emit("currentTime", 0);
    assert.deepEqual(s.adapter.snapshot(), before);
  });
}

test("a retired generation cannot renew the current generation's established session", () => {
  const s = session(), next = s.makeApi();
  s.time.advance(20_000); s.adapter.attach(next); next.connect(); s.complete(next);
  const before = s.adapter.snapshot();
  s.time.advance(20_000); s.api.emit("currentTime", 0);
  assert.deepEqual(s.adapter.snapshot(), before);
  next.emit("currentTime", 0);
  assert.equal(s.adapter.snapshot().apiReplyCheckedAt, s.time.now());
});

for (const phase of ["no handshake", "no target account", "partial target book"]) {
  test(`a heartbeat cannot authenticate or publish a non-working session: ${phase}`, () => {
    const s = session(), next = s.makeApi();
    s.adapter.attach(next); s.time.advance(20_000);
    if (phase !== "no handshake") next.connect();
    if (phase === "no target account") {
      next.emit("managedAccounts", "OTHER-ACCOUNT"); next.emit("positionEnd");
      next.emit("accountSummary", 9501, "OTHER-ACCOUNT", "NetLiquidation", "999", "EUR");
      next.emit("accountDownloadEnd", "OTHER-ACCOUNT");
    }
    if (phase === "partial target book") {
      next.emit("managedAccounts", account); next.emit("position", account, contract, 99, 10);
    }
    const before = s.adapter.snapshot();
    next.emit("currentTime", 0);
    assert.equal(s.adapter.snapshot().apiReplyCheckedAt, null);
    assert.deepEqual(s.adapter.snapshot(), before, "no partial publication");
  });
}

test("a heartbeat during an unfinished positions refresh retains the completed rows and coverage clock", () => {
  const s = session(), before = s.adapter.snapshot();
  s.time.advance(120_000); assert.equal(s.adapter.refreshPositions(), true);
  s.api.emit("position", account, contract, 99, 10);
  s.time.advance(20_000); s.api.emit("currentTime", 0);
  assert.equal(s.adapter.snapshot().apiReplyCheckedAt, s.time.now());
  assert.deepEqual(s.adapter.snapshot().positions, before.positions);
  assert.deepEqual(s.adapter.snapshot().positionsCoverage, before.positionsCoverage);
  s.api.emit("positionEnd");
  assert.equal(s.adapter.snapshot().positions[0].pos, 99);
  assert.equal(s.adapter.snapshot().positionsCoverage.observedAt, s.time.now());
});

test("periodic replies keep staged gateway and account money ready across a full 120-second positions cycle on a busy socket", () => {
  const s = session({ supervised: true });
  let keep;
  for (let ms = 0; ms <= 121_000; ms += 1_000) {
    if (ms) s.time.advance(1_000);
    s.api.emit("info", "synthetic activity", 2104);
    if (ms % 5_000 === 0 && s.adapter.refreshPositions()) {
      s.api.emit("position", account, contract, 3, 10); s.api.emit("positionEnd");
    }
    const value = s.candidate();
    assert.equal(value.safety.gateway.apiSessionReady, true, `at ${ms}ms`);
    assert.equal(value.safety.gateway.reason, undefined);
    assert.equal(value.brokerAccount.equity.amount, "12345.67000000");
    assert.equal(value.brokerAccount.cash.amount, "-12.3400");
    assert.equal(value.brokerAccount.observedAt, start, "heartbeat does not refresh account source time");
    assert.equal(s.adapter.snapshot().positionsCoverage.observedAt,
      ms < 120_000 ? start : new Date(Date.parse(start) + 120_000).toISOString());
    const rows = value.positions.rows.filter(row => row.scope === "keep");
    keep ??= rows; assert.deepEqual(rows, keep, "KEEP is unchanged");
  }
  assert.deepEqual(s.requests.filter(r => r.method === "reqCurrentTime").map(r => r.at),
    [20_000, 40_000, 60_000, 80_000, 100_000, 120_000]);
  assert.deepEqual(s.requests.filter(r => r.method === "reqPositions").map(r => r.at), [0, 120_000]);
  assert.equal(s.adapter.snapshot().apiReplyCheckedAt, s.time.now());
  assert.equal(s.maximumInFlight, 1);
  assert.deepEqual(s.failures, []);
  s.supervisor.shutdown(); assert.equal(s.time.pending, 0);
});

test("without qualifying replies the staged gateway becomes unconfirmed at exactly 60 seconds despite other activity", () => {
  const s = session();
  for (const ms of [59_999, 60_000, 60_001, 119_999]) {
    s.time.advance(ms - s.time.elapsed);
    s.api.emit("updatePortfolio", contract, 3, 20, 60, 10, 1, 0, account);
    s.api.emit("accountDownloadEnd", account);
    const value = s.candidate(), ready = ms < 60_000;
    assert.equal(value.safety.gateway.checkedAt, start);
    assert.equal(value.safety.gateway.apiSessionReady, ready);
    assert.equal(value.safety.gateway.reason, ready ? undefined : "gateway_unconfirmed");
    if (!ready) {
      assert.equal(value.brokerAccount.equity, null); assert.equal(value.brokerAccount.cash, null);
      assert.equal(value.positions.reason, "gateway_unconfirmed");
    }
  }
});

for (const replyDelayMs of [0, 14_999]) {
  test(`20-second probes do not overlap or falsely time out with ${replyDelayMs}ms reply latency`, () => {
    const s = session({ supervised: true, replyDelayMs });
    for (let ms = 1_000; ms <= 95_000; ms += 1_000) {
      s.time.advance(1_000); s.api.emit("info", "synthetic traffic", 2104);
    }
    assert.deepEqual(s.requests.filter(r => r.method === "reqCurrentTime").map(r => r.at), [20_000, 40_000, 60_000, 80_000]);
    assert.equal(s.maximumInFlight, 1); assert.deepEqual(s.failures, []);
    s.supervisor.shutdown(); assert.equal(s.time.pending, 0);
  });
}

test("unrelated callbacks cannot acknowledge a missing heartbeat or overlap its request", () => {
  const s = session({ supervised: true, replyDelayMs: null });
  for (let ms = 1_000; ms < 35_000; ms += 1_000) {
    s.time.advance(1_000); s.api.emit("info", "synthetic traffic", 2104);
  }
  assert.deepEqual(s.failures, []);
  s.time.advance(999); assert.deepEqual(s.failures, []);
  s.time.advance(1);
  assert.deepEqual(s.failures, ["broker socket health callback timed out"]);
  assert.equal(s.adapter.snapshot().apiReplyCheckedAt, null);
  s.api.emit("currentTime", 0);
  assert.equal(s.adapter.snapshot().apiReplyCheckedAt, null, "late reply from the retired generation is ignored");
  assert.equal(s.requests.filter(r => r.method === "reqCurrentTime").length, 1);
  assert.equal(s.maximumInFlight, 1);
  s.supervisor.shutdown(); assert.equal(s.time.pending, 0);
});
