import "../../tests/paper-desk-account-fixture.mjs";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { ACCOUNT, activityAttribution, belongsToDesk } from "./policy.mjs";
import { deskPositions as bookPositions } from "./ib.mjs";
import { assertPlacementAttribution, attributionConfig, planReattribution, reconcileAttribution } from "./attribution.mjs";
import { openLedger } from "./state.mjs";

const config = attributionConfig({ clientIds: { executor: 705, recon: 700 }, ownership: { j: [28, 702], joe: [701] } });
const contract = { conId: 11, symbol: "NVDA", secType: "STK", currency: "USD" };
const opening = () => ({ contract, execution: { execId: "paper-short.01.01", acctNumber: ACCOUNT, clientId: 705, orderId: 100, orderRef: "joe|261012|test-short-nvda", side: "SLD", shares: 4, price: 100, time: "2026-10-12T19:30:00Z" } });
const outside = () => ({ contract, execution: { execId: "paper-outside.01.01", acctNumber: ACCOUNT, clientId: 28, orderId: 101, permId: 102, orderRef: "", side: "BOT", shares: 4, price: 98, time: "2026-10-12T19:50:12Z" } });
const request = (extra = {}) => ({ execId: outside().execution.execId, desk: "joe", actor: "ops-test", reason: "Assign an outside cover to its desk", ...extra });
function fixture() {
  const ledger = openLedger(mkdtempSync(path.join(tmpdir(), "ops313-attribution-")));
  const state = ledger.load();
  Object.assign(state, { executions: [opening(), outside()], ownershipComplete: true, ownershipSnapshot: { account: ACCOUNT, positions: [], ownershipComplete: true }, marks: { 11: { price: 99 } }, commissions: [{ execId: opening().execution.execId, commission: 0.1, currency: "USD" }, { execId: outside().execution.execId, commission: 0.2, currency: "USD" }] });
  ledger.save(state);
  return { ledger, state };
}

test("foreign classification requires an executor client and a valid desk tag; legacy IDs only suggest", () => {
  for (const [clientId, orderRef, foreign, suggestion] of [
    [28, "", true, "j"], [28, "joe|261012|tag", true, "joe"],
    [705, "", true, null], [705, "unknown|261012|tag", true, null],
    [705, "j|261012|constructor", true, null], [706, "j|261012|tag", true, "j"],
    [700, "joe|261012|tag", false, null], [705, "JoE|261012|tag", false, null],
  ]) {
    const row = { clientId, orderRef };
    const attributed = activityAttribution(row, config);
    assert.equal(attributed.foreign, foreign);
    assert.equal(attributed.needsAttribution, foreign);
    assert.equal(attributed.suggestedDesk, suggestion);
    if (foreign) for (const desk of ["j", "joe"]) assert.equal(belongsToDesk(row, desk, config.ownership[desk], 705), false);
  }
});

test("retired executor clients own only pre-cutover executions; configured active clients remain owned", () => {
  for (const clientId of [701, 702, 703, 704, 706]) {
    for (const [time, foreign] of [["2026-10-11T23:59:59Z", false], ["2026-10-12T00:00:00Z", true], ["2026-10-13T15:00:00Z", true], ["unknown", true]]) {
      const row = { ...opening(), execution: { ...opening().execution, clientId, time } };
      assert.equal(activityAttribution(row, config).foreign, foreign, `${clientId}: ${time}`);
      assert.equal(belongsToDesk(row, "joe", [], 705), !foreign);
    }
    assert.equal(activityAttribution({ clientId, orderRef: opening().execution.orderRef }, config).foreign, true);
  }
  const configured = attributionConfig({ clientIds: { executor: 900, recon: 901 } });
  for (const clientId of [700, 705, 900, 901]) assert.equal(activityAttribution({ ...opening(), execution: { ...opening().execution, clientId } }, configured).foreign, false);
  const laterCutover = attributionConfig({ foreignAlertSince: "2026-10-14T00:00:00Z" });
  assert.equal(activityAttribution({ ...opening(), execution: { ...opening().execution, clientId: 703 } }, laterCutover).foreign, false);
});

test("post-cutover desk-tagged client 703 executions remain foreign and alert", (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: Date.parse("2026-10-13T20:00:00Z") });
  const { state } = fixture();
  state.executions = [{ ...opening(), execution: { ...opening().execution, clientId: 703 } }];
  const alerts = [];
  reconcileAttribution(state, config, { saveState: () => {}, alertForeign: (row) => alerts.push(row) });
  assert.equal(state.executions[0].attribution.desk, null);
  assert.equal(state.executions[0].attribution.suggestedDesk, "joe");
  assert.equal(state.executions[0].attribution.needsAttribution, true);
  assert.deepEqual(bookPositions(state.executions, config.ownership, 705, state.ownershipSnapshot), []);
  assert.equal(alerts.length, 1);
  assert.equal(alerts[0].clientId, 703);
});

test("placement attribution uses cutover, working status and contract identity, with a symbol fallback", () => {
  const old = { ...outside(), execution: { ...outside().execution, time: "2026-10-11T23:59:59Z" } };
  assert.doesNotThrow(() => assertPlacementAttribution([old], [], config, contract));
  assert.throws(() => assertPlacementAttribution([outside()], [], config, contract), /unassigned foreign activity/);
  assert.doesNotThrow(() => assertPlacementAttribution([outside()], [], config, { ...contract, conId: 12, symbol: "AMD" }));
  const working = { ...contract, account: ACCOUNT, clientId: 28, orderId: 100, status: "Submitted", orderRef: "" };
  assert.throws(() => assertPlacementAttribution([old], [working], config, contract), /unassigned foreign activity/);
  for (const status of ["Filled", "Cancelled", "Inactive", "ApiCancelled"]) assert.doesNotThrow(() => assertPlacementAttribution([old], [{ ...working, status }], config, contract));
  for (const conId of [undefined, 0]) {
    const row = { ...outside(), contract: { ...contract, conId } };
    assert.throws(() => assertPlacementAttribution([row], [], config, contract), /unassigned foreign activity/);
    assert.doesNotThrow(() => assertPlacementAttribution([row], [], config, { ...contract, symbol: "AMD" }));
    const acknowledged = planReattribution({ executions: [row] }, { execId: row.execution.execId, disposition: "external", actor: "ops-test", reason: "Acknowledge outside activity" }, { config }).state;
    assert.doesNotThrow(() => assertPlacementAttribution(acknowledged.executions, [], config, contract));
  }
});

test("incident-shaped outside cover stays foreign, preserves joe's short and alerts once across restart", (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: Date.parse("2026-10-12T20:00:00Z") });
  const { ledger, state } = fixture();
  const alerts = [];
  const context = { saveState: ledger.save, audit: ledger.audit, alertForeign: (event) => alerts.push(event) };
  reconcileAttribution(state, config, context);
  const held = state.executions.find((row) => row.execution.execId === outside().execution.execId);
  assert.equal(held.attribution.desk, null);
  assert.equal(held.attribution.suggestedDesk, "j");
  assert.equal(held.attribution.needsAttribution, true);
  assert.deepEqual(bookPositions(state.executions, config.ownership, 705, state.ownershipSnapshot).map((row) => [row.desk, row.quantity]), [["joe", -4]]);
  assert.equal(state.foreignPositions[0].quantity, 4);
  assert.equal(alerts.length, 1);
  assert.equal(alerts[0].event, "foreign_execution");
  assert.equal(alerts[0].desk, null);
  reconcileAttribution(state, config, context);
  reconcileAttribution(openLedger(ledger.root).load(), config, context);
  assert.equal(alerts.length, 1);
  const events = readFileSync(ledger.auditPath, "utf8").trim().split("\n").map(JSON.parse);
  assert.equal(events.filter((row) => row.event === "foreign_execution").length, 1);
  assert.equal(ledger.load().foreignAlerts.length, 1);
});

test("foreign alert persistence failure emits nothing before a durable receipt", () => {
  const { state } = fixture();
  let calls = 0;
  assert.throws(() => reconcileAttribution(state, config, { saveState: () => { throw new Error("disk unavailable"); }, audit: () => calls++, alertForeign: () => calls++ }), /disk unavailable/);
  assert.equal(calls, 0);
  assert.equal(state.foreignAlerts, undefined);
  reconcileAttribution(state, config, { saveState: () => {}, audit: () => calls++, alertForeign: () => calls++ });
  assert.equal(calls, 2, "the same in-memory execution can alert after persistence recovers");
});

test("the existing journal alert channel emits one structured account-free event across replay", (t) => {
  // Pin the clock like the neighbouring tests: the fixture's execution is fixed, and an unpinned clock
  // ages it past the 14-day lateness window (foreign_execution_late) as real time passes.
  t.mock.timers.enable({ apis: ["Date"], now: Date.parse("2026-10-12T20:00:00Z") });
  const { ledger, state } = fixture();
  const warn = t.mock.method(console, "warn", () => {});
  reconcileAttribution(state, config, { saveState: ledger.save, audit: ledger.audit });
  reconcileAttribution(ledger.load(), config, { saveState: ledger.save, audit: ledger.audit });
  assert.equal(warn.mock.callCount(), 1);
  const event = JSON.parse(warn.mock.calls[0].arguments[0]);
  assert.equal(event.event, "foreign_execution");
  assert.equal(event.execId, outside().execution.execId);
  assert.equal(event.needsAttribution, true);
  assert.doesNotMatch(JSON.stringify(event), /acctNumber|account|DU0000001/);
});

test("an unknown execution dry run does not initialize a missing ledger", () => {
  const ledger = openLedger(mkdtempSync(path.join(tmpdir(), "ops313-empty-attribution-")));
  assert.throws(() => ledger.reattribute(request()), (error) => error.statusCode === 404);
  assert.deepEqual(readdirSync(ledger.root), []);
});

test("admin attribution preserves unavailable PnL when ownership history is incomplete", () => {
  const { ledger, state } = fixture();
  state.ownershipComplete = false;
  state.ownershipSnapshot.ownershipComplete = false;
  ledger.save(state);
  const preview = ledger.reattribute(request());
  assert.equal(preview.before.pnlPerDesk.joe.realized, null);
  assert.deepEqual(preview.before.deskPositions, []);
  assert.equal(preview.after.pnlPerDesk.joe.realized, null);
  assert.equal(preview.after.pnlPerDesk.joe.status, "unavailable");
  assert.deepEqual(preview.after.deskPositions, []);
  ledger.reattribute(request({ dryRun: false }));
  assert.equal(ledger.load().ownershipComplete, false);
  assert.deepEqual(ledger.load().deskPositions, []);
  assert.equal(ledger.load().pnlPerDesk.joe.realized, null);
});

test("admin dry run is byte-preserving; atomic apply flattens joe and recalculates FIFO PnL", (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: Date.parse("2026-10-12T20:00:00Z") });
  const { ledger, state } = fixture();
  reconcileAttribution(state, config, { saveState: ledger.save, audit: ledger.audit, alertForeign: () => {} });
  const before = readFileSync(ledger.statePath, "utf8"), auditBefore = readFileSync(ledger.auditPath, "utf8");
  const preview = ledger.reattribute(request(), { peer: "127.0.0.1" });
  assert.equal(preview.dryRun, true);
  assert.equal(preview.from, "foreign"); assert.equal(preview.to, "joe");
  assert.equal(preview.before.deskPositions[0].quantity, -4);
  assert.deepEqual(preview.after.deskPositions, []);
  assert.deepEqual(preview.after.foreignPositions, []);
  assert.equal(preview.after.pnlPerDesk.joe.grossRealized, 8);
  assert.equal(preview.after.pnlPerDesk.joe.realized, 7.7);
  assert.equal(preview.after.pnlPerDesk.joe.unrealized, 0);
  assert.equal(preview.after.pnlPerDesk.j.grossRealized, 0);
  assert.equal(readFileSync(ledger.statePath, "utf8"), before);
  assert.equal(readFileSync(ledger.auditPath, "utf8"), auditBefore);
  const applied = ledger.reattribute(request({ dryRun: false }), { peer: "127.0.0.1" });
  assert.equal(applied.dryRun, false);
  const saved = ledger.load(), journal = saved.attributionJournal[0];
  assert.equal(journal.execId, outside().execution.execId);
  assert.equal(journal.actor, "ops-test"); assert.equal(journal.peer, "127.0.0.1");
  assert.equal(journal.from, "foreign"); assert.equal(journal.to, "joe");
  assert.ok(Number.isFinite(Date.parse(journal.at))); assert.equal(journal.reason, request().reason);
  assert.deepEqual(saved.deskPositions, []);
  assert.deepEqual(saved.executions.map((row) => row.execution), state.executions.map((row) => row.execution), "broker execution data remains unchanged");
  assert.equal(saved.executions[1].attribution.method, "admin");
  assert.equal(saved.executions[1].attribution.foreign, true);
  assert.equal(saved.executions[1].attribution.needsAttribution, false);
  for (const dryRun of [true, false]) assert.throws(() => ledger.reattribute(request({ dryRun })), (error) => error.statusCode === 409 && /already attributed/.test(error.message));
  assert.equal(ledger.load().attributionJournal.length, 1);
});

test("admin refuses unknown, owned, invalid, non-paper and KEEP executions without saving", () => {
  for (const [change, expected] of [
    [{ execId: "unknown.01" }, /unknown/], [{ execId: opening().execution.execId }, /not an unassigned/],
    [{ desk: "unknown" }, /desk/], [{ actor: "" }, /actor/], [{ reason: "" }, /reason/],
    [{ reason: "line\nbreak" }, /reason/], [{ dryRun: "false" }, /boolean/], [{ extra: true }, /unsupported/],
  ]) {
    const { ledger } = fixture(); const before = readFileSync(ledger.statePath, "utf8");
    assert.throws(() => ledger.reattribute(request({ dryRun: false, ...change })), expected);
    assert.equal(readFileSync(ledger.statePath, "utf8"), before);
  }
  for (const modification of [
    (row) => { row.execution.acctNumber = "U0000001"; },
    (row) => { row.contract = { ...row.contract, symbol: "TSLA" }; },
    (row) => { row.execution.shares = -4; },
  ]) {
    const { ledger, state } = fixture(); modification(state.executions[1]); ledger.save(state);
    const before = readFileSync(ledger.statePath, "utf8");
    assert.throws(() => ledger.reattribute(request({ dryRun: false })), /not an unassigned|KEEP|economics/);
    assert.equal(readFileSync(ledger.statePath, "utf8"), before);
  }
});

test("external disposition previews without writes, clears the execution gate, and changes no desk PnL", () => {
  const { ledger, state } = fixture();
  const change = { execId: outside().execution.execId, disposition: "external", actor: "ops-test", reason: "Acknowledge an external cover" };
  const before = readFileSync(ledger.statePath, "utf8");
  const preview = ledger.reattribute(change, { config });
  assert.equal(preview.dryRun, true);
  assert.equal(preview.to, "external");
  assert.deepEqual(preview.after.pnlPerDesk, preview.before.pnlPerDesk);
  assert.deepEqual(preview.after.deskPositions, []);
  assert.equal(preview.after.foreignPositions[0].needsAttribution, false);
  assert.equal(readFileSync(ledger.statePath, "utf8"), before);
  assert.throws(() => assertPlacementAttribution(ledger.load().executions, [], config, contract), /unassigned foreign activity/);
  assert.throws(() => ledger.reattribute({ ...change, desk: "joe" }, { config }), /cannot assign a desk/);
  assert.throws(() => ledger.reattribute({ ...change, disposition: "unknown" }, { config }), /disposition/);
  const applied = ledger.reattribute({ ...change, dryRun: false }, { config, peer: "100.64.0.14" });
  assert.deepEqual(applied.after.pnlPerDesk, preview.before.pnlPerDesk);
  const saved = ledger.load(), journal = saved.attributionJournal[0];
  assert.equal(journal.disposition, "external"); assert.equal(journal.to, "external");
  assert.equal(journal.actor, "ops-test"); assert.equal(journal.peer, "100.64.0.14");
  assert.equal(journal.event, "execution_acknowledged_external");
  assert.equal(saved.executions[1].attribution.desk, null);
  assert.equal(saved.executions[1].attribution.method, "external");
  assert.equal(saved.executions[1].attribution.needsAttribution, false);
  assert.deepEqual(saved.executions.map((row) => row.execution), state.executions.map((row) => row.execution));
  assert.doesNotThrow(() => assertPlacementAttribution(saved.executions, [], config, contract));
  for (const dryRun of [true, false]) assert.throws(() => ledger.reattribute({ ...change, dryRun }, { config }), (error) => error.statusCode === 409);
  const correction = { ...outside(), execution: { ...outside().execution, execId: "paper-outside.01.02" } };
  saved.executions.push(correction);
  reconcileAttribution(saved, config, { saveState: ledger.save, alertForeign: () => {} });
  assert.equal(saved.executions[1].attribution.needsAttribution, true);
  assert.throws(() => assertPlacementAttribution(saved.executions, [], config, contract), /unassigned foreign activity/);
});

test("a correction revision requires its own explicit assignment and new alert receipt", () => {
  const { ledger, state } = fixture();
  reconcileAttribution(state, config, { saveState: ledger.save, alertForeign: () => {} });
  ledger.reattribute(request({ dryRun: false }));
  const loaded = ledger.load();
  loaded.executions.push({ ...outside(), execution: { ...outside().execution, execId: "paper-outside.01.02", shares: 3 } });
  reconcileAttribution(loaded, config, { saveState: ledger.save, alertForeign: () => {} });
  assert.equal(loaded.executions[1].execution.execId, "paper-outside.01.02");
  assert.equal(loaded.executions[1].attribution.desk, null);
  assert.equal(loaded.foreignAlerts.length, 2);
});

test("old foreign executions get silent receipts and one summary; pruning does not alert full history again", (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: Date.parse("2026-10-13T20:00:00Z") });
  const { ledger, state } = fixture();
  const old = Array.from({ length: 200 }, (_, index) => ({ ...outside(), execution: { ...outside().execution, execId: `backlog-${index}.01`, time: "2026-10-11T15:00:00Z" } }));
  state.executions.push(...old);
  const alerts = [], context = { saveState: ledger.save, audit: ledger.audit, alertForeign: (row) => alerts.push(row) };
  reconcileAttribution(state, config, context);
  assert.equal(alerts.length, 1);
  assert.equal(state.foreignAlerts.filter((row) => row.silent).length, 200);
  reconcileAttribution(ledger.load(), config, context);
  let audit = readFileSync(ledger.auditPath, "utf8").trim().split("\n").map(JSON.parse);
  assert.equal(audit.filter((row) => row.event === "foreign_execution_backlog").length, 1);
  assert.equal(audit.find((row) => row.event === "foreign_execution_backlog").count, 200);
  assert.equal(audit.filter((row) => row.event === "foreign_execution").length, 1);
  t.mock.timers.tick(15 * 86400000);
  ledger.save(ledger.load());
  assert.deepEqual(ledger.load().foreignAlerts, []);
  reconcileAttribution(openLedger(ledger.root).load(), config, context);
  assert.equal(alerts.length, 1);
  assert.deepEqual(ledger.load().foreignAlerts, []);
  audit = readFileSync(ledger.auditPath, "utf8").trim().split("\n").map(JSON.parse);
  assert.equal(audit.filter((row) => row.event === "foreign_execution_backlog").length, 1);
});

test("alert cutover parses UTC and legacy New York IB timestamps at the boundary", (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: Date.parse("2026-10-13T20:00:00Z") });
  const { state } = fixture();
  state.executions = ["20261011-23:59:59", "20261012-00:00:00", "20261011 20:00:00 America/New_York"].map((time, index) => ({ ...outside(), execution: { ...outside().execution, execId: `cutover-${index}.01`, time } }));
  const alerts = [], audit = [];
  reconcileAttribution(state, config, { saveState: () => {}, audit: (row) => audit.push(row), alertForeign: (row) => alerts.push(row) });
  assert.deepEqual(alerts.map((row) => row.execId), ["cutover-1.01", "cutover-2.01"]);
  assert.equal(audit.find((row) => row.event === "foreign_execution_backlog").count, 1);
  assert.throws(() => attributionConfig({ foreignAlertSince: "not-a-date" }), /UTC/);
  assert.throws(() => attributionConfig({ foreignAlertRetentionDays: 0 }), /positive days/);
});

test("late post-cutover executions emit one durable summary per newly seen batch", (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: Date.parse("2026-10-29T20:00:00Z") });
  const { ledger, state } = fixture();
  state.executions = Array.from({ length: 3 }, (_, index) => ({ ...outside(), execution: { ...outside().execution, execId: `late-${index}.01` } }));
  const alerts = [], context = { saveState: ledger.save, audit: ledger.audit, alertForeign: (row) => alerts.push(row) };
  const longerRetention = { ...config, foreignAlertRetentionDays: 30 };
  reconcileAttribution(state, longerRetention, context);
  assert.deepEqual(alerts.map((row) => [row.event, row.count]), [["foreign_execution_late", 3]]);
  const loaded = ledger.load();
  reconcileAttribution(loaded, longerRetention, context);
  assert.equal(alerts.length, 1);
  loaded.executions.push({ ...outside(), execution: { ...outside().execution, execId: "late-next.01" } });
  reconcileAttribution(loaded, longerRetention, context);
  assert.deepEqual(alerts.map((row) => row.count), [3, 1]);
  const audit = readFileSync(ledger.auditPath, "utf8").trim().split("\n").map(JSON.parse);
  assert.deepEqual(audit.filter((row) => row.event.startsWith("foreign_")).map((row) => [row.event, row.count]), [["foreign_execution_late", 3], ["foreign_execution_late", 1]]);
});

test("foreign working orders alert once by permId or clientId:orderId across restart", () => {
  const { ledger, state } = fixture(); state.executions = [];
  const base = { ...contract, account: ACCOUNT, clientId: 28, orderId: 100, orderRef: "", status: "Submitted" };
  const orders = [{ ...base, permId: 300 }, { ...base, orderId: 101 }, { ...base, orderId: 101, clientId: 29 }, { ...base, orderId: 102, status: "Filled" }, { ...base, orderId: 103, status: "Cancelled" }];
  const alerts = [], context = { saveState: ledger.save, audit: ledger.audit, alertForeign: (row) => alerts.push(row), openOrders: orders };
  reconcileAttribution(state, config, context);
  assert.equal(alerts.length, 3);
  assert.ok(alerts.every((row) => row.event === "foreign_open_order"));
  assert.deepEqual(alerts.map((row) => row.key), ["order:permId:300", "order:clientId:28:orderId:101", "order:clientId:29:orderId:101"]);
  reconcileAttribution(openLedger(ledger.root).load(), config, { ...context, openOrders: [{ ...orders[0], orderId: 999, clientId: 30 }, ...orders.slice(1)] });
  assert.equal(alerts.length, 3);
  assert.equal(ledger.load().foreignAlerts.length, 3);
});

test("KEEP executions and orders are protected holdings that never need attribution or alerts", () => {
  const { ledger, state } = fixture();
  state.executions = ["TSLA", "SXR8"].map((symbol, index) => ({ ...outside(), contract: { ...contract, symbol, conId: 20 + index }, execution: { ...outside().execution, execId: `keep-${index}.01` } }));
  const alerts = [];
  reconcileAttribution(state, config, { saveState: ledger.save, alertForeign: (row) => alerts.push(row), openOrders: [{ ...contract, symbol: "TSLA", account: ACCOUNT, clientId: 28, orderId: 100, status: "Submitted" }] });
  for (const row of state.executions) { assert.equal(row.attribution.keep, true); assert.equal(row.attribution.needsAttribution, false); assert.equal(row.attribution.desk, null); }
  assert.equal(state.foreignPositions.length, 2);
  assert.ok(state.foreignPositions.every((row) => row.keep && !row.needsAttribution));
  assert.deepEqual(alerts, []);
  ledger.save(state);
  assert.throws(() => ledger.reattribute(request({ execId: "keep-0.01", dryRun: false })), (error) => error.statusCode === 400 && /KEEP/.test(error.message));
});

test("runtime attribution config overrides old ledger metadata and is never persisted", () => {
  const { ledger, state } = fixture();
  state.executions[1].execution.clientId = 900;
  state.executions[1].execution.orderRef = "joe|261012|configured-client";
  const latest = attributionConfig({ clientIds: { executor: 900, recon: 901 }, ownership: { joe: [701] } });
  state.attributionConfig = latest;
  // Without an explicit runtime override the current host config wins, even
  // when an old ledger says this client was owned.
  assert.equal(planReattribution(state, request()).result.dryRun, true);
  assert.throws(() => planReattribution(state, request(), { config: latest }), (error) => error.statusCode === 409);
  ledger.save(state);
  assert.equal(JSON.parse(readFileSync(ledger.statePath, "utf8")).attributionConfig, undefined);
  reconcileAttribution(state, latest, { saveState: ledger.save, alertForeign: () => {} });
  assert.equal(ledger.load().attributionConfig, undefined);
});
