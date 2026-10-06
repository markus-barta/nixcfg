import { evaluatePlacement, mergeExecutions } from "./policy.mjs";
import { flattenOwned, freshUsdToEur, openSession, placeProtectiveBracket, publicSnapshot, resolveStock } from "./ib.mjs";

function parseMap(name) {
  const value = JSON.parse(process.env[name] || "");
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${name} is invalid`);
  return value;
}

const CLIENT_IDS = parseMap("IB_DESK_CLIENT_IDS");
const OWNERSHIP_CLIENT_IDS = parseMap("IB_DESK_OWNERSHIP_CLIENT_IDS");
const OWNERSHIP_LEDGER = process.env.IB_DESK_OWNERSHIP_LEDGER || "";

export function publicError(error) {
  return String(error?.message || error).slice(0, 500);
}

function refusal(error) {
  const wrapped = new Error(publicError(error));
  wrapped.code = "rejected";
  return wrapped;
}

function uncertain(error) {
  const wrapped = new Error(`placement outcome uncertain; reconcile before any retry: ${publicError(error)}`);
  wrapped.code = "uncertain";
  return wrapped;
}

function clientIdFor(desk) {
  const clientId = Number(CLIENT_IDS[desk]);
  if (!Number.isSafeInteger(clientId) || clientId <= 0) throw refusal(new Error("desk has no dedicated client ID"));
  return clientId;
}

function ownershipFor(desk) {
  const ownership = OWNERSHIP_CLIENT_IDS[desk];
  if (!Array.isArray(ownership) || ownership.length === 0) throw refusal(new Error("desk has no ownership client IDs"));
  return ownership.map(Number);
}

export async function executeIntent(intent, state, { halt, saveState }) {
  const clientId = clientIdFor(intent.desk);
  if (intent.action === "recon") {
    const session = await openSession(Number(CLIENT_IDS.recon));
    try {
      state.executions = mergeExecutions(state.executions, session.state.executions);
      saveState(state);
      return {
        status: "ok",
        intentId: intent.intentId,
        desk: intent.desk,
        action: "recon",
        observedAt: new Date().toISOString(),
        ...publicSnapshot(session.state),
      };
    } finally {
      session.close();
    }
  }

  if (intent.action === "flatten") {
    const outcome = await flattenOwned({
      desk: intent.desk,
      clientId,
      ownershipClientIds: ownershipFor(intent.desk),
      stateExecutions: state.executions,
      ownershipLedgerFile: OWNERSHIP_LEDGER,
      intentId: intent.intentId,
    });
    state.executions = outcome.executions;
    saveState(state);
    const { executions: _privateExecutions, ...result } = outcome;
    return {
      status: "ok",
      intentId: intent.intentId,
      action: "flatten",
      observedAt: new Date().toISOString(),
      haltIgnoredForFlatten: halt.active,
      ...result,
    };
  }

  if (halt?.active) throw refusal(new Error("HALT is active: new orders are refused"));
  const session = await openSession(Number(CLIENT_IDS.recon));
  try {
    state.executions = mergeExecutions(state.executions, session.state.executions);
    saveState(state);
    const resolved = await resolveStock(session, intent.order.symbol);
    const usdToEur = await freshUsdToEur(session);
    let budget;
    try {
      budget = evaluatePlacement(intent, publicSnapshot(session.state), state, {
        halt: Boolean(halt?.active),
        stockType: resolved.stockType,
        usdToEur,
      });
    } catch (error) {
      throw refusal(error);
    }
    const placement = {
      intentId: intent.intentId,
      desk: intent.desk,
      clientId,
      symbol: intent.order.symbol,
      day: budget.day,
      riskEur: budget.riskEur,
      notionalEur: budget.notionalEur,
      status: "reserved",
      reservedAt: new Date().toISOString(),
    };
    state.placements.push(placement);
    saveState(state);
    const placingSession = await openSession(clientId);
    try {
      const placed = await placeProtectiveBracket(placingSession, { ...intent, clientId }, resolved);
      placement.status = "submitted";
      placement.orderIds = [placed.parentOrderId, placed.stopOrderId];
      placement.submittedAt = new Date().toISOString();
      state.executions = mergeExecutions(state.executions, placingSession.state.executions);
      saveState(state);
      return {
        status: "ok",
        intentId: intent.intentId,
        desk: intent.desk,
        action: "place",
        observedAt: new Date().toISOString(),
        paperPort: 4002,
        account: "DUR970597",
        contract: { conId: resolved.contract.conId, symbol: resolved.contract.symbol, stockType: resolved.stockType },
        budget,
        bracket: placed,
      };
    } catch (error) {
      placement.status = "uncertain";
      placement.error = publicError(error);
      saveState(state);
      throw uncertain(error);
    } finally {
      placingSession.close();
    }
  } finally {
    session.close();
  }
}
