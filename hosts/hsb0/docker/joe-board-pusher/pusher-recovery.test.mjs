#!/usr/bin/env node
/** Deterministic socket-recovery tests. No timers or network leave this process. */
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";

import {
  createConnectionSupervisor,
  createReconnectScheduler,
} from "./pusher-recovery.mjs";
import { createBrokerSessionAdapter } from "./pusher-state.mjs";

function fakeTimers() {
  let nextId = 0;
  const pending = new Map();
  return {
    set(callback, delay) {
      const id = ++nextId;
      pending.set(id, { callback, delay });
      return id;
    },
    clear(id) { pending.delete(id); },
    take(delay) {
      const entry = [...pending.entries()].find(([, timer]) => timer.delay === delay);
      assert.ok(entry, `no ${delay}ms timer pending`);
      pending.delete(entry[0]);
      return entry[1].callback;
    },
    run(delay) {
      this.take(delay)();
    },
    count(delay) {
      return [...pending.values()].filter((timer) => delay === undefined || timer.delay === delay).length;
    },
    id(delay) {
      return [...pending.entries()].find(([, timer]) => timer.delay === delay)?.[0] ?? null;
    },
  };
}

class FakeApi {
  connects = 0;
  disconnects = 0;
  connect() { this.connects += 1; }
  disconnect() { this.disconnects += 1; }
}

function virtualTimers() {
  let now = 0;
  let nextId = 0;
  const pending = new Map();
  return {
    set(callback, delay) {
      const id = ++nextId;
      pending.set(id, { callback, due: now + delay });
      return id;
    },
    clear(id) { pending.delete(id); },
    advance(duration) {
      const end = now + duration;
      for (;;) {
        const next = [...pending.entries()]
          .filter(([, timer]) => timer.due <= end)
          .sort((left, right) => left[1].due - right[1].due || left[0] - right[0])[0];
        if (!next) break;
        pending.delete(next[0]);
        now = next[1].due;
        next[1].callback();
      }
      now = end;
    },
    count() { return pending.size; },
    get now() { return now; },
  };
}

test("reconnect scheduler deduplicates and ramps to its cap until stable reset", () => {
  const timers = fakeTimers();
  const fired = [];
  const scheduler = createReconnectScheduler({
    baseDelayMs: 1_000,
    maxDelayMs: 4_000,
    jitterRatio: 0,
    random: () => 0.5,
    setTimer: timers.set,
    clearTimer: timers.clear,
    onRetry: (item) => fired.push(item),
  });

  assert.equal(scheduler.schedule("first"), true);
  assert.equal(scheduler.schedule("duplicate"), false);
  timers.run(1_000);
  assert.deepEqual(fired, [{ attempt: 1, delayMs: 1_000, reason: "first" }]);
  scheduler.schedule("second");
  timers.run(2_000);
  scheduler.schedule("third");
  timers.run(4_000);
  scheduler.schedule("capped");
  timers.run(4_000);
  assert.deepEqual(fired.map(({ delayMs }) => delayMs), [1_000, 2_000, 4_000, 4_000]);

  scheduler.schedule("cancelled by stable data");
  assert.equal(timers.count(), 1);
  scheduler.reset();
  assert.equal(timers.count(), 0);
  assert.equal(scheduler.attempt, 0);
  scheduler.schedule("after stable data");
  assert.equal(scheduler.lastDelayMs, 1_000);
});

test("scheduler applies deterministic bounded jitter", () => {
  const timers = fakeTimers();
  const samples = [0, 1];
  const scheduler = createReconnectScheduler({
    baseDelayMs: 1_000,
    maxDelayMs: 2_000,
    jitterRatio: 0.2,
    random: () => samples.shift(),
    setTimer: timers.set,
    clearTimer: timers.clear,
    onRetry: () => {},
  });
  scheduler.schedule();
  assert.equal(scheduler.lastDelayMs, 800);
  timers.run(800);
  scheduler.schedule();
  assert.equal(scheduler.lastDelayMs, 2_000);
});

test("one supervisor owns every socket generation and TCP connect does not reset backoff", () => {
  const timers = fakeTimers();
  const apis = [];
  const attached = [];
  const retryDelays = [];
  const supervisor = createConnectionSupervisor({
    createApi() {
      const api = new FakeApi();
      apis.push(api);
      return api;
    },
    attachApi: (api) => attached.push(api),
    requestHealth: () => {},
    onRetryScheduled: ({ delayMs }) => retryDelays.push(delayMs),
    baseDelayMs: 10,
    maxDelayMs: 40,
    jitterRatio: 0,
    connectTimeoutMs: 100,
    snapshotTimeoutMs: 200,
    healthIntervalMs: 1_000,
    healthTimeoutMs: 50,
    setTimer: timers.set,
    clearTimer: timers.clear,
  });

  assert.equal(supervisor.start(), true);
  assert.equal(supervisor.start(), false);
  assert.equal(apis.length, 1);
  assert.equal(apis[0].connects, 1);
  supervisor.socketConnected(apis[0]);
  assert.equal(supervisor.reconnect(apis[0], "EOF"), true);
  assert.equal(supervisor.reconnect(apis[0], "duplicate EOF"), false);
  assert.deepEqual(retryDelays, [10]);

  timers.run(10);
  assert.equal(apis.length, 2);
  assert.equal(attached.length, 2);
  assert.equal(apis[0].disconnects, 1);
  supervisor.socketConnected(apis[1]);
  assert.equal(supervisor.retryAttempt, 1);
  supervisor.reconnect(apis[1], "ECONNRESET");
  assert.deepEqual(retryDelays, [10, 20]);
  timers.run(20);

  assert.equal(apis.length, 3);
  supervisor.socketConnected(apis[2]);
  assert.equal(supervisor.socketActivity(apis[0]), false);
  assert.equal(supervisor.reconnect(apis[0], "old generation"), false);
  assert.equal(supervisor.activeApi, apis[2]);
  supervisor.stable(apis[2]);
  assert.equal(supervisor.retryAttempt, 0);
  supervisor.reconnect(apis[2], "after stable recovery");
  assert.deepEqual(retryDelays, [10, 20, 10]);
});

test("connection and health callback timeouts use the same retry scheduler", () => {
  const timers = fakeTimers();
  const apis = [];
  const failures = [];
  let healthRequests = 0;
  const supervisor = createConnectionSupervisor({
    createApi() {
      const api = new FakeApi();
      apis.push(api);
      return api;
    },
    attachApi: () => {},
    requestHealth: () => { healthRequests += 1; },
    onAttemptFailure: (_api, reason) => failures.push(reason),
    baseDelayMs: 10,
    maxDelayMs: 40,
    jitterRatio: 0,
    connectTimeoutMs: 100,
    healthIntervalMs: 1_000,
    healthTimeoutMs: 50,
    setTimer: timers.set,
    clearTimer: timers.clear,
  });

  supervisor.start();
  timers.run(100);
  assert.match(failures[0], /connection attempt timed out/);
  assert.equal(supervisor.retryPending, true);
  timers.run(10);
  supervisor.socketConnected(apis[1]);
  timers.run(1_000);
  assert.equal(healthRequests, 1);
  timers.run(50);
  assert.match(failures[1], /health callback timed out/);
  assert.equal(supervisor.retryPending, true);
  assert.equal(supervisor.retryAttempt, 2);
});

test("responsive callbacks cannot extend the complete-snapshot deadline", () => {
  const timers = fakeTimers();
  const apis = [];
  const failures = [];
  let healthRequests = 0;
  const supervisor = createConnectionSupervisor({
    createApi() {
      const api = new FakeApi();
      apis.push(api);
      return api;
    },
    attachApi: () => {},
    requestHealth: () => { healthRequests += 1; },
    onAttemptFailure: (_api, reason) => failures.push(reason),
    baseDelayMs: 10,
    maxDelayMs: 40,
    jitterRatio: 0,
    connectTimeoutMs: 100,
    snapshotTimeoutMs: 200,
    healthIntervalMs: 50,
    healthTimeoutMs: 20,
    upstreamLossDeadlineMs: 500,
    setTimer: timers.set,
    clearTimer: timers.clear,
  });

  supervisor.start();
  supervisor.socketConnected(apis[0]);
  const deadlineId = timers.id(200);
  assert.notEqual(deadlineId, null);

  timers.run(50);
  assert.equal(healthRequests, 1);
  supervisor.socketActivity(apis[0]); // currentTime response
  supervisor.socketActivity(apis[0]); // partial financial callback
  assert.equal(timers.id(200), deadlineId);

  const oldDeadline = timers.take(200);
  oldDeadline();
  assert.deepEqual(failures, ["broker complete snapshot timed out"]);
  assert.equal(apis[0].disconnects, 1);
  assert.equal(supervisor.retryPending, true);

  timers.run(10);
  assert.equal(apis.length, 2);
  supervisor.socketConnected(apis[1]);
  assert.equal(timers.count(200), 1);
  oldDeadline();
  assert.equal(failures.length, 1);
  assert.equal(supervisor.activeApi, apis[1]);

  supervisor.stable(apis[1]);
  assert.equal(timers.count(200), 0);
  assert.equal(supervisor.retryAttempt, 0);
  supervisor.shutdown();
  assert.equal(timers.count(), 0);
});

test("real callback activity satisfies health and shutdown cancels every timer", () => {
  const timers = fakeTimers();
  const api = new FakeApi();
  let healthRequests = 0;
  const supervisor = createConnectionSupervisor({
    createApi: () => api,
    attachApi: () => {},
    requestHealth: () => { healthRequests += 1; },
    baseDelayMs: 10,
    maxDelayMs: 40,
    jitterRatio: 0,
    connectTimeoutMs: 100,
    snapshotTimeoutMs: 200,
    healthIntervalMs: 1_000,
    healthTimeoutMs: 50,
    setTimer: timers.set,
    clearTimer: timers.clear,
  });
  supervisor.start();
  supervisor.socketConnected(api);
  timers.run(1_000);
  assert.equal(healthRequests, 1);
  assert.equal(timers.count(50), 1);
  supervisor.socketActivity(api);
  assert.equal(timers.count(50), 0);
  assert.equal(timers.count(1_000), 1);
  supervisor.upstreamUnavailable(api);
  assert.equal(timers.count(300_000), 1);
  supervisor.shutdown();
  assert.equal(timers.count(), 0);
  assert.equal(api.disconnects, 1);
  assert.equal(supervisor.start(), false);
});

test("upstream loss has an absolute deadline that no callback or repeated notice can extend", () => {
  const timers = fakeTimers();
  const api = new FakeApi();
  let healthRequests = 0;
  const failures = [];
  const supervisor = createConnectionSupervisor({
    createApi: () => api,
    attachApi: () => {},
    requestHealth: () => { healthRequests += 1; },
    onAttemptFailure: (_api, reason) => failures.push(reason),
    baseDelayMs: 10,
    maxDelayMs: 40,
    jitterRatio: 0,
    connectTimeoutMs: 100,
    snapshotTimeoutMs: 200,
    healthIntervalMs: 1_000,
    healthTimeoutMs: 50,
    upstreamLossDeadlineMs: 5_000,
    setTimer: timers.set,
    clearTimer: timers.clear,
  });
  supervisor.start();
  supervisor.socketConnected(api);
  assert.equal(timers.count(200), 1);
  supervisor.upstreamUnavailable(api);
  assert.equal(timers.count(200), 0);
  assert.equal(timers.count(5_000), 1);
  const deadlineId = timers.id(5_000);
  assert.equal(healthRequests, 0);

  supervisor.socketActivity(api);
  supervisor.socketActivity(api);
  supervisor.upstreamUnavailable(api);
  assert.equal(timers.count(5_000), 1);
  assert.equal(timers.id(5_000), deadlineId);
  assert.equal(api.disconnects, 0);
  assert.equal(supervisor.retryPending, false);
  timers.run(5_000);
  assert.match(failures[0], /upstream loss deadline expired/);
  assert.equal(api.disconnects, 1);
  assert.equal(supervisor.retryPending, true);
});

test("a genuine continuing outage retries only after each absolute deadline and capped backoff", () => {
  const timers = fakeTimers();
  const apis = [];
  const retryDelays = [];
  const supervisor = createConnectionSupervisor({
    createApi() {
      const api = new FakeApi();
      apis.push(api);
      return api;
    },
    attachApi: () => {},
    requestHealth: () => {},
    onRetryScheduled: ({ delayMs }) => retryDelays.push(delayMs),
    baseDelayMs: 10,
    maxDelayMs: 40,
    jitterRatio: 0,
    connectTimeoutMs: 100,
    snapshotTimeoutMs: 200,
    healthIntervalMs: 1_000,
    healthTimeoutMs: 50,
    upstreamLossDeadlineMs: 5_000,
    setTimer: timers.set,
    clearTimer: timers.clear,
  });

  supervisor.start();
  supervisor.socketConnected(apis[0]);
  supervisor.stable(apis[0]);
  supervisor.upstreamUnavailable(apis[0]);
  supervisor.upstreamUnavailable(apis[0]);
  timers.run(5_000);
  assert.deepEqual(retryDelays, [10]);
  assert.equal(apis.length, 1);

  timers.run(10);
  supervisor.socketConnected(apis[1]);
  supervisor.upstreamUnavailable(apis[1]);
  supervisor.socketActivity(apis[1]);
  timers.run(5_000);
  assert.deepEqual(retryDelays, [10, 20]);
  assert.equal(apis.length, 2);

  timers.run(20);
  assert.equal(apis.length, 3);
  assert.equal(supervisor.retryAttempt, 2);
  supervisor.shutdown();
  assert.equal(timers.count(), 0);
});

test("reviewer repro: 2110 with recurring 2104 and financial callbacks still recovers once", () => {
  const timers = virtualTimers();
  const account = "SYNTHETIC-PAPER";
  const contract = { conId: 1, symbol: "INTC", secType: "STK", currency: "USD" };
  const events = Object.fromEntries([
    "connected",
    "disconnected",
    "connectionClosed",
    "error",
    "info",
    "currentTime",
    "managedAccounts",
    "accountSummary",
    "accountSummaryEnd",
    "position",
    "positionEnd",
    "updatePortfolio",
    "accountDownloadEnd",
    "openOrder",
  ].map((name) => [name, name]));
  const apis = [];
  const retries = [];

  function emitCompleteBook(api) {
    api.emit(events.managedAccounts, account);
    api.emit(events.position, account, contract, 10, 20);
    api.emit(events.positionEnd);
    api.emit(events.accountSummary, 9501, account, "NetLiquidation", "12000", "EUR");
    api.emit(events.accountSummaryEnd, 9501);
    api.emit(events.accountDownloadEnd, account);
  }

  class ReviewerApi extends EventEmitter {
    connects = 0;
    disconnects = 0;
    connect() {
      this.connects += 1;
      timers.set(() => {
        this.emit(events.connected);
        emitCompleteBook(this);
      }, 100);
    }
    disconnect() { this.disconnects += 1; }
    reqManagedAccts() {}
    reqPositions() {}
    reqAllOpenOrders() {}
    reqAccountSummary() {}
    reqAccountUpdates() {}
    reqCurrentTime() { timers.set(() => this.emit(events.currentTime, 1), 10); }
  }

  let supervisor;
  const adapter = createBrokerSessionAdapter({
    targetAccount: account,
    eventNames: events,
    now: () => new Date(timers.now).toISOString(),
    hooks: {
      onConnected: ({ api }) => supervisor.socketConnected(api),
      onSocketActivity: ({ api }) => supervisor?.socketActivity(api),
      onStableData: ({ api }) => supervisor.stable(api),
      onReconnectNeeded: ({ api, reason }) => supervisor.reconnect(api, reason),
      onUpstreamUnavailable: ({ api }) => supervisor.upstreamUnavailable(api),
    },
  });
  supervisor = createConnectionSupervisor({
    createApi() {
      const api = new ReviewerApi();
      apis.push(api);
      return api;
    },
    attachApi: (api) => adapter.attach(api),
    requestHealth: (api) => api.reqCurrentTime(),
    onAttemptFailure: (api, reason) => api && adapter.fail(api, reason),
    onRetryScheduled: ({ delayMs }) => retries.push(delayMs),
    random: () => 0.5,
    setTimer: timers.set,
    clearTimer: timers.clear,
  });

  supervisor.start();
  timers.advance(1_000);
  const accepted = adapter.snapshot();
  assert.equal(accepted.positionsCoverage.status, "complete");

  apis[0].emit(events.info, "Connectivity between TWS and server is broken", 2110);
  apis[0].emit(events.info, "Repeated outage notice", 2110);
  timers.advance(60_000);
  apis[0].emit(events.info, "Market data farm connection is OK", 2104);
  timers.advance(180_000);
  apis[0].emit(events.updatePortfolio, contract, 10, 21, 210, 20, 10, 0, account);
  const unavailable = adapter.snapshot();
  assert.equal(unavailable.gateway, false);
  assert.equal(unavailable.positionsCoverage.status, "unavailable");
  assert.equal(unavailable.ts, accepted.ts);
  assert.equal(unavailable.gatewayLastSeenAt, accepted.gatewayLastSeenAt);

  for (let index = 1; index < 480; index += 1) {
    timers.advance(180_000);
    apis[0].emit(events.updatePortfolio, contract, 10, 21, 210, 20, 10, 0, account);
  }

  const recovered = adapter.snapshot();
  assert.equal(apis.length, 2);
  assert.equal(apis[0].disconnects, 1);
  assert.deepEqual(retries, [5_000]);
  assert.equal(supervisor.retryPending, false);
  assert.equal(adapter.connected, true);
  assert.equal(recovered.positionsCoverage.status, "complete");
  assert.equal(recovered.positions[0].pos, 10);
  assert.ok(recovered.ts > accepted.ts);

  apis[0].emit(events.position, account, contract, 999, 20);
  apis[0].emit(events.positionEnd);
  apis[0].emit(events.accountDownloadEnd, account);
  assert.equal(adapter.snapshot().positions[0].pos, 10);

  adapter.retire("test shutdown");
  supervisor.shutdown();
  assert.equal(timers.count(), 0);
});
