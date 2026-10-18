import { randomUUID } from "node:crypto";
import { ACCOUNT, EXECUTOR_CLIENT_IDS, FOREIGN_ALERT_SINCE, KEEP, activityAttribution, executionTimeMs, mergeExecutions, validateKey } from "./policy.mjs";
import { deskPositions, pnlPerDesk } from "./ib.mjs";

export function attributionConfig(config = {}) {
  const clientIds = config.clientIds || JSON.parse(process.env.IB_DESK_CLIENT_IDS || '{"recon":700,"executor":705}');
  const foreignAlertSince = config.foreignAlertSince ?? process.env.PAPER_DESK_FOREIGN_ALERT_SINCE ?? FOREIGN_ALERT_SINCE;
  const foreignAlertRetentionDays = config.foreignAlertRetentionDays ?? Number(process.env.PAPER_DESK_FOREIGN_ALERT_RETENTION_DAYS || 14);
  if (typeof foreignAlertSince !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?Z$/.test(foreignAlertSince) || !Number.isFinite(Date.parse(foreignAlertSince))) throw new Error("foreign alert cutover must be a UTC timestamp");
  if (!Number.isSafeInteger(foreignAlertRetentionDays) || foreignAlertRetentionDays <= 0) throw new Error("foreign alert retention must be positive days");
  return {
    executorClientId: config.executorClientId ?? clientIds.executor,
    ownClientIds: config.ownClientIds || [...new Set([...EXECUTOR_CLIENT_IDS, ...Object.values(clientIds)])],
    ownership: config.ownership || JSON.parse(process.env.IB_DESK_OWNERSHIP_CLIENT_IDS || "{}"),
    foreignAlertSince,
    foreignAlertRetentionDays,
  };
}

export function attributeExecutions(rows, config, journal = []) {
  const assignments = new Map(journal.map((entry) => [entry.execId, entry]));
  return mergeExecutions(rows).map((row) => {
    const entry = assignments.get(row.execution.execId);
    const raw = { ...row, attribution: undefined };
    const automatic = activityAttribution(raw, config);
    return { ...row, attribution: entry
      ? { ...automatic, desk: entry.disposition === "external" ? null : validateKey(entry.to, "desk"), method: entry.disposition === "external" ? "external" : "admin", needsAttribution: false, journalId: entry.id }
      : automatic };
  });
}

export function foreignPositions(executions, config) {
  const holdings = new Map();
  for (const row of mergeExecutions(executions)) {
    const attributed = activityAttribution(row, config);
    if (row.execution.acctNumber !== ACCOUNT || !attributed.foreign || attributed.method === "admin") continue;
    const { contract, execution } = row;
    const key = `${contract.conId}:${contract.symbol}:${contract.currency}`;
    const holding = holdings.get(key) || { conId: Number(contract.conId), symbol: contract.symbol, currency: contract.currency, quantity: 0, foreign: true, needsAttribution: attributed.needsAttribution, keep: attributed.keep, execIds: [] };
    holding.needsAttribution ||= attributed.needsAttribution;
    const side = { BOT: 1, BUY: 1, SLD: -1, SELL: -1 }[String(execution.side).toUpperCase()];
    const shares = Number(execution.shares);
    holding.quantity = holding.quantity !== null && side && Number.isFinite(shares) && shares > 0 ? holding.quantity + side * shares : null;
    holding.execIds.push(execution.execId);
    holdings.set(key, holding);
  }
  return [...holdings.values()];
}

export function pruneForeignAlerts(state, retentionDays = Number(process.env.PAPER_DESK_FOREIGN_ALERT_RETENTION_DAYS || 14), now = Date.now()) {
  if (!Number.isSafeInteger(retentionDays) || retentionDays <= 0) throw new Error("foreign alert retention must be positive days");
  if (!state.foreignAlerts) return;
  state.foreignAlerts = state.foreignAlerts.filter((row) => now - Date.parse(row.lastSeenAt || row.at) <= retentionDays * 86400000);
}

export function reconcileAttribution(state, config, context = {}) {
  state.executions = attributeExecutions(state.executions, config, state.attributionJournal);
  state.foreignPositions = foreignPositions(state.executions, config);
  const now = (context.now || Date.now)(), at = new Date(now).toISOString();
  const previous = { executions: state.executions, receipts: state.foreignAlerts, backlog: state.foreignAlertBacklog };
  const receiptKey = (row) => row.key || (row.execId ? `execution:${row.execId}` : null);
  const receipts = new Map((state.foreignAlerts || []).map((row) => [receiptKey(row), { ...row }]));
  const added = [], timeCache = new Map();
  let changed = false, backlogCount = 0, lateCount = 0;
  state.executions = state.executions.map((row) => {
    if (row.execution.acctNumber !== ACCOUNT || !row.attribution.needsAttribution || row.foreignAlertReceipt) return row;
    const key = `execution:${row.execution.execId}`;
    let receipt = receipts.get(key);
    if (!receipt) {
      const time = executionTimeMs(row.execution.time, timeCache);
      const beforeCutover = Number.isFinite(time) && time < Date.parse(config.foreignAlertSince);
      const late = !beforeCutover && Number.isFinite(time) && time < now - 14 * 86400000;
      const silent = beforeCutover || late;
      receipt = {
        key, event: "foreign_execution", ticket: "OPS-313", at, silent,
        execId: row.execution.execId, orderId: Number(row.execution.orderId) || null,
        permId: Number(row.execution.permId) || null, clientId: Number(row.execution.clientId) || null,
        symbol: row.contract.symbol, ...row.attribution,
      };
      receipts.set(key, receipt);
      added.push(receipt);
      if (beforeCutover) backlogCount++;
      if (late) lateCount++;
    }
    changed = true;
    // Compact proof stays with the retained execution after the full receipt
    // expires, preventing the full pusher history from alerting again.
    return { ...row, foreignAlertReceipt: { at: receipt.at, silent: receipt.silent === true } };
  });
  for (const order of context.openOrders || []) {
    if (order.account !== ACCOUNT || ["filled", "cancelled", "inactive", "apicancelled"].includes(String(order.status).toLowerCase())) continue;
    const attributed = activityAttribution(order, config);
    if (!attributed.needsAttribution) continue;
    const key = Number(order.permId) > 0 ? `order:permId:${Number(order.permId)}` : `order:clientId:${Number(order.clientId)}:orderId:${Number(order.orderId)}`;
    let receipt = receipts.get(key);
    if (!receipt) {
      receipt = { key, event: "foreign_open_order", ticket: "OPS-313", at, orderId: Number(order.orderId), permId: Number(order.permId) || null, clientId: Number(order.clientId), symbol: order.symbol, ...attributed };
      receipts.set(key, receipt);
      added.push(receipt);
    }
    if (receipt.lastSeenAt !== at) { receipt.lastSeenAt = at; changed = true; }
  }
  const summary = backlogCount && !state.foreignAlertBacklog ? { event: "foreign_execution_backlog", ticket: "OPS-313", at, count: backlogCount } : null;
  const lateSummary = lateCount ? { event: "foreign_execution_late", ticket: "OPS-313", at, count: lateCount } : null;
  if (summary) state.foreignAlertBacklog = summary;
  state.foreignAlerts = [...receipts.values()];
  pruneForeignAlerts(state, config.foreignAlertRetentionDays, now);
  changed ||= state.foreignAlerts.length !== (previous.receipts || []).length;
  if (!changed && !summary) return;
  // Publish receipts, compact proofs and the summary together before emitting.
  try { context.saveState?.(state); }
  catch (error) {
    if (error?.published === true) throw error;
    state.executions = previous.executions;
    state.foreignAlerts = previous.receipts;
    if (previous.backlog === undefined) delete state.foreignAlertBacklog;
    else state.foreignAlertBacklog = previous.backlog;
    throw error;
  }
  if (summary) context.audit?.(summary);
  if (lateSummary) {
    context.audit?.(lateSummary);
    (context.alertForeign || ((event) => console.warn(JSON.stringify(event))))(lateSummary);
  }
  for (const alert of added.filter((row) => !row.silent)) {
    context.audit?.(alert);
    (context.alertForeign || ((event) => console.warn(JSON.stringify(event))))(alert);
  }
}

function refusal(reason, statusCode = 400) {
  throw Object.assign(new Error(reason), { publicCode: "attribution_refused", publicReason: reason, statusCode });
}

export function planReattribution(state, request, { peer, config = attributionConfig() } = {}) {
  if (!request || typeof request !== "object" || Array.isArray(request) || Object.keys(request).some((key) => !["execId", "desk", "disposition", "actor", "reason", "dryRun"].includes(key))) refusal("attribution request has unsupported fields");
  if (typeof request.execId !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(request.execId)) refusal("execId is invalid");
  const disposition = request.disposition ?? "desk";
  if (!["desk", "external"].includes(disposition)) refusal("disposition is invalid");
  let desk = null;
  if (disposition === "external") {
    if (request.desk !== undefined) refusal("external disposition cannot assign a desk");
  } else {
    try { desk = validateKey(typeof request.desk === "string" ? request.desk.toLowerCase() : request.desk, "desk"); } catch { refusal("desk is invalid"); }
  }
  for (const [field, limit] of [["actor", 80], ["reason", 240]]) {
    const value = request[field];
    if (typeof value !== "string" || !value.trim() || value !== value.trim() || value.length > limit || /[\x00-\x1f\x7f-\x9f]/.test(value)) refusal(`${field} is invalid`);
  }
  if (request.dryRun !== undefined && typeof request.dryRun !== "boolean") refusal("dryRun must be boolean");
  if ((state.attributionJournal || []).some((row) => row.execId === request.execId)) refusal("execution was already attributed", 409);
  const rows = attributeExecutions(state.executions, config, state.attributionJournal);
  const execution = rows.find((row) => row.execution.execId === request.execId);
  if (!execution) refusal("execution is unknown", 404);
  if (KEEP.includes(execution.contract.symbol)) refusal("KEEP execution cannot be assigned to a trading desk");
  if (execution.execution.acctNumber !== ACCOUNT || !execution.attribution.needsAttribution) refusal("execution is not an unassigned foreign paper execution", 409);
  if (disposition === "desk" && (!Number.isSafeInteger(Number(execution.contract.conId)) || Number(execution.contract.conId) <= 0 || execution.contract.secType !== "STK" || !["BOT", "BUY", "SLD", "SELL"].includes(execution.execution.side) || !Number.isFinite(Number(execution.execution.shares)) || Number(execution.execution.shares) <= 0 || !Number.isFinite(Number(execution.execution.price)) || Number(execution.execution.price) <= 0)) refusal("execution economics are invalid");
  const to = disposition === "external" ? "external" : desk;
  const entry = { id: randomUUID(), event: disposition === "external" ? "execution_acknowledged_external" : "execution_reattributed", disposition, execId: request.execId, at: new Date().toISOString(), actor: request.actor, peer: peer || "local", from: "foreign", to, reason: request.reason };
  const candidate = structuredClone(state);
  candidate.attributionJournal = [...(state.attributionJournal || []), entry];
  candidate.executions = attributeExecutions(rows, config, candidate.attributionJournal);
  const book = (executions) => ({
    deskPositions: state.ownershipComplete === true ? deskPositions(executions, config.ownership, config.executorClientId, state.ownershipSnapshot, config) : [],
    foreignPositions: foreignPositions(executions, config),
    pnlPerDesk: pnlPerDesk(executions, state.commissions || [], state.marks || {}, config.ownership, config.executorClientId, state.ownershipComplete === true, config),
  });
  const before = book(rows), after = book(candidate.executions);
  Object.assign(candidate, after);
  return {
    state: candidate, journal: entry,
    result: { status: "ok", dryRun: request.dryRun !== false, disposition, execId: request.execId, orderId: Number(execution.execution.orderId) || null, symbol: execution.contract.symbol, from: "foreign", to, before, after },
  };
}

export function assertPlacementAttribution(executions, openOrders, config, contract) {
  const cutover = Date.parse(config.foreignAlertSince), timeCache = new Map();
  const affected = [...executions.filter((row) => {
    const time = executionTimeMs(row.execution.time, timeCache);
    return row.execution.acctNumber === ACCOUNT && (!Number.isFinite(time) || time >= cutover);
  }), ...openOrders.filter((row) => (!row.account || row.account === ACCOUNT) && !["filled", "cancelled", "inactive", "apicancelled"].includes(String(row.status).toLowerCase()))];
  if (affected.some((row) => {
    const conId = Number(row.contract?.conId ?? row.conId);
    const matches = Number.isSafeInteger(conId) && conId > 0 ? conId === Number(contract.conId) : String(row.contract?.symbol || row.symbol || "").toUpperCase() === String(contract.symbol).toUpperCase();
    return matches && activityAttribution(row, config).needsAttribution;
  })) {
    const reason = `unassigned foreign activity for ${contract.symbol}; admin attribution is required before placing this contract`;
    throw Object.assign(new Error(reason), { publicCode: "placement_refused", publicReason: reason });
  }
}
