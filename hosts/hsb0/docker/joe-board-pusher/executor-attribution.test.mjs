import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { createExecutorAttribution, executorClientCounts, readExecutorAttribution } from "./executor-attribution.mjs";
import { normalizeEconomicExecution } from "./execution-history.mjs";
import { executionActivity, createDeskStateReporter } from "./desk-activity.mjs";
import { copyObservation } from "./v2-stage-handoff.mjs";
import { buildCandidate } from "./v2-stage-worker.mjs";

const account = "SYNTHETIC-PAPER";
const instant = "2026-10-19T15:00:00.000Z";
const bracket = (desk = "j", clientId = 705) => ({ action: "place", desk,
  result: { bracket: { clientId, parentOrderId: 101, stopOrderId: 102 } } });
const execution = (overrides = {}) => ({ acctNumber: account, clientId: 705, orderId: 101, execId: "synthetic.01", ...overrides });
const row = (overrides = {}, symbol = "SYNTH") => ({ contract: { symbol }, execution: execution({ time: "20261019 10:00:00 US/Eastern", ...overrides }) });
const ledger = (intents = { "masked-intent": bracket() }, executions = []) => ({ schema: "barta.paper-desk-executor-state.v1", account, intents, executions });
const attribution = (intents, executions, clientIds, onEvent) => createExecutorAttribution({ ledger: ledger(intents, executions), account, clientIds, onEvent });

// Masked inventory shape only: unique synthetic keys, no live ledger values.
function maskedInventory() {
  const desks = [...Array(10).fill("j5"), ...Array(6).fill("j2"), ...Array(14).fill("joe")];
  const rows = desks.map((desk, index) => row({ orderId: 1000 + 2 * index, execId: `synthetic.${index}`,
    time: `20261019 10:00:${String(index).padStart(2, "0")} US/Eastern`, orderRef: "untrusted|masked",
    price: 123, shares: 45 }));
  const intents = Object.fromEntries(desks.map((desk, index) => [`masked-${index}`, {
    ...bracket(desk), result: { bracket: { clientId: 705, parentOrderId: rows[index].execution.orderId,
      stopOrderId: rows[index].execution.orderId + 1 } },
  }]));
  return { desks, rows, intents };
}
const inventoryActivity = (rows, source) => executionActivity({ executions: rows, coverageThrough: instant,
  coverageTradingDay: "2026-10-19" }, source);

test("masked 705 inventory: 30 fills roll j5 x10 and j2 x6 into j x16, with joe x14 and every subDesk retained", () => {
  const { desks, rows, intents } = maskedInventory();
  const before = structuredClone(rows);
  const source = attribution(intents, rows);
  const attributed = rows.map(row => source.attribute(row.execution));
  const counts = key => attributed.reduce((all, row) => ({ ...all, [row[key]]: (all[row[key]] ?? 0) + 1 }), {});
  assert.equal(attributed.length, 30);
  assert.deepEqual(counts("desk"), { j: 16, joe: 14 });
  assert.deepEqual(counts("subDesk"), { j5: 10, j2: 6, joe: 14 });
  attributed.forEach((execution, index) => {
    assert.equal(execution.clientId, 705);
    assert.equal(execution.subDesk, desks[index]);
    assert.equal(execution.desk, index < 16 ? "j" : "joe");
  });
  assert.deepEqual(rows, before, "subDesk stays on internal copies, never raw broker rows");
  assert.deepEqual(executorClientCounts(rows, source), [{ client: 705, matched: 30, unmatched: 0 }]);
  assert.deepEqual(inventoryActivity(rows, source), {
    observedAt: instant, day: "2026-10-19",
    latest: { j: "2026-10-19T14:00:15.000Z", joe: "2026-10-19T14:00:29.000Z", joel: null },
    executorClients: [{ client: 705, matched: 30, unmatched: 0 }],
  });
});

test("masked 30-fill inventory fails closed when a j5, j2 or joe order key has a second intent", () => {
  for (const index of [0, 10, 16]) {
    const { rows, intents } = maskedInventory();
    intents.duplicate = structuredClone(intents[`masked-${index}`]);
    const source = attribution(intents, rows);
    assert.throws(() => source.attribute(rows[index].execution), /intent_ambiguous/);
    assert.throws(() => rows.map(row => source.attribute(row.execution)), /intent_ambiguous/);
    assert.deepEqual(executorClientCounts(rows, source), [{ client: 705, matched: 29, unmatched: 1 }]);
    assert.deepEqual(inventoryActivity(rows, source), { cause: "execution_unowned", clientId: 705,
      executorClients: [{ client: 705, matched: 29, unmatched: 1 }] });
  }
});

test("masked 30-fill inventory rejects a desk outside the table with a value-free executor_intent_desk_unclaimed event", () => {
  const { rows, intents } = maskedInventory();
  intents["masked-10"].desk = "outside-table";
  const events = [];
  const source = attribution(intents, rows, undefined, event => events.push(event));
  assert.throws(() => source.attribute(rows[10].execution), /intent_desk_invalid/);
  assert.deepEqual(events, [{ event: "executor_intent_desk_unclaimed", cause: "intent_desk_invalid", desk: "outside-table" }]);
  assert.deepEqual(executorClientCounts(rows, source), [{ client: 705, matched: 29, unmatched: 1 }]);
  assert.deepEqual(inventoryActivity(rows, source), { cause: "execution_unowned", clientId: 705,
    executorClients: [{ client: 705, matched: 29, unmatched: 1 }] });
});

for (const [intentDesk, desk] of [["j", "j"], ["j2", "j"], ["j5", "j"], ["joe", "joe"], ["joel", "joel"]]) test(`705 explicitly rolls intent ${intentDesk} up to ${desk}, retaining its sub-desk and ignoring every orderRef prefix`, () => {
  const source = attribution({ "masked-intent": bracket(intentDesk) });
  for (const orderRef of ["j2|masked", "j5|masked", "joe|masked", "joel|masked", "unrecognized"]) {
    assert.equal(source.resolve(execution({ orderRef })), desk);
    assert.equal(source.resolve(execution({ orderId: 102, orderRef })), desk);
    const original = execution({ orderRef, desk: "forged", subDesk: "forged" });
    const before = structuredClone(original);
    const attributed = source.attribute(original);
    assert.deepEqual(attributed, { ...original, desk, subDesk: intentDesk });
    assert.notEqual(attributed, original);
    assert.deepEqual(original, before);
  }
});

test("700 and a configured executor client require their own client/order pair", () => {
  for (const clientId of [700, 812]) {
    const source = attribution({ "masked-intent": bracket("joe", clientId) }, [], [700, 705, 812]);
    assert.equal(source.resolve(execution({ clientId })), "joe");
    assert.throws(() => source.resolve(execution()), /intent_unmatched/);
  }
});

test("flatten submission keys match; cancel, modify and recon references cannot claim executions", () => {
  const source = attribution({
    flat: { action: "flatten", desk: "joel", result: { flattened: [{ clientId: 705, orderId: 105 }] } },
    cancel: { action: "cancel", desk: "joe", orderId: 101, brokerPlan: { clientId: 705, orderId: 101 } },
    modify: { action: "modify-stop", desk: "joe", brokerPlan: { clientId: 705, orderId: 101 } },
    recon: { action: "recon", desk: "joe", result: { executions: [row()] } },
  });
  assert.equal(source.resolve(execution({ orderId: 105 })), "joel");
  assert.throws(() => source.resolve(execution()), /intent_unmatched/);
});

test("zero, duplicate and same-roll-up duplicate intent matches all fail closed", () => {
  assert.throws(() => attribution({}).resolve(execution({ orderRef: "j|masked" })), /intent_unmatched/);
  for (const desk of ["j", "j2", "j5", "joe"]) assert.throws(() => attribution({ first: bracket(), second: bracket(desk) }).resolve(execution()), /intent_ambiguous/);
});

test("unknown intent desks fail closed with only the desk token in a value-free event", () => {
  for (const desk of ["J", "j20", "j50", "joe2", "joel2", "unknown", "constructor", "__proto__", "", null, { desk: "j" }]) {
    const events = [];
    const source = attribution({ only: bracket(desk) }, [], undefined, event => events.push(event));
    assert.throws(() => source.attribute(execution({ orderRef: "j|masked", price: 123, shares: 45 })), /intent_desk_invalid/);
    assert.deepEqual(events, [{ event: "executor_intent_desk_unclaimed", cause: "intent_desk_invalid",
      desk: typeof desk === "string" ? desk : null }]);
    assert.deepEqual(executorClientCounts([row()], source), [{ client: 705, matched: 0, unmatched: 1 }]);
  }
});

test("retained economic rows recover only an exact executor execution identity before joining an intent", () => {
  const source = attribution(undefined, [row()]);
  assert.equal(source.resolve(execution({ orderId: undefined })), "j");
  assert.throws(() => source.resolve(execution({ orderId: undefined, execId: "other.01" })), /order_key_missing/);
  assert.throws(() => source.resolve(execution({ orderId: 102 })), /identity_ambiguous/);
  assert.throws(() => source.resolve(execution({ acctNumber: "OTHER-SYNTHETIC" })), /identity_invalid/);
  assert.throws(() => attribution(undefined, [row(), row({ orderId: 102 })]).resolve(execution()), /identity_ambiguous/);
});

test("missing, malformed, wrong-schema and wrong-account ledger evidence fails closed", () => {
  for (const value of [null, {}, { ...ledger(), schema: "unknown" }, { ...ledger(), account: "OTHER-SYNTHETIC" }, { ...ledger(), intents: [] }]) {
    assert.throws(() => createExecutorAttribution({ ledger: value, account }).resolve(execution()), /ledger_unavailable/);
  }
});

test("read-only reader follows atomic replacements and refuses corrupt, symlink and oversized files", t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "ops392-executor-"));
  t.after(() => spawnSync("trash", [directory]));
  const file = path.join(directory, "ledger.json");
  const read = () => readExecutorAttribution({ file, account });
  assert.throws(() => read().resolve(execution()), /ledger_unavailable/);
  fs.writeFileSync(file, JSON.stringify(ledger()));
  const before = fs.readFileSync(file);
  assert.equal(read().resolve(execution()), "j");
  assert.deepEqual(fs.readFileSync(file), before);
  const next = path.join(directory, "next.json");
  fs.writeFileSync(next, JSON.stringify(ledger({ next: bracket("joe") })));
  fs.renameSync(next, file);
  assert.equal(read().resolve(execution()), "joe");
  const link = path.join(directory, "link.json"); fs.symlinkSync(file, link);
  assert.throws(() => readExecutorAttribution({ file: link, account }).resolve(execution()), /ledger_unavailable/);
  fs.writeFileSync(file, "invalid-json");
  assert.throws(() => read().resolve(execution()), /ledger_unavailable/);
  fs.truncateSync(file, 16 * 1024 * 1024 + 1);
  assert.throws(() => read().resolve(execution()), /ledger_unavailable/);
});

test("raw IB activity, open orders, v2 frame and value-free cause counts use the same intent owner", () => {
  const source = attribution();
  const executions = [row({ orderRef: "j5|masked" }), row({ orderId: 999 }, "TSLA"), row({ orderId: 999 }, "SXR8")];
  const summary = executionActivity({ executions, coverageThrough: instant, coverageTradingDay: "2026-10-19" }, source);
  assert.deepEqual(summary.executorClients, [{ client: 705, matched: 1, unmatched: 0 }]);
  assert.equal(summary.latest.j, "2026-10-19T14:00:00.000Z");
  const observation = {
    book: { ts: instant, gateway: true, positions: [], positionsCoverage: { status: "complete" },
      openOrders: [{ clientId: 705, orderId: 102, symbol: "SYNTH", status: "Submitted" }], ordersObservedAt: instant },
    deskEquities: { ok: true, oldestSourceObservedAt: instant, desks: Object.fromEntries(["j", "joe", "joel"].map(id => [id, { positions: [] }])) },
    executions: summary, executorAttribution: source,
  };
  const candidate = buildCandidate(1, instant, copyObservation(observation));
  assert.equal(candidate.desks.find(desk => desk.id === "j").state, "working");
  assert.equal(candidate.desks.find(desk => desk.id === "joe").state, "sit-out");
  const events = [];
  createDeskStateReporter({ onEvent: event => events.push(event) })(observation, instant);
  assert.deepEqual(events[0], { event: "v2_desk_state", desk: "j", state: "working", cause: null,
    executorClients: [{ client: 705, matched: 1, unmatched: 0 }] });
  const unmatched = [...executions, row({ orderId: 999 })];
  assert.deepEqual(executorClientCounts(unmatched, source), [{ client: 705, matched: 1, unmatched: 1 }]);
  assert.deepEqual(executionActivity({ executions: unmatched, coverageThrough: instant, coverageTradingDay: "2026-10-19" }, source), {
    cause: "execution_unowned", clientId: 705, executorClients: [{ client: 705, matched: 1, unmatched: 1 }],
  });
});

function opsRows(overrides = {}) {
  return ["BOT", "SLD"].map((side, index) => ({
    contract: { conId: 900, symbol: "SYNTH", secType: "STK", currency: "USD", multiplier: 1 },
    execution: execution({ execId: `ops.${index}.01`, orderId: 900 + index, orderRef: "joe|261006|ops-test-ko",
      side, shares: 2, price: 10 + index, time: `20261019 10:0${index}:00 US/Eastern`, ...overrides }),
  }));
}

function opsSource(rows, options = {}) {
  return createExecutorAttribution({ account, ledger: ledger({}, rows), executionRows: rows, onEvent() {}, ...options });
}

test("two flat OPS fills are separately counted, value-free, immutable and excluded from execution activity", () => {
  const rows = opsRows();
  const before = structuredClone(rows);
  const events = [];
  const source = opsSource(rows, { onEvent: event => events.push(event) });
  assert.equal(source.opsTestExecutionCount, 2);
  assert.equal(source.instrumentsNotFlat, 0);
  for (const row of rows) {
    assert.deepEqual(source.attribute(row.execution), { ...row.execution, desk: null, cause: "ops_test" });
    assert.equal(source.resolve(row.execution), null);
    assert.equal(source.attribute(normalizeEconomicExecution(row).execution).cause, "ops_test",
      "retained rows use exact execution identity without copying the marker into economic history");
  }
  assert.deepEqual(events, [{ event: "executor_ops_test", count: 2 }]);
  assert.deepEqual(executorClientCounts(rows, source), [{ client: 705, matched: 0, unmatched: 0, opsTest: 2 }]);
  assert.deepEqual(inventoryActivity(rows, source).latest, { j: null, joe: null, joel: null });
  assert.equal(inventoryActivity(rows, source).cause, undefined);
  assert.deepEqual(rows, before);
  const modified = { ...rows[0].execution, shares: 3 };
  assert.throws(() => source.attribute(modified), /intent_unmatched/);
  assert.throws(() => source.attribute({ ...rows[0].execution, time: "2026-02-30T10:00:00Z" }), /intent_unmatched/);
  assert.throws(() => opsSource([]).attribute(rows[0].execution), /intent_unmatched/, "no full snapshot grants no exception");
});

for (const marker of ["ops-test", "ops-test-ko", "ops-test-round-trip-2"]) test(`whole pipe token ${marker} is an OPS marker`, () => {
  const rows = opsRows({ orderRef: `joe|${marker}|suffix` });
  assert.equal(opsSource(rows).opsTestExecutionCount, 2);
});

for (const marker of ["xops-test", "not-ops-test-ko", "ops-testing", "ops-testko", "ops_test", "ops-test-", "OPS-TEST", " ops-test", "ops-test ", "ops-test_ko", "ops-test--ko", "ops-test/ko"]) {
  test(`other token ${JSON.stringify(marker)} stays intent_unmatched`, () => {
    const rows = opsRows({ orderRef: `joe|${marker}|suffix` });
    const source = opsSource(rows);
    assert.equal(source.opsTestExecutionCount, 0);
    assert.throws(() => source.attribute(rows[0].execution), /intent_unmatched/);
  });
}

test("flatness is per ledger instrument across all configured executor clients, never across symbols alone", () => {
  const rows = opsRows();
  rows[1].execution.clientId = 700;
  rows.push(...opsRows().map((row, index) => ({ ...row, contract: { ...row.contract, conId: 901 },
    execution: { ...row.execution, execId: `nonflat.${index}.01`, shares: index + 1 } })));
  const source = opsSource(rows);
  assert.equal(source.opsTestExecutionCount, 2);
  assert.equal(source.instrumentsNotFlat, 1);
  rows.slice(0, 2).forEach(row => assert.equal(source.attribute(row.execution).cause, "ops_test"));
  rows.slice(2).forEach(row => assert.throws(() => source.attribute(row.execution), /ops_test_not_flat/));
  const split = opsRows();
  split[1].contract.conId++;
  assert.equal(opsSource(split).instrumentsNotFlat, 2);
  assert.equal(opsSource(split).opsTestExecutionCount, 0);
  const fallback = opsRows();
  fallback.forEach(row => { row.contract.conId = 0; row.contract.multiplier = 0; });
  assert.equal(opsSource(fallback).opsTestExecutionCount, 2, "family fallback identity and IB blank multiplier semantics");
});

test("non-flat, missing opposite fill and conflicting instrument descriptions remain unclaimed", () => {
  for (const rows of [opsRows({ side: "BUY" }), opsRows().slice(0, 1), opsRows().map((row, index) => ({
    ...row, contract: { ...row.contract, currency: index ? "EUR" : "USD" },
  }))]) {
    const source = opsSource(rows);
    assert.equal(source.opsTestExecutionCount, 0);
    rows.forEach(row => assert.throws(() => source.attribute(row.execution), /ops_test_not_flat/));
    assert.equal(executorClientCounts(rows, source)[0].unmatched, rows.length);
    assert.equal(inventoryActivity(rows, source).cause, "execution_unowned");
  }
});

test("exact intent matches and every other attribution cause take priority over the OPS marker", () => {
  const rows = opsRows();
  const intent = { ...bracket("j5"), result: { bracket: { clientId: 705, parentOrderId: 900, stopOrderId: 901 } } };
  const exact = opsSource(rows, { ledger: ledger({ exact: intent }, rows) });
  assert.equal(exact.opsTestExecutionCount, 0);
  assert.equal(exact.attribute(rows[0].execution).subDesk, "j5");
  const onlyFirst = { ...intent, result: { bracket: { clientId: 705, parentOrderId: 900, stopOrderId: 999 } } };
  const partial = opsSource(rows, { ledger: ledger({ exact: onlyFirst }, rows) });
  assert.equal(partial.resolve(rows[0].execution), "j");
  assert.throws(() => partial.attribute(rows[1].execution), /ops_test_not_flat/, "matched fills cannot balance unmatched tests");
  for (const [cause, value] of [["intent_ambiguous", ledger({ a: intent, b: intent }, rows)],
    ["intent_desk_invalid", ledger({ a: { ...intent, desk: "unknown" } }, rows)],
    ["ledger_unavailable", null], ["identity_ambiguous", ledger({}, [...rows, { ...rows[0], execution: { ...rows[0].execution, orderId: 999 } }])]]) {
    const source = opsSource(rows, { ledger: value });
    assert.throws(() => source.attribute(rows[0].execution), new RegExp(cause));
    assert.equal(source.opsTestExecutionCount, 0);
  }
  const missingKey = opsRows({ orderId: undefined });
  assert.throws(() => opsSource(missingKey).attribute(missingKey[0].execution), /order_key_missing/);
});

test("non-executor clients and KEEP cannot join the OPS-test set; custom executor configuration can", () => {
  const foreign = opsRows({ clientId: 22 });
  assert.equal(opsSource(foreign).opsTestExecutionCount, 0);
  assert.throws(() => opsSource(foreign).attribute(foreign[0].execution), /identity_invalid/);
  const configured = opsRows({ clientId: 812 });
  assert.equal(opsSource(configured, { clientIds: [812] }).opsTestExecutionCount, 2);
  for (const symbol of ["SXR8", "TSLA"]) {
    const rows = opsRows().map(row => ({ ...row, contract: { ...row.contract, symbol } }));
    const source = opsSource(rows);
    assert.equal(source.opsTestExecutionCount, 0);
    assert.deepEqual(executorClientCounts(rows, source), []);
    assert.equal(inventoryActivity(rows, source).cause, undefined);
  }
});

for (const time of ["2026-02-30T10:00:00Z", "2025-02-29T10:00:00Z", "2026-04-31T10:00:00Z",
  "2026-10-19T24:00:00Z", "2026-02-30T10:00:00+02:00", "2026-10-19T24:00:00+02:00",
  "20260230 10:00:00 US/Eastern", "20250229 10:00:00 US/Eastern", "20260431 10:00:00 US/Eastern",
  "20261019 24:00:00 US/Eastern", "20261101 01:30:00 US/Eastern", "20260308 02:30:00 US/Eastern", "not-a-time"]) {
  test(`non-round-tripping OPS time ${time} stays intent_unmatched`, () => {
    const rows = opsRows({ time });
    const source = opsSource(rows);
    assert.equal(source.opsTestExecutionCount, 0);
    rows.forEach(row => assert.throws(() => source.attribute(row.execution), /intent_unmatched/));
  });
}

for (const time of ["2026-10-19T16:00:00.123+02:00", "2026-10-19T09:00:00-05:00", "2024-02-29T10:00:00Z"]) {
  test(`real civil OPS time ${time} round-trips including explicit ISO offsets`, () => {
    const rows = opsRows({ time });
    assert.equal(opsSource(rows).opsTestExecutionCount, 2);
  });
}

test("snapshot corrections and duplicate replays cannot manufacture a flat OPS-test set", () => {
  const rows = opsRows();
  const correction = structuredClone(rows[1]);
  correction.execution.execId = "ops.1.02";
  correction.execution.shares = 3;
  const source = opsSource([...rows, rows[0], correction]);
  assert.equal(source.opsTestExecutionCount, 0);
  assert.throws(() => source.attribute(rows[0].execution), /ops_test_not_flat/);
  assert.equal(opsSource([...rows, rows[0], rows[1]]).opsTestExecutionCount, 2);
});
