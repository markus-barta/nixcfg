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

test("the first observation after midnight is durable evidence of a missed boundary, never a baseline", () => {
  const h = harness({ now: "2026-09-12T16:00:10.000Z" });
  const late = observation({ at: "2026-09-12T16:00:00.000Z", oldest: "2026-09-12T15:59:55.000Z" });
  const first = h.adapter.observe(late, { boundaryProof: boundaryProof({ proofObservedAt: "2026-09-12T16:00:05.000Z" }) });
  assert.equal(first.ok, false);
  assert.match(first.reason, /first observation arrived after/);
  assert.equal(h.adapter.inspectState().baseline, null);
  assert.equal(h.adapter.inspectState().missed.periodStart, "2026-09-12T04:00:00.000Z");

  h.setNow("2026-09-12T16:01:10.000Z");
  const later = h.adapter.observe(observation({ at: "2026-09-12T16:01:00.000Z" }), {
    boundaryProof: boundaryProof({ proofObservedAt: "2026-09-12T16:01:05.000Z" }),
  });
  assert.equal(later.ok, false);
  assert.equal(h.adapter.inspectState().baseline, null);
});

test("a stale pre-boundary observation records a missed boundary", () => {
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
  assert.equal(result.ok, false);
  assert.match(result.reason, /too stale/);
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
  assert.equal(result.ok, false);
  assert.match(result.reason, /history revision differs/);
  assert.equal(h.adapter.inspectState().pending, null);
  assert.equal(h.adapter.inspectState().baseline, null);
  assert.ok(h.adapter.inspectState().missed);
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
  assert.equal(pending.ok, false);
  assert.ok(first.adapter.inspectState().pending);

  const restarted = harness({ store: createFileDayBaselineStore(file), now: "2026-09-12T04:01:00.000Z" });
  const proven = restarted.adapter.observe(observation({ at: "2026-09-12T04:00:50.000Z" }), {
    boundaryProof: boundaryProof({ proofObservedAt: "2026-09-12T04:00:55.000Z" }),
  });
  assert.equal(proven.ok, true);
  assert.equal(proven.evidence.sourceObservedAt, "2026-09-12T03:59:40.000Z");
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
