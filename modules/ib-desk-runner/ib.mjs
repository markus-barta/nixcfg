import { createRequire } from "node:module";
import { readFileSync } from "node:fs";

import { ACCOUNT, KEEP, PAPER_PORT, mergeExecutions, ownedPositions } from "./policy.mjs";

// The runner deliberately reuses only the pinned pusher image's Node runtime and
// installed @stoqey/ib dependency. It does not invoke or modify the pusher.
const require = createRequire(process.env.IB_DESK_PACKAGE_JSON || "/app/package.json");
const { IBApi, EventName } = require("@stoqey/ib");

const HOST = process.env.IB_DESK_GATEWAY_HOST || "100.64.0.6";
const PORT = Number(process.env.IB_DESK_GATEWAY_PORT || PAPER_PORT);
const TARGET_ACCOUNT = process.env.IB_DESK_ACCOUNT || ACCOUNT;
const INFORMATIONAL_CODES = new Set([202, 2104, 2106, 2107, 2108, 2119, 2158]);

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function paperGuard() {
  if (PORT !== PAPER_PORT || PORT === 4001) throw new Error("runner refuses any non-paper port");
  if (TARGET_ACCOUNT !== ACCOUNT) throw new Error("runner refuses any non-paper account");
  if (HOST !== "100.64.0.6") throw new Error("runner refuses an undeclared Gateway host");
}

function message(error) {
  return String(error?.message || error).slice(0, 240);
}

export async function openSession(clientId, timeoutMs = 20_000) {
  paperGuard();
  if (!Number.isSafeInteger(clientId) || clientId <= 0) throw new Error("invalid client ID");
  const api = new IBApi({ host: HOST, port: PORT, clientId });
  const state = {
    gateway: false,
    account: null,
    positions: [],
    openOrders: [],
    executions: [],
    statuses: [],
    errors: [],
    nextId: null,
  };
  let positionsEnd = false;
  let ordersEnd = false;
  let executionsEnd = false;
  let requested = false;

  api.on(EventName.error, (error, code, reqId) => {
    if (INFORMATIONAL_CODES.has(Number(code))) return;
    state.errors.push({ code: Number(code) || null, reqId: Number(reqId) || null, message: message(error) });
  });
  api.on(EventName.connected, () => {
    state.gateway = true;
    api.reqManagedAccts();
  });
  api.on(EventName.managedAccounts, (accounts) => {
    if (requested) return;
    requested = true;
    const values = String(accounts || "").split(",").map((item) => item.trim()).filter(Boolean);
    if (values.length !== 1 || values[0] !== ACCOUNT) {
      state.errors.push({ code: null, reqId: null, message: "managed account is not exactly the paper account" });
      return;
    }
    state.account = ACCOUNT;
    api.reqPositions();
    api.reqAllOpenOrders();
    api.reqExecutions(880000 + (clientId % 10000), {});
    api.reqIds(1);
  });
  api.on(EventName.position, (account, contract, position, averageCost) => {
    if (account !== ACCOUNT) return;
    state.positions.push({
      account,
      conId: Number(contract.conId) || 0,
      symbol: String(contract.symbol || "").toUpperCase(),
      secType: String(contract.secType || ""),
      currency: String(contract.currency || ""),
      exchange: String(contract.exchange || ""),
      primaryExch: String(contract.primaryExch || ""),
      position: Number(position),
      averageCost: Number(averageCost),
    });
  });
  api.on(EventName.positionEnd, () => { positionsEnd = true; });
  api.on(EventName.openOrder, (orderId, contract, order, orderState) => {
    state.openOrders.push({
      orderId: Number(orderId),
      conId: Number(contract.conId) || 0,
      symbol: String(contract.symbol || "").toUpperCase(),
      secType: String(contract.secType || ""),
      currency: String(contract.currency || ""),
      clientId: Number(order.clientId),
      action: String(order.action || ""),
      orderType: String(order.orderType || ""),
      quantity: Number(order.totalQuantity),
      parentId: Number(order.parentId) || 0,
      orderRef: String(order.orderRef || ""),
      status: String(orderState?.status || ""),
    });
  });
  api.on(EventName.openOrderEnd, () => { ordersEnd = true; });
  api.on(EventName.execDetails, (_requestId, contract, execution) => {
    if (execution.acctNumber !== ACCOUNT) return;
    state.executions.push({ contract: { ...contract }, execution: { ...execution } });
  });
  api.on(EventName.execDetailsEnd, () => { executionsEnd = true; });
  api.on(EventName.nextValidId, (orderId) => {
    if (state.nextId === null) state.nextId = Number(orderId);
  });
  api.on(EventName.orderStatus, (orderId, status, filled, remaining, averageFillPrice) => {
    state.statuses.push({
      orderId: Number(orderId),
      status: String(status || ""),
      filled: Number(filled),
      remaining: Number(remaining),
      averageFillPrice: Number(averageFillPrice),
    });
  });

  api.connect();
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if (state.gateway && state.account === ACCOUNT && positionsEnd && ordersEnd && executionsEnd && state.nextId !== null) {
      return {
        api,
        state,
        close() {
          try { api.disconnect(); } catch { /* best effort */ }
        },
      };
    }
    await sleep(100);
  }
  try { api.disconnect(); } catch { /* best effort */ }
  throw new Error(`paper Gateway snapshot timed out: ${state.errors.map((item) => item.message).join("; ") || "incomplete callbacks"}`);
}

export async function resolveStock(session, symbol, requestId = 881001) {
  const details = [];
  let ended = false;
  const onDetails = (id, value) => {
    if (Number(id) === requestId) details.push(value);
  };
  const onEnd = (id) => {
    if (id === undefined || Number(id) === requestId) ended = true;
  };
  session.api.on(EventName.contractDetails, onDetails);
  session.api.on(EventName.contractDetailsEnd, onEnd);
  session.api.reqContractDetails(requestId, { symbol, secType: "STK", exchange: "SMART", currency: "USD" });
  const started = Date.now();
  while (!ended && Date.now() - started < 10_000) await sleep(100);
  session.api.off(EventName.contractDetails, onDetails);
  session.api.off(EventName.contractDetailsEnd, onEnd);
  if (!ended) throw new Error("contract lookup timed out");
  if (details.length !== 1) throw new Error("symbol does not resolve to exactly one USD stock contract");
  const detail = details[0];
  const contract = detail.contract;
  if (String(contract.secType || "").toUpperCase() !== "STK" || String(contract.currency || "").toUpperCase() !== "USD") {
    throw new Error("contract is not a USD stock");
  }
  return {
    contract: {
      conId: Number(contract.conId),
      symbol: String(contract.symbol || "").toUpperCase(),
      secType: "STK",
      exchange: "SMART",
      currency: "USD",
      primaryExch: String(contract.primaryExch || ""),
    },
    stockType: String(detail.stockType || "").toUpperCase(),
  };
}

export async function freshUsdToEur(session, requestId = 881101) {
  const rates = new Map();
  let ended = false;
  const onValue = (id, account, _model, key, value, currency) => {
    if (Number(id) !== requestId || account !== ACCOUNT || key !== "ExchangeRate") return;
    const rate = Number(value);
    const code = String(currency || "").toUpperCase();
    if (/^[A-Z]{3}$/.test(code) && Number.isFinite(rate) && rate > 0) rates.set(code, rate);
  };
  const onEnd = (id) => {
    if (Number(id) === requestId) ended = true;
  };
  session.api.on(EventName.accountUpdateMulti, onValue);
  session.api.on(EventName.accountUpdateMultiEnd, onEnd);
  session.api.reqAccountUpdatesMulti(requestId, ACCOUNT, "", true);
  const started = Date.now();
  while (!ended && Date.now() - started < 10_000) await sleep(100);
  try { session.api.cancelAccountUpdatesMulti(requestId); } catch { /* best effort */ }
  session.api.off(EventName.accountUpdateMulti, onValue);
  session.api.off(EventName.accountUpdateMultiEnd, onEnd);
  if (!ended) throw new Error("IB account FX snapshot timed out");
  if (Math.abs(Number(rates.get("EUR")) - 1) > 1e-9) throw new Error("IB account base currency is not proven EUR");
  const usdToEur = rates.get("USD");
  if (!Number.isFinite(usdToEur) || usdToEur <= 0) throw new Error("IB USD/EUR exchange rate is unavailable");
  return usdToEur;
}

export async function placeProtectiveBracket(session, intent, resolved) {
  const parentId = session.state.nextId;
  const stopId = parentId + 1;
  const closeSide = intent.order.side === "BUY" ? "SELL" : "BUY";
  const common = {
    account: ACCOUNT,
    totalQuantity: intent.order.quantity,
    tif: "DAY",
    outsideRth: false,
    orderRef: intent.intentId,
  };
  session.api.placeOrder(parentId, resolved.contract, {
    ...common,
    action: intent.order.side,
    orderType: "LMT",
    lmtPrice: intent.order.limitPrice,
    transmit: false,
  });
  session.api.placeOrder(stopId, resolved.contract, {
    ...common,
    action: closeSide,
    orderType: "STP",
    auxPrice: intent.order.stopPrice,
    parentId,
    transmit: true,
  });
  await sleep(3_000);
  const statuses = session.state.statuses.filter((row) => row.orderId === parentId || row.orderId === stopId);
  const failed = statuses.find((row) => ["cancelled", "inactive", "apicancelled"].includes(row.status.toLowerCase()));
  if (session.state.errors.length || failed) {
    throw new Error(`paper bracket was not cleanly accepted: ${session.state.errors.map((row) => row.message).join("; ") || failed.status}`);
  }
  return {
    parentOrderId: parentId,
    stopOrderId: stopId,
    clientId: intent.clientId,
    statuses,
    errors: session.state.errors,
  };
}

function readPusherExecutions(filePath) {
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(filePath, "utf8"));
  } catch (error) {
    throw new Error(`durable ownership ledger unavailable: ${message(error)}`);
  }
  if (parsed?.schema !== "inspr.joe.best-available-history.v1" || parsed?.version !== 1
      || parsed?.account !== ACCOUNT || !Array.isArray(parsed.executions)) {
    throw new Error("durable ownership ledger is invalid or not the paper account");
  }
  return parsed.executions;
}

async function cancelOwnedOrders(openOrders, ownershipClientIds) {
  const ids = new Set(ownershipClientIds.map(Number));
  const owned = openOrders.filter((order) => ids.has(order.clientId) && !KEEP.includes(order.symbol));
  const cancelled = [];
  for (const clientId of [...new Set(owned.map((order) => order.clientId))]) {
    const session = await openSession(clientId);
    try {
      for (const order of owned.filter((row) => row.clientId === clientId)) {
        session.api.cancelOrder(order.orderId);
        cancelled.push({ orderId: order.orderId, symbol: order.symbol, placingClientId: clientId });
      }
      await sleep(2_000);
    } finally {
      session.close();
    }
  }
  return cancelled;
}

export async function flattenOwned({ desk, clientId, ownershipClientIds, stateExecutions, ownershipLedgerFile, intentId }) {
  paperGuard();
  const recon = await openSession(Number(process.env.IB_DESK_RECON_CLIENT_ID || 700));
  try {
    const pusherExecutions = readPusherExecutions(ownershipLedgerFile);
    let executions = mergeExecutions(pusherExecutions, stateExecutions || [], recon.state.executions);
    const cancelled = await cancelOwnedOrders(recon.state.openOrders, ownershipClientIds);
    const confirmation = await openSession(Number(process.env.IB_DESK_RECON_CLIENT_ID || 700));
    let confirmedExecutions;
    try {
      const ownedClients = new Set(ownershipClientIds.map(Number));
      const remaining = confirmation.state.openOrders.filter((order) => ownedClients.has(order.clientId)
        && !KEEP.includes(order.symbol)
        && !["cancelled", "filled", "inactive", "apicancelled"].includes(order.status.toLowerCase()));
      if (remaining.length) throw new Error("owned working orders remain after placing-client cancellation; flatten refused");
      confirmedExecutions = confirmation.state.executions;
    } finally {
      confirmation.close();
    }
    executions = mergeExecutions(executions, confirmedExecutions);
    // Query the dedicated placing client as well: IB may scope an execution
    // replay to the requesting client unless that client is configured master.
    const deskEvidence = await openSession(clientId);
    try {
      executions = mergeExecutions(executions, deskEvidence.state.executions);
    } finally {
      deskEvidence.close();
    }
    const owned = ownedPositions(executions, ownershipClientIds, ACCOUNT);
    const protectedOwned = owned.filter((row) => !KEEP.includes(row.symbol));
    const placed = [];
    if (protectedOwned.length) {
      const session = await openSession(clientId);
      try {
        let nextId = session.state.nextId;
        for (const position of protectedOwned) {
          if (!Number.isSafeInteger(Math.abs(position.quantity))) throw new Error("owned stock quantity is not an integer");
          const orderId = nextId++;
          session.api.placeOrder(orderId, {
            conId: position.conId,
            symbol: position.symbol,
            secType: "STK",
            exchange: "SMART",
            currency: position.currency,
          }, {
            account: ACCOUNT,
            action: position.quantity > 0 ? "SELL" : "BUY",
            totalQuantity: Math.abs(position.quantity),
            orderType: "MKT",
            tif: "DAY",
            outsideRth: false,
            orderRef: intentId,
            transmit: true,
          });
          placed.push({
            orderId,
            symbol: position.symbol,
            action: position.quantity > 0 ? "SELL" : "BUY",
            quantity: Math.abs(position.quantity),
            clientId,
          });
        }
        await sleep(4_000);
        return {
          desk,
          gateway: true,
          account: ACCOUNT,
          keepExcluded: KEEP,
          cancelled,
          flattened: placed,
          statuses: session.state.statuses,
          errors: session.state.errors,
          executions: mergeExecutions(executions, session.state.executions),
        };
      } finally {
        session.close();
      }
    }
    return {
      desk,
      gateway: true,
      account: ACCOUNT,
      keepExcluded: KEEP,
      cancelled,
      flattened: [],
      statuses: [],
      errors: [],
      executions,
    };
  } finally {
    recon.close();
  }
}

export function publicSnapshot(state) {
  const upstreamUnavailable = state.errors.some((row) => [1100, 2110].includes(Number(row.code)));
  return {
    gateway: state.gateway,
    gatewayStatus: upstreamUnavailable ? "upstream_unavailable" : state.gateway && state.account === ACCOUNT ? "api_ready" : "unavailable",
    account: state.account,
    paperPort: PAPER_PORT,
    positions: state.positions.map((row) => ({
      symbol: row.symbol,
      position: row.position,
      averageCost: row.averageCost,
      currency: row.currency,
      conId: row.conId,
      keep: KEEP.includes(row.symbol),
    })),
    openOrders: state.openOrders.map((row) => ({
      orderId: row.orderId,
      symbol: row.symbol,
      action: row.action,
      orderType: row.orderType,
      quantity: row.quantity,
      clientId: row.clientId,
      parentId: row.parentId,
      orderRef: row.orderRef,
      status: row.status,
      keep: KEEP.includes(row.symbol),
    })),
    errors: state.errors,
  };
}
