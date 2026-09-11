import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { PassThrough, Writable } from "node:stream";
import test from "node:test";
import {
  OFFICIAL_WINDOW_READER_LIMITS,
  createOfficialWindowReader,
} from "./official-window-reader.mjs";

const ACCOUNT = "DUR970597";
const NOW = "2026-09-11T12:00:00.000Z";

function execution(execId, time, overrides = {}) {
  return {
    contract: {
      conId: 1001,
      symbol: "MSFT",
      secType: "STK",
      currency: "USD",
      multiplier: "",
      exchange: "SMART",
    },
    execution: {
      execId,
      time,
      acctNumber: ACCOUNT,
      clientId: 56,
      side: "BOT",
      shares: "1",
      price: "10",
      pendingPriceRevision: false,
      ...overrides,
    },
  };
}

function commission(execId) {
  return {
    execId,
    commissionAndFees: "0.25",
    currency: "USD",
    realizedPNL: "1.50",
    yield: "0",
    yieldRedemptionDate: 0,
  };
}

function response(plan, { executionsByRequest = {}, commissionsByExecId = {}, mutate = null } = {}) {
  const requests = {};
  for (const window of plan.actualWindows) {
    requests[String(window.requestId)] = {
      label: "specific-date",
      filter: structuredClone(window.filter),
      actualWindow: {
        fromInclusive: window.fromInclusive,
        toExclusive: window.toExclusive,
      },
      requestedAt: "2026-09-11T12:00:00.250Z",
      endedAt: "2026-09-11T12:00:00.750Z",
      timedOut: false,
      errors: [],
      executions: structuredClone(executionsByRequest[window.requestId] || []),
    };
  }
  const value = {
    schemaVersion: 1,
    endpoint: structuredClone(plan.endpoint),
    sdk: { package: "ibapi", version: "10.45.1" },
    negotiated: {
      serverVersion: 223,
      executionRequestFraming: "protobuf",
      parameterizedExecutionFilters: true,
    },
    managedAccounts: [ACCOUNT],
    foreignAccountViolation: false,
    startedAt: plan.startedAt,
    finishedAt: "2026-09-11T12:00:01.000Z",
    requestedCoverage: structuredClone(plan.requestedCoverage),
    actualWindows: structuredClone(plan.actualWindows),
    disconnected: true,
    exitCode: 0,
    errors: [],
    requests,
    commissionsByExecId: structuredClone(commissionsByExecId),
  };
  mutate?.(value);
  return value;
}

function spawnHarness(onPlan) {
  const calls = [];
  let lastChild = null;
  function spawnImpl(command, args, options) {
    const child = new EventEmitter();
    const chunks = [];
    child.stdout = new PassThrough();
    child.stderr = new PassThrough();
    child.kills = [];
    child.closed = false;
    child.stdin = new Writable({
      write(chunk, _encoding, callback) {
        chunks.push(Buffer.from(chunk));
        callback();
      },
      final(callback) {
        const plan = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        queueMicrotask(() => onPlan(plan, child));
        callback();
      },
    });
    child.respond = (value, code = 0) => {
      if (child.closed) return;
      child.stdout.end(typeof value === "string" ? value : JSON.stringify(value));
      child.stderr.end();
      child.closed = true;
      queueMicrotask(() => child.emit("close", code, null));
    };
    child.fail = (message, code = 2) => {
      child.stderr.end(message);
      child.respond("", code);
    };
    child.kill = (signal) => {
      child.kills.push(signal);
      if (!child.closed) {
        child.closed = true;
        queueMicrotask(() => child.emit("close", null, signal));
      }
      return true;
    };
    calls.push({ command, args, options, child });
    lastChild = child;
    return child;
  }
  return { spawnImpl, calls, get child() { return lastChild; } };
}

function options(overrides = {}) {
  return {
    fromInclusive: "2026-09-10T16:00:00Z",
    toExclusive: "2026-09-12T04:00:00Z",
    targetAccount: ACCOUNT,
    host: "gateway",
    port: 4002,
    clientId: 94,
    ...overrides,
  };
}

function readerWith(harness, overrides = {}) {
  return createOfficialWindowReader({
    spawnImpl: harness.spawnImpl,
    now: () => new Date(NOW),
    ...overrides,
  });
}

test("one process plans one exact official query per New York date and clamps coverage to query start", async () => {
  let capturedPlan;
  const harness = spawnHarness((plan, child) => {
    capturedPlan = plan;
    const firstId = plan.actualWindows[0].requestId;
    const secondId = plan.actualWindows[1].requestId;
    const before = execution("synthetic.before.01", "20260910 11:59:59 America/New_York");
    const original = execution("synthetic.trade.01", "20260910 12:00:00 America/New_York");
    const correction = execution("synthetic.trade.02", "20260910 12:01:00 America/New_York", {
      pendingPriceRevision: true,
      price: "10.25",
    });
    const atCutoff = execution("synthetic.cutoff.01", "20260911 08:00:00 America/New_York");
    child.respond(response(plan, {
      executionsByRequest: {
        [firstId]: [before, original, structuredClone(original), correction],
        [secondId]: [atCutoff],
      },
      commissionsByExecId: {
        "synthetic.before.01": commission("synthetic.before.01"),
        "synthetic.trade.01": commission("synthetic.trade.01"),
        "synthetic.trade.02": commission("synthetic.trade.02"),
        "synthetic.cutoff.01": commission("synthetic.cutoff.01"),
      },
    }));
  });
  const read = readerWith(harness);
  const result = await read(options());

  assert.equal(harness.calls.length, 1);
  assert.equal(harness.calls[0].command, "/opt/ibapi/bin/python");
  assert.match(harness.calls[0].args[1], /official-window-reader\.py$/);
  assert.equal(capturedPlan.endpoint.clientId, 94);
  assert.equal(capturedPlan.requestedCoverage.toExclusive, NOW);
  assert.deepEqual(capturedPlan.actualWindows.map((window) => window.newYorkDate), [20260910, 20260911]);
  assert.deepEqual(capturedPlan.actualWindows.map((window) => window.filter), [
    { acctCode: ACCOUNT, time: "20260910-16:00:00", specificDates: [20260910] },
    { acctCode: ACCOUNT, time: "20260911-04:00:00", specificDates: [20260911] },
  ]);
  assert.deepEqual(
    Object.values(result.requests).flatMap((request) => request.executions.map((row) => row.execution.execId)),
    ["synthetic.trade.01", "synthetic.trade.02"],
  );
  assert.equal(result.requests["9300"].executions[1].execution.pendingPriceRevision, true);
  assert.deepEqual(Object.keys(result.commissionsByExecId), ["synthetic.trade.01", "synthetic.trade.02"]);
  assert.equal(result.finishedAt, "2026-09-11T12:00:01.000Z");
});

test("a true empty window succeeds after the reader quiet drain but an unmatched execution fails", async () => {
  const emptyHarness = spawnHarness((plan, child) => child.respond(response(plan)));
  const empty = await readerWith(emptyHarness)(options());
  assert.equal(empty.requests["9300"].executions.length, 0);
  assert.equal(empty.requests["9301"].executions.length, 0);

  const partialHarness = spawnHarness((plan, child) => {
    const firstId = plan.actualWindows[0].requestId;
    child.respond(response(plan, {
      executionsByRequest: {
        [firstId]: [execution("synthetic.partial.01", "20260910 12:30:00 America/New_York")],
      },
      commissionsByExecId: {},
    }));
  });
  await assert.rejects(readerWith(partialHarness)(options()), /without a commission/);
});

test("port, client, account, past-week, and seven-date limits fail before spawning", async () => {
  const harness = spawnHarness(() => assert.fail("subprocess must not start"));
  const read = readerWith(harness);
  for (const invalid of [
    options({ port: 4001 }),
    options({ clientId: 93 }),
    options({ targetAccount: "DU999999" }),
    options({ fromInclusive: "2026-09-04T11:59:59Z", toExclusive: NOW }),
    options({ fromInclusive: "2026-09-04T12:00:00Z", toExclusive: NOW }),
  ]) {
    await assert.rejects(read(invalid));
  }
  assert.equal(harness.calls.length, 0);
});

test("abort and hard timeout terminate the sole subprocess", async () => {
  const abortHarness = spawnHarness(() => {});
  const controller = new AbortController();
  const aborted = readerWith(abortHarness)(options({ signal: controller.signal }));
  controller.abort(new Error("caller cancelled"));
  await assert.rejects(aborted, /caller cancelled/);
  assert.deepEqual(abortHarness.child.kills, ["SIGTERM"]);

  const timeoutHarness = spawnHarness(() => {});
  const timed = readerWith(timeoutHarness, { totalTimeoutMs: 5 })(options());
  await assert.rejects(timed, /timed out/);
  assert.deepEqual(timeoutHarness.child.kills, ["SIGTERM"]);
});

test("foreign account, pending flag, filter drift, and malformed JSON are rejected", async () => {
  const variants = [
    (value) => {
      value.requests["9300"].executions = [execution("synthetic.foreign.01", "20260910 12:00:00 America/New_York", {
        acctNumber: "DU999999",
      })];
    },
    (value) => {
      value.requests["9300"].executions = [execution("synthetic.pending.01", "20260910 12:00:00 America/New_York", {
        pendingPriceRevision: null,
      })];
    },
    (value) => {
      value.requests["9300"].executions = [execution("synthetic.time.01", "not-a-broker-time")];
    },
    (value) => { value.requests["9300"].filter.specificDates = [20260909]; },
    (value) => { value.errors = [{ code: "late-callback" }]; },
    (value) => { value.commissionsByExecId.orphan = commission("orphan"); },
  ];
  for (const mutate of variants) {
    const harness = spawnHarness((plan, child) => child.respond(response(plan, { mutate })));
    await assert.rejects(readerWith(harness)(options()));
  }

  const malformed = spawnHarness((_plan, child) => child.respond("not-json"));
  await assert.rejects(readerWith(malformed)(options()), /response rejected/);
});

test("stdout byte bounds and nonzero subprocess exit fail closed", async () => {
  const oversized = spawnHarness((_plan, child) => child.respond("x".repeat(65)));
  await assert.rejects(
    readerWith(oversized, { maxStdoutBytes: 64 })(options()),
    /byte limit/,
  );
  assert.deepEqual(oversized.child.kills, ["SIGTERM"]);

  const failed = spawnHarness((_plan, child) => {
    child.stderr.end("synthetic failure");
    child.respond("", 2);
  });
  await assert.rejects(readerWith(failed)(options()), /exited 2/);
});

test("published safety constants identify only the dedicated paper reader", () => {
  assert.deepEqual(OFFICIAL_WINDOW_READER_LIMITS, {
    paperPort: 4002,
    clientId: 94,
    paperAccount: ACCOUNT,
    maxDates: 7,
    maxStdoutBytes: 16 * 1024 * 1024,
  });
});
