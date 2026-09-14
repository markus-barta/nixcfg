import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  DAY_BASELINE_INPUT_SCOPE,
  DAY_BASELINE_STATE_SCHEMA,
  DAY_PNL_METHOD,
  createDayBaselineAdapter,
  createDeskDayPnlProducer,
  createFileDayBaselineStore,
  newYorkPeriodStart,
} from "./day-baseline.mjs";

import { createPortfolioRefreshController } from "./portfolio-refresh.mjs";

const REV_A = "a".repeat(64);
const REV_B = "b".repeat(64);
const SOURCE_CONTRACT = {
  method: "complete-virtual-equity-vector-v1",
  classifier: {
    revision: "joe-stage0-desk-classifier-v1",
    familyClientIds: [93, 94, 95, 96, 97],
    joelPolicy: "SXR8-and-single-TSLA-grandfathered",
  },
  historyRevisionMethod: "effective-family-history-before-cutoff-sha256-v1",
  scope: DAY_BASELINE_INPUT_SCOPE,
  keepExcluded: true,
};
const POLICY_HASH = "c".repeat(64);
const PROVIDER_CONTRACT = {
  method: "owned-lots-current-mark-fx",
  policyMethod: "effective-dated-client-id-ownership-v1",
  policyHash: POLICY_HASH,
  scope: DAY_BASELINE_INPUT_SCOPE,
  keepExcluded: true,
};
const DESK_REVISION_METHOD = "sha256-effective-all-desk-economic-history-v1";

function vector({ j = 5000, joe = 5000, joel = 5000 } = {}) {
  return { j, joe, joel, total: j + joe + joel };
}

function observation({
  at,
  oldest = at,
  equity = vector(),
  revision = REV_A,
  coverageThrough = at,
  contract = SOURCE_CONTRACT,
  ...diagnosticOnly
}) {
  return {
    equity,
    sourceObservedAt: at,
    oldestSourceObservedAt: oldest,
    provenance: {
      ...structuredClone(contract),
      historyRevision: revision,
      executionCoverage: { status: "complete", throughInclusive: coverageThrough },
    },
    ...diagnosticOnly,
  };
}

function boundaryProof({
  periodStart = "2026-09-12T04:00:00.000Z",
  proofObservedAt = "2026-09-12T04:00:20.000Z",
  fromInclusive = "2026-09-12T03:55:00.000Z",
  throughExclusive = "2026-09-12T04:00:20.000Z",
  revision = REV_A,
  contract = SOURCE_CONTRACT,
} = {}) {
  return {
    periodStart,
    proofObservedAt,
    provenance: {
      ...structuredClone(contract),
      historyRevision: revision,
      executionCoverage: { status: "complete", fromInclusive, throughExclusive },
    },
  };
}

function memoryStore(seed = null) {
  let saved = seed ? structuredClone(seed) : null;
  return {
    load() { return { ok: true, state: saved ? structuredClone(saved) : null }; },
    save(state) { saved = structuredClone(state); },
    state() { return saved ? structuredClone(saved) : null; },
  };
}

function harness({ store = memoryStore(), boundaryFreshMs = 120_000, now = "2026-09-12T04:01:00.000Z", contract = SOURCE_CONTRACT } = {}) {
  let currentNow = now;
  return {
    store,
    setNow(value) { currentNow = value; },
    adapter: createDayBaselineAdapter({
      account: "SYNTHETIC-PAPER",
      sourceContract: contract,
      store,
      boundaryFreshMs,
      currentFreshMs: 300_000,
      now: () => currentNow,
    }),
  };
}

function deskEvidence({
  at,
  oldest = at,
  equity = vector(),
  revision = REV_A,
  contract = PROVIDER_CONTRACT,
  coverageThrough = at,
} = {}) {
  return {
    ok: true,
    equity,
    sourceObservedAt: at,
    oldestSourceObservedAt: oldest,
    historyRevisionMethod: DESK_REVISION_METHOD,
    historyRevision: revision,
    executionCoverage: {
      status: "complete",
      fromInclusive: "2026-09-10T04:00:00.000Z",
      throughInclusive: coverageThrough,
    },
    sourceContract: structuredClone(contract),
    ownershipEvidence: { status: "complete", policyHash: contract.policyHash, unclaimedExecutionCount: 0 },
  };
}

function seedAndCross(options = {}) {
  const h = harness(options);
  h.setNow("2026-09-12T03:59:50.000Z");
  h.adapter.observe(observation({
    at: "2026-09-12T03:59:40.000Z",
    oldest: "2026-09-12T03:59:10.000Z",
    equity: vector(),
  }));
  h.setNow("2026-09-12T04:00:30.000Z");
  return h;
}

test("New York period starts cover both 23-hour and 25-hour DST days", () => {
  const springStart = newYorkPeriodStart("2026-03-08T12:00:00Z");
  const springNext = newYorkPeriodStart("2026-03-09T12:00:00Z");
  assert.equal(springStart, "2026-03-08T05:00:00.000Z");
  assert.equal(springNext, "2026-03-09T04:00:00.000Z");
  assert.equal(Date.parse(springNext) - Date.parse(springStart), 23 * 60 * 60 * 1000);

  const fallStart = newYorkPeriodStart("2026-11-01T12:00:00Z");
  const fallNext = newYorkPeriodStart("2026-11-02T12:00:00Z");
  assert.equal(fallStart, "2026-11-01T04:00:00.000Z");
  assert.equal(fallNext, "2026-11-02T05:00:00.000Z");
  assert.equal(Date.parse(fallNext) - Date.parse(fallStart), 25 * 60 * 60 * 1000);
});

test("a later complete receipt can prove the retained pre-boundary vector without becoming SOD", () => {
  const h = seedAndCross();
  const result = h.adapter.observe(observation({
    at: "2026-09-12T04:00:25.000Z",
    oldest: "2026-09-12T04:00:20.000Z",
    equity: vector({ j: 5012.34 }),
    revision: REV_B,
  }), { boundaryProof: boundaryProof() });

  assert.equal(result.ok, true);
  assert.deepEqual(result.values, { j: 12.34, joe: 0, joel: 0, total: 12.34 });
  assert.equal(result.source.method, DAY_PNL_METHOD);
  assert.equal(result.source.periodStart, "2026-09-12T04:00:00.000Z");
  assert.equal(result.evidence.sourceObservedAt, "2026-09-12T03:59:40.000Z");
  assert.equal(result.evidence.oldestSourceObservedAt, "2026-09-12T03:59:10.000Z");
  assert.equal(result.evidence.proofObservedAt, "2026-09-12T04:00:20.000Z");
  assert.equal(result.evidence.ageAtBoundaryMs, 50_000);
  assert.equal(h.adapter.inspectState().baseline.candidate.equity.j, 5000);
});

test("an exactly-at-boundary observation accepts the provider's zero-length cutoff proof", () => {
  const h = harness({ now: "2026-09-12T04:00:05.000Z" });
  const result = h.adapter.observe(observation({ at: "2026-09-12T04:00:00.000Z" }), {
    boundaryProof: boundaryProof({
      proofObservedAt: "2026-09-12T04:00:01.000Z",
      fromInclusive: "2026-09-12T04:00:00.000Z",
      throughExclusive: "2026-09-12T04:00:00.000Z",
    }),
  });
  assert.equal(result.ok, true, result.reason);
  assert.deepEqual(result.values, { j: 0, joe: 0, joel: 0, total: 0 });
});

test("a flat current book still includes a closed roundtrip through the equity delta", () => {
  const h = seedAndCross();
  const result = h.adapter.observe(observation({
    at: "2026-09-12T04:00:25.000Z",
    oldest: "2026-09-12T04:00:20.000Z",
    equity: vector({ j: 5008.75 }),
    revision: REV_B,
    openPositions: [],
  }), { boundaryProof: boundaryProof() });
  assert.equal(result.values.j, 8.75);
  assert.equal(result.values.total, 8.75);
});

test("KEEP-only account movement cannot affect the KEEP-excluded virtual vector", () => {
  const h = seedAndCross();
  const result = h.adapter.observe(observation({
    at: "2026-09-12T04:00:25.000Z",
    oldest: "2026-09-12T04:00:20.000Z",
    equity: vector(),
    revision: REV_A,
    accountEquityIncludingKeep: 21_000,
  }), { boundaryProof: boundaryProof() });
  assert.deepEqual(result.values, { j: 0, joe: 0, joel: 0, total: 0 });
  assert.equal("accountEquityIncludingKeep" in h.adapter.inspectState().latest, false);
});

test("the first fresh observation after a missed boundary becomes an explicit fixed session proxy", () => {
  const h = harness({ now: "2026-09-12T16:00:10.000Z" });
  const late = observation({ at: "2026-09-12T16:00:00.000Z", oldest: "2026-09-12T15:59:55.000Z" });
  const first = h.adapter.observe(late, { boundaryProof: boundaryProof({ proofObservedAt: "2026-09-12T16:00:05.000Z" }) });
  assert.equal(first.ok, true, first.reason);
  assert.deepEqual(first.values, { j: 0, joe: 0, joel: 0, total: 0 });
  assert.equal(first.source.sodSource, "session_open_proxy");
  assert.equal(first.source.referenceAt, "2026-09-12T16:00:00.000Z");
  assert.equal(first.source.periodStart, "2026-09-12T04:00:00.000Z");
  assert.equal(first.source.approximate, true);
  assert.equal(first.evidence.proofObservedAt, null);
  assert.equal(first.evidence.ageAtReferenceMs, 5_000);
  assert.equal("ageAtBoundaryMs" in first.evidence, false);
  assert.equal(h.adapter.inspectState().baseline, null);
  assert.equal(h.adapter.inspectState().missed.periodStart, "2026-09-12T04:00:00.000Z");

  h.setNow("2026-09-12T16:01:10.000Z");
  const later = h.adapter.observe(observation({
    at: "2026-09-12T16:01:00.000Z",
    equity: vector({ j: 5007.25, joe: 4999 }),
  }), {
    boundaryProof: boundaryProof({ proofObservedAt: "2026-09-12T16:01:05.000Z" }),
  });
  assert.equal(later.ok, true, later.reason);
  assert.deepEqual(later.values, { j: 7.25, joe: -1, joel: 0, total: 6.25 });
  assert.equal(later.source.referenceAt, first.source.referenceAt);
  assert.equal(h.adapter.inspectState().baseline, null);
  assert.deepEqual(h.adapter.inspectState().proxy.candidate.equity, vector());
});

test("a stale pre-boundary observation falls back to the first fresh in-day sample", () => {
  const h = harness({ boundaryFreshMs: 60_000 });
  h.setNow("2026-09-12T03:59:01.000Z");
  h.adapter.observe(observation({
    at: "2026-09-12T03:59:00.000Z",
    oldest: "2026-09-12T03:58:00.000Z",
  }));
  h.setNow("2026-09-12T04:00:30.000Z");
  const result = h.adapter.observe(observation({ at: "2026-09-12T04:00:25.000Z" }), {
    boundaryProof: boundaryProof(),
  });
  assert.equal(result.ok, true, result.reason);
  assert.equal(result.source.sodSource, "session_open_proxy");
  assert.equal(result.source.referenceAt, "2026-09-12T04:00:25.000Z");
  assert.match(h.adapter.inspectState().missed.reason, /too stale/);
  assert.equal(h.adapter.inspectState().pending, null);
});

test("incomplete boundary coverage remains retryable and may extend beyond midnight", () => {
  const h = seedAndCross();
  const current = observation({ at: "2026-09-12T04:00:25.000Z", oldest: "2026-09-12T04:00:20.000Z" });
  const short = h.adapter.observe(current, {
    boundaryProof: boundaryProof({ throughExclusive: "2026-09-12T03:59:59.000Z" }),
  });
  assert.equal(short.ok, false);
  assert.match(short.reason, /does not span periodStart/);
  assert.ok(h.adapter.inspectState().pending);

  h.setNow("2026-09-12T04:01:00.000Z");
  const complete = h.adapter.observe(observation({ at: "2026-09-12T04:00:50.000Z" }), {
    boundaryProof: boundaryProof({
      proofObservedAt: "2026-09-12T04:00:55.000Z",
      throughExclusive: "2026-09-12T04:00:45.000Z",
    }),
  });
  assert.equal(complete.ok, true);
});

test("a boundary history revision mismatch permanently rejects that candidate", () => {
  const h = seedAndCross();
  const result = h.adapter.observe(observation({ at: "2026-09-12T04:00:25.000Z", revision: REV_B }), {
    boundaryProof: boundaryProof({ revision: REV_B }),
  });
  assert.equal(result.ok, true, result.reason);
  assert.equal(result.source.sodSource, "session_open_proxy");
  assert.equal(h.adapter.inspectState().pending, null);
  assert.equal(h.adapter.inspectState().baseline, null);
  assert.match(h.adapter.inspectState().missed.reason, /history revision differs/);
});

test("source method and classifier mismatches fail closed without replacing the latest evidence", () => {
  const h = harness({ now: "2026-09-12T03:59:50.000Z" });
  const accepted = observation({ at: "2026-09-12T03:59:40.000Z" });
  h.adapter.observe(accepted);
  const prior = h.adapter.inspectState().latest;
  const changedContract = {
    ...SOURCE_CONTRACT,
    classifier: { ...SOURCE_CONTRACT.classifier, revision: "changed" },
  };
  const result = h.adapter.observe(observation({ at: "2026-09-12T03:59:45.000Z", contract: changedContract }));
  assert.equal(result.ok, false);
  assert.match(result.reason, /method or classifier/);
  assert.deepEqual(h.adapter.inspectState().latest, prior);

  const omittedExecutionAge = h.adapter.observe(observation({
    at: "2026-09-12T03:59:45.000Z",
    oldest: "2026-09-12T03:59:40.000Z",
    coverageThrough: "2026-09-12T03:59:30.000Z",
  }));
  assert.equal(omittedExecutionAge.ok, false);
  assert.match(omittedExecutionAge.reason, /does not include the execution coverage watermark/);
  assert.deepEqual(h.adapter.inspectState().latest, prior);
});

test("an atomic file store survives restart with its SOD proof and rejects changed configuration", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "joe-day-baseline-test-"));
  const file = path.join(directory, "day-baseline.json");
  const store = createFileDayBaselineStore(file);
  const h = seedAndCross({ store });
  const established = h.adapter.observe(observation({
    at: "2026-09-12T04:00:25.000Z",
    oldest: "2026-09-12T04:00:20.000Z",
    equity: vector({ joel: 5002 }),
  }), { boundaryProof: boundaryProof() });
  assert.equal(established.ok, true);
  assert.equal(JSON.parse(fs.readFileSync(file, "utf8")).schema, DAY_BASELINE_STATE_SCHEMA);
  assert.deepEqual(fs.readdirSync(directory).sort(), ["day-baseline.json"]);

  const legacyV1 = JSON.parse(fs.readFileSync(file, "utf8"));
  delete legacyV1.proxy;
  fs.writeFileSync(file, `${JSON.stringify(legacyV1, null, 2)}\n`, { mode: 0o600 });

  const restarted = harness({ store: createFileDayBaselineStore(file), now: "2026-09-12T04:01:00.000Z" });
  assert.equal(restarted.adapter.project().values.joel, 2);

  const changed = harness({
    store: createFileDayBaselineStore(file),
    contract: { ...SOURCE_CONTRACT, method: "another-method" },
  });
  assert.match(changed.adapter.blockedReason, /method or classifier mismatch/);
  assert.equal(changed.adapter.project().ok, false);
});

test("restart preserves a pre-boundary candidate until asynchronous coverage proof arrives", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "joe-day-baseline-pending-test-"));
  const file = path.join(directory, "day-baseline.json");
  const first = harness({ store: createFileDayBaselineStore(file), now: "2026-09-12T03:59:50.000Z" });
  first.adapter.observe(observation({
    at: "2026-09-12T03:59:40.000Z",
    oldest: "2026-09-12T03:59:10.000Z",
  }));
  first.setNow("2026-09-12T04:00:30.000Z");
  const pending = first.adapter.observe(observation({ at: "2026-09-12T04:00:25.000Z" }));
  assert.equal(pending.ok, true, pending.reason);
  assert.equal(pending.source.sodSource, "session_open_proxy");
  assert.ok(first.adapter.inspectState().pending);

  const restarted = harness({ store: createFileDayBaselineStore(file), now: "2026-09-12T04:01:00.000Z" });
  assert.equal(restarted.adapter.project().source.sodSource, "session_open_proxy");
  assert.equal(restarted.adapter.project().source.referenceAt, "2026-09-12T04:00:25.000Z");
  const proven = restarted.adapter.observe(observation({ at: "2026-09-12T04:00:50.000Z" }), {
    boundaryProof: boundaryProof({ proofObservedAt: "2026-09-12T04:00:55.000Z" }),
  });
  assert.equal(proven.ok, true);
  assert.equal(proven.source.sodSource, "new_york_midnight_exact");
  assert.equal(proven.source.approximate, false);
  assert.equal(proven.evidence.sourceObservedAt, "2026-09-12T03:59:40.000Z");
  assert.equal(restarted.adapter.inspectState().proxy, null);
});

test("a Friday observation cannot seed Monday and the Monday proxy resets on the NY date", () => {
  const h = harness({ now: "2026-09-11T20:00:10.000Z" });
  h.adapter.observe(observation({
    at: "2026-09-11T20:00:00.000Z",
    oldest: "2026-09-11T19:59:55.000Z",
    equity: vector({ j: 4990 }),
  }));

  h.setNow("2026-09-14T13:30:10.000Z");
  const monday = h.adapter.observe(observation({
    at: "2026-09-14T13:30:00.000Z",
    oldest: "2026-09-14T13:29:55.000Z",
    equity: vector({ j: 5010 }),
  }));
  assert.equal(monday.ok, true, monday.reason);
  assert.equal(monday.source.periodStart, "2026-09-14T04:00:00.000Z");
  assert.equal(monday.source.referenceAt, "2026-09-14T13:30:00.000Z");
  assert.deepEqual(monday.values, { j: 0, joe: 0, joel: 0, total: 0 });

  h.setNow("2026-09-14T13:31:10.000Z");
  const moved = h.adapter.observe(observation({
    at: "2026-09-14T13:31:00.000Z",
    oldest: "2026-09-14T13:30:55.000Z",
    equity: vector({ j: 5012.5 }),
  }));
  assert.equal(moved.values.j, 2.5);
  assert.equal(moved.source.referenceAt, monday.source.referenceAt);
});

test("invalid and stale first samples cannot establish a session proxy", () => {
  const h = harness({ now: "2026-09-12T16:00:10.000Z" });
  const invalid = h.adapter.observe(observation({
    at: "2026-09-12T16:00:00.000Z",
    equity: { j: 5000, joe: 5000, joel: 5000, total: 1 },
  }));
  assert.equal(invalid.ok, false);
  assert.match(invalid.reason, /desk sum/);
  assert.equal(h.adapter.inspectState(), null);

  const stale = h.adapter.observe(observation({
    at: "2026-09-12T16:00:00.000Z",
    oldest: "2026-09-12T15:50:00.000Z",
  }));
  assert.equal(stale.ok, false);
  assert.match(stale.reason, /first observation arrived after/);
  assert.equal(h.adapter.inspectState().proxy, null);

  h.setNow("2026-09-12T16:01:10.000Z");
  const fresh = h.adapter.observe(observation({
    at: "2026-09-12T16:01:00.000Z",
    oldest: "2026-09-12T16:00:55.000Z",
  }));
  assert.equal(fresh.ok, true, fresh.reason);
  assert.equal(fresh.source.sodSource, "session_open_proxy");
});

test("persisted proxy evidence is fully validated on restart", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "joe-day-baseline-proxy-invalid-test-"));
  const file = path.join(directory, "day-baseline.json");
  const first = harness({ store: createFileDayBaselineStore(file), now: "2026-09-12T16:00:10.000Z" });
  assert.equal(first.adapter.observe(observation({
    at: "2026-09-12T16:00:00.000Z",
    oldest: "2026-09-12T15:59:55.000Z",
  })).ok, true);
  const forged = JSON.parse(fs.readFileSync(file, "utf8"));
  forged.proxy.ageAtReferenceMs = 1;
  fs.writeFileSync(file, `${JSON.stringify(forged, null, 2)}\n`, { mode: 0o600 });

  const restarted = harness({ store: createFileDayBaselineStore(file), now: "2026-09-12T16:00:20.000Z" });
  assert.match(restarted.adapter.blockedReason, /proxy freshness proof is invalid/);
  assert.equal(restarted.adapter.project().ok, false);
});

test("a session proxy is unavailable when its durable save fails", () => {
  const store = {
    load: () => ({ ok: true, state: null }),
    save: () => { throw new Error("synthetic disk failure"); },
  };
  const h = harness({ store, now: "2026-09-12T16:00:10.000Z" });
  const result = h.adapter.observe(observation({
    at: "2026-09-12T16:00:00.000Z",
    oldest: "2026-09-12T15:59:55.000Z",
  }));
  assert.equal(result.ok, false);
  assert.match(result.reason, /state save failed/);
  assert.match(h.adapter.blockedReason, /synthetic disk failure/);
  assert.equal(h.adapter.inspectState(), null);
});

test("corrupt persisted state stays unavailable and is never overwritten", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "joe-day-baseline-corrupt-test-"));
  const file = path.join(directory, "day-baseline.json");
  fs.writeFileSync(file, "{broken", { mode: 0o600 });
  const original = fs.readFileSync(file, "utf8");
  const h = harness({ store: createFileDayBaselineStore(file) });
  assert.match(h.adapter.blockedReason, /corrupt JSON/);
  assert.equal(h.adapter.observe(observation({ at: "2026-09-12T04:00:00.000Z" })).ok, false);
  assert.equal(fs.readFileSync(file, "utf8"), original);
});

test("all-desk producer preserves evidence and proves the retained boundary candidate", () => {
  let currentNow = "2026-09-12T03:59:50.000Z";
  let proofInput;
  const producer = createDeskDayPnlProducer({
    account: "SYNTHETIC-PAPER",
    policy: { id: "effective-policy" },
    providerContract: PROVIDER_CONTRACT,
    historyRevisionMethod: DESK_REVISION_METHOD,
    store: memoryStore(),
    buildBoundaryEvidence(input) {
      proofInput = input;
      return {
        ok: true,
        periodStart: input.periodStart,
        proofObservedAt: input.proofObservedAt,
        historyRevisionMethod: DESK_REVISION_METHOD,
        candidateHistoryRevision: input.candidateHistoryRevision,
        boundaryHistoryRevision: input.candidateHistoryRevision,
        executionCoverage: {
          status: "complete",
          fromInclusive: "2026-09-12T03:59:10.000Z",
          throughExclusive: "2026-09-12T04:00:20.000Z",
        },
        policyHash: POLICY_HASH,
      };
    },
    getVerifiedHistoryState: () => ({ schema: "verified-history" }),
    now: () => currentNow,
  });
  producer.observe(deskEvidence({
    at: "2026-09-12T03:59:40.000Z",
    oldest: "2026-09-12T03:59:10.000Z",
    coverageThrough: "2026-09-12T03:59:10.000Z",
  }));
  currentNow = "2026-09-12T04:00:30.000Z";
  const result = producer.observe(deskEvidence({
    at: "2026-09-12T04:00:25.000Z",
    oldest: "2026-09-12T04:00:20.000Z",
    coverageThrough: "2026-09-12T04:00:20.000Z",
    equity: vector({ j: 5004, joe: 4999, joel: 5000 }),
    revision: REV_B,
  }));

  assert.equal(result.ok, true, result.reason);
  assert.deepEqual(result.values, { j: 4, joe: -1, joel: 0, total: 3 });
  assert.equal(proofInput.candidateSourceObservedAt, "2026-09-12T03:59:40.000Z");
  assert.equal(proofInput.candidateHistoryRevision, REV_A);
  assert.equal(proofInput.periodStart, "2026-09-12T04:00:00.000Z");
  assert.equal(result.evidence.historyRevisionMethod, DESK_REVISION_METHOD);
});

test("unavailable asynchronous exact proof does not suppress the producer's session proxy", () => {
  let currentNow = "2026-09-12T03:59:50.000Z";
  const producer = createDeskDayPnlProducer({
    account: "SYNTHETIC-PAPER",
    policy: { id: "effective-policy" },
    providerContract: PROVIDER_CONTRACT,
    historyRevisionMethod: DESK_REVISION_METHOD,
    store: memoryStore(),
    buildBoundaryEvidence: () => ({ ok: false, reason: "exact cutoff coverage is pending" }),
    getVerifiedHistoryState: () => ({ schema: "verified-history" }),
    now: () => currentNow,
  });
  producer.observe(deskEvidence({
    at: "2026-09-12T03:59:40.000Z",
    oldest: "2026-09-12T03:59:10.000Z",
    coverageThrough: "2026-09-12T03:59:10.000Z",
  }));

  currentNow = "2026-09-12T04:00:30.000Z";
  const result = producer.observe(deskEvidence({
    at: "2026-09-12T04:00:25.000Z",
    oldest: "2026-09-12T04:00:20.000Z",
    coverageThrough: "2026-09-12T04:00:20.000Z",
  }));
  assert.equal(result.ok, true, result.reason);
  assert.equal(result.source.sodSource, "session_open_proxy");
  assert.ok(producer.inspectState().pending);
  assert.ok(producer.inspectState().proxy);
});

test("all-desk producer rejects self-asserted policy provenance before persistence", () => {
  const producer = createDeskDayPnlProducer({
    account: "SYNTHETIC-PAPER",
    policy: {},
    providerContract: PROVIDER_CONTRACT,
    historyRevisionMethod: DESK_REVISION_METHOD,
    store: memoryStore(),
    buildBoundaryEvidence: () => ({ ok: false, reason: "not reached" }),
    getVerifiedHistoryState: () => ({}),
    now: () => "2026-09-12T03:59:50.000Z",
  });
  const forged = deskEvidence({ at: "2026-09-12T03:59:40.000Z" });
  forged.sourceContract.policyHash = "d".repeat(64);
  const result = producer.observe(forged);
  assert.equal(result.ok, false);
  assert.match(result.reason, /source contract/);
  assert.equal(producer.inspectState(), null);
});


test("HOSTD-64 portfolio refresh restores DAY without moving the saved session reference", () => {
  const referenceAt = "2026-09-14T16:22:27.771Z";
  let instant = Date.parse(referenceAt);
  const h = harness({ now: referenceAt });
  const first = h.adapter.observe(observation({ at: referenceAt }));
  assert.equal(first.ok, true, first.reason);
  assert.equal(first.source.sodSource, "session_open_proxy");
  const savedProxy = structuredClone(h.adapter.inspectState().proxy);
  const contract = { conId: 101, symbol: "SYNTH", secType: "STK", currency: "EUR" };
  const book = {
    gateway: true,
    positionsCoverage: { status: "complete", rows: [{ contract, pos: 1 }] },
    portfolio: [{ contract, pos: 1, marketPrice: 100, markObservedAt: referenceAt }],
  };
  let requests = 0;
  const refresh = createPortfolioRefreshController({ nowMs: () => instant, refresh: () => { requests += 1; } });
  const value = () => h.adapter.observe(observation({
    at: new Date(instant).toISOString(),
    oldest: book.portfolio[0].markObservedAt,
    equity: vector({ j: 5000 + book.portfolio[0].marketPrice - 100 }),
  }));

  // Gateway and publisher still advance; the actual held mark does not.
  instant += 360_000;
  h.setNow(new Date(instant).toISOString());
  assert.equal(refresh.tick(book), true);
  assert.equal(requests, 1);
  const waiting = value();
  assert.equal(waiting.ok, false);
  assert.match(waiting.reason, /current virtual-equity observation is stale/);
  assert.deepEqual(h.adapter.inspectState().proxy, savedProxy);
  assert.equal(book.portfolio[0].markObservedAt, referenceAt);

  // Only the broker mark response supplies a new valuation/time.
  instant += 5_000;
  h.setNow(new Date(instant).toISOString());
  book.portfolio[0].marketPrice = 102;
  book.portfolio[0].markObservedAt = new Date(instant).toISOString();
  refresh.tick(book);
  const restored = value();
  assert.equal(restored.ok, true, restored.reason);
  assert.equal(restored.values.j, 2);
  assert.equal(restored.source.referenceAt, referenceAt);
  assert.deepEqual(h.adapter.inspectState().proxy, savedProxy);
});
