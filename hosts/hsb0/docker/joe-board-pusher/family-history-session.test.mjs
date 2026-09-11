#!/usr/bin/env node
/** Synthetic runtime capture tests. No broker connection or real account data. */
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { pathToFileURL } from "node:url";

import {
  createFamilyHistorySessionAdapter,
  createOfficialHistoryRefresher,
} from "./family-history-session.mjs";
import { reconcileExecutionCapture } from "./execution-reconciliation.mjs";
import {
  FAMILY_BASELINE_PERIOD_START,
  FAMILY_STATE_SCHEMA,
  createFileFamilyStateStore,
} from "./family-state.mjs";

const ACCOUNT = "SYNTHETIC-PAPER";
const CLIENT_ID = 92;
const FAMILY_IDS = [27, 28, 29, 50, 51, 52, 53, 54, 55, 56];
const CLASSIFIER = { familyClientIds: FAMILY_IDS, excludedSymbols: ["SXR8", "TSLA"] };
const HISTORY_START = "2026-09-10T04:00:00Z";
const EVENTS = {
  connected: "connected",
  disconnected: "disconnected",
  managedAccounts: "managedAccounts",
  execDetails: "execDetails",
  execDetailsEnd: "execDetailsEnd",
  commissionReport: "commissionReport",
};

class FakeApi extends EventEmitter {
  requests = [];
  connectCalls = 0;
  disconnectCalls = 0;
  reqManagedAccts() { this.requests.push(["managedAccounts"]); }
  reqExecutions(...args) { this.requests.push(["executions", ...args]); }
  connect() { this.connectCalls += 1; }
  disconnect() { this.disconnectCalls += 1; }
}

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
    runDelay(delay) {
      const entry = [...pending.entries()].find(([, value]) => value.delay === delay);
      assert.ok(entry, `no ${delay}ms timer pending`);
      pending.delete(entry[0]);
      entry[1].callback();
    },
    count(delay) { return [...pending.values()].filter((item) => item.delay === delay).length; },
  };
}

function execution(execId, {
  clientId = 56,
  symbol = "ACME",
  time = "20260911 07:30:00 US/Eastern",
  shares = "1",
  price = "10",
} = {}) {
  return {
    contract: { conId: 101, symbol, secType: "STK", currency: "USD", exchange: "SMART" },
    execution: { execId, acctNumber: ACCOUNT, clientId, side: "BOT", shares, price, time },
  };
}

function commission(execId, amount = 0.25, realizedPNL = 0) {
  return { execId, commissionAndFees: amount, currency: "USD", realizedPNL };
}

function normalizeExecutionRow({ contract, execution: row }) {
  const time = row.time === "20260910 10:00:00 US/Eastern"
    ? "2026-09-10T14:00:00.000Z"
    : "2026-09-11T11:30:00.000Z";
  return {
    contract: { conId: Number(contract.conId), symbol: contract.symbol, secType: contract.secType, currency: contract.currency, multiplier: 1 },
    execution: {
      execId: row.execId,
      acctNumber: row.acctNumber,
      clientId: Number(row.clientId),
      side: row.side === "BOT" ? "BUY" : "SELL",
      shares: Number(row.shares),
      price: Number(row.price),
      time,
    },
  };
}

function normalizeCommissionReport(row) {
  return {
    execId: row.execId,
    commission: Number(row.commissionAndFees ?? row.commission),
    currency: row.currency,
    realizedPNL: row.realizedPNL ?? null,
  };
}

function memoryStore(initial = null, loadError = null) {
  let state = initial ? structuredClone(initial) : null;
  let saves = 0;
  return {
    load: () => loadError ? { ok: false, reason: loadError } : { ok: true, state: state ? structuredClone(state) : null },
    save(next) { state = structuredClone(next); saves += 1; },
    get state() { return state ? structuredClone(state) : null; },
    get saves() { return saves; },
  };
}

function durableState({ executions = [], commissions = [], targetThrough = "2026-09-11T12:00:00.000Z" } = {}) {
  const target = { fromInclusive: "2026-09-10T04:00:00.000Z", toExclusive: targetThrough };
  return {
    account: ACCOUNT,
    classifier: structuredClone(CLASSIFIER),
    target,
    executions: structuredClone(executions),
    commissions: structuredClone(commissions),
    receipts: [],
    coverage: {
      status: "known",
      target,
      completeIntervals: [],
      knownIntervals: [],
      gaps: [{ fromInclusive: target.fromInclusive, toExclusive: target.toExclusive, reason: "synthetic unknown coverage" }],
    },
  };
}

function legacyCapture({ account = ACCOUNT, classifier = CLASSIFIER } = {}) {
  const row = normalizeExecutionRow({
    ...execution("seed.synthetic.01", { time: "20260910 10:00:00 US/Eastern" }),
  });
  return {
    schema: "synthetic.execution-capture.v1",
    account,
    classifier: structuredClone(classifier),
    source: { kind: "persisted-ledger", id: "synthetic-legacy", sha256: "a".repeat(64), metadata: {} },
    capturedAt: "2026-09-10T20:00:00.000Z",
    window: { fromInclusive: "2026-09-10T04:00:00.000Z", toExclusive: "2026-09-10T20:00:00.000Z" },
    coverageStatus: "known",
    completenessAssertion: null,
    executions: [row],
    commissions: [{ execId: row.execution.execId, commission: 0.25, currency: "USD", realizedPNL: 1 }],
  };
}

function knownReconcile({ prior, capture, target }) {
  assert.equal(capture.coverageStatus, "known");
  assert.equal(capture.completenessAssertion, null);
  assert.ok(["paper-api", "persisted-ledger"].includes(capture.source.kind));
  assert.equal(capture.classifier.familyClientIds.at(-1), 56);
  assert.deepEqual(capture.classifier.excludedSymbols, ["SXR8", "TSLA"]);
  const executions = new Map((prior?.executions || []).map((row) => [row.execution.execId, row]));
  const commissions = new Map((prior?.commissions || []).map((row) => [row.execId, row]));
  for (const row of capture.executions) executions.set(row.execution.execId, row);
  for (const row of capture.commissions) commissions.set(row.execId, row);
  return {
    account: capture.account,
    classifier: capture.classifier,
    target,
    executions: [...executions.values()],
    commissions: [...commissions.values()],
    receipts: [...(prior?.receipts || []), { source: capture.source, window: capture.window }],
    coverage: {
      status: "known",
      target,
      completeIntervals: structuredClone(prior?.coverage?.completeIntervals || []),
      knownIntervals: [...(prior?.coverage?.knownIntervals || []), capture.window],
      gaps: [{ fromInclusive: HISTORY_START, toExclusive: target.toExclusive, reason: "synthetic unknown coverage" }],
    },
  };
}

function projectHistory({ state }) {
  const realizedPnl = state.commissions.reduce((sum, row) => sum + (Number(row.realizedPNL) || 0), 0);
  return {
    ok: true,
    status: "BEST_AVAILABLE",
    equity: null,
    capturedSubtotal: {
      currency: state.commissions.length ? "USD" : null,
      realizedPnl: state.commissions.length ? realizedPnl : null,
      points: state.commissions.map((row, index) => ({ at: `2026-09-1${index}T12:00:00.000Z`, realizedPnl: row.realizedPNL || 0 })),
      executionCount: state.executions.length,
      commissionCount: state.commissions.length,
      fromInclusive: null,
      throughInclusive: null,
    },
    coverage: state.coverage,
  };
}

function setup({
  at = "2026-09-11T12:00:00Z",
  store = memoryStore(),
  reconcileCapture = knownReconcile,
  loadBootstrapCapture = null,
  project = projectHistory,
  retryBaseMs = 5_000,
  retryMaxMs = 300_000,
} = {}) {
  let current = at;
  const timers = fakeTimers();
  const unavailable = [];
  const updated = [];
  const seeded = [];
  const adapter = createFamilyHistorySessionAdapter({
    targetAccount: ACCOUNT,
    brokerClientId: CLIENT_ID,
    familyClientIds: FAMILY_IDS,
    excludedSymbols: ["SXR8", "TSLA"],
    historyStart: HISTORY_START,
    captureSchema: "synthetic.execution-capture.v1",
    normalizeExecutionRow,
    normalizeCommissionReport,
    reconcileCapture,
    projectHistory: project,
    eventNames: EVENTS,
    store,
    loadBootstrapCapture,
    pollIntervalMs: 30_000,
    requestTimeoutMs: 20_000,
    commissionDrainMs: 3_000,
    retryBaseMs,
    retryMaxMs,
    retryJitterRatio: 0,
    now: () => current,
    random: () => 0.5,
    setTimer: timers.set,
    clearTimer: timers.clear,
    requestManagedAccounts: false,
    hooks: {
      onUnavailable: (reason) => unavailable.push(reason),
      onSeeded: (detail) => seeded.push(detail),
      onUpdated: (detail) => updated.push(detail),
    },
  });
  return { adapter, store, timers, unavailable, updated, seeded, setNow(value) { current = value; } };
}

function connect(session, api = new FakeApi()) {
  session.adapter.attach(api);
  api.emit(EVENTS.connected);
  api.emit(EVENTS.managedAccounts, ACCOUNT);
  return api;
}

function currentRequest(api) {
  return api.requests.findLast((row) => row[0] === "executions");
}

async function loadHistoryHelpers() {
  const configured = process.env.HOSTD39_HELPER_DIR;
  const base = configured
    ? pathToFileURL(`${path.resolve(configured)}${path.sep}`)
    : new URL("./", import.meta.url);
  const [historySource, reconciliation, history] = await Promise.all([
    import(new URL("execution-history.mjs", base)),
    import(new URL("execution-reconciliation.mjs", base)),
    import(new URL("family-history.mjs", base)),
  ]);
  return { ...historySource, ...reconciliation, ...history };
}

test("next-day known capture continues after the complete family adapter would latch, retaining omitted prior IDs", () => {
  const priorRow = normalizeExecutionRow(execution("prior.synthetic.01", { time: "20260910 10:00:00 US/Eastern" }));
  const prior = durableState({
    executions: [priorRow],
    commissions: [{ execId: priorRow.execution.execId, commission: 0.1, currency: "USD", realizedPNL: 0 }],
  });
  const session = setup({ store: memoryStore(prior) });
  const fullAccountingLatch = "unproved execution retrieval gap across America/New_York midnight";
  assert.match(fullAccountingLatch, /midnight/);
  const api = connect(session);
  const request = currentRequest(api);
  assert.equal(request[1] % 2, 1);
  assert.deepEqual(request[2], {
    acctCode: ACCOUNT,
    time: "20260911-04:00:00",
    specificDates: [20260911],
  });
  assert.equal(api.connectCalls, 0);
  assert.equal(api.disconnectCalls, 0);

  const next = execution("next.synthetic.01");
  api.emit(EVENTS.execDetails, request[1], next.contract, next.execution);
  api.emit(EVENTS.execDetailsEnd, request[1]);
  assert.equal(session.adapter.requestInFlight, true);
  api.emit(EVENTS.commissionReport, commission(next.execution.execId, 0.4));
  session.timers.runDelay(3_000);

  assert.equal(session.adapter.requestInFlight, false);
  assert.deepEqual(session.store.state.executions.map((row) => row.execution.execId), [
    "prior.synthetic.01",
    "next.synthetic.01",
  ]);
  assert.deepEqual(session.store.state.coverage.completeIntervals, []);
  assert.equal(session.store.state.coverage.knownIntervals.length, 1);
  assert.deepEqual(session.store.state.commissions.find((row) => row.execId === next.execution.execId), {
    execId: next.execution.execId,
    commission: 0.4,
    currency: "USD",
    realizedPNL: 0,
  });
  assert.equal(session.updated[0].missingCommissionCount, 0);
  assert.equal(session.adapter.project().status, "BEST_AVAILABLE");

  assert.equal(session.adapter.upstreamUnavailable("synthetic retained-socket outage"), true);
  assert.equal(session.adapter.project().status, "BEST_AVAILABLE");
});

test("unchanged retained-day replays do not churn receipts or the durable sidecar", () => {
  const session = setup();
  const api = connect(session);
  const firstRequest = currentRequest(api);
  const row = execution("stable.synthetic.01");
  api.emit(EVENTS.execDetails, firstRequest[1], row.contract, row.execution);
  api.emit(EVENTS.commissionReport, commission(row.execution.execId));
  api.emit(EVENTS.execDetailsEnd, firstRequest[1]);
  session.timers.runDelay(3_000);
  const persisted = session.store.state;
  assert.equal(session.store.saves, 1);

  session.timers.runDelay(30_000);
  const repeatRequest = currentRequest(api);
  api.emit(EVENTS.execDetails, repeatRequest[1], row.contract, row.execution);
  api.emit(EVENTS.commissionReport, commission(row.execution.execId));
  api.emit(EVENTS.execDetailsEnd, repeatRequest[1]);
  session.timers.runDelay(3_000);
  assert.equal(session.store.saves, 1);
  assert.deepEqual(session.store.state, persisted);
  assert.equal(session.timers.count(30_000), 1);
});

test("official import skips an equivalent write and preserves a concurrent live target", () => {
  const store = memoryStore();
  const targets = [];
  const session = setup({
    at: "2026-09-11T14:00:00Z",
    store,
    reconcileCapture(args) {
      targets.push(structuredClone(args.target));
      return reconcileExecutionCapture(args);
    },
  });
  const row = normalizeExecutionRow(execution("official-stable.synthetic.01"));
  const window = { fromInclusive: "2026-09-11T04:00:00Z", toExclusive: "2026-09-11T12:00:00Z" };
  function officialCapture(id, capturedAt) {
    return {
      schema: "inspr.ib.execution-capture.v1",
      account: ACCOUNT,
      classifier: structuredClone(CLASSIFIER),
      source: {
        kind: "paper-api",
        id,
        sha256: id === "official-request-1" ? "b".repeat(64) : "c".repeat(64),
        metadata: {
          adapterId: "official-window-json",
          adapterVersion: "1",
          endpointIdentitySha256: "d".repeat(64),
          requestId: id,
        },
      },
      capturedAt,
      window,
      coverageStatus: "complete",
      completenessAssertion: {
        provider: "ibkr-official-sdk-execution-window-v1",
        assertionId: `assertion:${id}`,
      },
      executions: [row],
      commissions: [{ execId: row.execution.execId, commission: 0.25, currency: "USD", realizedPNL: 0 }],
    };
  }

  const first = officialCapture("official-request-1", "2026-09-11T12:00:01Z");
  assert.equal(session.adapter.importCaptures([first], {
    fromInclusive: HISTORY_START,
    toExclusive: "2026-09-11T14:00:00Z",
  }).ok, true);
  const persisted = store.state;
  assert.equal(store.saves, 1);
  assert.equal(session.updated.length, 1);

  const replay = officialCapture("official-request-2", "2026-09-11T13:00:01Z");
  const replayBefore = structuredClone(replay);
  assert.equal(session.adapter.importCaptures([replay], {
    fromInclusive: HISTORY_START,
    toExclusive: "2026-09-11T13:00:00Z",
  }).ok, true);
  assert.deepEqual(targets.at(-1), {
    fromInclusive: "2026-09-10T04:00:00.000Z",
    toExclusive: "2026-09-11T14:00:00.000Z",
  });
  assert.equal(store.saves, 1);
  assert.equal(session.updated.length, 1);
  assert.deepEqual(store.state, persisted);
  assert.deepEqual(replay, replayBefore);
});

test("an absent sidecar seeds exactly once from immutable legacy capture and restart loads the exact state", () => {
  const source = legacyCapture();
  const sourceBefore = structuredClone(source);
  const store = memoryStore();
  let loads = 0;
  const loadBootstrapCapture = ({ targetAccount, classifier, historyStart }) => {
    loads += 1;
    assert.equal(targetAccount, ACCOUNT);
    assert.equal(historyStart, "2026-09-10T04:00:00Z");
    assert.deepEqual(classifier, CLASSIFIER);
    assert.equal(classifier.familyClientIds.at(-1), 56);
    return { ok: true, capture: source };
  };
  const first = setup({ store, loadBootstrapCapture });
  assert.equal(loads, 1);
  assert.equal(store.saves, 1);
  assert.equal(first.seeded.length, 1);
  assert.equal(first.seeded[0].capturedAt, source.capturedAt);
  assert.deepEqual(source, sourceBefore);
  assert.deepEqual(store.state.receipts[0].window, {
    fromInclusive: "2026-09-10T04:00:00.000Z",
    toExclusive: "2026-09-10T20:00:00.000Z",
  });
  assert.equal(store.state.target.toExclusive, "2026-09-11T12:00:00.000Z");
  const seededState = store.state;

  const restarted = setup({ store, loadBootstrapCapture });
  assert.equal(loads, 1);
  assert.equal(store.saves, 1);
  assert.deepEqual(restarted.adapter.inspectState(), seededState);
  assert.deepEqual(store.state, seededState);
});

test("real legacy and history stores preserve the literal Z bootstrap seam and reject wrong identities", async () => {
  const {
    EXECUTION_CAPTURE_SCHEMA,
    captureFromFamilyLedgerFile,
    createFileFamilyHistoryStore,
    normalizeEconomicCommission,
    normalizeEconomicExecution,
    projectBestAvailableHistory,
    reconcileExecutionCapture,
  } = await loadHistoryHelpers();
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "family-history-bootstrap-test-"));
  const legacyPath = path.join(directory, "family-ledger.json");
  const historyPath = path.join(directory, "family-history.json");
  const legacyStore = createFileFamilyStateStore(legacyPath);
  const legacyRow = execution("bootstrap.real-helper.01", {
    time: "20260910 10:00:00 US/Eastern",
    shares: 1,
    price: 10,
  });
  legacyStore.save({
    schema: FAMILY_STATE_SCHEMA,
    version: 1,
    account: ACCOUNT,
    periodStart: FAMILY_BASELINE_PERIOD_START,
    classifier: structuredClone(CLASSIFIER),
    initializedAt: "2026-09-10T12:00:00Z",
    ledgerObservedAt: "2026-09-10T20:00:00Z",
    coverageThrough: "2026-09-10T20:00:00Z",
    coverageTradingDay: "2026-09-10",
    queryExecutionIdentities: [legacyRow.execution.execId],
    executions: [legacyRow],
    commissions: [{ execId: legacyRow.execution.execId, commission: 0.25, currency: "USD", realizedPNL: 1 }],
    family: null,
  });
  const legacyBytes = fs.readFileSync(legacyPath);
  let bootstrapLoads = 0;

  function adapterFor({
    targetAccount = ACCOUNT,
    familyClientIds = FAMILY_IDS,
    historyStart = FAMILY_BASELINE_PERIOD_START,
    statePath = historyPath,
  } = {}) {
    const historyStore = createFileFamilyHistoryStore(statePath);
    return createFamilyHistorySessionAdapter({
      targetAccount,
      brokerClientId: CLIENT_ID,
      familyClientIds,
      excludedSymbols: ["SXR8", "TSLA"],
      historyStart,
      captureSchema: EXECUTION_CAPTURE_SCHEMA,
      normalizeExecutionRow: normalizeEconomicExecution,
      normalizeCommissionReport: normalizeEconomicCommission,
      reconcileCapture: reconcileExecutionCapture,
      projectHistory: projectBestAvailableHistory,
      eventNames: EVENTS,
      store: historyStore,
      loadBootstrapCapture({ targetAccount: configuredAccount, classifier, historyStart: configuredStart }) {
        bootstrapLoads += 1;
        const loaded = legacyStore.load({
          account: configuredAccount,
          periodStart: configuredStart,
          classifier,
        });
        if (!loaded.ok) return { ok: false, freshInstall: false, reason: loaded.reason };
        if (!loaded.state) return { ok: false, freshInstall: true, reason: "legacy family ledger is absent" };
        return {
          ok: true,
          capture: captureFromFamilyLedgerFile({
            filePath: legacyPath,
            window: {
              fromInclusive: loaded.state.periodStart,
              toExclusive: loaded.state.coverageThrough,
            },
            classifier,
          }),
        };
      },
      now: () => "2026-09-11T12:00:00Z",
    });
  }

  const seeded = adapterFor();
  assert.equal(seeded.blockedReason, null);
  assert.equal(bootstrapLoads, 1);
  assert.equal(seeded.inspectState().target.fromInclusive, "2026-09-10T04:00:00.000Z");
  assert.equal(seeded.inspectState().receipts[0].window.fromInclusive, "2026-09-10T04:00:00.000Z");
  assert.equal(seeded.inspectState().receipts[0].window.toExclusive, "2026-09-10T20:00:00.000Z");
  assert.deepEqual(fs.readFileSync(legacyPath), legacyBytes);
  const historyBytes = fs.readFileSync(historyPath);

  const restarted = adapterFor();
  assert.equal(restarted.blockedReason, null);
  assert.equal(bootstrapLoads, 1);
  assert.deepEqual(restarted.inspectState(), seeded.inspectState());
  assert.deepEqual(fs.readFileSync(historyPath), historyBytes);

  for (const variant of [
    { label: "baseline", options: { historyStart: "2026-09-10T05:00:00Z" } },
    { label: "account", options: { targetAccount: "OTHER-PAPER" } },
    { label: "classifier", options: { familyClientIds: FAMILY_IDS.slice(0, -1) } },
  ]) {
    const statePath = path.join(directory, `family-history-wrong-${variant.label}.json`);
    const refused = adapterFor({ ...variant.options, statePath });
    assert.ok(refused.blockedReason, `${variant.label} identity was accepted`);
    assert.equal(fs.existsSync(statePath), false);
    assert.deepEqual(fs.readFileSync(legacyPath), legacyBytes);
  }
});

test("existing or bootstrap history with a wrong identity is unavailable and never overwritten", () => {
  const variants = [
    { label: "account", mutate: (state) => { state.account = "OTHER-PAPER"; } },
    { label: "classifier", mutate: (state) => { state.classifier.familyClientIds.pop(); } },
    { label: "target", mutate: (state) => { state.target.fromInclusive = "2026-09-09T04:00:00.000Z"; } },
  ];
  for (const variant of variants) {
    const existing = durableState();
    variant.mutate(existing);
    const store = memoryStore(existing);
    const session = setup({ store });
    assert.match(session.adapter.blockedReason, new RegExp(variant.label));
    assert.equal(session.adapter.project().ok, false);
    assert.deepEqual(store.state, existing);
    assert.equal(store.saves, 0);
    assert.equal(currentRequest(connect(session)), undefined);
  }

  const wrongCapture = legacyCapture({ account: "OTHER-PAPER" });
  const seedStore = memoryStore();
  const seed = setup({
    store: seedStore,
    loadBootstrapCapture: () => ({ ok: true, capture: wrongCapture }),
  });
  assert.match(seed.adapter.blockedReason, /capture account/);
  assert.equal(seedStore.state, null);
  assert.equal(seedStore.saves, 0);

  const invalidStore = memoryStore();
  const invalid = setup({
    store: invalidStore,
    loadBootstrapCapture: () => ({ ok: false, freshInstall: false, reason: "legacy family ledger is invalid" }),
  });
  assert.match(invalid.adapter.blockedReason, /legacy family ledger is invalid/);
  assert.equal(invalidStore.saves, 0);
});

test("a genuinely fresh install reports unknown history and only persists an actual empty broker capture", () => {
  const store = memoryStore();
  const session = setup({
    store,
    loadBootstrapCapture: () => ({
      ok: false,
      freshInstall: true,
      reason: "legacy family ledger is absent; starting with unknown past history",
    }),
  });
  assert.equal(session.adapter.blockedReason, null);
  assert.match(session.adapter.startupReason, /unknown past history/);
  assert.equal(session.adapter.project().ok, false);
  assert.equal(store.saves, 0);

  const api = connect(session);
  const request = currentRequest(api);
  api.emit(EVENTS.execDetailsEnd, request[1]);
  session.timers.runDelay(3_000);
  assert.equal(store.saves, 1);
  assert.deepEqual(store.state.executions, []);
  assert.deepEqual(store.state.commissions, []);
  assert.equal(store.state.receipts.length, 1);
  assert.deepEqual(store.state.coverage.completeIntervals, []);
  assert.equal(session.adapter.project().status, "BEST_AVAILABLE");
});

test("no-new-facts projection extends gaps through hours and midnight without receipts, writes, or timestamp churn", () => {
  const session = setup();
  const api = connect(session);
  const row = execution("unchanged-hours.synthetic.01");
  const request = currentRequest(api);
  api.emit(EVENTS.execDetails, request[1], row.contract, row.execution);
  api.emit(EVENTS.commissionReport, commission(row.execution.execId, 0.25, 1));
  api.emit(EVENTS.execDetailsEnd, request[1]);
  session.timers.runDelay(3_000);
  const durable = session.store.state;
  const receiptCount = durable.receipts.length;
  const knownIntervals = structuredClone(durable.coverage.knownIntervals);

  session.setNow("2026-09-11T18:00:00Z");
  const hoursLater = session.adapter.project();
  assert.equal(hoursLater.status, "BEST_AVAILABLE");
  assert.equal(hoursLater.coverage.target.toExclusive, "2026-09-11T18:00:00.000Z");
  assert.deepEqual(hoursLater.coverage.knownIntervals, knownIntervals);
  assert.deepEqual(hoursLater.coverage.gaps.at(-1), {
    fromInclusive: durable.target.toExclusive,
    toExclusive: "2026-09-11T18:00:00.000Z",
    reason: "runtime target extension has no capture receipt",
  });
  assert.equal(session.store.saves, 1);

  session.timers.runDelay(30_000);
  const sameDay = currentRequest(api);
  api.emit(EVENTS.execDetails, sameDay[1], row.contract, row.execution);
  api.emit(EVENTS.commissionReport, commission(row.execution.execId, 0.25, 1));
  api.emit(EVENTS.execDetailsEnd, sameDay[1]);
  session.timers.runDelay(3_000);
  assert.equal(session.store.saves, 1);

  session.setNow("2026-09-12T05:00:00Z");
  session.timers.runDelay(30_000);
  const nextDay = currentRequest(api);
  assert.deepEqual(nextDay[2].specificDates, [20260912]);
  api.emit(EVENTS.execDetailsEnd, nextDay[1]);
  session.timers.runDelay(3_000);
  const afterMidnight = session.adapter.project();
  assert.equal(afterMidnight.coverage.target.toExclusive, "2026-09-12T05:00:00.000Z");
  assert.deepEqual(afterMidnight.coverage.knownIntervals, knownIntervals);
  assert.equal(session.store.state.receipts.length, receiptCount);
  assert.equal(session.store.saves, 1);
  assert.deepEqual(session.store.state, durable);
  assert.deepEqual(afterMidnight.capturedSubtotal.points, hoursLater.capturedSubtotal.points);
});

test("recurring actual execution and commission callbacks update the captured subtotal and pass its curve through", () => {
  const session = setup();
  const api = connect(session);
  const first = execution("pnl-first.synthetic.01");
  let request = currentRequest(api);
  api.emit(EVENTS.execDetails, request[1], first.contract, first.execution);
  api.emit(EVENTS.commissionReport, commission(first.execution.execId, 0.25, 1));
  api.emit(EVENTS.execDetailsEnd, request[1]);
  session.timers.runDelay(3_000);
  assert.equal(session.adapter.project().capturedSubtotal.realizedPnl, 1);

  session.setNow("2026-09-11T13:00:00Z");
  session.timers.runDelay(30_000);
  request = currentRequest(api);
  const second = execution("pnl-second.synthetic.01", { price: "11" });
  for (const row of [first, second]) api.emit(EVENTS.execDetails, request[1], row.contract, row.execution);
  api.emit(EVENTS.commissionReport, commission(first.execution.execId, 0.25, 1));
  api.emit(EVENTS.commissionReport, commission(second.execution.execId, 0.3, 2));
  api.emit(EVENTS.execDetailsEnd, request[1]);
  session.timers.runDelay(3_000);
  const projection = session.adapter.project();
  assert.equal(projection.capturedSubtotal.realizedPnl, 3);
  assert.equal(projection.capturedSubtotal.executionCount, 2);
  assert.deepEqual(projection.capturedSubtotal.points, [
    { at: "2026-09-10T12:00:00.000Z", realizedPnl: 1 },
    { at: "2026-09-11T12:00:00.000Z", realizedPnl: 2 },
  ]);
  assert.equal(session.store.saves, 2);
});

test("one capture at a time times out into one exponentially backed-off retry capped by configuration", () => {
  const session = setup({ retryBaseMs: 100, retryMaxMs: 300 });
  const api = connect(session);
  assert.equal(session.adapter.pollNow(), false);
  assert.equal(api.requests.filter((row) => row[0] === "executions").length, 1);

  session.timers.runDelay(20_000);
  assert.match(session.adapter.retryReason, /timed out/);
  assert.equal(session.timers.count(100), 1);
  session.timers.runDelay(100);
  assert.equal(api.requests.filter((row) => row[0] === "executions").length, 2);

  session.timers.runDelay(20_000);
  assert.equal(session.timers.count(200), 1);
  session.timers.runDelay(200);
  session.timers.runDelay(20_000);
  assert.equal(session.timers.count(300), 1);
  assert.equal(session.timers.count(100), 0);
});

test("reattach and upstream loss reject the old generation without opening or closing sockets", () => {
  const session = setup();
  const oldApi = connect(session);
  const oldRequest = currentRequest(oldApi);
  const nextApi = connect(session, new FakeApi());
  const nextRequest = currentRequest(nextApi);
  assert.equal(oldApi.listenerCount(EVENTS.execDetails), 0);
  oldApi.emit(EVENTS.execDetails, oldRequest[1], execution("stale.synthetic.01").contract, execution("stale.synthetic.01").execution);
  oldApi.emit(EVENTS.execDetailsEnd, oldRequest[1]);
  assert.equal(session.timers.count(3_000), 0);
  assert.equal(oldApi.connectCalls + oldApi.disconnectCalls + nextApi.connectCalls + nextApi.disconnectCalls, 0);

  assert.equal(session.adapter.upstreamUnavailable("synthetic upstream loss"), true);
  nextApi.emit(EVENTS.execDetailsEnd, nextRequest[1]);
  assert.equal(session.timers.count(3_000), 0);
  assert.equal(session.adapter.requestInFlight, false);

  const recoveredApi = connect(session, new FakeApi());
  assert.ok(currentRequest(recoveredApi));
  assert.equal(recoveredApi.connectCalls, 0);
});

test("cold-load and reconciliation conflicts preserve the prior sidecar and stop capture safely", () => {
  const corruptStore = memoryStore(null, "family history state is invalid");
  let bootstrapLoads = 0;
  const corrupt = setup({
    store: corruptStore,
    loadBootstrapCapture: () => {
      bootstrapLoads += 1;
      return { ok: true, capture: legacyCapture() };
    },
  });
  const api = connect(corrupt);
  assert.equal(currentRequest(api), undefined);
  assert.match(corrupt.adapter.blockedReason, /invalid/);
  assert.equal(corruptStore.saves, 0);
  assert.equal(bootstrapLoads, 0);

  const prior = durableState({
    executions: [normalizeExecutionRow(execution("retained.synthetic.01", { time: "20260910 10:00:00 US/Eastern" }))],
  });
  const store = memoryStore(prior);
  const conflict = setup({
    store,
    reconcileCapture: () => { throw new Error("conflicting execution retained.synthetic.01"); },
  });
  const conflictApi = connect(conflict);
  const request = currentRequest(conflictApi);
  const conflictingRow = execution("retained.synthetic.01", { price: "99" });
  conflictApi.emit(EVENTS.execDetails, request[1], conflictingRow.contract, conflictingRow.execution);
  conflictApi.emit(EVENTS.execDetailsEnd, request[1]);
  conflict.timers.runDelay(3_000);
  assert.match(conflict.adapter.blockedReason, /conflicting execution/);
  assert.deepEqual(store.state, prior);
  assert.equal(store.saves, 0);
  assert.equal(conflict.timers.count(30_000), 0);
});

test("official refresher is startup-singleflight, uses client 94, schedules 15m, and backs off without erasing state", async () => {
  const timers = fakeTimers();
  const calls = [];
  const imports = [];
  let fail = false;
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const refresher = createOfficialHistoryRefresher({
    readOfficialExecutionWindow: async (args) => {
      calls.push(args);
      if (calls.length === 1) await gate;
      if (fail) throw new Error("synthetic subprocess failure");
      return { synthetic: true };
    },
    makeCaptures: ({ requestedWindow }) => [{ window: requestedWindow }],
    importCaptures: (captures, target) => { imports.push({ captures, target }); return { ok: true }; },
    targetAccount: ACCOUNT,
    host: "paper.invalid",
    port: 4002,
    clientId: 94,
    historyStart: HISTORY_START,
    now: () => "2026-09-11T08:55:00Z",
    setTimer: timers.set,
    clearTimer: timers.clear,
    retryBaseMs: 100,
    retryMaxMs: 300,
  });
  refresher.start();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(refresher.requestInFlight, true);
  assert.equal(await refresher.pollNow(), false);
  assert.equal(calls.length, 1);
  release();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(calls[0].clientId, 94);
  assert.equal(calls[0].fromInclusive, "2026-09-10T04:00:00.000Z");
  assert.equal(calls[0].toExclusive, "2026-09-11T08:55:00.000Z");
  assert.equal(imports.length, 1);
  assert.equal(timers.count(15 * 60_000), 1);

  fail = true;
  timers.runDelay(15 * 60_000);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(imports.length, 1);
  assert.equal(timers.count(100), 1);
  refresher.stop();
});

test("official refresher starts at a recoverable durable gap and returns to two-day overlap when caught up", async () => {
  const calls = [];
  let history = {
    target: { fromInclusive: HISTORY_START, toExclusive: "2026-09-11T04:00:00.000Z" },
    coverage: {
      gaps: [{
        fromInclusive: "2026-09-11T04:00:00.254Z",
        toExclusive: "2026-09-14T12:00:00.000Z",
      }],
    },
  };
  const refresher = createOfficialHistoryRefresher({
    readOfficialExecutionWindow: async (args) => { calls.push(args); return {}; },
    makeCaptures: () => [{}],
    importCaptures: () => ({ ok: true }),
    targetAccount: ACCOUNT,
    host: "paper.invalid",
    port: 4002,
    historyStart: HISTORY_START,
    getHistoryState: () => history,
    now: () => "2026-09-14T12:00:00Z",
  });
  assert.equal(await refresher.pollNow(), true);
  assert.equal(calls[0].fromInclusive, "2026-09-11T04:00:00.000Z");
  history = {
    target: { fromInclusive: HISTORY_START, toExclusive: "2026-09-14T12:00:00.000Z" },
    coverage: { gaps: [] },
  };
  assert.equal(await refresher.pollNow(), true);
  assert.equal(calls[1].fromInclusive, "2026-09-13T04:00:00.000Z");
  refresher.stop();
});
