#!/usr/bin/env node
/** Deterministic socket-recovery tests. No timers or network leave this process. */
import assert from "node:assert/strict";
import test from "node:test";

import {
  createConnectionSupervisor,
  createReconnectScheduler,
} from "./pusher-recovery.mjs";

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
    upstreamSilenceTimeoutMs: 500,
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
  supervisor.shutdown();
  assert.equal(timers.count(), 0);
  assert.equal(api.disconnects, 1);
  assert.equal(supervisor.start(), false);
});

test("sustained upstream notices retain the socket while bounded silence recovers it", () => {
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
    upstreamSilenceTimeoutMs: 5_000,
    setTimer: timers.set,
    clearTimer: timers.clear,
  });
  supervisor.start();
  supervisor.socketConnected(api);
  assert.equal(timers.count(200), 1);
  supervisor.upstreamUnavailable(api);
  assert.equal(timers.count(200), 0);
  assert.equal(timers.count(5_000), 1);
  assert.equal(healthRequests, 0);

  supervisor.socketActivity(api);
  assert.equal(timers.count(5_000), 1);
  assert.equal(api.disconnects, 0);
  assert.equal(supervisor.retryPending, false);
  timers.run(5_000);
  assert.match(failures[0], /silent during upstream outage/);
  assert.equal(api.disconnects, 1);
  assert.equal(supervisor.retryPending, true);
});
