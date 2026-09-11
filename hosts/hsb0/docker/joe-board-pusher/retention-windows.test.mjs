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
    baselineRequired: false,
    reason: null,
    providerId: PROVIDER,
    gatewayTimeZone: VIENNA,
    evaluatedAt: "2026-09-10T21:59:30.000Z",
    observedThrough: "2026-09-10T21:59:30.000Z",
    maxReplayAgeMs: null,
    reconciledWindows: [],
    unreconciledWindows: [],
    unresolvedConflictWindows: [],
    invalidatedReceiptIdsByWindow: [],
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

function correctedState() {
  const closed = retentionWindowAt({ instant: "2026-09-10T21:59:30Z", timeZone: VIENNA });
  const readyNow = "2026-09-10T22:00:20.000Z";
  const ready = transitionRetentionReadiness({
    prior: priorState(),
    now: readyNow,
    gatewayTimeZone: VIENNA,
    finalEvidence: [evidence(closed)],
    freshReplay: replay({ now: readyNow, observedThrough: "2026-09-10T22:00:10.000Z" }),
  });
  const correctedNow = "2026-09-10T22:01:00.000Z";
  const corrected = transitionRetentionReadiness({
    prior: ready,
    now: correctedNow,
    gatewayTimeZone: VIENNA,
    finalEvidence: [evidence(closed, { receiptId: "receipt-correction", conflict: true })],
    freshReplay: replay({ now: correctedNow, observedThrough: "2026-09-10T22:00:50.000Z" }),
  });
  return { closed, ready, corrected };
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
  assert.equal(invalid.status, "needs-baseline");
  assert.equal(invalid.baselineRequired, true);
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

test("R1 superseded receipts stay invalidated while backward clocks remain blocked", () => {
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
  assert.match(corrected.reason, /conflicting receipt invalidated/);
  assert.deepEqual(corrected.reconciledWindows, []);
  assert.deepEqual(corrected.unreconciledWindows, [closed]);
  assert.deepEqual(corrected.invalidatedReceiptIdsByWindow, [{
    window: closed,
    receiptIds: ["receipt-1", "receipt-correction"],
  }]);

  const reused = transitionRetentionReadiness({
    prior: corrected,
    now: "2026-09-10T22:01:05.000Z",
    gatewayTimeZone: VIENNA,
    finalEvidence: [evidence(closed)],
    freshReplay: replay({
      now: "2026-09-10T22:01:05.000Z",
      observedThrough: "2026-09-10T22:01:00.000Z",
    }),
  });
  assert.equal(reused.status, "blocked");
  assert.match(reused.reason, /receipt-1 was invalidated/);
  assert.deepEqual(reused.unreconciledWindows, [closed]);

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

test("R2 calendar changes cannot launder a Vienna obligation through New York and back", () => {
  const hop1 = transitionRetentionReadiness({
    prior: priorState(),
    now: "2026-09-10T22:00:20.000Z",
    gatewayTimeZone: NEW_YORK,
    finalEvidence: [],
    freshReplay: replay({
      now: "2026-09-10T22:00:20.000Z",
      observedThrough: "2026-09-10T22:00:10.000Z",
      timeZone: NEW_YORK,
    }),
  });
  assert.equal(hop1.status, "blocked");
  assert.equal(hop1.gatewayTimeZone, VIENNA);
  assert.equal(hop1.evaluatedAt, "2026-09-10T21:59:30.000Z");

  const hop2 = transitionRetentionReadiness({
    prior: hop1,
    now: "2026-09-10T22:00:30.000Z",
    gatewayTimeZone: NEW_YORK,
    finalEvidence: [],
    freshReplay: replay({
      now: "2026-09-10T22:00:30.000Z",
      observedThrough: "2026-09-10T22:00:25.000Z",
      timeZone: NEW_YORK,
    }),
  });
  assert.equal(hop2.status, "blocked");
  assert.equal(hop2.gatewayTimeZone, VIENNA);

  const hop3 = transitionRetentionReadiness({
    prior: hop2,
    now: "2026-09-10T22:00:40.000Z",
    gatewayTimeZone: VIENNA,
    finalEvidence: [],
    freshReplay: {},
  });
  assert.equal(hop3.status, "blocked");
  assert.equal(hop3.unreconciledWindows.length, 1);

  const hop4 = transitionRetentionReadiness({
    prior: hop3,
    now: "2026-09-10T22:00:50.000Z",
    gatewayTimeZone: VIENNA,
    finalEvidence: [],
    freshReplay: replay({ now: "2026-09-10T22:00:50.000Z", observedThrough: "2026-09-10T22:00:45.000Z" }),
  });
  assert.equal(hop4.status, "blocked");
  assert.equal(hop4.unreconciledWindows.length, 1);
});

test("R3 missing and backward clocks cannot launder a corrected-window obligation", () => {
  for (const invalidNow of [undefined, "2026-09-10T22:00:05.000Z"]) {
    const { closed, corrected } = correctedState();
    const first = transitionRetentionReadiness({
      prior: corrected,
      now: invalidNow,
      gatewayTimeZone: VIENNA,
      finalEvidence: [],
      freshReplay: {},
    });
    assert.equal(first.status, "blocked");
    assert.equal(first.evaluatedAt, corrected.evaluatedAt);
    assert.equal(first.maxReplayAgeMs, corrected.maxReplayAgeMs);
    assert.deepEqual(first.unreconciledWindows, [closed]);
    assert.deepEqual(first.invalidatedReceiptIdsByWindow, corrected.invalidatedReceiptIdsByWindow);

    const second = transitionRetentionReadiness({
      prior: first,
      now: "2026-09-10T22:01:20.000Z",
      gatewayTimeZone: VIENNA,
      finalEvidence: [],
      freshReplay: {},
    });
    assert.equal(second.status, "blocked");
    assert.deepEqual(second.unreconciledWindows, [closed]);

    const third = transitionRetentionReadiness({
      prior: second,
      now: "2026-09-10T22:01:30.000Z",
      gatewayTimeZone: VIENNA,
      finalEvidence: [],
      freshReplay: replay({ now: "2026-09-10T22:01:30.000Z", observedThrough: "2026-09-10T22:01:25.000Z" }),
    });
    assert.equal(third.status, "blocked");
    assert.deepEqual(third.unreconciledWindows, [closed]);
  }
});

test("R4 a conflicting receipt in the open Gateway window blocks and its ID stays invalidated", () => {
  const prior = priorState({
    evaluatedAt: "2026-09-10T03:59:30.000Z",
    observedThrough: "2026-09-10T03:59:30.000Z",
  });
  const now = "2026-09-10T04:00:30.000Z";
  const current = retentionWindowAt({ instant: now, timeZone: VIENNA });
  const conflicting = evidence(current, {
    receiptId: "receipt-open-conflict",
    end: "2026-09-10T03:00:00.000Z",
    conflict: true,
  });
  const blocked = transitionRetentionReadiness({
    prior,
    now,
    gatewayTimeZone: VIENNA,
    finalEvidence: [conflicting],
    freshReplay: replay({ now, observedThrough: "2026-09-10T04:00:20.000Z" }),
  });
  assert.equal(blocked.status, "blocked");
  assert.deepEqual(blocked.invalidatedReceiptIdsByWindow, [{
    window: current,
    receiptIds: ["receipt-open-conflict"],
  }]);
  assert.deepEqual(blocked.unresolvedConflictWindows, [current]);

  const reused = transitionRetentionReadiness({
    prior: blocked,
    now: "2026-09-10T04:00:40.000Z",
    gatewayTimeZone: VIENNA,
    finalEvidence: [{ ...conflicting, conflict: false }],
    freshReplay: replay({ now: "2026-09-10T04:00:40.000Z", observedThrough: "2026-09-10T04:00:35.000Z" }),
  });
  assert.equal(reused.status, "blocked");
  assert.match(reused.reason, /receipt-open-conflict was invalidated/);

  const omitted = transitionRetentionReadiness({
    prior: blocked,
    now: "2026-09-10T04:00:40.000Z",
    gatewayTimeZone: VIENNA,
    finalEvidence: [],
    freshReplay: replay({ now: "2026-09-10T04:00:40.000Z", observedThrough: "2026-09-10T04:00:35.000Z" }),
  });
  assert.equal(omitted.status, "blocked");
  assert.match(omitted.reason, /unresolved conflict requires replacement coverage/);
  assert.deepEqual(omitted.unresolvedConflictWindows, [current]);

  const partialReplacement = transitionRetentionReadiness({
    prior: omitted,
    now: "2026-09-10T04:00:50.000Z",
    gatewayTimeZone: VIENNA,
    finalEvidence: [evidence(current, {
      receiptId: "receipt-partial-replacement",
      end: "2026-09-10T03:00:00.000Z",
    })],
    freshReplay: replay({ now: "2026-09-10T04:00:50.000Z", observedThrough: "2026-09-10T04:00:45.000Z" }),
  });
  assert.equal(partialReplacement.status, "blocked");
  assert.deepEqual(partialReplacement.unresolvedConflictWindows, [current]);

  const afterMidnight = transitionRetentionReadiness({
    prior: partialReplacement,
    now: "2026-09-10T22:00:30.000Z",
    gatewayTimeZone: VIENNA,
    finalEvidence: [],
    freshReplay: replay({ now: "2026-09-10T22:00:30.000Z", observedThrough: "2026-09-10T22:00:20.000Z" }),
  });
  assert.equal(afterMidnight.status, "blocked");
  assert.deepEqual(afterMidnight.unresolvedConflictWindows, [current]);

  const replacement = transitionRetentionReadiness({
    prior: afterMidnight,
    now: "2026-09-10T22:00:40.000Z",
    gatewayTimeZone: VIENNA,
    finalEvidence: [evidence(current, { receiptId: "receipt-valid-replacement" })],
    freshReplay: replay({ now: "2026-09-10T22:00:40.000Z", observedThrough: "2026-09-10T22:00:35.000Z" }),
  });
  assert.equal(replacement.status, "ready");
  assert.deepEqual(replacement.unresolvedConflictWindows, []);
  assert.equal(replacement.reconciledWindows.some((record) => (
    record.window.begin === current.begin && record.receiptIds.includes("receipt-valid-replacement")
  )), true);
  assert.deepEqual(replacement.invalidatedReceiptIdsByWindow, blocked.invalidatedReceiptIdsByWindow);
});

test("R5 malformed persisted window records require a new trusted baseline permanently", () => {
  const closed = retentionWindowAt({ instant: "2026-09-10T21:59:30Z", timeZone: VIENNA });
  const nyWindow = retentionWindowAt({ instant: "2026-09-10T21:59:30Z", timeZone: NEW_YORK });
  const reconciled = (receiptIds, overrides = {}) => ({
    ok: true,
    complete: true,
    window: closed,
    providerId: PROVIDER,
    receiptIds,
    ...overrides,
  });
  const malformedStates = [
    priorState({ reconciledWindows: [reconciled([])] }),
    priorState({
      reconciledWindows: [
        reconciled(["receipt-a"]),
        reconciled(["receipt-b"]),
      ],
    }),
    priorState({
      status: "blocked",
      reconciledWindows: [reconciled(["receipt-a"])],
      unreconciledWindows: [closed],
    }),
    priorState({ status: "blocked", unreconciledWindows: [nyWindow] }),
    priorState({ invalidatedReceiptIdsByWindow: [{ window: closed, receiptIds: [] }] }),
    priorState({ reconciledWindows: [reconciled(["receipt-a"], { complete: false })] }),
    priorState({ reconciledWindows: [reconciled(["receipt-a", "receipt-a"])] }),
    priorState({ status: "blocked", unreconciledWindows: [closed, closed] }),
    priorState({
      invalidatedReceiptIdsByWindow: [
        { window: closed, receiptIds: ["receipt-a"] },
        { window: closed, receiptIds: ["receipt-b"] },
      ],
    }),
    priorState({
      reconciledWindows: [reconciled(["receipt-a"])],
      invalidatedReceiptIdsByWindow: [{ window: closed, receiptIds: ["receipt-a"] }],
    }),
  ];

  for (const prior of malformedStates) {
    const terminal = transitionRetentionReadiness({
      prior,
      now: "2026-09-10T22:00:20.000Z",
      gatewayTimeZone: VIENNA,
      finalEvidence: [],
      freshReplay: {},
    });
    assert.equal(terminal.status, "needs-baseline");
    assert.equal(terminal.baselineRequired, true);
    assert.equal(terminal.gatewayTimeZone, null);
    assert.deepEqual(terminal.reconciledWindows, []);

    const cannotSelfHeal = transitionRetentionReadiness({
      prior: terminal,
      now: "2026-09-10T22:00:30.000Z",
      gatewayTimeZone: VIENNA,
      finalEvidence: [evidence(closed, { receiptId: "replacement" })],
      freshReplay: replay({ now: "2026-09-10T22:00:30.000Z", observedThrough: "2026-09-10T22:00:25.000Z" }),
    });
    assert.equal(cannotSelfHeal.status, "needs-baseline");
    assert.equal(cannotSelfHeal.baselineRequired, true);
  }
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
