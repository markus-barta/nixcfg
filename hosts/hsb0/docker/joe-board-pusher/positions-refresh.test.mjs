import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";
import { createBrokerSessionAdapter } from "./pusher-state.mjs";
import { copyDeskActivity, createDeskStateReporter, deskStateDetails, newYorkDay } from "./desk-activity.mjs";
import { copyObservation } from "./v2-stage-handoff.mjs";
import { buildCandidate } from "./v2-stage-worker.mjs";
import { runPusher } from "./fixtures/pusher-harness.mjs";

const start = "2026-10-20T15:00:00.000Z";
const account = "DUFIXTURE";
const contract = (symbol = "INTC", conId = 1) => ({ symbol, conId, secType: "STK", currency: "USD" });

test("Amy (1): the positions clock means last heard from IB: 120 s re-requests with unchanged positions advance it; ten-minute run with 3-min account cycles, no stuck or flap; v1 bytes unchanged", async () => {
  const url = new URL("./pusher.mjs", import.meta.url);
  const baseline = await runPusher(url);
  const refreshed = await runPusher(url, { refreshTicks: 3 });
  assert.deepEqual(refreshed.refreshCalls, ["orders", "positions", "orders", "positions", "orders", "positions"]);
  assert.deepEqual(refreshed.requests, baseline.requests);
  assert.deepEqual(refreshed.schedule, baseline.schedule);
});
function session(rows = [contract()]) {
  let elapsed = 0;
  const at = () => new Date(Date.parse(start) + elapsed).toISOString();
  const names = ["connected", "disconnected", "info", "error", "managedAccounts", "accountSummary", "accountSummaryEnd",
    "accountDownloadEnd", "position", "positionEnd", "updatePortfolio", "openOrder", "openOrderEnd"];
  const adapter = createBrokerSessionAdapter({ targetAccount: account, eventNames: Object.fromEntries(names.map(n => [n, n])), now: at });
  const make = () => Object.assign(new EventEmitter(), { requests: [], ...Object.fromEntries([
    "reqManagedAccts", "reqPositions", "cancelPositions", "reqAllOpenOrders", "reqAccountSummary", "reqAccountUpdates",
  ].map(n => [n, function (...args) { this.requests.push([n, elapsed, ...args]); }])) });
  const api = make();
  const position = (row, qty = 3, emitter = api) => emitter.emit("position", account, row, qty, 10);
  function accountCycle() {
    api.emit("accountSummary", 9501, account, "NetLiquidation", "10000", "EUR");
    api.emit("accountSummary", 9501, account, "TotalCashValue", "9000", "EUR");
    api.emit("accountSummaryEnd", 9501);
    api.emit("accountDownloadEnd", account);
  }
  adapter.attach(api); api.emit("connected"); api.emit("managedAccounts", account);
  for (const row of rows) position(row);
  api.emit("positionEnd"); accountCycle(); api.emit("openOrderEnd");
  function source(path = "desks") {
    const positions = rows.filter(row => !["SXR8", "TSLA"].includes(row.symbol)).map(row => ({ symbol: row.symbol, side: "Long", currency: "USD" }));
    return { book: adapter.snapshot(),
      ...(path === "desks" ? { deskEquities: { ok: true, oldestSourceObservedAt: start,
        desks: { j: { positions }, joe: { positions: [] }, joel: { positions: [] } } } }
        : { family: { ok: true, observedAt: start, positions } }),
      executions: { observedAt: at(), day: newYorkDay(Date.parse(at())), latest: {} } };
  }
  return { adapter, api, at, make, position, source, accountCycle, advance(ms) { elapsed += ms; } };
}

for (const populated of [false, true]) test(`120-second completed replies keep unchanged ${populated ? "holdings" : "empty positions"} fresh for ten minutes with 3-minute account cycles`, () => {
  const rows = populated ? [contract(), contract("TSLA", 2)] : [];
  const s = session(rows), events = [];
  const report = createDeskStateReporter({ onEvent: e => events.push(e) });
  let seq = 0;
  let keep;
  for (let ms = 0; ms <= 600_000; ms += 5_000) {
    if (ms) s.advance(5_000);
    if (ms && ms % 180_000 === 0) s.accountCycle();
    const requested = s.adapter.refreshPositions();
    assert.equal(requested, ms > 0 && ms % 120_000 === 0);
    if (requested) { for (const row of rows) s.position(row); s.api.emit("positionEnd"); }
    if (s.adapter.refreshOpenOrders()) s.api.emit("openOrderEnd");
    assert.ok(Date.parse(s.at()) - Date.parse(s.adapter.snapshot().positionsCoverage.observedAt) < 120_000);
    for (const path of ["desks", "family"]) {
      const source = s.source(path), activity = copyDeskActivity(source);
      assert.equal(activity.j.positionsAt, s.adapter.snapshot().positionsCoverage.observedAt, path);
      assert.equal(deskStateDetails(activity.j, s.at(), s.at()).state, populated ? "working" : "sit-out", path);
      if (path === "desks") {
        report(source, s.at());
        const value = buildCandidate(++seq, s.at(), copyObservation(source));
        assert.notEqual(value.positions.reason, "source_unavailable");
        assert.deepEqual(value.desks.map(d => d.state), [populated ? "working" : "sit-out", "sit-out", "sit-out"]);
        const row = value.positions.rows.find(row => row.symbol === "TSLA");
        if (populated) {
          assert.equal(row.scope, "keep"); assert.equal(row.desk, null);
          keep ??= JSON.stringify(row); assert.equal(JSON.stringify(row), keep);
        }
      }
    }
  }
  assert.equal(events.length, 3, "no desk-state transition or stale flap across the ten-minute run");
  assert.deepEqual(s.api.requests.filter(([n]) => ["cancelPositions", "reqPositions"].includes(n)).map(([n, ms]) => [n, ms]), [
    ["reqPositions", 0], ...[120_000, 240_000, 360_000, 480_000, 600_000].flatMap(ms => [["cancelPositions", ms], ["reqPositions", ms]]),
  ]);
});

test("refresh replaces rows only at positionEnd, including omitted contracts and an empty reply", () => {
  const s = session([contract(), contract("OTHER", 2)]);
  const old = s.adapter.snapshot().positionsCoverage;
  s.advance(119_999); assert.equal(s.adapter.refreshPositions(), false);
  s.advance(1); assert.equal(s.adapter.refreshPositions(), true);
  s.position(contract(), 7);
  s.api.emit("position", "OTHER-ACCOUNT", contract("FOREIGN", 3), 5, 10);
  s.api.emit("updatePortfolio", contract("OTHER", 2), 20, 30, 600, 10, 1, 0, account);
  s.accountCycle();
  assert.deepEqual(s.adapter.snapshot().positionsCoverage, old, "partial positions and account publications retain completed rows and clock");
  for (let i = 0; i < 10; i++) assert.equal(s.adapter.refreshPositions(), false);
  s.api.emit("positionEnd");
  assert.deepEqual(s.adapter.snapshot().positions.map(r => [r.symbol, r.pos]), [["INTC", 7]]);
  assert.equal(s.adapter.snapshot().positionsCoverage.observedAt, s.at());
  s.advance(120_000); assert.equal(s.adapter.refreshPositions(), true);
  s.api.emit("positionEnd");
  assert.deepEqual(s.adapter.snapshot().positions, []);
  const clock = s.adapter.snapshot().positionsCoverage.observedAt;
  s.advance(5_000); s.api.emit("positionEnd"); s.accountCycle();
  assert.equal(s.adapter.snapshot().positionsCoverage.observedAt, clock, "unsolicited ends and account cycles cannot restamp");
});

test("unchanged refreshed holdings preserve actual marks and their original age", () => {
  const s = session();
  s.api.emit("updatePortfolio", contract(), 3, 20.123456789, 60, 10, 1, 0, account);
  const mark = s.adapter.snapshot().positions[0];
  s.advance(120_000); assert.equal(s.adapter.refreshPositions(), true);
  s.position(contract()); s.api.emit("positionEnd");
  const row = s.adapter.snapshot().positions[0];
  assert.equal(row.marketPrice, mark.marketPrice);
  assert.equal(row.marketValue, mark.marketValue);
  assert.equal(row.unrealizedPNL, mark.unrealizedPNL);
  assert.equal(row.markObservedAt, start, "positions completion cannot renew an unchanged price");
  assert.equal(row.positionObservedAt, s.at());
  assert.equal(s.adapter.snapshot().portfolio[0].markObservedAt, start);
});

test("Amy (2): a re-request with no completed reply never stamps; partial position, portfolio and account callbacks cannot renew coverage; a real outage is stale at 421 seconds", () => {
  const s = session();
  s.advance(120_000); assert.equal(s.adapter.refreshPositions(), true);
  for (let ms = 125_000; ms <= 420_000; ms += 5_000) {
    s.advance(5_000); s.position(contract(), 9);
    s.api.emit("updatePortfolio", contract(), 9, 20, 180, 10, 1, 0, account);
    s.accountCycle();
    assert.equal(s.adapter.refreshPositions(), false, "never overlap even an overdue reply");
    if (s.adapter.refreshOpenOrders()) s.api.emit("openOrderEnd");
    assert.equal(s.adapter.snapshot().positionsCoverage.observedAt, start);
  }
  assert.equal(deskStateDetails(copyDeskActivity(s.source()).j, s.at(), s.at()).state, "working");
  s.advance(1_000);
  assert.deepEqual(deskStateDetails(copyDeskActivity(s.source()).j, s.at(), s.at()), { state: "stuck", cause: "positions_stale" });
  assert.equal(buildCandidate(1, s.at(), copyObservation(s.source())).positions.reason, "source_unavailable");
  assert.equal(s.api.requests.filter(([n]) => n === "reqPositions").length, 2);
});

for (const transition of ["disconnect", "upstream loss", "attach"]) test(`a reconnect mid-request cannot stamp from retired callbacks (${transition})`, () => {
  const s = session(); s.advance(120_000); s.adapter.refreshPositions(); s.position(contract(), 99);
  if (transition === "disconnect") s.api.emit("disconnected");
  if (transition === "upstream loss") s.api.emit("info", "synthetic", 1100);
  const next = s.make(); s.adapter.attach(next);
  s.api.emit("positionEnd"); s.accountCycle();
  assert.equal(s.adapter.snapshot().positionsCoverage.observedAt, null);
  next.emit("connected"); next.emit("managedAccounts", account);
  next.emit("accountSummary", 9501, account, "NetLiquidation", "10000", "EUR");
  next.emit("accountSummaryEnd", 9501); next.emit("accountDownloadEnd", account);
  s.api.emit("positionEnd");
  assert.equal(s.adapter.snapshot().positionsCoverage.observedAt, null);
  s.advance(5_000); next.emit("positionEnd");
  assert.equal(s.adapter.snapshot().positionsCoverage.observedAt, s.at());
  assert.deepEqual(s.adapter.snapshot().positions, []);
});

for (const method of ["cancelPositions", "reqPositions"]) test(`failed ${method} retires the generation and refuses a late end`, () => {
  const s = session(); s.advance(120_000);
  s.api[method] = () => { throw new Error("synthetic request failure"); };
  assert.equal(s.adapter.refreshPositions(), false);
  s.api.emit("positionEnd");
  assert.equal(s.adapter.snapshot().gateway, false);
  assert.equal(s.adapter.snapshot().positionsCoverage.observedAt, null);
});
