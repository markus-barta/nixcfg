#!/usr/bin/env node
/** Synthetic JSONL/helper tests. No broker connection or private capture data. */
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";

import {
  EXECUTION_QUERY_REQUEST_SCHEMA,
  EXECUTION_QUERY_RESULT_SCHEMA,
  createExecutionHistorySupervisor,
  validateExecutionQueryRequest,
  validateExecutionQueryResult,
} from "./execution-history.mjs";

const ACCOUNT = "DU123456";
const DAY = "20260910";

function request(overrides = {}) {
  return {
    schema: EXECUTION_QUERY_REQUEST_SCHEMA,
    cycleId: "cycle-1",
    account: ACCOUNT,
    specificDates: [DAY],
    ...overrides,
  };
}

function execution(execId = "synthetic.1.01", overrides = {}) {
  return {
    contract: {
      conId: 101,
      symbol: "acme",
      secType: "stk",
      currency: "usd",
      multiplier: 0,
      ignoredSdkField: "not persisted",
    },
    execution: {
      execId,
      time: `${DAY} 09:30:00 US/Eastern`,
      acctNumber: ACCOUNT,
      clientId: 27,
      side: "BOT",
      shares: 2,
      price: 10,
      pendingPriceRevision: false,
      realizedPNL: 999,
      ...overrides,
    },
  };
}

function result(overrides = {}) {
  const row = execution();
  return {
    schema: EXECUTION_QUERY_RESULT_SCHEMA,
    cycleId: "cycle-1",
    account: ACCOUNT,
    sdkVersion: "10.45.1",
    serverVersion: 223,
    framing: "protobuf",
    requests: [{
      date: DAY,
      requestedAt: "2026-09-10T12:00:00Z",
      endedAt: "2026-09-10T12:00:01Z",
      executions: [row],
      errors: [],
    }],
    commissions: [{ execId: row.execution.execId, commission: 0.25, currency: "usd" }],
    errors: [],
    finishedAt: "2026-09-10T12:00:02Z",
    ...overrides,
  };
}

class FakeChild extends EventEmitter {
  constructor() {
    super();
    this.stdout = new EventEmitter();
    this.stderr = new EventEmitter();
    this.writes = [];
    this.kills = [];
    this.exitCode = null;
    this.signalCode = null;
    this.stdin = {
      write: (line, callback) => {
        this.writes.push(line);
        callback?.(null);
        return true;
      },
    };
  }

  kill(signal) {
    this.kills.push(signal);
    this.signalCode = signal;
    return true;
  }
}

function fakeTimers() {
  let nextId = 0;
  const timers = new Map();
  return {
    set(fn, delay) {
      const id = ++nextId;
      timers.set(id, { fn, delay });
      return id;
    },
    clear(id) { timers.delete(id); },
    run(delay) {
      const item = [...timers.entries()].find(([, timer]) => timer.delay === delay);
      assert.ok(item, `missing ${delay}ms timer`);
      timers.delete(item[0]);
      item[1].fn();
    },
  };
}

test("request and result validators enforce the original account-scoped seam", () => {
  const expected = validateExecutionQueryRequest(request());
  const normalized = validateExecutionQueryResult(result(), expected);
  assert.deepEqual(normalized.requests[0].executions[0], {
    contract: {
      conId: 101,
      symbol: "ACME",
      secType: "STK",
      currency: "USD",
      multiplier: 1,
    },
    execution: {
      execId: "synthetic.1.01",
      time: `${DAY} 09:30:00 US/Eastern`,
      acctNumber: ACCOUNT,
      clientId: 27,
      side: "BUY",
      shares: 2,
      price: 10,
      pendingPriceRevision: false,
    },
  });
  assert.deepEqual(normalized.commissions, [
    { execId: "synthetic.1.01", commission: 0.25, currency: "USD" },
  ]);
  assert.equal("realizedPNL" in normalized.requests[0].executions[0].execution, false);

  const buy = result();
  buy.requests[0].executions[0].execution.side = "BUY";
  assert.deepEqual(
    validateExecutionQueryResult(buy, expected).requests[0].executions[0],
    normalized.requests[0].executions[0]
  );
  const sold = result();
  sold.requests[0].executions[0].execution.side = "SLD";
  const sell = result();
  sell.requests[0].executions[0].execution.side = "SELL";
  assert.deepEqual(
    validateExecutionQueryResult(sold, expected).requests[0].executions[0],
    validateExecutionQueryResult(sell, expected).requests[0].executions[0]
  );
});

test("partial, mismatched, noncanonical, and conflicting protocol replies fail closed", () => {
  const expected = validateExecutionQueryRequest(request());
  for (const [mutate, pattern] of [
    [(value) => { value.account = "OTHER"; }, /account mismatch/],
    [(value) => { value.cycleId = "wrong"; }, /cycleId mismatch/],
    [(value) => { value.errors = [{ code: 1 }]; }, /partial coverage/],
    [(value) => { value.requests[0].errors = [{ code: "failed" }]; }, /date request returned errors/],
    [(value) => { value.requests = []; }, /every requested date/],
    [(value) => { value.requests[0].executions[0].execution.acctNumber = "OTHER"; }, /query account/],
    [(value) => { value.requests[0].executions[0].execution.price = Number.MAX_VALUE; }, /finite number/],
    [(value) => { value.serverVersion = 199; }, /required capability/],
    [(value) => { value.sdkVersion = "10.44.0"; }, /sdkVersion mismatch/],
    [(value) => { value.framing = "legacy-extended"; }, /framing mismatch/],
    [(value) => { value.finishedAt = "2026-09-10T12:00:00Z"; }, /precedes a request end/],
  ]) {
    const value = result();
    mutate(value);
    assert.throws(() => validateExecutionQueryResult(value, expected), pattern);
  }

  const duplicate = result();
  duplicate.requests[0].executions.push(structuredClone(duplicate.requests[0].executions[0]));
  assert.throws(() => validateExecutionQueryResult(duplicate, expected), /duplicate execution/);

  const feeConflict = result();
  feeConflict.commissions.push({ ...feeConflict.commissions[0], commission: 9 });
  assert.throws(() => validateExecutionQueryResult(feeConflict, expected), /conflicting commission/);

  const blankMultiplier = result();
  blankMultiplier.requests[0].executions[0].contract.multiplier = "";
  assert.equal(
    validateExecutionQueryResult(blankMultiplier, expected).requests[0].executions[0].contract.multiplier,
    1
  );
});

test("multiple exact dates must be requested and returned oldest first", () => {
  const expected = validateExecutionQueryRequest(request({ specificDates: ["20260910", "20260911"] }));
  const value = result({
    requests: [
      { date: "20260911", requestedAt: "2026-09-11T12:00:00Z", endedAt: "2026-09-11T12:00:01Z", executions: [], errors: [] },
      { date: "20260910", requestedAt: "2026-09-10T12:00:00Z", endedAt: "2026-09-10T12:00:01Z", executions: [], errors: [] },
    ],
    commissions: [],
  });
  assert.throws(() => validateExecutionQueryResult(value, expected), /oldest first/);
  assert.throws(
    () => validateExecutionQueryRequest(request({ specificDates: ["20260911", "20260910"] })),
    /not canonical/
  );
  assert.throws(
    () => validateExecutionQueryRequest(request({
      specificDates: Array.from({ length: 8 }, (_, index) => `202609${String(index + 10).padStart(2, "0")}`),
    })),
    /specificDates are invalid/
  );

  const legacy = result({ serverVersion: 200, framing: "legacy-extended" });
  assert.equal(validateExecutionQueryResult(legacy, validateExecutionQueryRequest(request())).framing, "legacy-extended");
});

test("supervisor keeps one helper, one outstanding query, and accepts fragmented JSONL", async () => {
  const child = new FakeChild();
  const spawns = [];
  const supervisor = createExecutionHistorySupervisor({
    command: "/synthetic/python",
    args: ["/synthetic/reader.py", "--account", ACCOUNT],
    spawnImpl(command, args, options) {
      spawns.push({ command, args, options });
      return child;
    },
  });

  const pending = supervisor.query(request());
  await assert.rejects(supervisor.query(request({ cycleId: "cycle-2" })), /already in flight/);
  assert.equal(spawns.length, 1);
  assert.deepEqual(JSON.parse(child.writes[0]), request());
  const line = `${JSON.stringify(result())}\n`;
  child.stdout.emit("data", line.slice(0, 11));
  child.stdout.emit("data", line.slice(11));
  const reply = await pending;
  assert.equal(reply.serverVersion, 223);
  assert.equal(supervisor.running, true);

  const nextRequest = request({ cycleId: "cycle-2" });
  const nextResult = result({ cycleId: "cycle-2" });
  const second = supervisor.query(nextRequest);
  child.stdout.emit("data", `${JSON.stringify(nextResult)}\n`);
  await second;
  assert.equal(spawns.length, 1);
  supervisor.stop();
  assert.deepEqual(child.kills, ["SIGTERM"]);
});

test("malformed output, timeout, and oversized diagnostics reject and kill only the owned child", async () => {
  const malformedChild = new FakeChild();
  const malformed = createExecutionHistorySupervisor({ spawnImpl: () => malformedChild });
  const malformedQuery = malformed.query(request());
  malformedChild.stdout.emit("data", "not-json\n");
  await assert.rejects(malformedQuery, /malformed JSONL/);
  assert.deepEqual(malformedChild.kills, ["SIGTERM"]);

  const timers = fakeTimers();
  const timeoutChild = new FakeChild();
  const timeout = createExecutionHistorySupervisor({
    spawnImpl: () => timeoutChild,
    startupTimeoutMs: 10,
    perDateTimeoutMs: 20,
    ipcAllowanceMs: 3,
    setTimer: timers.set,
    clearTimer: timers.clear,
  });
  const timedQuery = timeout.query(request());
  timers.run(33);
  await assert.rejects(timedQuery, /timed out/);
  assert.deepEqual(timeoutChild.kills, ["SIGTERM"]);

  const twoDateTimers = fakeTimers();
  const twoDateChild = new FakeChild();
  const twoDate = createExecutionHistorySupervisor({
    spawnImpl: () => twoDateChild,
    startupTimeoutMs: 10,
    perDateTimeoutMs: 20,
    ipcAllowanceMs: 3,
    setTimer: twoDateTimers.set,
    clearTimer: twoDateTimers.clear,
  });
  const twoDateQuery = twoDate.query(request({ specificDates: ["20260910", "20260911"] }));
  twoDateTimers.run(53);
  await assert.rejects(twoDateQuery, /timed out/);

  const diagnostics = [];
  const noisyChild = new FakeChild();
  const noisy = createExecutionHistorySupervisor({
    spawnImpl: () => noisyChild,
    maxStderrBytes: 4,
    hooks: { onDiagnostic: (event) => diagnostics.push(event) },
  });
  const noisyQuery = noisy.query(request());
  noisyChild.stderr.emit("data", "private broker row");
  await assert.rejects(noisyQuery, /diagnostics exceeded/);
  assert.deepEqual(diagnostics, [{ event: "execution_helper_stderr", bytes: 18 }]);
});
