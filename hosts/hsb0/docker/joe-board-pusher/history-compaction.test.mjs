import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";
import test from "node:test";
import {
  combineIntervals,
  compactBestAvailableHistoryState,
  reconcileExecutionCapture,
  validateBestAvailableHistoryState,
} from "./execution-reconciliation.mjs";
import { createFamilyHistoryIngestor, createFileFamilyHistoryStore, projectBestAvailableHistory } from "./family-history.mjs";
import { createFamilyHistorySessionAdapter } from "./family-history-session.mjs";
import { officialReceiptChain } from "./family-state.mjs";
import { EventEmitter } from "node:events";

const ACCOUNT = "SYNTHETIC-PAPER";
const START = "2026-09-10T04:00:00.000Z";
const CLASSIFIER = { familyClientIds: [51, 56], excludedSymbols: ["SXR8", "TSLA"] };
const MiB = 1024 * 1024;
const hash = (value) => createHash("sha256").update(value).digest("hex");
const bytes = (value) => Buffer.byteLength(`${JSON.stringify(value, null, 2)}\n`);
const iso = (value) => new Date(value).toISOString();
const day = (value) => new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York" }).format(new Date(value));

function execution(execId, time, side = "BUY") {
  return { contract: { conId: 101, symbol: "ACME", secType: "STK", currency: "USD", multiplier: 1 },
    execution: { execId, acctNumber: ACCOUNT, clientId: 56, side, shares: 1, price: side === "BUY" ? 10 : 11, time } };
}
const fee = (row) => ({ execId: row.execution.execId, commission: 0.1, currency: "USD", realizedPNL: null });

function capture(id, fromInclusive, toExclusive, rows = [], complete = false, capturedAt = toExclusive) {
  return { schema: "inspr.ib.execution-capture.v1", account: ACCOUNT, classifier: CLASSIFIER,
    source: { kind: "paper-api", id, sha256: hash(id), metadata: complete ? {
      adapterId: "official-window-json", adapterVersion: "1", sdkPackage: "ibapi", sdkVersion: "10.45.1",
      serverVersion: 223, executionRequestFraming: "protobuf", parameterizedExecutionFilters: true,
      responseEndedCleanly: true, completenessClaimed: true, endpointIdentitySha256: hash("synthetic-endpoint"),
    } : { brokerClientId: 92, requestId: id, retainedDay: day(toExclusive) } },
    capturedAt, window: { fromInclusive, toExclusive }, coverageStatus: complete ? "complete" : "known",
    completenessAssertion: complete ? { provider: "ibkr-official-sdk-execution-window-v1", assertionId: id } : null,
    executions: rows, commissions: rows.map(fee) };
}

function history(captures, target = { fromInclusive: START, toExclusive: captures.at(-1).window.toExclusive }) {
  let state = null;
  for (const item of captures) state = reconcileExecutionCapture({ prior: state, capture: item, target });
  return state;
}

const quiet = { onCompacted() {}, onSizeWarning() {} };

// The executor's readPusherExecutions schema/account/coverage/clock checks,
// copied from modules/paper-desk-executor/ib.mjs:404-430. No broker imports.
function executorVisible(state, now, allowIntradayGaps = false) {
  const { schema, version, account, executions, commissions, coverage } = state;
  let rejection = null;
  try {
    if (schema !== "inspr.joe.best-available-history.v1" || version !== 1 || account !== ACCOUNT || !Array.isArray(executions)) throw Error("schema");
    if (!Array.isArray(coverage?.gaps) || !(coverage.status === "complete" || allowIntradayGaps && coverage.status === "known" && coverage.gaps.length)) throw Error("coverage");
    const start = Date.parse(coverage.target?.fromInclusive);
    const end = Date.parse(coverage.target?.toExclusive);
    if (!Number.isFinite(start) || !Number.isFinite(end) || start >= end || end > now || start > now || day(end) !== day(now)) throw Error("clock");
    for (const gap of coverage.gaps) {
      const from = Date.parse(gap?.fromInclusive);
      const to = Date.parse(gap?.toExclusive);
      if (!Number.isFinite(from) || !Number.isFinite(to) || from >= to || from < start || to > end) throw Error("gap");
      if (day(from) !== day(now) || day(to - 1) !== day(now)) throw Error("gap date");
    }
    if (coverage.gaps.length && !allowIntradayGaps) throw Error("fresh snapshot required");
  } catch (error) { rejection = error.message; }
  return { schema, version, account, executions, commissions,
    coverage: { status: coverage.status, target: coverage.target, gaps: coverage.gaps }, rejection };
}

test("compaction preserves gaps, records, executor checks and native subtotal; it is idempotent", () => {
  const row = execution("compaction.open.01", "2026-09-10T05:00:00.000Z");
  const close = execution("compaction.close.01", "2026-09-10T06:00:00.000Z", "SELL");
  const raw = history([
    capture("complete", START, "2026-09-11T04:00:00.000Z", [row, close], true),
    ...[1, 2, 3, 4].map((n) => capture(`known-${n}`, "2026-09-11T04:00:00.000Z", `2026-09-11T0${n + 4}:00:00.000Z`)),
  ]);
  const compacted = compactBestAvailableHistoryState(raw);
  assert.equal(compacted.receipts.length, 3);
  assert.strictEqual(compactBestAvailableHistoryState(compacted), compacted);
  assert.deepEqual(executorVisible(compacted, Date.parse(raw.updatedAt), true), executorVisible(raw, Date.parse(raw.updatedAt), true));
  assert.equal(executorVisible(compacted, Date.parse(raw.updatedAt), true).rejection, null);
  assert.deepEqual(projectBestAvailableHistory({ state: compacted }).capturedSubtotal, projectBestAvailableHistory({ state: raw }).capturedSubtotal);
  assert.deepEqual(compacted.receipts.filter((r) => r.coverageStatus === "complete"), raw.receipts.filter((r) => r.coverageStatus === "complete"));
  assert.ok(compacted.coverage.knownIntervals.every((r) => r.receiptIds.length <= 2));
  const tampered = structuredClone(compacted);
  tampered.coverage.knownIntervals[0].receiptIdsSha256 = "0".repeat(64);
  assert.throws(() => validateBestAvailableHistoryState(tampered), /coverage/);
});

test("separate known windows and completeness gaps never get bridged", () => {
  const raw = history([
    capture("a", START, "2026-09-10T05:00:00.000Z"),
    capture("b", START, "2026-09-10T06:00:00.000Z"),
    capture("c", START, "2026-09-10T07:00:00.000Z"),
    capture("d", "2026-09-10T08:00:00.000Z", "2026-09-10T09:00:00.000Z", [], true),
  ]);
  const compacted = compactBestAvailableHistoryState(raw);
  for (const key of ["knownIntervals", "completeIntervals"]) {
    assert.deepEqual(compacted.coverage[key].map(({ fromInclusive, toExclusive }) => ({ fromInclusive, toExclusive })),
      raw.coverage[key].map(({ fromInclusive, toExclusive }) => ({ fromInclusive, toExclusive })));
  }
  assert.deepEqual(compacted.coverage.gaps, raw.coverage.gaps);
});

test("complete compaction preserves dated membership, observation cutoffs and anti-truncation", () => {
  const end = "2026-09-10T12:00:00.000Z";
  const row = execution("official.synthetic.01", "2026-09-10T05:30:00.000Z");
  const raw = history([
    capture("proof-a", START, "2026-09-10T06:00:00.000Z", [row], true, end),
    capture("proof-b", "2026-09-10T06:00:00.000Z", "2026-09-10T07:00:00.000Z", [], true, end),
    capture("proof-c", "2026-09-10T07:00:00.000Z", "2026-09-10T08:00:00.000Z", [], true, end),
    capture("proof-d", "2026-09-10T08:00:00.000Z", "2026-09-10T09:00:00.000Z", [], true, end),
    // This empty wide reply is contradicted by the retained execution.
    capture("truncated", START, end, [], true, "2026-09-10T12:00:01.000Z"),
  ]);
  const compacted = compactBestAvailableHistoryState(raw);
  assert.ok(compacted.receipts.length < raw.receipts.length);
  for (const observed of ["2026-09-10T11:59:59.000Z", end, "2026-09-10T12:00:01.000Z"]) {
    const before = officialReceiptChain(raw, START, observed);
    const after = officialReceiptChain(compacted, START, observed);
    assert.equal(after.through, before.through);
    assert.deepEqual(after.executions, before.executions);
    assert.deepEqual(after.commissions, before.commissions);
  }
  assert.equal(officialReceiptChain(compacted, START, "2026-09-10T12:00:01.000Z").through, "2026-09-10T09:00:00.000Z");
});

test("legacy digest-only known receipts compact without inventing identity membership", () => {
  const raw = structuredClone(history([1, 2, 3, 4].map((n) => capture(`legacy-${n}`, START, `2026-09-10T0${n + 4}:00:00.000Z`))));
  for (const receipt of raw.receipts) { delete receipt.executionIds; delete receipt.commissionIds; }
  const compacted = compactBestAvailableHistoryState(raw);
  assert.equal(compacted.receipts.length, 2);
  assert.equal(compacted.receipts[0].executionIds, undefined);
  assert.strictEqual(compactBestAvailableHistoryState(compacted), compacted);
});

test("a newest receipt bridging two older runs keeps compaction idempotent on timestamp ties", () => {
  const at = "2026-09-10T12:00:00.000Z";
  for (let n = 0; n < 20; n += 1) {
    const raw = history([
      capture(`left-a-${n}`, START, "2026-09-10T06:00:00.000Z", [], false, at),
      capture(`left-b-${n}`, START, "2026-09-10T06:00:00.000Z", [], false, at),
      capture(`right-a-${n}`, "2026-09-10T08:00:00.000Z", "2026-09-10T10:00:00.000Z", [], false, at),
      capture(`right-b-${n}`, "2026-09-10T08:00:00.000Z", "2026-09-10T10:00:00.000Z", [], false, at),
      capture(`bridge-${n}`, START, "2026-09-10T10:00:00.000Z", [], false, at),
    ]);
    const compacted = compactBestAvailableHistoryState(raw);
    assert.strictEqual(compactBestAvailableHistoryState(compacted), compacted);
    assert.deepEqual(compacted.coverage.gaps, raw.coverage.gaps);
    assert.equal(compacted.coverage.knownIntervals.length, 1);
  }
});

test("separate invalid complete memberships cannot combine into an authoritative proof", () => {
  const end = "2026-09-10T12:00:00.000Z";
  const a = execution("mismatched.a.01", "2026-09-10T05:00:00.000Z");
  const b = execution("mismatched.b.01", "2026-09-10T07:00:00.000Z");
  const c = execution("mismatched.c.01", "2026-09-10T09:00:00.000Z");
  const first = capture("wrong-fee-a", START, "2026-09-10T06:00:00.000Z", [a], true, end);
  first.commissions = [fee(b)];
  const second = capture("wrong-fee-b", "2026-09-10T06:00:00.000Z", "2026-09-10T08:00:00.000Z", [b], true, end);
  second.commissions = [fee(a)];
  const raw = history([first, second, capture("paired-c", "2026-09-10T08:00:00.000Z", "2026-09-10T10:00:00.000Z", [c], true, end)]);
  const compacted = compactBestAvailableHistoryState(raw);
  assert.deepEqual(compacted.receipts, raw.receipts);
  assert.equal(officialReceiptChain(compacted, START, end).through, START);
});

test("repeated saves stay bounded in RAM and on disk and retain the latest exact replay guard", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "history-steady-compaction-"));
  const file = path.join(directory, "history.json");
  const store = createFileFamilyHistoryStore(file, fs, quiet);
  let state = null;
  let baselineBytes;
  let item;
  for (let n = 1; n <= 200; n += 1) {
    item = capture(`steady-${n}`, START, iso(Date.parse(START) + n * 34_000));
    state = store.save(reconcileExecutionCapture({ prior: state, capture: item, target: item.window }));
    assert.ok(state.receipts.length <= 2);
    if (n === 3) baselineBytes = fs.statSync(file).size;
  }
  assert.ok(fs.statSync(file).size < baselineBytes + 100);
  assert.strictEqual(reconcileExecutionCapture({ prior: state, capture: item, target: state.target }), state);
  assert.throws(() => reconcileExecutionCapture({ prior: state,
    capture: { ...item, source: { ...item.source, sha256: hash("conflict") } }, target: state.target }), /different facts/);
  assert.deepEqual(store.load().state, state);
});

test("50 days at one real-writer receipt per 34 seconds stay under 4 MiB; oversized disk history self-heals", async (t) => {
  const START = "2026-09-07T04:00:00.000Z";
  const start = Date.parse(START);
  const end = start + 50 * 86_400_000;
  const target = { fromInclusive: START, toExclusive: iso(end) };
  const receipts = [];
  const rows = [];
  let seed;
  for (let at = start + 34_000; at <= end; at += 34_000) {
    const dateIndex = Math.floor((at - start - 1) / 86_400_000);
    const from = start + dateIndex * 86_400_000;
    const dailyRows = [execution(`day-${String(dateIndex).padStart(2, "0")}.buy.01`, iso(from + 1_000)),
      execution(`day-${String(dateIndex).padStart(2, "0")}.sell.01`, iso(from + 2_000), "SELL")];
    if (rows.length === dateIndex * 2) rows.push(...dailyRows);
    // Avoid quadratic reconciliation of a deliberately un-compacted legacy file:
    // each original receipt is produced by the actual capture/receipt writer.
    const single = reconcileExecutionCapture({ capture: capture(`capture-${receipts.length}`, iso(from), iso(at), dailyRows.filter((r) => Date.parse(r.execution.time) < at)), target });
    seed ||= single;
    receipts.push(single.receipts[0]);
  }
  const intervals = combineIntervals(receipts.map((r) => ({ ...r.window, receiptIds: [r.receiptId] })));
  const raw = { ...seed, updatedAt: receipts.at(-1).capturedAt,
    executions: rows.sort((a, b) => a.execution.execId.localeCompare(b.execution.execId)),
    commissions: rows.map(fee).sort((a, b) => a.execId.localeCompare(b.execId)), receipts,
    coverage: { ...seed.coverage, knownIntervals: intervals } };
  assert.ok(receipts.length >= 60_000);
  validateBestAvailableHistoryState(raw);
  const beforeBytes = bytes(raw);
  const compacted = compactBestAvailableHistoryState(raw);
  const afterBytes = bytes(compacted);
  assert.ok(afterBytes < 4 * MiB);
  assert.deepEqual(executorVisible(compacted, end, true), executorVisible(raw, end, true));
  assert.strictEqual(compactBestAvailableHistoryState(compacted), compacted);
  t.diagnostic(JSON.stringify({ captures: receipts.length, days: 50, cadenceSeconds: 34, beforeBytes, afterBytes,
    receiptBytes: bytes(receipts), coverageBytes: bytes(raw.coverage), executionBytes: bytes(raw.executions), commissionBytes: bytes(raw.commissions) }));

  // A real serialized legacy file just above the 32 MiB write cap, below the
  // independent 64 MiB recovery-read ceiling. No large padding or fake receipts.
  const liveReceipts = receipts.slice(0, 26_000);
  const liveRows = raw.executions.filter((r) => r.execution.time < liveReceipts.at(-1).window.toExclusive);
  const live = { ...raw, target: { fromInclusive: START, toExclusive: liveReceipts.at(-1).window.toExclusive },
    updatedAt: liveReceipts.at(-1).capturedAt, receipts: liveReceipts, executions: liveRows, commissions: liveRows.map(fee),
    coverage: { status: "known", target: { fromInclusive: START, toExclusive: liveReceipts.at(-1).window.toExclusive },
      knownIntervals: combineIntervals(liveReceipts.map((r) => ({ ...r.window, receiptIds: [r.receiptId] }))), completeIntervals: [],
      gaps: [{ fromInclusive: START, toExclusive: liveReceipts.at(-1).window.toExclusive, reason: "no authoritative completeness receipt" }] } };
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "history-compaction-"));
  const file = path.join(directory, "family-history.json");
  fs.writeFileSync(file, `${JSON.stringify(live, null, 2)}\n`, { mode: 0o600 });
  const diskBeforeBytes = fs.statSync(file).size;
  assert.ok(diskBeforeBytes > 32 * MiB && diskBeforeBytes <= 64 * MiB, `${diskBeforeBytes} bytes`);
  const events = [];
  const store = createFileFamilyHistoryStore(file, fs, { onCompacted: (sizes) => events.push(sizes), onSizeWarning: () => assert.fail("compacted state should be small") });
  const loaded = store.load();
  assert.equal(loaded.ok, true);
  assert.equal(loaded.compacted, true);
  assert.deepEqual(executorVisible(loaded.state, end, true), executorVisible(live, end, true));
  assert.equal(fs.statSync(file).size, diskBeforeBytes, "load must not rewrite the inode");
  const ingestor = createFamilyHistoryIngestor({ store, setTimer: () => 1, clearTimer() {},
    fetchCapture: async () => ({ capture: capture("first-update", iso(end - 86_400_000), iso(end)), target }) });
  assert.equal(await ingestor.pollNow(), true);
  ingestor.stop();
  assert.equal(day(ingestor.inspectState().coverage.target.toExclusive), day(end));
  assert.ok(fs.statSync(file).size < 4 * MiB);
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  assert.deepEqual(fs.readdirSync(directory), ["family-history.json"]);
  assert.ok(events.every((event) => Object.keys(event).sort().join() === "afterBytes,beforeBytes"));
  t.diagnostic(JSON.stringify({ diskBeforeBytes, diskAfterBytes: fs.statSync(file).size, updatedTarget: ingestor.inspectState().target.toExclusive }));
});

test("runtime persists a compacted load on its first no-new-facts capture, then keeps RAM bounded", () => {
  const initial = history([1, 2, 3, 4].map((n) => capture(`boot-${n}`, START, `2026-09-10T0${n + 4}:00:00.000Z`)));
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "history-runtime-compaction-"));
  const file = path.join(directory, "history.json");
  const realStore = createFileFamilyHistoryStore(file, fs, quiet);
  const state = realStore.save(initial);
  const store = { load: () => ({ ok: true, state, compacted: true }), save: realStore.save };
  const timers = new Map();
  let id = 0;
  let now = "2026-09-11T12:00:00.000Z";
  const adapter = createFamilyHistorySessionAdapter({ targetAccount: ACCOUNT, brokerClientId: 92,
    familyClientIds: CLASSIFIER.familyClientIds, excludedSymbols: CLASSIFIER.excludedSymbols, historyStart: START,
    captureSchema: "inspr.ib.execution-capture.v1", normalizeExecutionRow: (r) => r, normalizeCommissionReport: (r) => r,
    reconcileCapture: reconcileExecutionCapture, projectHistory: projectBestAvailableHistory,
    eventNames: { connected: "connected", disconnected: "disconnected", managedAccounts: "managedAccounts",
      execDetails: "execDetails", execDetailsEnd: "execDetailsEnd", commissionReport: "commissionReport" },
    store, now: () => now, requestManagedAccounts: false,
    setTimer: (callback, delay) => { timers.set(++id, { callback, delay }); return id; }, clearTimer: (key) => timers.delete(key) });
  const api = new EventEmitter();
  let request;
  api.reqExecutions = (requestId) => { request = requestId; };
  adapter.attach(api);
  api.emit("connected");
  api.emit("managedAccounts", ACCOUNT);
  api.emit("execDetailsEnd", request);
  const drain = [...timers.values()].find((item) => item.delay === 3_000);
  assert.ok(drain);
  drain.callback();
  assert.equal(adapter.blockedReason, null);
  assert.equal(adapter.inspectState().target.toExclusive, now);
  assert.equal(realStore.load().state.target.toExclusive, now);
  assert.ok(adapter.inspectState().receipts.length <= 4);
  adapter.retire();
});

test("atomic replacement failure preserves the prior history and cleans only its temporary file", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "history-atomic-compaction-"));
  const file = path.join(directory, "history.json");
  const prior = history([capture("original", START, "2026-09-10T06:00:00.000Z")]);
  createFileFamilyHistoryStore(file, fs, quiet).save(prior);
  const before = fs.readFileSync(file, "utf8");
  const faulty = Object.create(fs);
  faulty.renameSync = () => { throw Error("injected rename failure"); };
  assert.throws(() => createFileFamilyHistoryStore(file, faulty, quiet).save(history([1, 2, 3, 4].map((n) => capture(`atomic-${n}`, START, `2026-09-10T0${n + 4}:00:00.000Z`)))), /rename failure/);
  assert.equal(fs.readFileSync(file, "utf8"), before);
  assert.deepEqual(fs.readdirSync(directory), ["history.json"]);
});

test("irreducible history warns above 75%, rejects above 32 MiB, and bounds recovery reads", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "history-limits-compaction-"));
  const file = path.join(directory, "history.json");
  const warnings = [];
  const store = createFileFamilyHistoryStore(file, fs, { onCompacted() {}, onSizeWarning: (sizes) => warnings.push(sizes) });
  const makeLarge = (size) => {
    const row = execution("large.synthetic.01", "2026-09-10T05:00:00.000Z");
    row.contract.syntheticDescription = "x".repeat(size);
    return history([capture(`large-${size}`, START, "2026-09-10T06:00:00.000Z", [row])]);
  };
  store.save(makeLarge(25 * MiB));
  assert.equal(warnings.length, 1);
  assert.ok(warnings[0].afterBytes > 24 * MiB);
  const size = fs.statSync(file).size;
  assert.throws(() => store.save(makeLarge(33 * MiB)), /exceeds size limit/);
  assert.equal(fs.statSync(file).size, size);
  assert.equal(warnings.length, 2);
  assert.ok(warnings.every((event) => Object.keys(event).sort().join() === "afterBytes,beforeBytes"));
  const fake = Object.create(fs);
  fake.fstatSync = () => ({ isFile: () => true, size: 64 * MiB + 1 });
  fake.readSync = () => assert.fail("oversized recovery input must not be read");
  assert.equal(createFileFamilyHistoryStore(file, fake, quiet).load().ok, false);
  const link = path.join(directory, "history-link.json");
  fs.symlinkSync(file, link);
  assert.equal(createFileFamilyHistoryStore(link, fs, quiet).load().ok, false);
});
