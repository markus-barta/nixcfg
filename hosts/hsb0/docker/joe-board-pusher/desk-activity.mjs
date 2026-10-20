import { CURRENT_DESK_OWNERSHIP_POLICY } from "./desk-ledger.mjs";

export const DESK_IDS = ["j", "joe", "joel"];
// Same bound as project.mjs and the family reader's fxFreshMs (five minutes).
export const ACTIVITY_FRESH_MS = 300_000;
export const DESK_ACTION = "Valuation is not exact yet.";
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

function owner(clientId, time) {
  const matches = CURRENT_DESK_OWNERSHIP_POLICY.assignments.filter(rule => rule.clientId === clientId
    && rule.fromInclusive <= time && (rule.toExclusive === null || time < rule.toExclusive));
  return matches.length === 1 ? matches[0].desk : null;
}

// Called on completed execution replies, outside the publication/handoff path.
// The dated ownership policy is the same one used by the existing desk reader.
// An unclaimed client cannot prove absence for any desk; never infer orderRef ownership.
export function executionActivity(state) {
  const at = Date.parse(state?.coverageThrough);
  if (!Number.isFinite(at) || !Array.isArray(state?.executions)
    || state.coverageTradingDay !== newYorkDay(at)) return null;
  const latest = Object.fromEntries(DESK_IDS.map(id => [id, null]));
  for (const row of state.executions) {
    if (KEEP.includes(row.contract?.symbol)) continue;
    const time = row.execution?.time;
    const epoch = Date.parse(time);
    if (!Number.isFinite(epoch) || epoch > at) return null;
    if (epoch < at - 26 * 60 * 60 * 1000 || newYorkDay(epoch) !== state.coverageTradingDay) continue;
    const desk = owner(row.execution.clientId, time);
    if (!desk) return null;
    if (!latest[desk] || time > latest[desk]) latest[desk] = time;
  }
  return { observedAt: state.coverageThrough, day: state.coverageTradingDay, latest };
}

// No ledger traversal: only the existing bounded broker/desk rows and the
// precomputed execution summary. The worker rechecks ages at staging receipt.
export function copyDeskActivity({ book, family, deskEquities, executions } = {}) {
  const result = {};
  const positionsKnown = deskEquities?.ok && DESK_IDS.every(id => Array.isArray(deskEquities.desks?.[id]?.positions));
  let ordersKnown = Array.isArray(book?.openOrders) && book.openOrders.length <= 256 && typeof book.ordersObservedAt === "string";
  const orders = Object.fromEntries(DESK_IDS.map(id => [id, false]));
  if (ordersKnown) for (const row of book.openOrders) {
    if (KEEP.includes(row.symbol) || ["filled", "cancelled", "inactive", "apicancelled"].includes(String(row.status).toLowerCase())) continue;
    const desk = owner(row.clientId, book.ordersObservedAt);
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
