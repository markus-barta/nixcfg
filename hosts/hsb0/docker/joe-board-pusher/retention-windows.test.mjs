import assert from "node:assert/strict";
import test from "node:test";

import {
  RETENTION_CONTRACT,
  RetentionContractError,
  reconcileWindowCoverage,
  retentionWindowAt,
  transitionRetentionReadiness as reduceRetentionReadiness,
  uncoveredRetentionWindows,
} from "./retention-windows.mjs";

const PROVIDER = "paper-trade-confirmation";
const VIENNA = "Europe/Vienna";
const NEW_YORK = "America/New_York";
const REPLAY_AGE_MS = 60_000;

function transitionRetentionReadiness(input) {
  return reduceRetentionReadiness({ maxReplayAgeMs: REPLAY_AGE_MS, ...input });
}

function priorState(overrides = {}) {
  return {
    schema: RETENTION_CONTRACT.stateSchema,
    status: "ready",
    reason: null,
    providerId: PROVIDER,
    gatewayTimeZone: VIENNA,
    evaluatedAt: "2026-09-10T21:59:30.000Z",
    observedThrough: "2026-09-10T21:59:30.000Z",
    reconciledWindows: [],
    unreconciledWindows: [],
    ...overrides,
  };
}

function evidence(window, overrides = {}) {
  return {
    schema: RETENTION_CONTRACT.evidenceSchema,
    providerId: PROVIDER,
    calendarTimeZone: window.timeZone,
    receiptId: "receipt-1",
    finality: "validated-final",
    executionSetMatch: "exact",
    conflict: false,
    begin: window.begin,
    end: window.end,
    ...overrides,
  };
}

function replay({ now, observedThrough, executionCount = 0, timeZone = VIENNA, ...overrides }) {
  const window = retentionWindowAt({ instant: now, timeZone });
  return {
    schema: RETENTION_CONTRACT.replaySchema,
    source: "raw-socket-ledger",
    calendarTimeZone: timeZone,
    windowBegin: window.begin,
    completeness: "validated-current-window",
    knownExecutionSet: "retained",
    conflict: false,
    executionCount,
    observedThrough,
    completedAt: now,
    ...overrides,
  };
}

test("retention windows use local midnight and preserve 23-hour and 25-hour Vienna days", () => {
  const spring = retentionWindowAt({ instant: "2026-03-29T12:00:00Z", timeZone: VIENNA });
  assert.deepEqual(
    { localDate: spring.localDate, begin: spring.begin, end: spring.end, durationMs: spring.durationMs },
    {
      localDate: "2026-03-29",
      begin: "2026-03-28T23:00:00.000Z",
      end: "2026-03-29T22:00:00.000Z",
      durationMs: 23 * 60 * 60 * 1000,
    },
  );

  const autumn = retentionWindowAt({ instant: "2026-10-25T12:00:00Z", timeZone: VIENNA });
  assert.deepEqual(
    { localDate: autumn.localDate, begin: autumn.begin, end: autumn.end, durationMs: autumn.durationMs },
    {
      localDate: "2026-10-25",
      begin: "2026-10-24T22:00:00.000Z",
      end: "2026-10-25T23:00:00.000Z",
      durationMs: 25 * 60 * 60 * 1000,
    },
  );
});

test("Gateway and New York calendars diverge without either calendar being inferred", () => {
  const instant = "2026-03-20T03:30:00Z";
  assert.equal(retentionWindowAt({ instant, timeZone: VIENNA }).localDate, "2026-03-20");
  assert.equal(retentionWindowAt({ instant, timeZone: NEW_YORK }).localDate, "2026-03-19");
});

test("uncovered windows are complete explicit-calendar windows and reject a backward clock", () => {
  const windows = uncoveredRetentionWindows({
    observedThrough: "2026-09-10T21:59:30Z",
    now: "2026-09-11T22:00:01Z",
    timeZone: VIENNA,
  });
  assert.deepEqual(windows.map(({ localDate, begin, end }) => ({ localDate, begin, end })), [
    {
      localDate: "2026-09-10",
      begin: "2026-09-09T22:00:00.000Z",
      end: "2026-09-10T22:00:00.000Z",
    },
    {
      localDate: "2026-09-11",
      begin: "2026-09-10T22:00:00.000Z",
      end: "2026-09-11T22:00:00.000Z",
    },
  ]);
  assert.throws(
    () => uncoveredRetentionWindows({ observedThrough: "2026-09-10T12:00:00Z", now: "2026-09-10T11:59:59Z", timeZone: VIENNA }),
    RetentionContractError,
  );
});

test("validated interval union covers a closed window while a one-millisecond gap fails closed", () => {
  const window = retentionWindowAt({ instant: "2026-09-10T12:00:00Z", timeZone: VIENNA });
  const midpoint = "2026-09-10T10:00:00.000Z";
  const complete = reconcileWindowCoverage({
    window,
    providerId: PROVIDER,
    evidenceIntervals: [
      evidence(window, { receiptId: "receipt-b", begin: midpoint }),
      evidence(window, { receiptId: "receipt-a", end: midpoint }),
    ],
  });
  assert.equal(complete.ok, true);
  assert.deepEqual(complete.receiptIds, ["receipt-a", "receipt-b"]);

  const gap = reconcileWindowCoverage({
    window,
    providerId: PROVIDER,
    evidenceIntervals: [
      evidence(window, { receiptId: "receipt-a", end: midpoint }),
      evidence(window, { receiptId: "receipt-b", begin: "2026-09-10T10:00:00.001Z" }),
    ],
  });
  assert.deepEqual({ ok: gap.ok, complete: gap.complete }, { ok: false, complete: false });
  assert.match(gap.reason, /coverage gap/);
});

test("timestamps, empty evidence, unconfigured providers, and invalid zones never establish coverage", () => {
  const window = retentionWindowAt({ instant: "2026-09-10T12:00:00Z", timeZone: VIENNA });
  assert.equal(reconcileWindowCoverage({ window, providerId: PROVIDER, evidenceIntervals: [] }).ok, false);
  assert.equal(reconcileWindowCoverage({ window, providerId: "", evidenceIntervals: [evidence(window)] }).ok, false);
  assert.equal(
    reconcileWindowCoverage({
      window,
      providerId: PROVIDER,
      evidenceIntervals: [{ begin: window.begin, end: window.end }],
    }).ok,
    false,
  );
  assert.throws(
    () => retentionWindowAt({ instant: "2026-09-10T12:00:00Z", timeZone: "Unknown/Gateway" }),
    RetentionContractError,
  );
  assert.throws(
    () => retentionWindowAt({ instant: "2026-09-10 12:00:00", timeZone: VIENNA }),
    RetentionContractError,
  );
});

test("timestamp validation rejects normalization, non-leap dates, and malformed offsets", () => {
  assert.equal(
    retentionWindowAt({ instant: "2028-02-29T12:34:56.7+01:00", timeZone: VIENNA }).localDate,
    "2028-02-29",
  );
  for (const instant of [
    "2026-02-29T12:00:00Z",
    "2028-02-30T12:00:00Z",
    "2026-13-01T12:00:00Z",
    "2026-09-10T24:00:00Z",
    "2026-09-10T12:60:00Z",
    "2026-09-10T12:00:60Z",
    "2026-09-10T12:00:00+14:01",
    "2026-09-10T12:00:00+01:60",
    "2026-09-10T12:00:00+0100",
  ]) {
    assert.throws(() => retentionWindowAt({ instant, timeZone: VIENNA }), RetentionContractError, instant);
  }
});

test("an empty replay after the 18:00 New York roundtrip window cannot prove the closed Gateway day", () => {
  // A fill could occur at 17:59:40 New York (21:59:40Z), after the prior
  // watermark and before Vienna midnight. The empty new-day replay is silent
  // about that interval and therefore cannot restore readiness by itself.
  const now = "2026-09-10T22:00:20.000Z";
  const result = transitionRetentionReadiness({
    prior: priorState(),
    now,
    gatewayTimeZone: VIENNA,
    finalEvidence: [],
    freshReplay: replay({ now, observedThrough: "2026-09-10T22:00:10.000Z", executionCount: 0 }),
  });
  assert.equal(result.status, "blocked");
  assert.match(result.reason, /FINAL evidence intervals are required/);
  assert.equal(result.observedThrough, "2026-09-10T21:59:30.000Z");
});

test("complete old-window evidence plus a fresh current-window replay restores readiness", () => {
  const now = "2026-09-10T22:00:20.000Z";
  const closed = retentionWindowAt({ instant: "2026-09-10T21:59:30Z", timeZone: VIENNA });
  const result = transitionRetentionReadiness({
    prior: priorState(),
    now,
    gatewayTimeZone: VIENNA,
    finalEvidence: [evidence(closed)],
    freshReplay: replay({ now, observedThrough: "2026-09-10T22:00:10.000Z", executionCount: 0 }),
    maxReplayAgeMs: 10_000,
  });
  assert.equal(result.status, "ready");
  assert.equal(result.observedThrough, "2026-09-10T22:00:10.000Z");
  assert.equal(result.reconciledWindows.length, 1);
  assert.equal(result.reconciledWindows[0].window.begin, closed.begin);
  assert.equal(result.maxReplayAgeMs, 10_000);
});

test("explicit replay age is mandatory and checks watermark and completion freshness", () => {
  const prior = priorState({
    evaluatedAt: "2026-09-10T03:59:30.000Z",
    observedThrough: "2026-09-10T03:59:30.000Z",
  });
  const now = "2026-09-10T04:00:30.000Z";
  const freshShape = replay({ now, observedThrough: "2026-09-10T03:59:40.000Z" });

  const absent = reduceRetentionReadiness({
    prior, now, gatewayTimeZone: VIENNA, finalEvidence: [], freshReplay: freshShape,
  });
  assert.equal(absent.status, "blocked");
  assert.match(absent.reason, /maxReplayAgeMs/);

  const invalid = reduceRetentionReadiness({
    prior, now, gatewayTimeZone: VIENNA, finalEvidence: [], freshReplay: freshShape, maxReplayAgeMs: 0,
  });
  assert.equal(invalid.status, "blocked");
  assert.match(invalid.reason, /maxReplayAgeMs/);

  const currentWindow = retentionWindowAt({ instant: now, timeZone: VIENNA });
  const unbounded = reduceRetentionReadiness({
    prior,
    now,
    gatewayTimeZone: VIENNA,
    finalEvidence: [],
    freshReplay: freshShape,
    maxReplayAgeMs: currentWindow.durationMs + 1,
  });
  assert.equal(unbounded.status, "blocked");
  assert.match(unbounded.reason, /maxReplayAgeMs/);

  const staleWatermark = reduceRetentionReadiness({
    prior,
    now,
    gatewayTimeZone: VIENNA,
    finalEvidence: [],
    freshReplay: freshShape,
    maxReplayAgeMs: 30_000,
  });
  assert.equal(staleWatermark.status, "blocked");
  assert.match(staleWatermark.reason, /watermark is older/);

  const staleCompletion = reduceRetentionReadiness({
    prior,
    now,
    gatewayTimeZone: VIENNA,
    finalEvidence: [],
    freshReplay: replay({
      now,
      observedThrough: "2026-09-10T03:59:40.000Z",
      completedAt: "2026-09-10T03:59:50.000Z",
    }),
    maxReplayAgeMs: 30_000,
  });
  assert.equal(staleCompletion.status, "blocked");
  assert.match(staleCompletion.reason, /completion is older/);
});

test("prior watermark ordering fails closed and reducer inputs remain unchanged", () => {
  const now = "2026-09-10T22:00:20.000Z";
  const invalidPrior = priorState({ evaluatedAt: "2026-09-10T21:59:29.000Z" });
  const invalid = transitionRetentionReadiness({
    prior: invalidPrior,
    now,
    gatewayTimeZone: VIENNA,
    finalEvidence: [],
    freshReplay: replay({ now, observedThrough: "2026-09-10T22:00:10.000Z" }),
  });
  assert.equal(invalid.status, "blocked");
  assert.match(invalid.reason, /observedThrough cannot follow/);

  const prior = priorState();
  const closed = retentionWindowAt({ instant: prior.observedThrough, timeZone: VIENNA });
  const input = {
    prior,
    now,
    gatewayTimeZone: VIENNA,
    finalEvidence: [evidence(closed)],
    freshReplay: replay({ now, observedThrough: "2026-09-10T22:00:10.000Z" }),
    maxReplayAgeMs: REPLAY_AGE_MS,
  };
  const before = structuredClone(input);
  assert.equal(reduceRetentionReadiness(input).status, "ready");
  assert.deepEqual(input, before);
});

test("a no-fill closed window still needs complete FINAL evidence", () => {
  const now = "2026-09-10T22:00:20.000Z";
  const emptyReplay = replay({ now, observedThrough: "2026-09-10T22:00:10.000Z", executionCount: 0 });
  const withoutReceipt = transitionRetentionReadiness({
    prior: priorState(), now, gatewayTimeZone: VIENNA, finalEvidence: [], freshReplay: emptyReplay,
  });
  assert.equal(withoutReceipt.status, "blocked");

  const closed = retentionWindowAt({ instant: "2026-09-10T21:59:30Z", timeZone: VIENNA });
  const withReceipt = transitionRetentionReadiness({
    prior: priorState(), now, gatewayTimeZone: VIENNA, finalEvidence: [evidence(closed)], freshReplay: emptyReplay,
  });
  assert.equal(withReceipt.status, "ready");
});

test("New York midnight is irrelevant while the configured Gateway window remains open", () => {
  const prior = priorState({
    evaluatedAt: "2026-09-10T03:59:30.000Z",
    observedThrough: "2026-09-10T03:59:30.000Z",
  });
  const now = "2026-09-10T04:00:30.000Z";
  const result = transitionRetentionReadiness({
    prior,
    now,
    gatewayTimeZone: VIENNA,
    finalEvidence: [],
    freshReplay: replay({ now, observedThrough: "2026-09-10T04:00:20.000Z", executionCount: 4 }),
  });
  assert.equal(result.status, "ready");
  assert.deepEqual(result.reconciledWindows, []);
});

test("repeated successful transitions are idempotent", () => {
  const now = "2026-09-10T22:00:20.000Z";
  const closed = retentionWindowAt({ instant: "2026-09-10T21:59:30Z", timeZone: VIENNA });
  const finalEvidence = [evidence(closed)];
  const freshReplay = replay({ now, observedThrough: "2026-09-10T22:00:10.000Z" });
  const first = transitionRetentionReadiness({
    prior: priorState(), now, gatewayTimeZone: VIENNA, finalEvidence, freshReplay,
  });
  const second = transitionRetentionReadiness({
    prior: first, now, gatewayTimeZone: VIENNA, finalEvidence, freshReplay,
  });
  assert.deepEqual(second, first);
  assert.equal(Object.isFrozen(second), true);
});

test("backward clocks block and corrected conflicting receipts invalidate reconciled coverage", () => {
  const initialNow = "2026-09-10T22:00:20.000Z";
  const closed = retentionWindowAt({ instant: "2026-09-10T21:59:30Z", timeZone: VIENNA });
  const ready = transitionRetentionReadiness({
    prior: priorState(),
    now: initialNow,
    gatewayTimeZone: VIENNA,
    finalEvidence: [evidence(closed)],
    freshReplay: replay({ now: initialNow, observedThrough: "2026-09-10T22:00:10.000Z" }),
  });
  assert.equal(ready.status, "ready");

  const backward = transitionRetentionReadiness({
    prior: ready,
    now: "2026-09-10T22:00:19.000Z",
    gatewayTimeZone: VIENNA,
    finalEvidence: [],
    freshReplay: replay({
      now: "2026-09-10T22:00:19.000Z",
      observedThrough: "2026-09-10T22:00:10.000Z",
    }),
  });
  assert.equal(backward.status, "blocked");
  assert.match(backward.reason, /clock moved backward/);

  const correctedNow = "2026-09-10T22:01:00.000Z";
  const corrected = transitionRetentionReadiness({
    prior: ready,
    now: correctedNow,
    gatewayTimeZone: VIENNA,
    finalEvidence: [evidence(closed, { receiptId: "receipt-correction", conflict: true })],
    freshReplay: replay({ now: correctedNow, observedThrough: "2026-09-10T22:00:50.000Z" }),
  });
  assert.equal(corrected.status, "blocked");
  assert.match(corrected.reason, /corrected receipt invalidated/);
  assert.deepEqual(corrected.reconciledWindows, []);
  assert.deepEqual(corrected.unreconciledWindows, [closed]);

  const stillBlocked = transitionRetentionReadiness({
    prior: corrected,
    now: "2026-09-10T22:01:10.000Z",
    gatewayTimeZone: VIENNA,
    finalEvidence: [],
    freshReplay: replay({
      now: "2026-09-10T22:01:10.000Z",
      observedThrough: "2026-09-10T22:01:00.000Z",
    }),
  });
  assert.equal(stillBlocked.status, "blocked");
  assert.deepEqual(stillBlocked.unreconciledWindows, [closed]);
});

test("transition fails closed for an invalid Gateway calendar or incomplete replay contract", () => {
  const now = "2026-09-10T22:00:20.000Z";
  const invalidZone = transitionRetentionReadiness({
    prior: priorState(), now, gatewayTimeZone: "Local/Gateway", finalEvidence: [], freshReplay: {},
  });
  assert.equal(invalidZone.status, "blocked");

  const closed = retentionWindowAt({ instant: "2026-09-10T21:59:30Z", timeZone: VIENNA });
  const timestampOnlyReplay = transitionRetentionReadiness({
    prior: priorState(),
    now,
    gatewayTimeZone: VIENNA,
    finalEvidence: [evidence(closed)],
    freshReplay: { observedThrough: "2026-09-10T22:00:10.000Z" },
  });
  assert.equal(timestampOnlyReplay.status, "blocked");
  assert.match(timestampOnlyReplay.reason, /schema/);
});
