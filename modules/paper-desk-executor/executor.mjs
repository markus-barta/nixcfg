import { ACCOUNT, newYorkDay, normalizeOrderRef, assertSideEffect, evaluatePlacement, mergeExecutions } from "./policy.mjs";
import { assertBrokerRuntime, deskPositions, flattenOwned, freshExecutionSnapshot, freshMarks, freshUsdToEur, modifyStopOwned, openSession, placeProtectiveBracket, publicSnapshot, readPusherExecutions, reconcileDeskPositions, resolveStock } from "./ib.mjs";
import { rememberFirstOrders } from "./state.mjs";

export function publicError(error) { return String(error?.message || error).slice(0, 500); }

function configFromHost() {
  return {
    clientIds: JSON.parse(process.env.IB_DESK_CLIENT_IDS || "{}"),
    ownership: JSON.parse(process.env.IB_DESK_OWNERSHIP_CLIENT_IDS || "{}"),
    ownershipLedger: process.env.IB_DESK_OWNERSHIP_LEDGER || "",
    blockOnInitDay: process.env.PAPER_DESK_BLOCK_ON_INIT_DAY === "true",
  };
}

function resolveUncertain(state, broker, clientId, replayedClients) {
  for (const [intentId, record] of state.intents || new Map()) {
    if (!["uncertain", "claimed"].includes(record.status) || !["place", "flatten", "cancel", "modify-stop"].includes(record.action)) continue;
    if (record.action === "modify-stop") {
      const plan = record.brokerPlan?.modification;
      if (!plan || !broker.gateway || broker.account !== ACCOUNT || broker.errors.length) continue;
      const stop = broker.openOrders.find((row) => row.orderId === plan.orderId && row.clientId === clientId);
      if (!stop || stop.conId !== plan.conId || stop.symbol !== plan.symbol || stop.orderType !== "STP" || stop.parentId !== plan.parentId || stop.action !== plan.action || stop.quantity !== plan.quantity || stop.account !== plan.account || stop.tif !== plan.tif || stop.orderRef !== plan.orderRef || stop.auxPrice !== plan.to || !["submitted", "presubmitted"].includes(stop.status.toLowerCase())) continue;
      const status = [...broker.statuses].reverse().find((row) => row.orderId === plan.orderId && (row.clientId === undefined || row.clientId === clientId));
      if (!status || !["submitted", "presubmitted"].includes(status.status.toLowerCase()) || status.filled !== 0 || status.remaining !== plan.quantity) continue;
      const observedAt = new Date().toISOString();
      record.status = "done";
      record.finishedAt = observedAt;
      record.resolution = { status: "modified", action: record.action, observedAt, orderId: plan.orderId, orderRef: plan.orderRef, clientId };
      if (record.modification) { record.modification.status = "submitted"; record.modification.acknowledgedAt = observedAt; }
      const placement = state.placements.find((row) => row.orderIds?.[1] === plan.orderId && row.clientId === clientId && normalizeOrderRef(row.orderRef) === normalizeOrderRef(plan.orderRef));
      const change = placement?.stopHistory?.find((row) => row.intentId === intentId);
      if (change) { change.status = "submitted"; change.acknowledgedAt = observedAt; }
      if (placement) placement.currentStopPrice = plan.to;
      record.result = { status: "ok", intentId, desk: record.desk, action: record.action, observedAt, modification: plan, resolution: record.resolution };
      continue;
    }
    const placement = state.placements.find((row) => row.intentId === intentId);
    const ref = record.orderRef || placement?.orderRef;
    const plan = record.brokerPlan;
    let resolution;
    if (record.action === "cancel") {
      const targets = plan?.cancellationTargets || [];
      if (!targets.length || targets.some((row) => !replayedClients.has(row.clientId))) continue;
      const target = (row) => targets.some((item) => item.orderId === Number(row.orderId) && item.clientId === Number(row.clientId));
      const working = broker.openOrders.some((row) => target(row) && !["filled", "cancelled", "inactive", "apicancelled"].includes(String(row.status).toLowerCase()));
      const fills = state.executions.filter((row) => target(row.execution));
      const complete = targets.every((item) => fills.filter((row) => item.orderId === Number(row.execution.orderId) && item.clientId === Number(row.execution.clientId)).reduce((sum, row) => sum + Number(row.execution.shares), 0) >= item.quantity);
      resolution = working ? "partial" : complete ? "filled" : fills.length ? "partial" : "absent";
    } else {
      if (!ref) continue;
      const fills = state.executions.filter((row) => normalizeOrderRef(row.execution.orderRef) === normalizeOrderRef(ref) && Number(row.execution.clientId) === clientId);
      const orders = broker.openOrders.filter((row) => normalizeOrderRef(row.orderRef) === normalizeOrderRef(ref) && row.clientId === clientId && !["cancelled", "inactive", "apicancelled"].includes(String(row.status).toLowerCase()));
      if (record.action === "flatten") {
        const closing = plan?.closing || [];
        const complete = closing.length && closing.every((leg) => fills.filter((row) => Number(row.contract.conId) === leg.conId && ["BOT", "BUY"].includes(row.execution.side) === (leg.side === "BUY")).reduce((sum, row) => sum + Number(row.execution.shares), 0) >= leg.quantity);
        const targets = plan?.cancellationTargets || [];
        const cancellationPending = broker.openOrders.some((row) => targets.some((item) => item.orderId === row.orderId && item.clientId === row.clientId) && !["filled", "cancelled", "inactive", "apicancelled"].includes(String(row.status).toLowerCase()));
        resolution = complete ? "filled" : fills.length || orders.length || cancellationPending ? "partial" : "absent";
        if (resolution === "absent" && targets.some((row) => !replayedClients.has(row.clientId))) continue;
      } else {
        const entryFills = fills.filter((row) => ["BOT", "BUY"].includes(row.execution.side) === (placement?.side === "BUY"));
        const quantity = entryFills.reduce((sum, row) => sum + Number(row.execution.shares), 0);
        resolution = quantity >= (placement?.quantity || Infinity) ? "filled" : fills.length || orders.length ? "partial" : "absent";
      }
    }
    // Absence needs same-day execution replay from each relevant client.
    if (resolution === "absent" && newYorkDay(Date.parse(record.claimedAt)) !== newYorkDay()) continue;
    record.status = resolution === "partial" ? "uncertain" : "done";
    record.resolution = { status: resolution, action: record.action, observedAt: new Date().toISOString(), orderRef: ref || null, clientId };
    record.result = { ...record.result, status: resolution === "partial" ? "uncertain" : "ok", resolution: record.resolution };
    if (placement) placement.status = resolution === "absent" ? "absent" : resolution === "filled" ? "filled" : "partial";
  }
}

export function assertRuntime() {
  assertBrokerRuntime();
  const config = configFromHost();
  validateConfig(config);
}

function validateConfig(config) {
  const { executor, recon } = config.clientIds;
  if (!Number.isSafeInteger(executor) || executor <= 0 || !Number.isSafeInteger(recon) || recon <= 0 || executor === recon) throw new Error("executor and recon require distinct valid client IDs");
  const legacy = Object.values(config.ownership).flat();
  if (legacy.some((id) => !Number.isSafeInteger(id) || id <= 0 || id === executor || id === recon) || new Set(legacy).size !== legacy.length) throw new Error("legacy desk ownership client IDs must be valid and disjoint");
}

// Pusher history rows carry no orderId/orderRef/permId (OPS-266). Persisting
// them as they come would erase the executor's own attribution of earlier
// fills, so missing identifiers are filled from the attributed or previously
// cached row with the same execId (correction revisions share the prefix).
function keepAttribution(rows, ...sources) {
  const prefix = (execution) => String(execution?.execId || "").replace(/\d+$/, "");
  const known = new Map();
  for (const row of sources.flat()) {
    const execution = row?.execution;
    if (!execution?.orderRef) continue;
    const prior = known.get(prefix(execution)) || {};
    known.set(prefix(execution), { orderRef: execution.orderRef, orderId: Number(execution.orderId) || prior.orderId, permId: Number(execution.permId) || prior.permId });
  }
  return rows.map((row) => {
    const found = known.get(prefix(row.execution));
    if (!found || row.execution.orderRef) return row;
    const execution = { ...row.execution, orderRef: found.orderRef };
    if (!Number(execution.orderId) && found.orderId) execution.orderId = found.orderId;
    if (!Number(execution.permId) && found.permId) execution.permId = found.permId;
    return { ...row, execution };
  });
}

export async function executeIntent(intent, state, context = {}, runtime = {}) {
  const config = runtime.config || configFromHost();
  const connect = runtime.connect || ((id, options) => openSession(id, 20_000, options));
  const readHistory = runtime.readHistory || readPusherExecutions;
  validateConfig(config);
  const clientId = Number(config.clientIds.executor);
  const reconClientId = Number(config.clientIds.recon);
  if (!Number.isSafeInteger(clientId) || clientId <= 0 || !Number.isSafeInteger(reconClientId) || reconClientId <= 0 || clientId === reconClientId) throw new Error("executor and recon require distinct valid client IDs");
  const saveState = context.saveState || (() => {});
  const guard = { getHalt: context.getHalt || (() => context.halt || { active: false }), now: context.now || Date.now };
  const ownershipClientIds = config.ownership[intent.desk];
  if (!Array.isArray(ownershipClientIds) || !ownershipClientIds.length) throw new Error("desk has no ownership client IDs");
  const result = (body) => ({ status: "ok", intentId: intent.intentId, desk: intent.desk, action: intent.action, observedAt: new Date().toISOString(), ...body });

  if (intent.action === "modify-stop") {
    rememberFirstOrders(state);
    let change;
    let placement;
    try {
      const outcome = await modifyStopOwned({ desk: intent.desk, clientId, ownershipClientIds, ownership: config.ownership, stateExecutions: state.executions, statePlacements: state.placements, intentRecords: state.intents, firstOrders: state.firstOrders.get(intent.desk) || new Map(), ownershipHistoryFrom: state.ownershipHistoryFrom, ownershipLedgerFile: config.ownershipLedger, intent, guard, connect, readHistory, onPlan: (plan) => {
        placement = state.placements.find((row) => row.orderIds?.[0] === plan.parentId && row.orderIds?.[1] === plan.orderId && row.clientId === clientId && row.desk === intent.desk && row.symbol === plan.symbol && row.quantity === plan.quantity && row.side === (plan.action === "SELL" ? "BUY" : "SELL") && !["rejected", "absent"].includes(row.status) && normalizeOrderRef(row.orderRef) === normalizeOrderRef(plan.orderRef));
        change = { at: new Date().toISOString(), from: plan.from, to: plan.to, intentId: intent.intentId, orderId: plan.orderId, status: "reserved" };
        (placement.stopHistory ||= []).push(change);
        const record = state.intents?.get(intent.intentId);
        if (record) { record.brokerPlan = { modification: plan }; record.modification = change; }
        saveState(state);
      } });
      change.status = "submitted";
      change.acknowledgedAt = new Date().toISOString();
      placement.currentStopPrice = outcome.modification.to;
      state.executions = keepAttribution(outcome.executions, state.executions, outcome.ownershipExecutions);
      state.ownershipComplete = true;
      state.deskPositions = deskPositions(outcome.ownershipExecutions, config.ownership, clientId, outcome.ownershipSnapshot);
      state.activeOrders = outcome.openOrders;
      state.concurrentObservedAt = new Date().toISOString();
      saveState(state);
      return result({ paperPort: 4002, account: ACCOUNT, modification: outcome.modification });
    } catch (error) {
      // A durable acknowledgement followed by a ledger failure still needs recon.
      if (change?.status === "submitted") error.code = "uncertain";
      if (change) { change.status = error.code === "uncertain" ? "uncertain" : "rejected"; change.error = publicError(error); saveState(state); }
      throw error;
    }
  }

  if (["flatten", "cancel"].includes(intent.action)) {
    rememberFirstOrders(state);
    const outcome = await flattenOwned({ desk: intent.desk, clientId, reconClientId, ownershipClientIds, ownership: config.ownership, stateExecutions: state.executions, statePlacements: state.placements, firstOrders: state.firstOrders.get(intent.desk) || new Map(), ownershipHistoryFrom: state.ownershipHistoryFrom, ownershipLedgerFile: config.ownershipLedger, intent, guard, connect, readHistory, onPlan: (plan) => {
      const record = state.intents?.get(intent.intentId);
      if (record) { record.brokerPlan = { ...record.brokerPlan, ...plan }; saveState(state); }
    } });
    state.executions = keepAttribution(outcome.executions, state.executions, outcome.ownershipExecutions);
    if (outcome.ownershipComplete !== undefined) state.ownershipComplete = outcome.ownershipComplete;
    state.deskPositions = deskPositions(outcome.ownershipExecutions || state.executions, state.ownershipComplete === false ? {} : config.ownership, clientId, state.ownershipComplete === false ? undefined : outcome.ownershipSnapshot);
    saveState(state);
    const { executions: _private, ownershipExecutions: _attribution, ownershipSnapshot: _snapshot, ...body } = outcome;
    return result(body);
  }

  if (intent.action === "place") assertSideEffect(intent, guard);
  let history = [];
  let historyError = null;
  try { history = readHistory(config.ownershipLedger, Date.now(), undefined, { allowIntradayGaps: true }); }
  catch (error) { historyError = publicError(error); }
  const recon = await connect(reconClientId);
  let resolved;
  let usdToEur;
  let snapshot;
  try {
    if (!recon.state.gateway || recon.state.account !== ACCOUNT || recon.state.errors.length) throw new Error("broker reconciliation has errors");
    try { if (!historyError) freshExecutionSnapshot(recon, history.coverage); }
    catch (error) { historyError = publicError(error); }
    state.executions = mergeExecutions(history, state.executions, recon.state.executions);
    state.deskPositions = historyError ? [] : deskPositions(state.executions, config.ownership, clientId, recon.state);
    state.commissions = [...new Map([...(state.commissions || []), ...(history.commissions || []), ...(recon.state.commissions || [])].map((row) => [row.execId, row])).values()];
    recon.state.commissions = state.commissions;
    if (intent.action === "recon") await freshMarks(recon);
    if (intent.action === "place" && !historyError) reconcileDeskPositions(state.executions, recon.state, config.ownership, clientId);
    if (intent.action === "place") resolved = await resolveStock(recon, intent.order.symbol);
    try { usdToEur = await freshUsdToEur(recon); } catch (error) { if (intent.action === "place") throw error; }
    snapshot = publicSnapshot(recon.state, { executions: state.executions, ownership: config.ownership, executorClientId: clientId, ownershipComplete: !historyError });
    state.ownershipComplete = !historyError;
    state.accountActiveSymbols = [...new Set([...snapshot.positions.filter((row) => row.position !== 0 && !row.keep).map((row) => row.symbol), ...snapshot.openOrders.filter((row) => !row.keep && !["filled", "cancelled", "inactive", "apicancelled"].includes(String(row.status).toLowerCase())).map((row) => row.symbol)])];
    state.activeOrders = snapshot.openOrders;
    state.concurrentObservedAt = new Date().toISOString();
    saveState(state);
  } finally { recon.close(); }

  if (intent.action === "recon") {
    // Query shared placing-client execution replay before declaring absence.
    const evidence = await connect(clientId);
    let ownershipSnapshot = evidence.state;
    try {
      if (evidence.state.errors.length || !evidence.state.gateway) throw new Error("placing-client reconciliation has errors");
      state.executions = mergeExecutions(state.executions, evidence.state.executions);
      const replayedClients = new Set([clientId]);
      const targets = [...(state.intents?.values() || [])].filter((row) => ["claimed", "uncertain"].includes(row.status)).flatMap((row) => row.brokerPlan?.cancellationTargets || []);
      for (const targetClient of new Set(targets.map((row) => row.clientId).filter((id) => id !== clientId && id !== reconClientId))) {
        let legacy;
        try {
          legacy = await connect(targetClient);
          if (!legacy.state.errors.length && legacy.state.gateway) {
            state.executions = mergeExecutions(state.executions, legacy.state.executions);
            ownershipSnapshot = legacy.state;
            replayedClients.add(targetClient);
          }
        } catch { /* Keep unresolved when the relevant client's replay is unavailable. */ }
        finally { legacy?.close(); }
      }
      resolveUncertain(state, evidence.state, clientId, replayedClients);
    } finally { evidence.close(); }
    state.deskPositions = historyError ? [] : deskPositions(state.executions, config.ownership, clientId, ownershipSnapshot);
    state.activeOrders = [...new Map([...snapshot.openOrders, ...evidence.state.openOrders].map((row) => [`${row.clientId}:${row.orderId}`, row])).values()];
    saveState(state);
    return result({ ...snapshot, deskPositions: state.deskPositions, ownershipHistory: historyError ? { status: "unavailable", reason: historyError } : { status: "complete" }, resolutions: Object.fromEntries([...(state.intents || new Map())].filter(([, row]) => row.resolution).map(([id, row]) => [id, row.resolution])) });
  }

  // A loaded ledger needs its validated execution receipt before placing;
  // unreadable history retains the existing conservative concurrency fallback.
  if (history.coverage && historyError) throw new Error(historyError);
  const budget = evaluatePlacement(intent, snapshot, state, { halt: guard.getHalt().active, stockType: resolved.stockType, usdToEur, blockOnInitDay: config.blockOnInitDay });
  const placement = { intentId: intent.intentId, orderRef: intent.orderRef, desk: intent.desk, clientId, symbol: intent.order.symbol, side: intent.order.side, quantity: intent.order.quantity, day: budget.day, riskEur: budget.riskEur, notionalEur: budget.notionalEur, status: "reserved", reservedAt: new Date().toISOString() };
  state.placements.push(placement);
  rememberFirstOrders(state);
  saveState(state);
  let placingSession;
  try {
    placingSession = await connect(clientId);
    state.executions = mergeExecutions(state.executions, placingSession.state.executions);
    if (!historyError) reconcileDeskPositions(state.executions, placingSession.state, config.ownership, clientId);
    const current = publicSnapshot(placingSession.state, { executions: state.executions, ownership: config.ownership, executorClientId: clientId, ownershipComplete: !historyError });
    evaluatePlacement(intent, current, { ...state, placements: state.placements.filter((row) => row !== placement) }, { halt: guard.getHalt().active, stockType: resolved.stockType, usdToEur, blockOnInitDay: config.blockOnInitDay });
    const placed = await placeProtectiveBracket(placingSession, { ...intent, clientId }, resolved, guard);
    placement.status = "submitted";
    placement.orderIds = [placed.parentOrderId, placed.stopOrderId];
    state.executions = mergeExecutions(state.executions, placingSession.state.executions);
    state.deskPositions = historyError ? [] : deskPositions(state.executions, config.ownership, clientId, placingSession.state);
    state.activeOrders = [...snapshot.openOrders, ...placed.statuses.map((row) => ({ ...row, desk: intent.desk, symbol: intent.order.symbol, orderRef: intent.orderRef, clientId }))];
    state.concurrentObservedAt = new Date().toISOString();
    saveState(state);
    return result({ paperPort: 4002, account: ACCOUNT, contract: resolved.contract, budget, bracket: placed, ownershipHistory: historyError ? { status: "unavailable", reason: historyError, concurrency: "conservative_account_wide" } : { status: "complete" } });
  } catch (error) {
    if (placingSession?.sideEffects) error.code = "uncertain";
    placement.status = error.code === "uncertain" ? "uncertain" : "rejected";
    placement.error = publicError(error);
    saveState(state);
    throw error;
  } finally { placingSession?.close(); }
}
