import { createRequire } from "node:module";
import { readFileSync, statSync } from "node:fs";

import { ACCOUNT, KEEP, PAPER_PORT, DESKS, newYorkDay, belongsToDesk, assertSideEffect, mergeExecutions, ownedPositions } from "./policy.mjs";
import { confinedPath } from "./security.mjs";

// The runner deliberately reuses only the pinned pusher image's Node runtime and
// installed @stoqey/ib dependency. It does not invoke or modify the pusher.
const PACKAGE_JSON_PATH = confinedPath("/app", process.env.IB_DESK_PACKAGE_JSON || "/app/package.json", "package manifest path");
const require = createRequire(PACKAGE_JSON_PATH);
const activeClients = new Set();

export function assertBrokerRuntime() { paperGuard(); const runtime = require("@stoqey/ib"); if (typeof runtime.IBApi !== "function" || !runtime.EventName) throw new Error("IB runtime is unavailable"); }

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

export async function openSession(clientId, timeoutMs = 20_000, runtime = {}) {
  const { IBApi, EventName } = runtime.IBApi ? runtime : require("@stoqey/ib");
  const wait = runtime.wait || sleep;
  paperGuard();
  if (!Number.isSafeInteger(clientId) || clientId <= 0) throw new Error("invalid client ID");
  if (activeClients.has(clientId)) throw new Error("client ID already has a live session");
  activeClients.add(clientId);
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
    commissions: [],
    marks: {},
    fxObservedAt: null,
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
  api.on(EventName.commissionReport, (report) => { state.commissions.push({ ...report }); });
  api.on(EventName.disconnected, () => { state.gateway = false; });
  api.on(EventName.orderStatus, (orderId, status, filled, remaining, averageFillPrice) => {
    state.statuses.push({
      orderId: Number(orderId),
      status: String(status || ""),
      filled: Number(filled),
      remaining: Number(remaining),
      averageFillPrice: Number(averageFillPrice),
    });
  });

  try { api.connect(); } catch (error) { activeClients.delete(clientId); throw error; }
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if (state.gateway && state.account === ACCOUNT && positionsEnd && ordersEnd && executionsEnd && state.nextId !== null) {
      return {
        api,
        state,
        events: EventName,
        wait,
        close() {
          try { api.disconnect(); } catch { /* best effort */ }
          activeClients.delete(clientId);
        },
      };
    }
    await wait(100);
  }
  try { api.disconnect(); } catch { /* best effort */ }
  activeClients.delete(clientId);
  throw new Error(`paper Gateway snapshot timed out: ${state.errors.map((item) => item.message).join("; ") || "incomplete callbacks"}`);
}

export async function resolveStock(session, symbol, requestId = 881001) {
  const EventName = session.events;
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
  while (!ended && Date.now() - started < 10_000) await session.wait(100);
  session.api.off(EventName.contractDetails, onDetails);
  session.api.off(EventName.contractDetailsEnd, onEnd);
  if (!ended) throw new Error("contract lookup timed out");
  if (details.length !== 1) throw new Error("symbol does not resolve to exactly one USD stock contract");
  const detail = details[0];
  const contract = detail.contract;
  if (String(contract.secType || "").toUpperCase() !== "STK" || String(contract.currency || "").toUpperCase() !== "USD") {
    throw new Error("contract is not a USD stock");
  }
  assertContract(contract, { symbol, conId: Number(contract.conId) });
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
  const EventName = session.events;
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
  while (!ended && Date.now() - started < 10_000) await session.wait(100);
  try { session.api.cancelAccountUpdatesMulti(requestId); } catch { /* best effort */ }
  session.api.off(EventName.accountUpdateMulti, onValue);
  session.api.off(EventName.accountUpdateMultiEnd, onEnd);
  if (!ended) throw new Error("IB account FX snapshot timed out");
  if (Math.abs(Number(rates.get("EUR")) - 1) > 1e-9) throw new Error("IB account base currency is not proven EUR");
  const usdToEur = rates.get("USD");
  if (!Number.isFinite(usdToEur) || usdToEur <= 0) throw new Error("IB USD/EUR exchange rate is unavailable");
  session.state.fxObservedAt = new Date().toISOString();
  return usdToEur;
}

export function assertContract(contract, expected) {
  const symbol = String(contract?.symbol || "").toUpperCase();
  const conId = Number(contract?.conId);
  if (KEEP.includes(symbol)) throw new Error(`${symbol} is KEEP; broker side effect refused`);
  if (!/^[A-Z][A-Z0-9.]{0,9}$/.test(symbol) || !Number.isSafeInteger(conId) || conId <= 0) throw new Error("contract symbol/conId is blank or unknown");
  if (symbol !== expected.symbol || conId !== Number(expected.conId)) throw new Error("resolved contract symbol/conId mismatch");
  if (String(contract.secType).toUpperCase() !== "STK" || !["USD", "EUR"].includes(String(contract.currency).toUpperCase())) throw new Error("contract is not a supported stock");
}

function cleanSnapshot(session) {
  if (!session.state.gateway || session.state.account !== ACCOUNT || session.state.errors.length) throw new Error("broker reconciliation is incomplete or has errors");
}

function uncertain(error) {
  const result = new Error(`broker outcome uncertain; reconcile before retry: ${message(error)}`);
  result.code = "uncertain";
  return result;
}

function acceptance(session, orderIds, { filledOnly = false, quantities = {} } = {}) {
  if (session.state.errors.length || !session.state.gateway) throw new Error("broker errors or disconnection after order submission");
  const latest = new Map(session.state.statuses.map((row) => [row.orderId, row]));
  for (const id of orderIds) {
    const row = latest.get(id);
    const accepted = filledOnly ? ["filled"] : ["presubmitted", "submitted", "filled"];
    if (!row || !accepted.includes(row.status.toLowerCase()) || !Number.isFinite(row.filled) || !Number.isFinite(row.remaining) || row.filled < 0 || row.remaining < 0 || (row.filled > 0 && row.remaining > 0) || row.filled + row.remaining !== quantities[id] || (filledOnly && (row.remaining !== 0 || row.filled !== quantities[id]))) throw new Error("missing, partial or rejected broker acknowledgement");
  }
  return orderIds.map((id) => latest.get(id));
}

function before(session, contract, expected, intent, guard) {
  cleanSnapshot(session);
  assertContract(contract, expected);
  assertSideEffect(intent, guard);
}

export async function placeProtectiveBracket(session, intent, resolved, guard = {}) {
  const parentId = session.state.nextId;
  const stopId = parentId + 1;
  if (!Number.isSafeInteger(parentId) || parentId <= 0 || parentId >= 2147483647) throw new Error("broker order ID unavailable");
  const expected = { symbol: intent.order.symbol, conId: resolved.contract.conId };
  const common = { account: ACCOUNT, totalQuantity: intent.order.quantity, tif: "DAY", outsideRth: false, orderRef: intent.orderRef };
  let sent = false;
  try {
    before(session, resolved.contract, expected, intent, guard);
    sent = true;
    session.sideEffects = true;
    session.api.placeOrder(parentId, resolved.contract, { ...common, action: intent.order.side, orderType: "LMT", lmtPrice: intent.order.limitPrice, transmit: false });
    before(session, resolved.contract, expected, intent, guard);
    session.api.placeOrder(stopId, resolved.contract, { ...common, action: intent.order.side === "BUY" ? "SELL" : "BUY", orderType: "STP", auxPrice: intent.order.stopPrice, parentId, transmit: true });
    await session.wait(3_000);
    const statuses = acceptance(session, [parentId, stopId], { quantities: { [parentId]: intent.order.quantity, [stopId]: intent.order.quantity } });
    return { parentOrderId: parentId, stopOrderId: stopId, clientId: intent.clientId, orderRef: intent.orderRef, statuses, errors: [] };
  } catch (error) { if (sent) throw uncertain(error); throw error; }
}

export function readPusherExecutions(filePath, now = Date.now(), readFile = readFileSync) {
  const ledgerPath = confinedPath("/pusher-state", filePath, "ownership ledger path");
  let parsed;
  let body;
  try {
    if (readFile === readFileSync && statSync(ledgerPath).size > 16 * 1024 * 1024) throw new Error("ownership history exceeds size limit");
    body = readFile(ledgerPath, "utf8");
  } catch (error) { throw new Error(`durable ownership ledger unavailable: ${message(error)}`); }
  try { parsed = JSON.parse(body); } catch { throw new Error("durable ownership ledger JSON is invalid"); }
  if (parsed?.schema !== "inspr.joe.best-available-history.v1" || parsed?.version !== 1 || parsed?.account !== ACCOUNT || !Array.isArray(parsed.executions)) throw new Error("durable ownership ledger is invalid or not the paper account");
  const coverage = parsed.coverage;
  if (coverage?.status !== "complete" || !Array.isArray(coverage.gaps) || coverage.gaps.length) throw new Error("ownership history coverage is incomplete or has gaps; no cancellation or order allowed");
  const end = Date.parse(coverage.target?.toExclusive);
  const start = Date.parse(coverage.target?.fromInclusive);
  if (!Number.isFinite(start) || !Number.isFinite(end) || start >= end || end > now || now - end > 120000 || start > now || newYorkDay(end) !== newYorkDay(now)) throw new Error("ownership history target is stale or invalid on the host clock");
  const rows = mergeExecutions(parsed.executions);
  rows.commissions = Array.isArray(parsed.commissions) ? parsed.commissions : [];
  return rows;
}

export function deskPositions(executions, ownership, executorClientId) {
  return DESKS.flatMap((desk) => ownedPositions(executions, ownership[desk] || [], ACCOUNT, desk, executorClientId));
}

export function reconcileDeskPositions(executions, snapshot, ownership, executorClientId) {
  const attributed = deskPositions(executions, ownership, executorClientId);
  const totals = new Map();
  for (const row of attributed) {
    const actual = snapshot.positions.find((position) => position.conId === row.conId);
    if (!actual || actual.symbol !== row.symbol || Math.sign(actual.position) !== Math.sign(row.quantity)) throw new Error("desk ownership does not reconcile with broker position");
    totals.set(row.conId, (totals.get(row.conId) || 0) + Math.abs(row.quantity));
  }
  for (const [conId, quantity] of totals) {
    if (quantity > Math.abs(snapshot.positions.find((row) => row.conId === conId).position) + 1e-9) throw new Error("aggregate desk ownership exceeds broker position; no cancellation or order allowed");
  }
}

function reconcileOwned(executions, snapshot, desk, ownershipClientIds, executorClientId) {
  const owned = ownedPositions(executions, ownershipClientIds, ACCOUNT, desk, executorClientId);
  for (const row of owned) {
    const actual = snapshot.positions.find((position) => position.conId === row.conId);
    if (!actual || actual.symbol !== row.symbol || Math.sign(actual.position) !== Math.sign(row.quantity) || Math.abs(actual.position) < Math.abs(row.quantity)) throw new Error("owned quantity does not reconcile with broker position; no cancellation or order allowed");
  }
  return owned;
}

function working(order) { return !["cancelled", "filled", "inactive", "apicancelled"].includes(String(order.status).toLowerCase()); }

async function cancelOwnedOrders(orders, options) {
  const { desk, ownershipClientIds, executorClientId, intent, guard, connect } = options;
  const candidates = orders.filter((row) => belongsToDesk(row, desk, ownershipClientIds, executorClientId) && working(row));
  // Validate the complete candidate set before the first cancellation.
  for (const row of candidates) assertContract(row, row);
  const cancelled = [];
  let sent = false;
  try {
    for (const clientId of [...new Set(candidates.map((row) => row.clientId))]) {
      const session = await connect(clientId);
      try {
        cleanSnapshot(session);
        for (const order of candidates.filter((row) => row.clientId === clientId)) {
          const current = session.state.openOrders.find((row) => row.orderId === order.orderId && row.clientId === clientId);
          if (!current || !working(current) || !belongsToDesk(current, desk, ownershipClientIds, executorClientId) || current.orderRef !== order.orderRef) throw new Error("cancel ownership/order changed during reconciliation");
          const status = [...session.state.statuses].reverse().find((row) => row.orderId === order.orderId);
          const fill = session.state.executions.some((row) => Number(row.execution.orderId) === order.orderId && Number(row.execution.clientId) === clientId);
          if ((intent.action === "cancel") && (fill || !status || !Number.isFinite(status.filled) || status.filled !== 0 || status.remaining !== current.quantity)) throw new Error("cancel requires explicit evidence of a working unfilled order");
          const resolved = await resolveStock(session, current.symbol);
          assertContract(resolved.contract, order);
          before(session, current, order, intent, guard);
          sent = true;
          session.api.cancelOrder(order.orderId);
          cancelled.push({ orderId: order.orderId, symbol: order.symbol, clientId, orderRef: order.orderRef });
        }
        await session.wait(2_000);
        if (session.state.errors.length || !session.state.gateway) throw new Error("broker errors during cancellation");
        for (const order of cancelled.filter((row) => row.clientId === clientId)) {
          const status = [...session.state.statuses].reverse().find((row) => row.orderId === order.orderId);
          if (!status || !["cancelled", "apicancelled"].includes(status.status.toLowerCase()) || (intent.action === "cancel" && (!Number.isFinite(status.filled) || status.filled !== 0))) throw new Error("cancellation acknowledgement missing or partial");
        }
      } finally { session.close(); }
    }
    return cancelled;
  } catch (error) { if (sent) throw uncertain(error); throw error; }
}

export async function flattenOwned(options) {
  paperGuard();
  const { desk, clientId, ownershipClientIds, ownership = { [desk]: ownershipClientIds }, stateExecutions, ownershipLedgerFile, intent, guard = {}, connect = openSession, readHistory = readPusherExecutions, reconClientId = 700, onPlan = () => {} } = options;
  // History is mandatory BEFORE touching broker state. Recon is never open
  // alongside another connection with the same clientId.
  const history = readHistory(ownershipLedgerFile);
  let executions;
  let orders;
  let owned;
  const recon = await connect(reconClientId);
  try {
    cleanSnapshot(recon);
    executions = mergeExecutions(history, stateExecutions || [], recon.state.executions);
    reconcileDeskPositions(executions, recon.state, ownership, clientId);
    owned = reconcileOwned(executions, recon.state, desk, ownershipClientIds, clientId);
    orders = recon.state.openOrders;
    const preflightOrders = orders.filter((row) => belongsToDesk(row, desk, ownershipClientIds, clientId) && working(row)
      && (intent.action === "cancel" ? (intent.orderId ? row.orderId === intent.orderId : row.orderRef === intent.orderRef) : !KEEP.includes(row.symbol)));
    for (const order of preflightOrders) {
      assertContract(order, order);
      const resolved = await resolveStock(recon, order.symbol);
      assertContract(resolved.contract, order);
    }
    for (const position of owned) {
      assertContract(position, position);
      const resolved = await resolveStock(recon, position.symbol);
      assertContract(resolved.contract, position);
      if (!Number.isSafeInteger(Math.abs(position.quantity))) throw new Error("owned stock quantity is not an integer");
    }
  } finally { recon.close(); }
  const selected = intent.action === "cancel" ? orders.filter((row) => intent.orderId ? row.orderId === intent.orderId : row.orderRef === intent.orderRef) : orders.filter((row) => !KEEP.includes(row.symbol));
  if (intent.action === "cancel" && (!selected.length || selected.some((row) => !working(row) || !belongsToDesk(row, desk, ownershipClientIds, clientId)))) throw new Error("cancel target is not this desk's working order");
  onPlan({ clientId, orderRef: intent.orderRef || null, closing: intent.action === "flatten" ? owned.map((row) => ({ conId: row.conId, symbol: row.symbol, quantity: Math.abs(row.quantity), side: row.quantity > 0 ? "SELL" : "BUY" })) : [], cancellationTargets: selected.filter((row) => belongsToDesk(row, desk, ownershipClientIds, clientId) && working(row)).map((row) => ({ orderId: row.orderId, clientId: row.clientId, orderRef: row.orderRef, quantity: row.quantity })) });
  const cancelled = await cancelOwnedOrders(selected, { desk, ownershipClientIds, executorClientId: clientId, intent, guard, connect });
  if (intent.action === "cancel") return { desk, cancelled, flattened: [], executions };
  let sideEffects = cancelled.length > 0;
  try {
    const confirmation = await connect(reconClientId);
    try {
      cleanSnapshot(confirmation);
      executions = mergeExecutions(executions, confirmation.state.executions);
      if (confirmation.state.openOrders.some((row) => working(row) && !KEEP.includes(row.symbol) && belongsToDesk(row, desk, ownershipClientIds, clientId))) throw new Error("owned working orders remain after cancellation; flatten refused");
      reconcileDeskPositions(executions, confirmation.state, ownership, clientId);
      owned = reconcileOwned(executions, confirmation.state, desk, ownershipClientIds, clientId);
    } finally { confirmation.close(); }
    const placed = [];
    const statuses = [];
    if (owned.length) {
      const session = await connect(clientId);
      try {
        cleanSnapshot(session);
        executions = mergeExecutions(executions, session.state.executions);
        reconcileDeskPositions(executions, session.state, ownership, clientId);
        owned = reconcileOwned(executions, session.state, desk, ownershipClientIds, clientId);
        onPlan({ clientId, orderRef: intent.orderRef, closing: owned.map((row) => ({ conId: row.conId, symbol: row.symbol, quantity: Math.abs(row.quantity), side: row.quantity > 0 ? "SELL" : "BUY" })) });
        let nextId = session.state.nextId;
        if (!Number.isSafeInteger(nextId) || nextId <= 0 || nextId + owned.length > 2147483647) throw new Error("broker order IDs unavailable");
        for (const position of owned) {
          const resolved = await resolveStock(session, position.symbol);
          const expected = { symbol: position.symbol, conId: position.conId };
          before(session, resolved.contract, expected, intent, guard);
          if (!Number.isSafeInteger(Math.abs(position.quantity))) throw new Error("owned stock quantity is not an integer");
          const orderId = nextId++;
          sideEffects = true;
          session.api.placeOrder(orderId, resolved.contract, { account: ACCOUNT, action: position.quantity > 0 ? "SELL" : "BUY", totalQuantity: Math.abs(position.quantity), orderType: "MKT", tif: "DAY", outsideRth: false, orderRef: intent.orderRef, transmit: true });
          placed.push({ orderId, symbol: position.symbol, quantity: Math.abs(position.quantity), clientId });
        }
        await session.wait(4_000);
        statuses.push(...acceptance(session, placed.map((row) => row.orderId), { filledOnly: true, quantities: Object.fromEntries(placed.map((row) => [row.orderId, row.quantity])) }));
        executions = mergeExecutions(executions, session.state.executions);
      } finally { session.close(); }
    }
    return { desk, gateway: true, account: ACCOUNT, keepExcluded: KEEP, cancelled, flattened: placed, statuses, errors: [], executions };
  } catch (error) { if (sideEffects) throw uncertain(error); throw error; }
}

export function publicSnapshot(state, { executions = state.executions, ownership = {}, executorClientId, ownershipComplete = true } = {}) {
  const positions = ownershipComplete ? deskPositions(executions, ownership, executorClientId) : [];
  const deskOf = (row) => DESKS.find((desk) => belongsToDesk(row, desk, ownership[desk] || [], executorClientId)) || null;
  return {
    gateway: state.gateway,
    gatewayStatus: state.gateway && state.account === ACCOUNT ? state.errors.some((row) => [1100, 2110].includes(row.code)) ? "upstream_unavailable" : state.errors.length ? "degraded" : "api_ready" : "unavailable",
    account: state.account, paperPort: PAPER_PORT, fxObservedAt: state.fxObservedAt,
    positions: state.positions.map((row) => ({ ...row, keep: KEEP.includes(row.symbol), desks: positions.filter((position) => position.conId === row.conId) })),
    deskPositions: positions,
    ownershipComplete,
    openOrders: state.openOrders.map((row) => ({ ...row, desk: deskOf(row), keep: KEEP.includes(row.symbol), legs: state.openOrders.filter((leg) => leg.parentId === (row.parentId || row.orderId)).map((leg) => ({ ...leg })) })),
    executions: mergeExecutions(state.executions).filter((row) => executionDay(row.execution.time) === newYorkDay()).map((row) => ({ ...row, desk: deskOf(row.execution), orderRef: row.execution.orderRef || null })),
    pnlPerDesk: ownershipComplete ? pnlPerDesk(executions, state.commissions || [], state.marks || {}, ownership, executorClientId) : Object.fromEntries(DESKS.map((desk) => [desk, { realized: null, unrealized: null, status: "unavailable", reason: "complete ownership history unavailable" }])),
    errors: state.errors,
  };
}

function executionDay(time) {
  const source = String(time || "");
  if (/^\d{4}-\d{2}-\d{2}T/.test(source) && Number.isFinite(Date.parse(source))) return newYorkDay(Date.parse(source));
  const match = source.match(/^(\d{4})(\d{2})(\d{2})[ -]/);
  return match ? `${match[1]}-${match[2]}-${match[3]}` : null;
}

export async function freshMarks(session) {
  const events = session.events;
  const requests = new Map();
  const prices = new Map();
  const ended = new Set();
  const onPrice = (id, field, price) => {
    const row = requests.get(Number(id));
    if (!row || ![1, 2, 4].includes(Number(field)) || !Number.isFinite(Number(price)) || Number(price) <= 0) return;
    const quote = prices.get(Number(id)) || {};
    quote[Number(field)] = Number(price);
    prices.set(Number(id), quote);
  };
  const onEnd = (id) => { if (requests.has(Number(id))) ended.add(Number(id)); };
  session.api.on(events.tickPrice, onPrice);
  session.api.on(events.tickSnapshotEnd, onEnd);
  try {
    for (const row of session.state.positions.filter((row) => row.position !== 0 && !KEEP.includes(row.symbol))) {
      const id = 882000 + requests.size;
      requests.set(id, row);
      // Snapshot quotes are in the contract's native currency. Account-level
      // PnL/value callbacks cannot safely be treated as native prices.
      session.api.reqMktData(id, { conId: row.conId, symbol: row.symbol, secType: row.secType, exchange: "SMART", currency: row.currency }, "", true, false);
    }
    const start = Date.now();
    while (ended.size < requests.size && Date.now() - start < 3000) await session.wait(100);
    for (const [id, row] of requests) {
      const quote = prices.get(id);
      const price = quote?.[1] && quote?.[2] && quote[2] >= quote[1] ? (quote[1] + quote[2]) / 2 : quote?.[4];
      if (Number.isFinite(price) && price > 0) session.state.marks[row.conId] = { price, currency: row.currency, observedAt: new Date().toISOString() };
    }
  } finally {
    for (const id of requests.keys()) session.api.cancelMktData(id);
    session.api.off(events.tickPrice, onPrice);
    session.api.off(events.tickSnapshotEnd, onEnd);
  }
}

function pnlPerDesk(executions, commissions, marks, ownership, clientId) {
  const fees = new Map(commissions.map((row) => [row.execId, row]));
  const today = newYorkDay();
  return Object.fromEntries(DESKS.map((desk) => {
    const lots = new Map();
    const currencies = new Set();
    let realized = 0;
    let dayFees = 0;
    let unrealized = 0;
    let feesComplete = true;
    let marksComplete = true;
    let pricesComplete = true;
    const rows = mergeExecutions(executions).filter((row) => row.execution.acctNumber === ACCOUNT && !KEEP.includes(row.contract.symbol) && belongsToDesk(row.execution, desk, ownership[desk] || [], clientId)).sort((a, b) => String(a.execution.time).localeCompare(String(b.execution.time)) || String(a.execution.execId).localeCompare(String(b.execution.execId)));
    for (const { contract, execution } of rows) {
      currencies.add(contract.currency);
      const price = Number(execution.price);
      if (!Number.isFinite(price) || price <= 0) { pricesComplete = false; continue; }
      const book = lots.get(contract.conId) || [];
      const sign = ["BOT", "BUY"].includes(execution.side) ? 1 : -1;
      let quantity = Number(execution.shares) * sign;
      while (quantity && book.length && Math.sign(book[0].quantity) !== sign) {
        const lot = book[0];
        const matched = Math.min(Math.abs(quantity), Math.abs(lot.quantity));
        if (executionDay(execution.time) === today) realized += (price - lot.price) * matched * Math.sign(lot.quantity);
        lot.quantity += matched * sign;
        quantity -= matched * sign;
        if (Math.abs(lot.quantity) < 1e-9) book.shift();
      }
      if (quantity) book.push({ quantity, price });
      lots.set(contract.conId, book);
      if (executionDay(execution.time) === today) {
        const fee = fees.get(execution.execId);
        if (!fee || fee.currency !== contract.currency || !Number.isFinite(Number(fee.commission))) feesComplete = false;
        else dayFees += Number(fee.commission);
      }
    }
    for (const [conId, book] of lots) {
      if (!book.length) continue;
      const mark = marks[conId];
      if (!mark || !Number.isFinite(mark.price) || mark.price <= 0) { marksComplete = false; continue; }
      for (const lot of book) unrealized += (mark.price - lot.price) * lot.quantity;
    }
    const singleCurrency = currencies.size <= 1;
    return [desk, { day: today, currency: singleCurrency ? [...currencies][0] || "USD" : null, realized: singleCurrency && pricesComplete && feesComplete ? realized - dayFees : null, grossRealized: singleCurrency && pricesComplete ? realized : null, unrealized: singleCurrency && pricesComplete && marksComplete ? unrealized : null, status: singleCurrency && pricesComplete && feesComplete && marksComplete ? "complete" : "unavailable", reason: !singleCurrency ? "mixed native currencies" : !pricesComplete ? "execution prices unavailable" : !feesComplete ? "commissions unavailable" : !marksComplete ? "fresh broker marks unavailable" : null }];
  }));
}
