import { CURRENT_DESK_OWNERSHIP_POLICY } from "./desk-ledger.mjs";
import { executionTime } from "./execution-history.mjs";
import { executorDesk, isExecutorClient, executorClientCounts } from "./executor-attribution.mjs";

export const DESK_IDS = ["j", "joe", "joel"];
// Same bound as project.mjs and the family reader's fxFreshMs (five minutes).
export const ACTIVITY_FRESH_MS = 300_000;
export const DESK_ACTION = "Valuation is not exact yet.";
export const EXECUTION_CAUSES = ["executions_unavailable", "execution_day_mismatch", "execution_unowned", "execution_after_coverage"];
const KEEP = ["SXR8", "TSLA"];

// Mirrored verbatim from paper-desk-executor/policy.mjs; parity is tested
// against brakeUsage at NY midnight, DST transitions and weekends.
export function newYorkDay(epoch = Date.now()) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/New_York",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date(epoch));
  const found = Object.fromEntries(parts.filter((part) => part.type !== "literal").map((part) => [part.type, part.value]));
  return `${found.year}-${found.month}-${found.day}`;
}

function owner(clientId, at, execution, executorAttribution) {
  if (isExecutorClient(clientId, executorAttribution)) {
    try { return executorDesk(execution, executorAttribution); }
    catch { return null; }
  }
  const matches = CURRENT_DESK_OWNERSHIP_POLICY.assignments.filter(rule => rule.clientId === clientId
    && Date.parse(rule.fromInclusive) <= at && (rule.toExclusive === null || at < Date.parse(rule.toExclusive)));
  return matches.length === 1 ? matches[0].desk : null;
}

// Called on completed execution replies, outside the publication/handoff path.
// The dated ownership policy is the same one used by the existing desk reader.
// An unclaimed client cannot prove absence for any desk; never infer orderRef ownership.
export function executionActivity(state, executorAttribution = null) {
  const counts = executorClientCounts(state?.executions, executorAttribution);
  const diagnostics = counts.length ? { executorClients: counts } : {};
  const at = Date.parse(state?.coverageThrough);
  if (!Number.isFinite(at) || !Array.isArray(state?.executions)) return { cause: "executions_unavailable" };
  if (state.coverageTradingDay !== newYorkDay(at)) return { cause: "execution_day_mismatch" };
  const latest = Object.fromEntries(DESK_IDS.map(id => [id, null]));
  const latestEpoch = Object.fromEntries(DESK_IDS.map(id => [id, -Infinity]));
  for (const row of state.executions) {
    if (KEEP.includes(row?.contract?.symbol)) continue;
    let time;
    try { time = executionTime(row?.execution?.time); }
    catch { return { cause: "executions_unavailable" }; }
    const epoch = Date.parse(time);
    if (!Number.isFinite(epoch)) return { cause: "executions_unavailable" };
    if (epoch > at) return { cause: "execution_after_coverage" };
    if (epoch < at - 26 * 60 * 60 * 1000 || newYorkDay(epoch) !== state.coverageTradingDay) continue;
    const desk = owner(row.execution.clientId, epoch, row.execution, executorAttribution);
    if (!desk) return { cause: "execution_unowned",
      ...diagnostics,
      ...(Number.isSafeInteger(row.execution.clientId) && row.execution.clientId >= 0 ? { clientId: row.execution.clientId } : {}) };
    if (epoch > latestEpoch[desk]) {
      latestEpoch[desk] = epoch;
      latest[desk] = time;
    }
  }
  return { observedAt: state.coverageThrough, day: state.coverageTradingDay, latest, ...diagnostics };
}

// No ledger traversal: only the existing bounded broker/desk rows and the
// precomputed execution summary. The worker rechecks ages at staging receipt.
export function copyDeskActivity({ book, family, deskEquities, executions, executorAttribution } = {}) {
  const result = {};
  const positionsKnown = deskEquities?.ok && DESK_IDS.every(id => Array.isArray(deskEquities.desks?.[id]?.positions));
  let ordersKnown = Array.isArray(book?.openOrders) && book.openOrders.length <= 256 && typeof book.ordersObservedAt === "string";
  const orders = Object.fromEntries(DESK_IDS.map(id => [id, false]));
  if (ordersKnown) for (const row of book.openOrders) {
    if (KEEP.includes(row.symbol) || ["filled", "cancelled", "inactive", "apicancelled"].includes(String(row.status).toLowerCase())) continue;
    const desk = owner(row.clientId, Date.parse(book.ordersObservedAt), row, executorAttribution);
    if (!desk) { ordersKnown = false; break; }
    orders[desk] = true;
  }
  for (const id of DESK_IDS) {
    const known = positionsKnown || (id === "j" && family?.ok && Array.isArray(family.positions));
    result[id] = {
      positionsAt: known && book?.gateway === true && book.positionsCoverage?.status === "complete"
        ? (positionsKnown ? deskEquities.oldestSourceObservedAt : family.observedAt) ?? book.ts : null,
      hasPositions: known ? (positionsKnown ? deskEquities.desks[id].positions : family.positions).length > 0 : false,
      ordersAt: ordersKnown && book?.gateway === true ? book.ordersObservedAt : null,
      hasOrders: ordersKnown ? orders[id] : false,
      executionsAt: executions?.observedAt ?? null,
      executionDay: executions?.day ?? null,
      lastExecutionAt: executions?.latest?.[id] ?? null,
      ...(EXECUTION_CAUSES.includes(executions?.cause) ? { executionCause: {
        cause: executions.cause,
        ...(executions.cause === "execution_unowned" && Number.isSafeInteger(executions.clientId) && executions.clientId >= 0
          ? { clientId: executions.clientId } : {}),
      } } : {}),
    };
  }
  return result;
}

export function deskState(evidence, generatedAt, receivedAt) {
  const epoch = Date.parse(receivedAt);
  const fresh = value => {
    const at = Date.parse(value);
    return Number.isFinite(at) && at <= epoch && epoch - at <= ACTIVITY_FRESH_MS
      && at <= Date.parse(generatedAt) && Date.parse(generatedAt) - at <= ACTIVITY_FRESH_MS;
  };
  if (!evidence || ![evidence.positionsAt, evidence.ordersAt, evidence.executionsAt].every(fresh)
    || evidence.executionDay !== newYorkDay(epoch)
    || evidence.executionDay !== newYorkDay(Date.parse(evidence.executionsAt))) return "stuck";
  if (evidence.lastExecutionAt !== null && (!Number.isFinite(Date.parse(evidence.lastExecutionAt))
    || Date.parse(evidence.lastExecutionAt) > Date.parse(evidence.executionsAt))) return "stuck";
  return evidence.hasPositions || evidence.hasOrders || (evidence.lastExecutionAt !== null
    && newYorkDay(Date.parse(evidence.lastExecutionAt)) === newYorkDay(epoch)) ? "working" : "sit-out";
}

// Diagnostics describe the existing decision; they never participate in it.
// Missing/invalid clocks are unavailable, while old or future clocks are stale.
export function deskStateDetails(evidence, generatedAt, receivedAt) {
  const state = deskState(evidence, generatedAt, receivedAt);
  if (state !== "stuck") return { state, cause: null };
  const stuck = cause => ({ state, cause });
  for (const [reader, field] of [["positions", "positionsAt"], ["orders", "ordersAt"], ["executions", "executionsAt"]]) {
    const at = Date.parse(evidence?.[field]);
    if (!Number.isFinite(at)) {
      const failure = evidence?.executionCause;
      if (reader === "executions" && EXECUTION_CAUSES.includes(failure?.cause)) return {
        ...stuck(failure.cause),
        ...(failure.cause === "execution_unowned" && Number.isSafeInteger(failure.clientId) && failure.clientId >= 0
          ? { client: failure.clientId } : {}),
      };
      return stuck(`${reader}_unavailable`);
    }
    if ([generatedAt, receivedAt].some(time => {
      const age = Date.parse(time) - at;
      return !Number.isFinite(age) || age < 0 || age > ACTIVITY_FRESH_MS;
    })) return stuck(`${reader}_stale`);
  }
  const epoch = Date.parse(receivedAt);
  if (evidence.executionDay !== newYorkDay(epoch)
    || evidence.executionDay !== newYorkDay(Date.parse(evidence.executionsAt))) return stuck("execution_day_mismatch");
  return stuck(Number.isFinite(Date.parse(evidence.lastExecutionAt)) ? "execution_after_coverage" : "executions_unavailable");
}

// One bounded entry per desk. A changed client alone does not repeat the event.
// Called by the pusher after its v1 request settles, independently of IPC credit.
export function createDeskStateReporter({ onEvent = event => console.log(JSON.stringify(event)) } = {}) {
  const previous = new Map();
  return (observation, receivedAt) => {
    const activity = copyDeskActivity(observation);
    for (const desk of DESK_IDS) {
      const details = deskStateDetails(activity[desk], observation.book?.ts, receivedAt);
      const key = JSON.stringify([details.state, details.cause]);
      if (previous.get(desk) === key) continue;
      const counts = observation.deskEquities?.executorClients ?? observation.executions?.executorClients;
      onEvent({ event: "v2_desk_state", desk, ...details, ...(counts?.length ? { executorClients: counts } : {}) });
      previous.set(desk, key);
    }
  };
}
