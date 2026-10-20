import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { newYorkDay, deskState, copyDeskActivity, executionActivity, DESK_ACTION } from "./desk-activity.mjs";
import { copyObservation } from "./v2-stage-handoff.mjs";
import { buildCandidate, validObservation } from "./v2-stage-worker.mjs";
import { createBrokerSessionAdapter } from "./pusher-state.mjs";
import { EventEmitter } from "node:events";
import { validateContract } from "./contracts/index.mjs";

const instant = "2026-10-19T15:00:00.000Z";
const evidence = (at = instant) => ({ positionsAt: at, hasPositions: false, ordersAt: at, hasOrders: false,
  executionsAt: at, executionDay: newYorkDay(Date.parse(at)), lastExecutionAt: null });
const activity = (at = instant) => Object.fromEntries(["j", "joe", "joel"].map(id => [id, evidence(at)]));

for (const [label, change, expected] of [
  ["empty", {}, "sit-out"], ["positions-only", { hasPositions: true }, "working"],
  ["orders-only", { hasOrders: true }, "working"], ["executions-only", { lastExecutionAt: instant }, "working"],
  ["unavailable", { ordersAt: null, hasPositions: true }, "stuck"],
  ["stale", { ordersAt: "2026-10-19T14:54:59.999Z", hasOrders: true }, "stuck"],
  ["future", { executionsAt: "2026-10-19T15:00:00.001Z" }, "stuck"],
  ["future-fill", { lastExecutionAt: "2026-10-19T15:00:00.001Z" }, "stuck"],
]) test(`desk state ${label} maps to rev 9 desks[].state and leaves KEEP untouched`, () => {
  const deskActivity = activity(); Object.assign(deskActivity.j, change);
  const source = { bookTs: instant, deskActivity, positions: [{ symbol: "TSLA", side: "short", desk: null, scope: "keep" }] };
  const value = buildCandidate(1, instant, source);
  assert.equal(value.desks[0].state, expected);
  assert.equal(value.desks[0].action, DESK_ACTION);
  for (const desk of value.desks) for (const field of ["equity", "dayPnl", "openPnl", "totalPnl"]) {
    assert.equal(desk.money[field], null); assert.equal(desk.money.reasons[field], "not_exact_yet");
  }
  assert.equal(value.positions.rows.find(row => row.symbol === "TSLA").desk, null);
  for (const row of value.positions.rows) assert.equal(Object.hasOwn(row.reasons, "desk"), false);
  assert.equal(validateContract("data", value, { stage: "ingress" }).ok, true);
});

test("each reader's freshness is checked independently at the five-minute bound and staging receipt", () => {
  for (const field of ["positionsAt", "ordersAt", "executionsAt"]) {
    const row = evidence(); row[field] = "2026-10-19T14:55:00.000Z";
    assert.equal(deskState(row, instant, instant), "sit-out");
    assert.equal(deskState(row, instant, "2026-10-19T15:00:00.001Z"), "stuck");
    row[field] = null; assert.equal(deskState(row, instant, instant), "stuck");
  }
});

const instants = [
  "2026-10-20T03:59:59.999Z", "2026-10-20T04:00:00.000Z", "2026-10-20T04:00:00.001Z",
  "2026-12-01T04:59:59.999Z", "2026-12-01T05:00:00.000Z", "2026-12-01T05:00:00.001Z",
  "2026-03-08T04:59:59.999Z", "2026-03-08T05:00:00.000Z", "2026-03-08T06:59:59.999Z", "2026-03-08T07:00:00.000Z",
  "2026-11-01T03:59:59.999Z", "2026-11-01T04:00:00.000Z", "2026-11-01T05:59:59.999Z", "2026-11-01T06:00:00.000Z",
  "2026-10-17T03:59:59.999Z", "2026-10-17T04:00:00.000Z", "2026-10-18T04:00:00.000Z",
];
test("mirrored NY day agrees with executor brakeUsage around midnight, DST and weekends", () => {
  const policy = new URL("../../../../modules/paper-desk-executor/policy.mjs", import.meta.url).href;
  const code = `const { brakeUsage } = await import(${JSON.stringify(policy)});
    console.log(JSON.stringify(${JSON.stringify(instants)}.map(at => brakeUsage({}, Date.parse(at)).day)));`;
  const result = spawnSync(process.execPath, ["--input-type=module", "-e", code], {
    encoding: "utf8", env: { PATH: process.env.PATH, IB_DESK_ACCOUNT: "DUFIXTURE" },
  });
  assert.equal(result.status, 0, result.stderr);
  const days = instants.map(at => newYorkDay(Date.parse(at)));
  assert.deepEqual(days, JSON.parse(result.stdout));
  assert.deepEqual(days.slice(0, 3), ["2026-10-19", "2026-10-20", "2026-10-20"]);
  for (const at of instants) {
    const row = evidence(at); row.lastExecutionAt = at;
    assert.equal(deskState(row, at, at), "working", at);
  }
});

for (const [before, after] of [
  ["2026-10-20T03:59:59.999Z", "2026-10-20T04:00:00.000Z"],
  ["2026-03-08T04:59:59.999Z", "2026-03-08T05:00:00.000Z"],
  ["2026-11-01T03:59:59.999Z", "2026-11-01T04:00:00.000Z"],
  ["2026-10-17T03:59:59.999Z", "2026-10-17T04:00:00.000Z"],
]) test(`executions do not leak across NY midnight ${after}`, () => {
  const row = evidence(after); row.lastExecutionAt = before;
  assert.equal(deskState(row, after, after), "sit-out");
  const old = evidence(before); old.lastExecutionAt = before;
  assert.equal(deskState(old, before, after), "stuck", "a new-day completed execution reply is required");
});

test("raw completed reader evidence attributes by existing dated policy, excludes KEEP and refuses unclaimed activity", () => {
  const exec = (symbol, clientId, time = instant) => ({ contract: { symbol }, execution: { clientId, time } });
  const state = { coverageThrough: instant, coverageTradingDay: "2026-10-19", executions: [exec("SYNTH", 22), exec("TSLA", 999)] };
  const executions = executionActivity(state);
  assert.deepEqual(executions.latest, { j: null, joe: instant, joel: null });
  state.executions.push(exec("UNCLAIMED", 999)); assert.equal(executionActivity(state), null);
  const source = { book: { ts: instant, gateway: true, positionsCoverage: { status: "complete" },
    positions: [{ symbol: "TSLA", pos: 1 }], openOrders: [{ symbol: "SYNTH", clientId: 22, status: "Submitted" }], ordersObservedAt: instant },
  deskEquities: { ok: true, desks: { j: { positions: [] }, joe: { positions: [] }, joel: { positions: [] } } }, executions };
  const copied = copyDeskActivity(source);
  assert.equal(copied.joe.hasOrders, true); assert.equal(deskState(copied.joe, instant, instant), "working");
  assert.equal(deskState(copied.j, instant, instant), "sit-out");
  const frame = copyObservation(source); assert.equal(validObservation(frame), true);
  assert.doesNotMatch(JSON.stringify(frame), /clientId|orderRef|account|executions"/);
  source.book.openOrders[0].clientId = 999;
  assert.equal(deskState(copyDeskActivity(source).joe, instant, instant), "stuck");
  source.book.openOrders[0] = { symbol: "TSLA", clientId: 999 };
  assert.equal(copyDeskActivity(source).joe.hasOrders, false);
  source.book.openOrders[0] = { symbol: "SYNTH", clientId: 22, status: "Filled" };
  assert.equal(copyDeskActivity(source).joe.hasOrders, false);
  delete source.executions;
  assert.equal(deskState(copyDeskActivity(source).joe, instant, instant), "stuck");
});

test("broker order completion clock is generation scoped and invalidated on upstream loss", () => {
  const events = Object.fromEntries(["connected", "disconnected", "error", "info", "managedAccounts", "accountSummary", "accountSummaryEnd", "position", "positionEnd", "updatePortfolio", "accountDownloadEnd", "openOrder", "openOrderEnd"].map(name => [name, name]));
  const adapter = createBrokerSessionAdapter({ targetAccount: "DUFIXTURE", eventNames: events, now: () => instant });
  const make = () => Object.assign(new EventEmitter(), Object.fromEntries(["reqManagedAccts", "reqPositions", "reqAllOpenOrders", "reqAccountSummary", "reqAccountUpdates"].map(name => [name, () => {}])));
  const api = make(); adapter.attach(api); api.emit("connected"); api.emit("managedAccounts", "DUFIXTURE");
  api.emit("accountSummary", 9501, "DUFIXTURE", "NetLiquidation", "1", "EUR");
  api.emit("accountSummaryEnd", 9501); api.emit("positionEnd"); api.emit("accountDownloadEnd", "DUFIXTURE");
  assert.equal(adapter.snapshot().ordersObservedAt, null);
  api.emit("openOrder", 1, { symbol: "SYNTH" }, { account: "DUFIXTURE", clientId: 22 }, { status: "Submitted" });
  api.emit("openOrderEnd");
  assert.equal(adapter.snapshot().ordersObservedAt, instant); assert.equal(adapter.snapshot().openOrders[0].clientId, 22);
  // Order IDs are scoped to the broker client. Equal IDs must not erase a desk.
  api.emit("openOrder", 1, { symbol: "OTHER" }, { account: "DUFIXTURE", clientId: 27 }, { status: "Submitted" });
  assert.equal(adapter.snapshot().ordersObservedAt, null, "incomplete updates cannot retain an old completeness clock");
  api.emit("openOrderEnd");
  assert.deepEqual(adapter.snapshot().openOrders.map(row => row.clientId), [22, 27]);
  api.emit("info", "synthetic", 1100); assert.equal(adapter.snapshot().ordersObservedAt, null);
  const next = make(); adapter.attach(next); api.emit("openOrderEnd");
  assert.equal(adapter.snapshot().ordersObservedAt, null);
});
