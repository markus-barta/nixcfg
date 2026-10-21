import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { EventEmitter } from "node:events";
import test from "node:test";
import { copyObservation } from "./v2-stage-handoff.mjs";
import { buildCandidate, StageStore, prepareLock, validObservation } from "./v2-stage-worker.mjs";
import { createDeskStateReporter, deskStateDetails, newYorkDay, ACTIVITY_FRESH_MS, ACTIVITY_FUTURE_SKEW_MS } from "./desk-activity.mjs";
import { startCycle } from "./v1-cycle.mjs";
import { createBrokerSessionAdapter } from "./pusher-state.mjs";
import { validateContract } from "./contracts/index.mjs";
import { acceptSnapshot } from "./contracts/accept.mjs";

const epoch = Date.parse("2026-10-20T14:00:00.000Z");
const at = seconds => new Date(epoch + seconds * 1000).toISOString();
const freshSeconds = ACTIVITY_FRESH_MS / 1000;
const skewSeconds = ACTIVITY_FUTURE_SKEW_MS / 1000;
const read = name => JSON.parse(fs.readFileSync(name));
function source(bookSeconds = 0, readerSeconds = bookSeconds) {
  return {
    book: { ts: at(bookSeconds), gateway: true, apiReplyCheckedAt: at(readerSeconds),
      summary: { NetLiquidation: { value: "12345.67000000", currency: "EUR" },
        TotalCashValue: { value: "-0.0000", currency: "EUR" } },
      positions: [{ symbol: "SYNTH", pos: 1, currency: "EUR" }],
      positionsCoverage: { status: "complete" }, openOrders: [], ordersObservedAt: at(readerSeconds) },
    deskEquities: { ok: true, oldestSourceObservedAt: at(bookSeconds),
      desks: { j: { positions: [{ symbol: "SYNTH", side: "Long", currency: "EUR" }] },
        joe: { positions: [] }, joel: { positions: [] } } },
    executions: { observedAt: at(readerSeconds), day: newYorkDay(Date.parse(at(readerSeconds))),
      latest: { j: null, joe: at(0), joel: null } },
  };
}
async function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "ops404-generation-"));
  fs.chmodSync(root, 0o700);
  t.after(() => spawnSync("trash", [root]));
  const options = { root, uid: process.getuid(), gid: process.getgid() };
  prepareLock(root, options.uid, options.gid);
  const store = new StageStore(options); store.enroll(); await store.open();
  return { store, options, root };
}
function current(root) {
  const { pair } = read(path.join(root, "current.json"));
  return { value: read(path.join(root, pair, "snapshot.json")), receipt: read(path.join(root, pair, "receipt.json")) };
}

test("ten minutes of 3-minute books and 30-second readers advances every generation without desk flaps", async t => {
  const { store, root, options } = await fixture(t);
  const events = [], report = createDeskStateReporter({ onEvent: value => events.push(value) });
  let previous, previousGeneration;
  for (let seconds = 0; seconds <= 600; seconds += 30) {
    const bookSeconds = Math.floor(seconds / 180) * 180;
    const observation = source(bookSeconds, seconds);
    const body = JSON.stringify({ schema: "inspr.joe.household.v1", generatedAt: at(bookSeconds) });
    observation.v1Cycle = startCycle(body)(200, at(seconds));
    const copied = copyObservation(observation);
    const reservation = store.reserve(copied, at(seconds));
    assert.equal(store.stage(copied, () => at(seconds + 0.02), reservation, true).status, 200);
    const { value, receipt } = current(root);
    assert.equal(value.generatedAt, at(seconds));
    if (previousGeneration) assert.ok(value.generatedAt > previousGeneration);
    previousGeneration = value.generatedAt;
    assert.equal(value.brokerAccount.observedAt, at(bookSeconds));
    assert.equal(value.positions.observedAt, at(bookSeconds));
    assert.deepEqual(value.brokerAccount.equity, { amount: "12345.67000000", currency: "EUR" });
    assert.deepEqual(value.brokerAccount.cash, { amount: "-0.0000", currency: "EUR" });
    assert.equal(value.safety.gateway.apiSessionReady, true);
    assert.deepEqual(value.desks.map(desk => desk.state), ["working", "working", "sit-out"]);
    assert.equal(receipt.v1Sha256, observation.v1Cycle.v1Sha256);
    assert.equal(receipt.generatedAdvancedAt, receipt.stagedReceivedAt);
    if (seconds % 180 !== 0) assert.notEqual(value.generatedAt, JSON.parse(body).generatedAt);
    assert.equal(validateContract("data", value, { stage: "ingress" }).ok, true);
    previous = acceptSnapshot("data", value, previous, receipt.stagedReceivedAt);
    assert.equal(previous.status, 200);
    assert.equal(validateContract("data", previous.value).ok, true);
    report(observation, at(seconds));
  }
  assert.deepEqual(events.map(({ desk, state, cause }) => ({ desk, state, cause })), [
    { desk: "j", state: "working", cause: null },
    { desk: "joe", state: "working", cause: null },
    { desk: "joel", state: "sit-out", cause: null },
  ]);
  const restarted = await new StageStore(options).open();
  assert.equal(restarted.state.lastGeneratedAt, at(600));
});

test(`all reader clocks accept gen-${freshSeconds} through gen+${skewSeconds}, including after the book, and reject gen+${skewSeconds + 1} and age ${freshSeconds + 1}s`, () => {
  const observation = copyObservation(source(0, 150));
  for (const reader of ["positions", "orders", "executions"]) {
    const field = `${reader}At`, base = observation.deskActivity.j;
    for (const seconds of [150 - freshSeconds, 150, 150 + skewSeconds]) {
      assert.deepEqual(deskStateDetails({ ...base, [field]: at(seconds) }, at(150), at(150)),
        { state: "working", cause: null });
    }
    for (const seconds of [150 - freshSeconds - 1, 150 + skewSeconds + 1]) {
      assert.deepEqual(deskStateDetails({ ...base, [field]: at(seconds) }, at(150), at(150)),
        { state: "stuck", cause: `${reader}_stale` });
    }
    for (const unavailable of [null, "not-a-time"]) {
      assert.deepEqual(deskStateDetails({ ...base, [field]: unavailable }, at(150), at(150)),
        { state: "stuck", cause: `${reader}_unavailable` });
    }
  }
});

for (const age of [180, freshSeconds, freshSeconds + 1]) test(`account and positions source age ${age}s is independent of fresh readiness`, () => {
  const copied = copyObservation(source(0, age));
  const value = buildCandidate(1, at(age), copied);
  assert.equal(value.safety.gateway.apiSessionReady, true);
  assert.equal(value.brokerAccount.observedAt, at(0));
  assert.equal(value.positions.observedAt, at(0));
  if (age <= freshSeconds) {
    assert.equal(value.brokerAccount.equity.amount, "12345.67000000");
    assert.equal(value.brokerAccount.cash.amount, "-0.0000");
    assert.equal(value.positions.rows[0].reasons.quantity, "not_exact_yet");
  } else {
    assert.equal(value.brokerAccount.equity, null);
    assert.equal(value.brokerAccount.reason, "source_unavailable");
    assert.equal(value.brokerAccount.cash, null);
    assert.equal(value.brokerAccount.reasons.cash, "source_unavailable");
    assert.equal(value.positions.reason, "source_unavailable");
    assert.ok(value.desks.every(desk => desk.state === "stuck"));
    for (const row of value.positions.rows) {
      assert.equal(row.desk, null);
      for (const field of ["quantity", "mark", "marketValue", "dayPnl", "openPnl"]) {
        assert.equal(row[field], null); assert.equal(row.reasons[field], "source_unavailable");
      }
    }
    const staleNumber = structuredClone(value);
    staleNumber.brokerAccount.equity = { amount: "12345.67000000", currency: "EUR" };
    assert.equal(new StageStore().validProjection(staleNumber), false);
  }
  assert.equal(new StageStore().validProjection(value), true);
  assert.equal(acceptSnapshot("data", value, null, at(age)).status, 200);
});

test(`a ${freshSeconds + 1}-second-old gateway reply is unconfirmed with snapshot_stale and withholds money`, () => {
  const value = buildCandidate(1, at(freshSeconds + 1), copyObservation(source(0, 0)));
  // Rev 9 requires a boolean readiness flag; false plus a reason represents unavailable.
  assert.deepEqual(value.safety.gateway, { apiSessionReady: false, checkedAt: at(0), reason: "snapshot_stale" });
  assert.equal(value.brokerAccount.equity, null);
  assert.equal(value.brokerAccount.cash, null);
  assert.equal(validateContract("data", value, { stage: "ingress" }).ok, true);
});

test("unrelated book and readiness callbacks cannot renew NAV, cash or position coverage", () => {
  let seconds = 0;
  const events = Object.fromEntries(["connected", "disconnected", "error", "info", "managedAccounts", "accountSummary",
    "accountSummaryEnd", "position", "positionEnd", "updatePortfolio", "accountDownloadEnd", "openOrder"].map(name => [name, name]));
  const adapter = createBrokerSessionAdapter({ targetAccount: "DUFIXTURE", eventNames: events, now: () => at(seconds) });
  const api = Object.assign(new EventEmitter(), Object.fromEntries(["reqManagedAccts", "reqPositions", "cancelPositions", "reqAllOpenOrders",
    "reqAccountSummary", "reqAccountUpdates"].map(name => [name, () => {}])));
  adapter.attach(api); api.emit("connected"); api.emit("managedAccounts", "DUFIXTURE");
  api.emit("accountSummary", 9501, "DUFIXTURE", "NetLiquidation", "12345.67000000", "EUR");
  api.emit("accountSummary", 9501, "DUFIXTURE", "TotalCashValue", "-0.0000", "EUR");
  api.emit("accountSummaryEnd", 9501); api.emit("positionEnd"); api.emit("accountDownloadEnd", "DUFIXTURE");
  seconds = freshSeconds + 1;
  api.emit("accountSummary", 9501, "DUFIXTURE", "BuyingPower", "1", "EUR");
  api.emit("accountSummaryEnd", 9501);
  const observation = copyObservation({ ...source(seconds, seconds), book: adapter.snapshot() });
  assert.equal(observation.bookTs, at(seconds));
  assert.deepEqual(observation.sourceObservedAt, { equity: at(0), cash: at(0), positions: at(0) });
  let value = buildCandidate(1, at(seconds), observation);
  assert.equal(value.safety.gateway.apiSessionReady, true);
  assert.equal(value.brokerAccount.equity, null);
  assert.equal(value.brokerAccount.cash, null);
  assert.equal(value.positions.reason, "source_unavailable");
  assert.ok(value.desks.every(desk => desk.state === "stuck"));
  // A fresh NAV callback and complete positions reply prove only those sources.
  api.emit("accountSummary", 9501, "DUFIXTURE", "NetLiquidation", "12345.67000000", "EUR");
  assert.equal(adapter.refreshPositions(), true);
  api.emit("positionEnd");
  value = buildCandidate(2, at(seconds), copyObservation({ book: adapter.snapshot() }));
  assert.equal(value.brokerAccount.equity.amount, "12345.67000000");
  assert.equal(value.brokerAccount.cash, null);
  assert.equal(value.brokerAccount.reasons.cash, "source_unavailable");
  assert.equal(value.brokerAccount.observedAt, at(seconds));
  assert.equal(value.positions.observedAt, at(seconds));
  assert.equal(new StageStore().validProjection(value), true);
  assert.equal(acceptSnapshot("data", value, null, at(seconds)).status, 200);
});

test("private source clocks are closed, calendar validated and optional for old frames", () => {
  const value = copyObservation(source());
  assert.equal(validObservation(value), true);
  for (const clock of ["private-value", "2026-02-30T14:00:00.000Z", 1]) {
    assert.equal(validObservation({ ...value, sourceObservedAt: { ...value.sourceObservedAt, cash: clock } }), false);
  }
  assert.equal(validObservation({ ...value, sourceObservedAt: { ...value.sourceObservedAt, extra: at(0) } }), false);
  delete value.sourceObservedAt;
  assert.equal(validObservation(value), true);
});

test("existing sequence-state format keeps generation non-regressing across restart and clock rollback", async t => {
  const { store, root, options } = await fixture(t);
  assert.equal(store.stage(copyObservation(source()), () => at(0)).status, 200);
  const originalState = read(path.join(root, "sequence-state.json"));
  const restarted = await new StageStore(options).open();
  // No schema migration or extra field is required to read an r15 high water.
  assert.deepEqual(restarted.state, originalState);
  const reservation = restarted.reserve(copyObservation(source()), at(-5));
  assert.equal(reservation.status, 200);
  assert.equal(restarted.state.lastGeneratedAt, at(0));
  assert.equal(restarted.stage(copyObservation(source()), () => at(0), reservation).status, 200);
  assert.equal(current(root).value.generatedAt, at(0));
  const again = await new StageStore(options).open();
  assert.equal(again.reserve(copyObservation(source()), at(-5.001)).reason, "clock_ahead");
  assert.equal(again.state.lastReservedSeq, 2);
  assert.equal(again.stage(copyObservation(source()), () => at(30)).status, 200);
  assert.equal(current(root).value.generatedAt, at(30));
  assert.equal(current(root).receipt.generatedAdvancedAt, at(30));
});

test("restart after an unpublished reservation preserves its generation floor", async t => {
  const { store, root, options } = await fixture(t);
  assert.equal(store.reserve(copyObservation(source()), at(30)).status, 200);
  const restarted = await new StageStore(options).open();
  assert.equal(restarted.state.lastGeneratedAt, at(30));
  assert.equal(restarted.stage(copyObservation(source()), () => at(26)).status, 200);
  assert.equal(current(root).value.seq, 2);
  assert.equal(current(root).value.generatedAt, at(30));
  assert.equal(acceptSnapshot("data", current(root).value, null, at(26)).status, 200);
});
