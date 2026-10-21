import fs from "node:fs";
import { executionTime } from "./execution-history.mjs";
import { familyInstrument, familySignedQuantity, normalizeFamilyQuantity, mergeExecutionRecords } from "./family-ledger.mjs";

export const EXECUTOR_CLIENT_IDS = Object.freeze([700, 705]);
export const EXECUTOR_ATTRIBUTION_METHOD = "exactly-one-executor-intent-client-order-v1";
export const EXECUTOR_DESK_ROLLUP = Object.freeze({ j: "j", j2: "j", j5: "j", joe: "joe", joel: "joel" });
export const EXECUTOR_LEDGER_PATH = "/var/lib/paper-desk-executor/ledger.json";
const MAX_LEDGER_BYTES = 16 * 1024 * 1024;
const positiveId = value => Number.isSafeInteger(value) && value > 0;
const dictionary = value => value && typeof value === "object" && !Array.isArray(value);
const keep = new Set(["SXR8", "TSLA"]);

// Case-sensitive, whole pipe-delimited token: ops-test or ops-test-<lowercase
// alphanumeric segments>. No substring, whitespace, case or desk inference.
const opsTestMarker = value => typeof value === "string" &&
  value.split("|").some(token => /^ops-test(?:-[a-z0-9]+)*$/.test(token));

// executionTime round-trips IANA civil times, but its ISO fast path permits
// Date.parse rollover. Check the original civil fields in the stated offset too.
// This stricter check gates only the OPS-test exception and diagnostic clocks.
export function validatedExecutionTime(value) {
  try {
    const time = executionTime(value);
    const source = value.trim();
    if (!/^\d{4}-\d{2}-\d{2}T/.test(source)) return time;
    const match = source.match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?(Z|([+-])(\d{2}):(\d{2}))$/);
    if (!match) return null;
    const [, year, month, day, hour, minute, second, fraction, zone, sign, oh, om] = match;
    const offsetHour = Number(oh || 0), offsetMinute = Number(om || 0);
    if (offsetHour > 14 || offsetMinute > 59 || (offsetHour === 14 && offsetMinute !== 0)) return null;
    const offset = zone === "Z" ? 0 : (sign === "+" ? 1 : -1) * (offsetHour * 60 + offsetMinute);
    const civil = new Date(Date.parse(time) + offset * 60_000);
    const expected = [year, month, day, hour, minute, second, (fraction || "").padEnd(3, "0")].map(Number);
    const actual = [civil.getUTCFullYear(), civil.getUTCMonth() + 1, civil.getUTCDate(), civil.getUTCHours(),
      civil.getUTCMinutes(), civil.getUTCSeconds(), civil.getUTCMilliseconds()];
    return actual.every((part, index) => part === expected[index]) ? time : null;
  } catch { return null; }
}

function unclaimed(execution, cause) {
  const client = execution?.clientId;
  const error = new Error(`execution client ${Number.isSafeInteger(client) ? client : "unknown"} is unclaimed by executor intent ledger (${cause})`);
  error.executorCause = cause;
  throw error;
}

function economicIdentity(execution) {
  const time = validatedExecutionTime(execution?.time);
  if (!time || typeof execution?.acctNumber !== "string" || !Number.isFinite(execution.price)) return null;
  try { return JSON.stringify([execution.acctNumber, time, familySignedQuantity(execution), execution.price]); }
  catch { return null; }
}

export function isExecutorClient(clientId, attribution) {
  return (attribution?.clientIds ?? EXECUTOR_CLIENT_IDS).includes(clientId);
}

export function executorDesk(execution, attribution) {
  return executorExecution(execution, attribution).desk;
}

// Internal copy only: broker captures and the rev 9 contract keep their shape.
export function executorExecution(execution, attribution) {
  if (!attribution) throw new Error("executor intent ledger is unavailable");
  return attribution.attribute(execution);
}

// The index holds broker keys, never orderRef prefixes or inferred desk names.
// A bracket's two legs belong to one intent; duplicate keys in different intents
// remain ambiguous even when their desk is identical.
export function createExecutorAttribution({ ledger, account, clientIds = EXECUTOR_CLIENT_IDS, executionRows = [],
  onEvent = event => console.warn(JSON.stringify(event)) } = {}) {
  if (!Array.isArray(clientIds) || !clientIds.length || clientIds.some(id => !positiveId(id))) {
    throw new Error("executor client configuration is invalid");
  }
  clientIds = [...new Set(clientIds)].sort((a, b) => a - b);
  const orders = new Map();
  const executions = new Map();
  const available = typeof account === "string" && !!account && ledger?.schema === "barta.paper-desk-executor-state.v1"
    && ledger.account === account && dictionary(ledger.intents) && Array.isArray(ledger.executions);
  const add = (clientId, orderId, intentId, record) => {
    if (!clientIds.includes(clientId) || !positiveId(orderId)) return;
    const key = `${clientId}:${orderId}`;
    if (!orders.has(key)) orders.set(key, new Map());
    orders.get(key).set(intentId, record);
  };
  if (available) {
    for (const [intentId, record] of Object.entries(ledger.intents)) {
      if (!dictionary(record)) continue;
      if (record.action === "place") {
        const bracket = record.result?.bracket;
        add(bracket?.clientId, bracket?.parentOrderId, intentId, record);
        add(bracket?.clientId, bracket?.stopOrderId, intentId, record);
      }
      if (record.action === "flatten" && Array.isArray(record.result?.flattened)) {
        for (const row of record.result.flattened) add(row?.clientId, row?.orderId, intentId, record);
      }
    }
    for (const row of ledger.executions) {
      const execution = row?.execution;
      if (execution?.acctNumber !== account || !clientIds.includes(execution?.clientId)
        || typeof execution.execId !== "string" || !positiveId(execution.orderId)) continue;
      const key = `${execution.clientId}:${execution.execId}`;
      if (!executions.has(key)) executions.set(key, new Set());
      executions.get(key).add(execution.orderId);
    }
  }
  const attributeIntent = execution => {
    const client = execution?.clientId;
    const fail = cause => unclaimed(execution, cause);
    if (!available) return fail("ledger_unavailable");
    if (!clientIds.includes(client) || (execution.acctNumber !== undefined && execution.acctNumber !== account)) return fail("identity_invalid");
    // Retained economic captures intentionally omit routing fields. Recover only
    // an exact execId/client/account identity from the executor's own executions.
    const known = executions.get(`${client}:${execution.execId}`);
    if (known?.size > 1 || (positiveId(execution.orderId) && known?.size === 1 && !known.has(execution.orderId))) return fail("identity_ambiguous");
    const orderId = positiveId(execution.orderId) ? execution.orderId : known?.size === 1 ? [...known][0] : null;
    if (!positiveId(orderId)) return fail("order_key_missing");
    const matches = orders.get(`${client}:${orderId}`);
    if (matches?.size !== 1) return fail(matches?.size > 1 ? "intent_ambiguous" : "intent_unmatched");
    const [record] = matches.values();
    if (typeof record.desk !== "string" || !Object.hasOwn(EXECUTOR_DESK_ROLLUP, record.desk)) {
      onEvent({ event: "executor_intent_desk_unclaimed", cause: "intent_desk_invalid",
        desk: typeof record.desk === "string" ? record.desk : null });
      return fail("intent_desk_invalid");
    }
    return { ...execution, desk: EXECUTOR_DESK_ROLLUP[record.desk], subDesk: record.desk };
  };
  // The complete family snapshot, not a per-desk/day subset, proves flatness.
  // Invalid/conflicting snapshots grant no exception. Corrections/replays use
  // the same latest-revision semantics as family valuation.
  let rows = [];
  try { rows = mergeExecutionRecords([], executionRows); } catch { /* fail closed */ }
  const candidates = new Map();
  const instruments = new Map();
  for (const row of rows) {
    const execution = row.execution;
    if (keep.has(String(row.contract?.symbol ?? "").trim().toUpperCase()) ||
        !clientIds.includes(execution.clientId) || execution.acctNumber !== account ||
        !opsTestMarker(execution.orderRef)) continue;
    try { attributeIntent(execution); continue; }
    catch (error) { if (error.executorCause !== "intent_unmatched") continue; }
    const identity = economicIdentity(execution);
    if (!identity) continue;
    try {
      const instrument = familyInstrument(row.contract);
      let group = instruments.get(instrument.key);
      if (!group) {
        group = { instrument, quantity: 0, valid: true };
        instruments.set(instrument.key, group);
      }
      if (group.instrument.symbol !== instrument.symbol || group.instrument.currency !== instrument.currency ||
          group.instrument.secType !== instrument.secType) group.valid = false;
      group.quantity = normalizeFamilyQuantity(group.quantity + familySignedQuantity(execution));
      if (!Number.isFinite(group.quantity)) group.valid = false;
      candidates.set(`${execution.clientId}:${execution.execId}`, { identity, orderId: execution.orderId, group });
    } catch { /* malformed candidates stay intent_unmatched */ }
  }
  const flat = group => group.valid && group.quantity === 0;
  const opsTestExecutionCount = [...candidates.values()].filter(candidate => flat(candidate.group)).length;
  const instrumentsNotFlat = [...instruments.values()].filter(group => !flat(group)).length;
  if (opsTestExecutionCount) onEvent({ event: "executor_ops_test", count: opsTestExecutionCount });
  const attribute = execution => {
    try { return attributeIntent(execution); }
    catch (error) {
      if (error.executorCause !== "intent_unmatched") throw error;
      const candidate = candidates.get(`${execution.clientId}:${execution.execId}`);
      if (!candidate || candidate.identity !== economicIdentity(execution) ||
          (positiveId(execution.orderId) && positiveId(candidate.orderId) && execution.orderId !== candidate.orderId)) throw error;
      if (!flat(candidate.group)) return unclaimed(execution, "ops_test_not_flat");
      return { ...execution, desk: null, cause: "ops_test" };
    }
  };
  const resolve = execution => attribute(execution).desk;
  return Object.freeze({ clientIds: Object.freeze(clientIds), resolve, attribute, opsTestExecutionCount, instrumentsNotFlat });
}

// The caller replaces this snapshot before valuation. Read failures expose a
// fixed cause only; the separate unknown-desk event names only the desk token.
export function readExecutorAttribution({ account, clientIds = EXECUTOR_CLIENT_IDS, file = EXECUTOR_LEDGER_PATH, executionRows, onEvent } = {}) {
  let handle;
  let ledger;
  try {
    handle = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const stat = fs.fstatSync(handle);
    if (!stat.isFile() || stat.size > MAX_LEDGER_BYTES) throw new Error("ledger_size");
    ledger = JSON.parse(fs.readFileSync(handle, "utf8"));
  } catch { ledger = null; }
  finally { if (handle !== undefined) fs.closeSync(handle); }
  return createExecutorAttribution({ ledger, account, clientIds, executionRows, onEvent });
}

export function executorClientCounts(rows, attribution) {
  const counts = new Map();
  for (const row of Array.isArray(rows) ? rows : []) {
    if (["SXR8", "TSLA"].includes(String(row?.contract?.symbol ?? "").toUpperCase()) || !isExecutorClient(row?.execution?.clientId, attribution)) continue;
    const client = row.execution.clientId;
    if (!counts.has(client)) counts.set(client, { client, matched: 0, unmatched: 0 });
    try {
      if (attribution.attribute(row.execution).cause === "ops_test") {
        counts.get(client).opsTest = (counts.get(client).opsTest || 0) + 1;
      } else counts.get(client).matched++;
    }
    catch { counts.get(client).unmatched++; }
  }
  return [...counts.values()].sort((a, b) => a.client - b.client);
}
