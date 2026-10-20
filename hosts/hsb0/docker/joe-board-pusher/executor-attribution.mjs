import fs from "node:fs";

export const EXECUTOR_CLIENT_IDS = Object.freeze([700, 705]);
export const EXECUTOR_ATTRIBUTION_METHOD = "exactly-one-executor-intent-client-order-v1";
export const EXECUTOR_LEDGER_PATH = "/var/lib/paper-desk-executor/ledger.json";
const MAX_LEDGER_BYTES = 16 * 1024 * 1024;
const DESKS = ["j", "joe", "joel"];
const positiveId = value => Number.isSafeInteger(value) && value > 0;
const dictionary = value => value && typeof value === "object" && !Array.isArray(value);

export function isExecutorClient(clientId, attribution) {
  return (attribution?.clientIds ?? EXECUTOR_CLIENT_IDS).includes(clientId);
}

export function executorDesk(execution, attribution) {
  if (!attribution) throw new Error("executor intent ledger is unavailable");
  return attribution.resolve(execution);
}

// The index holds broker keys, never orderRef prefixes or inferred desk names.
// A bracket's two legs belong to one intent; duplicate keys in different intents
// remain ambiguous even when their desk is identical.
export function createExecutorAttribution({ ledger, account, clientIds = EXECUTOR_CLIENT_IDS } = {}) {
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
  const resolve = execution => {
    const client = execution?.clientId;
    const fail = cause => {
      const error = new Error(`execution client ${Number.isSafeInteger(client) ? client : "unknown"} is unclaimed by executor intent ledger (${cause})`);
      error.executorCause = cause;
      throw error;
    };
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
    if (!DESKS.includes(record.desk)) return fail("intent_desk_invalid");
    return record.desk;
  };
  return Object.freeze({ clientIds: Object.freeze(clientIds), resolve });
}

// The caller replaces this snapshot before valuation. Read errors expose a
// fixed cause only; neither filesystem errors nor ledger data reach diagnostics.
export function readExecutorAttribution({ account, clientIds = EXECUTOR_CLIENT_IDS, file = EXECUTOR_LEDGER_PATH } = {}) {
  let handle;
  let ledger;
  try {
    handle = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const stat = fs.fstatSync(handle);
    if (!stat.isFile() || stat.size > MAX_LEDGER_BYTES) throw new Error("ledger_size");
    ledger = JSON.parse(fs.readFileSync(handle, "utf8"));
  } catch { ledger = null; }
  finally { if (handle !== undefined) fs.closeSync(handle); }
  return createExecutorAttribution({ ledger, account, clientIds });
}

export function executorClientCounts(rows, attribution) {
  const counts = new Map();
  for (const row of Array.isArray(rows) ? rows : []) {
    if (["SXR8", "TSLA"].includes(String(row?.contract?.symbol ?? "").toUpperCase()) || !isExecutorClient(row?.execution?.clientId, attribution)) continue;
    const client = row.execution.clientId;
    if (!counts.has(client)) counts.set(client, { client, matched: 0, unmatched: 0 });
    try { attribution.resolve(row.execution); counts.get(client).matched++; }
    catch { counts.get(client).unmatched++; }
  }
  return [...counts.values()].sort((a, b) => a.client - b.client);
}
