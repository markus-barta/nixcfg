import { ACCOUNT, newYorkDay, assertSideEffect, evaluatePlacement, mergeExecutions } from "./policy.mjs";
import { assertBrokerRuntime, deskPositions, flattenOwned, freshMarks, freshUsdToEur, openSession, placeProtectiveBracket, publicSnapshot, readPusherExecutions, reconcileDeskPositions, resolveStock } from "./ib.mjs";
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
    if (!["uncertain", "claimed"].includes(record.status) || !["place", "flatten", "cancel"].includes(record.action)) continue;
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
      const fills = state.executions.filter((row) => row.execution.orderRef === ref && Number(row.execution.clientId) === clientId);
      const orders = broker.openOrders.filter((row) => row.orderRef === ref && row.clientId === clientId && !["cancelled", "inactive", "apicancelled"].includes(String(row.status).toLowerCase()));
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

  if (["flatten", "cancel"].includes(intent.action)) {
    rememberFirstOrders(state);
    const outcome = await flattenOwned({ desk: intent.desk, clientId, reconClientId, ownershipClientIds, ownership: config.ownership, stateExecutions: state.executions, statePlacements: state.placements, firstOrders: state.firstOrders.get(intent.desk) || new Map(), ownershipHistoryFrom: state.ownershipHistoryFrom, ownershipLedgerFile: config.ownershipLedger, intent, guard, connect, readHistory, onPlan: (plan) => {
      const record = state.intents?.get(intent.intentId);
      if (record) { record.brokerPlan = { ...record.brokerPlan, ...plan }; saveState(state); }
    } });
    state.executions = outcome.executions;
    if (outcome.ownershipComplete !== undefined) state.ownershipComplete = outcome.ownershipComplete;
    state.deskPositions = deskPositions(outcome.ownershipExecutions || state.executions, state.ownershipComplete === false ? {} : config.ownership, clientId);
    saveState(state);
    const { executions: _private, ownershipExecutions: _attribution, ...body } = outcome;
    return result(body);
  }

  if (intent.action === "place") assertSideEffect(intent, guard);
  let history = [];
  let historyError = null;
  try { history = readHistory(config.ownershipLedger); }
  catch (error) { historyError = publicError(error); }
  const recon = await connect(reconClientId);
  let resolved;
  let usdToEur;
  let snapshot;
  try {
    if (!recon.state.gateway || recon.state.account !== ACCOUNT || recon.state.errors.length) throw new Error("broker reconciliation has errors");
    state.executions = mergeExecutions(history, state.executions, recon.state.executions);
    state.deskPositions = historyError ? [] : deskPositions(state.executions, config.ownership, clientId);
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
            replayedClients.add(targetClient);
          }
        } catch { /* Keep unresolved when the relevant client's replay is unavailable. */ }
        finally { legacy?.close(); }
      }
      resolveUncertain(state, evidence.state, clientId, replayedClients);
    } finally { evidence.close(); }
    state.deskPositions = historyError ? [] : deskPositions(state.executions, config.ownership, clientId);
    state.activeOrders = [...new Map([...snapshot.openOrders, ...evidence.state.openOrders].map((row) => [`${row.clientId}:${row.orderId}`, row])).values()];
    saveState(state);
    return result({ ...snapshot, deskPositions: state.deskPositions, ownershipHistory: historyError ? { status: "unavailable", reason: historyError } : { status: "complete" }, resolutions: Object.fromEntries([...(state.intents || new Map())].filter(([, row]) => row.resolution).map(([id, row]) => [id, row.resolution])) });
  }

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
    state.deskPositions = historyError ? [] : deskPositions(state.executions, config.ownership, clientId);
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
