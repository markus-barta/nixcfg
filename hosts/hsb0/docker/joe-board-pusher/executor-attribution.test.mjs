import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { createExecutorAttribution, executorClientCounts, readExecutorAttribution } from "./executor-attribution.mjs";
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
const attribution = (intents, executions, clientIds) => createExecutorAttribution({ ledger: ledger(intents, executions), account, clientIds });

for (const desk of ["j", "joe", "joel"]) test(`705 uses exactly one intent desk ${desk}, ignoring every orderRef prefix`, () => {
  const source = attribution({ "masked-intent": bracket(desk) });
  for (const orderRef of ["j2|masked", "j5|masked", "joe|masked", "joel|masked", "unrecognized"]) {
    assert.equal(source.resolve(execution({ orderRef })), desk);
    assert.equal(source.resolve(execution({ orderId: 102, orderRef })), desk);
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

test("zero, duplicate, same-desk duplicate and unauthorized desk matches all fail closed", () => {
  assert.throws(() => attribution({}).resolve(execution({ orderRef: "j|masked" })), /intent_unmatched/);
  for (const desk of ["j", "joe"]) assert.throws(() => attribution({ first: bracket(), second: bracket(desk) }).resolve(execution()), /intent_ambiguous/);
  for (const desk of ["j2", "j5", "J", "unknown", null]) assert.throws(() => attribution({ only: bracket(desk) }).resolve(execution()), /intent_desk_invalid/);
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
