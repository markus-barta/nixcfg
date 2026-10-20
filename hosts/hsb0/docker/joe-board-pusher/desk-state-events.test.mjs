import assert from "node:assert/strict";
import test from "node:test";
import { copyDeskActivity, createDeskStateReporter, deskState, deskStateDetails, executionActivity } from "./desk-activity.mjs";
import { copyObservation } from "./v2-stage-handoff.mjs";
import { buildCandidate, validObservation } from "./v2-stage-worker.mjs";
import { validateContract } from "./contracts/index.mjs";
import { runPusher } from "./fixtures/pusher-harness.mjs";

const instant = "2026-10-19T15:00:00.000Z";
const old = "2026-10-19T14:54:59.999Z";
const future = "2026-10-19T15:00:00.001Z";
const execution = (clientId = 22, time = instant) => ({ contract: { symbol: "SYNTH" }, execution: { clientId, time } });
const completed = (executions = []) => ({ coverageThrough: instant, coverageTradingDay: "2026-10-19", executions });
function source() {
  return {
    book: { ts: instant, gateway: true, positions: [], positionsCoverage: { status: "complete" }, openOrders: [], ordersObservedAt: instant },
    deskEquities: { ok: true, oldestSourceObservedAt: instant,
      desks: Object.fromEntries(["j", "joe", "joel"].map(id => [id, { positions: [] }])) },
    executions: executionActivity(completed()),
  };
}

for (const [label, input, expected] of [
  ["missing state", undefined, { cause: "executions_unavailable" }],
  ["missing coverage", { ...completed(), coverageThrough: null }, { cause: "executions_unavailable" }],
  ["invalid coverage", { ...completed(), coverageThrough: "invalid" }, { cause: "executions_unavailable" }],
  ["missing rows", { ...completed(), executions: null }, { cause: "executions_unavailable" }],
  ["wrong coverage day", { ...completed(), coverageTradingDay: "2026-10-18" }, { cause: "execution_day_mismatch" }],
  ["invalid execution time", completed([execution(22, "invalid")]), { cause: "executions_unavailable" }],
  ["missing execution row", completed([null]), { cause: "executions_unavailable" }],
  ["execution after coverage", completed([execution(22, future)]), { cause: "execution_after_coverage" }],
  ["unclaimed client", completed([execution(230)]), { cause: "execution_unowned", clientId: 230 }],
  ["non-numeric unclaimed client", completed([execution("private-identity")]), { cause: "execution_unowned" }],
]) test(`execution summary cause: ${label}`, () => {
  assert.deepEqual(executionActivity(input), expected);
});

test("KEEP and prior-day executions retain their existing exclusion rules", () => {
  const keep = { contract: { symbol: "TSLA" }, execution: { clientId: 230, time: future } };
  const summary = executionActivity(completed([keep, execution(230, "2026-10-18T15:00:00.000Z")]));
  assert.deepEqual(summary, { observedAt: instant, day: "2026-10-19", latest: { j: null, joe: null, joel: null } });
});

const cases = [
  ["positions_unavailable", s => { s.deskEquities = { ok: false, reason: "execution client 230 is unclaimed by the desk ownership policy" }; }],
  ["positions_stale", s => { s.deskEquities.oldestSourceObservedAt = old; }],
  ["orders_unavailable", s => { s.book.openOrders = null; }],
  ["orders_stale", s => { s.book.ordersObservedAt = old; }],
  ["executions_unavailable", s => { s.executions = executionActivity(undefined); }],
  ["executions_stale", s => { s.executions.observedAt = old; }],
  ["execution_day_mismatch", s => { s.executions = executionActivity({ ...completed(), coverageTradingDay: "2026-10-18" }); }],
  ["execution_unowned", s => { s.executions = executionActivity(completed([execution(230)])); }, { client: 230 }],
  ["execution_after_coverage", s => { s.executions = executionActivity(completed([execution(22, future)])); }],
];
for (const [cause, change, extra = {}] of cases) test(`${cause} emits once per desk until state or cause changes, with a closed event shape`, () => {
  const observation = source(); change(observation);
  const events = [];
  const report = createDeskStateReporter({ onEvent: event => events.push(event) });
  report(observation, instant); report(observation, instant);
  assert.deepEqual(events, ["j", "joe", "joel"].map(desk => ({ event: "v2_desk_state", desk, state: "stuck", cause, ...extra })));
  const frame = copyObservation(observation);
  assert.equal(validObservation(frame), true);
  const candidate = buildCandidate(1, instant, frame);
  assert.equal(validateContract("data", candidate, { stage: "ingress" }).ok, true);
  for (const row of candidate.desks) {
    assert.equal(row.state, "stuck");
    assert.deepEqual(Object.keys(row).sort(), ["action", "id", "label", "money", "state"]);
  }
  report(source(), instant); report(source(), instant);
  assert.deepEqual(events.slice(3), ["j", "joe", "joel"].map(desk => ({ event: "v2_desk_state", desk, state: "sit-out", cause: null })));
  report(observation, instant); report(observation, instant);
  assert.equal(events.length, 9);
  assert.deepEqual(events.slice(6), events.slice(0, 3));
});

test("cause changes while stuck emit; changed client IDs or timestamps alone do not", () => {
  const events = [], observation = source();
  const report = createDeskStateReporter({ onEvent: event => events.push(event) });
  observation.executions = executionActivity(completed([execution(230)]));
  report(observation, instant);
  observation.executions = executionActivity(completed([execution(999)]));
  observation.book.ts = future;
  report(observation, future);
  assert.equal(events.length, 3);
  observation.executions = { cause: "executions_unavailable" };
  report(observation, future); report(observation, future);
  assert.equal(events.length, 6);
  assert.ok(events.slice(3).every(event => event.cause === "executions_unavailable" && !Object.hasOwn(event, "client")));
});

test("healthy working/sit-out transitions emit only for the changed desk", () => {
  const events = [], observation = source();
  const report = createDeskStateReporter({ onEvent: event => events.push(event) });
  report(observation, instant);
  observation.executions = executionActivity(completed([execution()]));
  report(observation, instant); report(observation, instant);
  assert.equal(events.length, 4);
  assert.deepEqual(events[3], { event: "v2_desk_state", desk: "joe", state: "working", cause: null });
  observation.executions = executionActivity(completed());
  report(observation, instant); report(observation, instant);
  assert.equal(events.length, 5);
  assert.deepEqual(events[4], { event: "v2_desk_state", desk: "joe", state: "sit-out", cause: null });
});

test("client 229 produces J working diagnostics from executions and from fallback orders", () => {
  const observation = source();
  const events = [];
  const report = createDeskStateReporter({ onEvent: event => events.push(event) });
  observation.executions = executionActivity(completed([execution(229)]));
  report(observation, instant);
  assert.deepEqual(events[0], { event: "v2_desk_state", desk: "j", state: "working", cause: null });
  observation.executions = executionActivity(completed());
  observation.book.openOrders = [{ symbol: "SYNTH", clientId: 229, status: "Submitted" }];
  report(observation, instant);
  assert.equal(events.length, 3, "fallback orders keep J working without repeating its diagnostic");
  assert.equal(copyDeskActivity(observation).j.hasOrders, true);
});

test("positions failures retain J family fallback and stable reader precedence", () => {
  const observation = source();
  observation.deskEquities = { ok: false, reason: "arbitrary private reader reason" };
  observation.family = { ok: true, observedAt: instant, positions: [] };
  observation.executions = executionActivity(completed([execution(230)]));
  const activity = copyDeskActivity(observation);
  assert.deepEqual(deskStateDetails(activity.j, instant, instant), { state: "stuck", cause: "execution_unowned", client: 230 });
  assert.deepEqual(deskStateDetails(activity.joe, instant, instant), { state: "stuck", cause: "positions_unavailable" });
  observation.book.openOrders = [{ symbol: "SYNTH", clientId: 230 }];
  assert.equal(deskStateDetails(copyDeskActivity(observation).j, instant, instant).cause, "orders_unavailable");
});

test("diagnostic details preserve deskState decisions at generation/receipt bounds and day rollover", () => {
  const base = copyDeskActivity(source()).joe;
  for (const field of ["positionsAt", "ordersAt", "executionsAt"]) for (const at of [null, "invalid", old, future, instant, "2026-10-19T14:55:00.000Z"]) {
    const row = { ...base, [field]: at };
    for (const receivedAt of [instant, future, "2026-10-20T04:00:00.000Z"]) {
      assert.equal(deskStateDetails(row, instant, receivedAt).state, deskState(row, instant, receivedAt));
    }
  }
  for (const [change, cause] of [
    [{ lastExecutionAt: future }, "execution_after_coverage"],
    [{ lastExecutionAt: "invalid" }, "executions_unavailable"],
    [{ executionDay: "2026-10-18" }, "execution_day_mismatch"],
  ]) assert.deepEqual(deskStateDetails({ ...base, ...change }, instant, instant), { state: "stuck", cause });
  for (const field of ["positionsAt", "ordersAt", "executionsAt"]) {
    assert.equal(deskStateDetails({ ...base, [field]: future }, instant, instant).cause, `${field.slice(0, -2)}_stale`);
  }
});

test("private handoff cause validation rejects arbitrary data; old frames remain valid", () => {
  const frame = copyObservation(source());
  assert.equal(validObservation(frame), true);
  for (const executionCause of [null, { cause: "private-value" }, { cause: "execution_unowned", clientId: "230" },
    { cause: "execution_unowned", clientId: -1 }, { cause: "execution_unowned", clientId: 1.5 },
    { cause: "execution_unowned", clientId: 230, symbol: "PRIVATE" }, { cause: "executions_unavailable", clientId: 230 }]) {
    frame.deskActivity.j.executionCause = executionCause;
    assert.equal(validObservation(frame), false);
  }
});

for (const stageState of ["idle", "busy", "throw"]) test(`actual pusher stdout suppresses repeated desk events with ${stageState} IPC`, async () => {
  const result = await runPusher(new URL("./pusher.mjs", import.meta.url), { stageState, cycles: 3 });
  assert.deepEqual(result.deskEvents, ["j", "joe", "joel"].map(desk => ({ event: "v2_desk_state", desk, state: "stuck", cause: "positions_unavailable" })));
  assert.equal(result.requests.length, 3);
});

test("v1 rejection still emits diagnostic events after settlement", async () => {
  const result = await runPusher(new URL("./pusher.mjs", import.meta.url), { fetchError: { synthetic: "rejection" }, cycles: 2 });
  assert.equal(result.deskEvents.length, 3);
  assert.equal(result.errorIdentityPreserved, true);
  assert.equal(result.observations.length, 2);
});
