import { createHash } from "node:crypto";

export const SCHEMA = "barta.paper-desk-intent.v2";
export const ACCOUNT = "DUR970597";
export const PAPER_PORT = 4002;
export const KEEP = Object.freeze(["SXR8", "TSLA"]);
export const DESKS = Object.freeze(["j", "j2", "j3", "j4", "j5", "joe", "joel"]);
export const LIMITS = Object.freeze({
  perNameRiskEur: 25,
  dailyRiskEur: 50,
  notionalEur: 1000,
  newPerDay: 2,
  concurrent: 3,
  fleetConcurrent: 6,
  minStopFraction: 0.005,
  fxSafetyBuffer: 1.02,
});

function fail(message, publicCode = "invalid_intent") {
  const error = new Error(message);
  error.publicCode = publicCode;
  throw error;
}

const RESERVED_KEYS = new Set(["__proto__", "constructor", "prototype"]);

// Only desk identity is case-insensitive; preserve the date and thesis bytes.
export function normalizeOrderRef(value) {
  const [desk, ...segments] = String(value || "").split("|");
  return [desk.toLowerCase(), ...segments].join("|");
}

export function validateKey(value, kind) {
  if (typeof value !== "string" || RESERVED_KEYS.has(value.toLowerCase())) fail(`${kind} is invalid`);
  if (kind === "orderRef") value = normalizeOrderRef(value);
  const valid = kind === "intentId" ? /^[A-Za-z0-9][A-Za-z0-9._:-]{7,63}$/.test(value)
    : kind === "desk" ? DESKS.includes(value)
    : kind === "symbol" ? /^[A-Z][A-Z0-9.]{0,9}$/.test(value)
    : kind === "orderRef" ? /^[a-z0-9]+\|\d{6}\|[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/.test(value)
      && DESKS.includes(value.split("|")[0]) && !RESERVED_KEYS.has(value.split("|")[2].toLowerCase())
    : false;
  if (!valid) fail(`${kind} is invalid`);
  return value;
}

function object(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail(`${label} must be an object`);
  return value;
}

function exactKeys(value, allowed, label) {
  const extra = Object.keys(value).filter((key) => !allowed.includes(key));
  if (extra.length) fail(`${label} has unsupported field(s): ${extra.join(", ")}`, "unsupported_field");
}

function text(value, label, pattern) {
  if (typeof value !== "string" || !value.trim() || value !== value.trim()) fail(`${label} is invalid`);
  if (pattern && !pattern.test(value)) fail(`${label} is invalid`);
  return value;
}

function positive(value, label) {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) fail(`${label} must be positive`);
  return value;
}

function instant(value, label) {
  const source = text(value, label, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$/);
  const epoch = Date.parse(source);
  if (!Number.isFinite(epoch)) fail(`${label} is invalid`);
  return epoch;
}

export function stable(value) {
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stable(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

export function digest(value) {
  return createHash("sha256").update(stable(value)).digest("hex");
}

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

export function parseIntent(raw, now = Date.now()) {
  const value = object(raw, "intent");
  exactKeys(value, ["schema", "intentId", "desk", "action", "createdAt", "expiresAt", "order", "orderRef", "orderId", "symbol"], "intent");
  if (value.schema !== SCHEMA) fail(`schema must be ${SCHEMA}`, "invalid_schema");
  const intentId = validateKey(value.intentId, "intentId");
  const desk = text(value.desk, "desk").toLowerCase();
  if (!DESKS.includes(desk)) fail("desk is not authorized");
  validateKey(desk, "desk");
  const action = text(value.action, "action").toLowerCase();
  if (!["recon", "place", "flatten", "cancel"].includes(action)) fail("action is not supported");
  const createdAt = instant(value.createdAt, "createdAt");
  const expiresAt = instant(value.expiresAt, "expiresAt");
  if (createdAt > now + 60_000) fail("createdAt is in the future");
  if (expiresAt <= now) fail("intent is expired");
  if (expiresAt - createdAt > 15 * 60_000) fail("intent validity exceeds 15 minutes");
  if (now - createdAt > 15 * 60_000) fail("intent is stale");
  if (action !== "place" && value.order !== undefined) fail("order is allowed only for place", "invalid_order");
  let symbol;
  if (value.symbol !== undefined) {
    if (!["flatten", "cancel"].includes(action)) fail("symbol is allowed only for flatten or cancel");
    symbol = validateKey(value.symbol, "symbol");
    if (KEEP.includes(symbol)) fail(`${symbol} is KEEP and can never be traded`, "keep_protected");
  }
  let orderRef;
  if (value.orderRef !== undefined) {
    orderRef = validateKey(value.orderRef, "orderRef");
    if (orderRef.split("|")[0] !== desk) fail("orderRef belongs to another desk");
  }
  if (["place", "flatten"].includes(action) && !orderRef) orderRef = `${desk}|${newYorkDay(createdAt).replaceAll("-", "").slice(2)}|${intentId}`;
  if (value.orderId !== undefined && (action !== "cancel" || !Number.isSafeInteger(value.orderId) || value.orderId <= 0)) fail("orderId is allowed only for cancel and must be positive");
  if (action === "cancel" && Boolean(orderRef) === Boolean(value.orderId)) fail("cancel requires exactly one of orderRef or orderId");
  if (!["place", "cancel", "flatten"].includes(action) && orderRef) fail("orderRef is allowed only for place, flatten or cancel");
  let order = null;
  if (action === "place") {
    order = object(value.order, "order");
    exactKeys(order, ["symbol", "side", "quantity", "limitPrice", "stopPrice", "currency"], "order");
    const symbol = validateKey(order.symbol, "symbol");
    if (KEEP.includes(symbol)) fail(`${symbol} is KEEP and can never be traded`, "keep_protected");
    const side = text(order.side, "side").toUpperCase();
    if (!["BUY", "SELL"].includes(side)) fail("side must be BUY or SELL");
    if (!Number.isSafeInteger(order.quantity) || order.quantity <= 0) fail("quantity must be a positive integer");
    const limitPrice = positive(order.limitPrice, "limitPrice");
    const stopPrice = positive(order.stopPrice, "stopPrice");
    if ((side === "BUY" && stopPrice >= limitPrice) || (side === "SELL" && stopPrice <= limitPrice)) {
      fail("stopPrice must protect the entry side");
    }
    const stopFraction = Math.abs(limitPrice - stopPrice) / limitPrice;
    if (stopFraction + Number.EPSILON < LIMITS.minStopFraction) fail("protective stop must be at least 0.5% from entry");
    if (order.currency !== "USD") fail("only USD Stage-0 stocks are accepted");
    order = { symbol, side, quantity: order.quantity, limitPrice, stopPrice, currency: "USD" };
  }
  return {
    schema: SCHEMA,
    intentId,
    desk,
    action,
    createdAt: new Date(createdAt).toISOString(),
    expiresAt: new Date(expiresAt).toISOString(),
    ...(order ? { order } : {}),
    ...(orderRef ? { orderRef } : {}),
    ...(value.orderId ? { orderId: value.orderId } : {}),
    ...(symbol ? { symbol } : {}),
  };
}

export function placementBudget(order, usdToEur) {
  if (typeof usdToEur !== "number" || !Number.isFinite(usdToEur) || usdToEur <= 0) fail("fresh IB USD/EUR rate is required");
  const bufferedFx = usdToEur * LIMITS.fxSafetyBuffer;
  const riskEur = Math.abs(order.limitPrice - order.stopPrice) * order.quantity * bufferedFx;
  const notionalEur = order.limitPrice * order.quantity * bufferedFx;
  return {
    riskEur: Math.ceil(riskEur * 100) / 100,
    notionalEur: Math.ceil(notionalEur * 100) / 100,
  };
}

function activeSymbols(snapshot) {
  const result = new Set();
  for (const row of snapshot.positions || []) {
    const symbol = String(row.symbol || "").toUpperCase();
    if (Number(row.position) !== 0 && !KEEP.includes(symbol)) result.add(symbol);
  }
  for (const row of snapshot.openOrders || []) {
    const symbol = String(row.symbol || "").toUpperCase();
    const status = String(row.status || "").toLowerCase();
    if (symbol && !KEEP.includes(symbol) && !["cancelled", "filled", "inactive"].includes(status)) result.add(symbol);
  }
  return result;
}

export function brakeUsage(state, epoch = Date.now(), { blockOnInitDay = false } = {}) {
  const day = newYorkDay(epoch);
  const today = (state?.placements || []).filter((row) => row.day === day && row.status !== "rejected");
  const dailyRiskEur = Math.round(today.reduce((sum, row) => sum + Number(row.riskEur || 0), 0) * 100) / 100;
  const initializedAt = Date.parse(state?.initializedAt);
  return {
    day,
    newToday: today.length,
    newPerDay: LIMITS.newPerDay,
    newOrderLimitScope: "per_desk",
    concurrentObservedAt: state.concurrentObservedAt || null,
    dailyRiskEur,
    dailyRiskEurLimit: LIMITS.dailyRiskEur,
    perNameRiskEur: LIMITS.perNameRiskEur,
    notionalEur: LIMITS.notionalEur,
    concurrent: LIMITS.concurrent,
    fleetConcurrent: LIMITS.fleetConcurrent,
    perDesk: Object.fromEntries(DESKS.map((desk) => [desk, {
      newToday: today.filter((row) => row.desk === desk).length,
      newPerDay: LIMITS.newPerDay,
      concurrent: new Set([
        ...(state.ownershipComplete === false ? state.accountActiveSymbols || [] : []),
        ...(state.deskPositions || []).filter((row) => row.desk === desk && row.quantity !== 0 && !KEEP.includes(row.symbol)).map((row) => row.symbol),
        ...(state.activeOrders || []).filter((row) => row.desk === desk && !KEEP.includes(row.symbol) && !["filled", "cancelled", "inactive", "apicancelled"].includes(String(row.status).toLowerCase())).map((row) => row.symbol),
        ...(state.placements || []).filter((row) => row.desk === desk && ["reserved", "uncertain", "partial"].includes(row.status)).map((row) => row.symbol),
      ]).size,
      concurrentLimit: LIMITS.concurrent,
    }])),
    minStopFraction: LIMITS.minStopFraction,
    fxSafetyBuffer: LIMITS.fxSafetyBuffer,
    keep: KEEP,
    placementBlockedOnInitDay: blockOnInitDay && (!Number.isFinite(initializedAt) || newYorkDay(initializedAt) === day),
    ledgerInitializedAt: state?.initializedAt || null,
  };
}

export function evaluatePlacement(intent, snapshot, state, { halt = false, stockType, usdToEur, blockOnInitDay = false } = {}) {
  if (intent.action !== "place") fail("placement evaluation requires a place intent");
  if (halt) fail("HALT is active: new orders are refused");
  if (!["COMMON", "ADR"].includes(String(stockType || "").toUpperCase())) fail("contract is not proven to be a non-ETF stock");
  const budget = placementBudget(intent.order, usdToEur);
  if (budget.riskEur > LIMITS.perNameRiskEur) fail(`per-name risk ${budget.riskEur} exceeds EUR ${LIMITS.perNameRiskEur}`);
  if (budget.notionalEur > LIMITS.notionalEur) fail(`notional ${budget.notionalEur} exceeds EUR ${LIMITS.notionalEur}`);
  // Daily brakes are keyed from the host clock, never the caller-controlled timestamp.
  const day = newYorkDay();
  if (blockOnInitDay && (!Number.isFinite(Date.parse(state.initializedAt)) || newYorkDay(Date.parse(state.initializedAt)) === day)) {
    fail("new orders are refused on the ledger initialization day; prior daily risk is unproven");
  }
  const today = (state.placements || []).filter((row) => row.day === day && row.status !== "rejected");
  if (today.filter((row) => row.desk === intent.desk).length >= LIMITS.newPerDay) fail(`daily new-order limit ${LIMITS.newPerDay} reached`);
  const dailyRisk = today.reduce((sum, row) => sum + Number(row.riskEur || 0), 0);
  if (dailyRisk + budget.riskEur > LIMITS.dailyRiskEur) fail(`daily risk would exceed EUR ${LIMITS.dailyRiskEur}`);
  const symbols = activeSymbols(snapshot);
  if (symbols.has(intent.order.symbol)) fail("symbol already has account position or working order; piling is refused");
  const deskSymbols = new Set((snapshot.deskPositions || []).filter((row) => row.desk === intent.desk && row.quantity !== 0 && !KEEP.includes(row.symbol)).map((row) => row.symbol));
  if (snapshot.ownershipComplete === false) for (const symbol of symbols) deskSymbols.add(symbol);
  for (const row of snapshot.openOrders || []) {
    if (row.desk === intent.desk && !KEEP.includes(row.symbol) && !["cancelled", "filled", "inactive", "apicancelled"].includes(String(row.status).toLowerCase())) deskSymbols.add(row.symbol);
  }
  for (const row of state.placements || []) {
    if (["reserved", "uncertain", "partial"].includes(row.status)) {
      symbols.add(row.symbol);
      if (row.desk === intent.desk) deskSymbols.add(row.symbol);
    }
  }
  if (symbols.has(intent.order.symbol)) fail("symbol already has account position, working order or unresolved placement; piling is refused");
  if (deskSymbols.size >= LIMITS.concurrent) fail(`desk concurrent-name limit ${LIMITS.concurrent} reached`);
  if (symbols.size >= LIMITS.fleetConcurrent) fail(`fleet concurrent-name limit ${LIMITS.fleetConcurrent} reached`);
  if ((state.placements || []).some((row) => thesisKey(row.orderRef) === thesisKey(intent.orderRef) && ["reserved", "uncertain", "partial"].includes(row.status))) fail("thesis has an unresolved intent; reconcile before retry");
  if ([...(state.intents || new Map())].some(([id, row]) => id !== intent.intentId && thesisKey(row.orderRef) === thesisKey(intent.orderRef) && ["claimed", "uncertain"].includes(row.status))) fail("thesis has an unresolved intent; reconcile before retry");
  return { ...budget, day, concurrentBefore: symbols.size, usdToEur, fxSafetyBuffer: LIMITS.fxSafetyBuffer };
}

function correctionIdentity(execId) {
  const match = String(execId || "").match(/^(.*\.)(\d+)$/);
  if (!match || match[1] === ".") fail("execution ID has no correction revision");
  return { prefix: match[1], revision: BigInt(match[2]) };
}

function executionSecond(value, cache) {
  if (value === undefined || value === null) return null;
  const source = value instanceof Date && Number.isFinite(value.getTime()) ? value.toISOString() : String(value).trim();
  if (cache.has(source)) return cache.get(source);
  let epoch = NaN;
  if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(source)) epoch = Date.parse(source);
  else {
    const match = source.match(/^(\d{4})(\d{2})(\d{2})([ -]+)(\d{2}):(\d{2}):(\d{2})(?:\s+(.+))?$/);
    if (match) {
      const expected = [match[1], match[2], match[3], match[5], match[6], match[7]].map(Number);
      // IB's hyphen format is UTC; unzoned legacy gateway times are New York local.
      const zone = match[8] || (match[4] === "-" ? "UTC" : "America/New_York");
      try {
        const format = new Intl.DateTimeFormat("en-CA", { timeZone: zone, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23" });
        const naive = Date.UTC(expected[0], expected[1] - 1, expected[2], expected[3], expected[4], expected[5]);
        const candidates = [];
        for (let offset = -14 * 60; offset <= 14 * 60; offset += 15) {
          const candidate = naive - offset * 60_000;
          const parts = Object.fromEntries(format.formatToParts(new Date(candidate)).filter((part) => part.type !== "literal").map((part) => [part.type, Number(part.value)]));
          if ([parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second].every((part, i) => part === expected[i])) candidates.push(candidate);
        }
        if (candidates.length === 1) epoch = candidates[0];
      } catch { /* Unsupported or ambiguous timestamps cannot prove an economic match. */ }
    }
  }
  const second = Number.isFinite(epoch) ? Math.floor(epoch / 1000) : NaN;
  cache.set(source, second);
  return second;
}

function executionConflicts(left, right, timeCache) {
  const fields = [];
  const normalizedText = (value) => String(value || "").trim().toUpperCase();
  const numeric = (value) => {
    if (value === undefined || value === null) return null;
    const number = typeof value === "number" || (typeof value === "string" && value.trim()) ? Number(value) : NaN;
    return Number.isFinite(number) ? number : NaN;
  };
  const differs = (field, a, b) => { if (a !== b || Number.isNaN(a) || Number.isNaN(b)) fields.push(field); };
  const a = left.contract, b = right.contract;
  if (Number(a.conId) > 0 && Number(b.conId) > 0) differs("conId", Number(a.conId), Number(b.conId));
  else for (const field of ["symbol", "secType", "currency"]) {
    const first = normalizedText(a[field]), second = normalizedText(b[field]);
    if (!first || !second || first !== second) fields.push(field);
  }
  const side = (value) => ({ BOT: "BUY", BUY: "BUY", SLD: "SELL", SELL: "SELL" })[normalizedText(value)] || NaN;
  differs("side", side(left.execution.side), side(right.execution.side));
  differs("shares", numeric(left.execution.shares), numeric(right.execution.shares));
  const priceA = numeric(left.execution.price), priceB = numeric(right.execution.price);
  if (!(priceA === null && priceB === null) && !(priceA !== null && priceB !== null && Number.isFinite(priceA) && Number.isFinite(priceB) && Math.abs(priceA - priceB) < 1e-6)) fields.push("price");
  if (left.execution.clientId != null && right.execution.clientId != null) differs("clientId", numeric(left.execution.clientId), numeric(right.execution.clientId));
  differs("time", executionSecond(left.execution.time, timeCache), executionSecond(right.execution.time, timeCache));
  return fields;
}

export function mergeExecutions(...collections) {
  const latest = new Map();
  const timeCache = new Map();
  for (const row of collections.flat()) {
    if (!row?.contract || !row?.execution) fail("execution ledger row is malformed");
    const id = text(row.execution.execId, "execution execId");
    const identity = correctionIdentity(id);
    const prior = latest.get(identity.prefix);
    if (!prior || identity.revision > prior.identity.revision) latest.set(identity.prefix, { identity, row });
    else if (identity.revision === prior.identity.revision) {
      const fields = executionConflicts(prior.row, row, timeCache);
      if (fields.length) {
        console.error(`conflicting duplicate execution revision fields: ${fields.join(", ")}`);
        fail("conflicting duplicate execution revision");
      }
      // Callers supply retained history first and fresh broker snapshots last.
      const present = (value) => Object.fromEntries(Object.entries(value).filter(([, item]) => item != null));
      prior.row = { ...prior.row, ...row, contract: { ...prior.row.contract, ...present(row.contract) }, execution: { ...prior.row.execution, ...present(row.execution) } };
    }
  }
  return [...latest.values()].map(({ row }) => row);
}

// Only a matching same-session account position proves a flat boundary. Keep
// full history on malformed evidence or a mismatch so reconciliation stays closed.
export function ownershipSinceFlat(executions, snapshot, account = ACCOUNT) {
  if (snapshot?.account !== account || !Array.isArray(snapshot.positions) || snapshot.ownershipComplete === false) return executions;
  const rows = mergeExecutions(executions);
  const contracts = new Map(), timeCache = new Map(), resets = new Map();
  for (const row of rows) {
    const { contract, execution } = row;
    const symbol = String(contract.symbol || "").toUpperCase(), conId = Number(contract.conId);
    if (execution.acctNumber !== account || KEEP.includes(symbol) || !Number.isSafeInteger(conId) || conId <= 0) continue;
    const group = contracts.get(conId) || { symbol, currency: String(contract.currency || "").toUpperCase(), valid: true, fills: [] };
    const second = executionSecond(execution.time, timeCache), shares = Number(execution.shares), side = String(execution.side || "").toUpperCase();
    const signed = ["BOT", "BUY"].includes(side) ? shares : ["SLD", "SELL"].includes(side) ? -shares : NaN;
    if (!Number.isFinite(second) || !Number.isFinite(shares) || shares <= 0 || !Number.isFinite(signed) || !/^[A-Z][A-Z0-9.]{0,9}$/.test(symbol) || String(contract.secType || "").toUpperCase() !== "STK" || group.symbol !== symbol || group.currency !== String(contract.currency || "").toUpperCase()) group.valid = false;
    group.fills.push({ second, signed }); contracts.set(conId, group);
  }
  for (const [conId, group] of contracts) {
    if (!group.valid) continue;
    const actual = snapshot.positions.filter((row) => Number(row.conId) === conId);
    if (actual.length > 1 || actual.some((row) => row.symbol !== group.symbol || !Number.isFinite(row.position) || row.account && row.account !== account)) continue;
    group.fills.sort((a, b) => a.second - b.second);
    let net = 0, flat = -Infinity;
    for (let i = 0; i < group.fills.length; i++) {
      net += group.fills[i].signed;
      // IB time has second precision; an intermediate fill cannot prove flat.
      if (group.fills[i + 1]?.second !== group.fills[i].second && Math.abs(net) <= 1e-9) flat = group.fills[i].second;
    }
    if (Math.abs(net - (actual[0]?.position || 0)) <= 1e-9 && flat !== -Infinity) resets.set(conId, flat);
  }
  return rows.filter((row) => row.execution.acctNumber !== account || KEEP.includes(String(row.contract.symbol || "").toUpperCase()) || !resets.has(Number(row.contract.conId)) || executionSecond(row.execution.time, timeCache) > resets.get(Number(row.contract.conId)));
}

export function ownedPositions(executions, ownershipClientIds, account = ACCOUNT, desk = null, executorClientId = null, snapshot) {
  const clients = new Set(ownershipClientIds);
  const positions = new Map();
  for (const row of mergeExecutions(ownershipSinceFlat(executions, snapshot, account))) {
    const contract = row.contract;
    const execution = row.execution;
    if (execution.acctNumber !== account) continue;
    if (desk) {
      if (!belongsToDesk(execution, desk, ownershipClientIds, executorClientId)) continue;
    } else if (!clients.has(Number(execution.clientId))) continue;
    const symbol = String(contract.symbol || "").toUpperCase();
    if (KEEP.includes(symbol)) continue;
    if (!/^[A-Z][A-Z0-9.]{0,9}$/.test(symbol) || !Number.isSafeInteger(Number(contract.conId)) || Number(contract.conId) <= 0) fail("owned contract identity is missing");
    if (String(contract.secType || "").toUpperCase() !== "STK") fail("owned execution is not stock");
    const side = String(execution.side || "").toUpperCase();
    const shares = positive(Number(execution.shares), "execution shares");
    const signed = ["BOT", "BUY"].includes(side) ? shares : ["SLD", "SELL"].includes(side) ? -shares : fail("execution side is invalid");
    const key = Number(contract.conId) > 0 ? `conId:${Number(contract.conId)}` : `${symbol}:${contract.currency}`;
    const prior = positions.get(key) || {
      conId: Number(contract.conId) || 0,
      symbol,
      currency: String(contract.currency || "").toUpperCase(),
      secType: "STK",
      quantity: 0,
      ...(desk ? { desk, orderRefs: [] } : {}),
    };
    if (prior.symbol !== symbol || prior.currency !== String(contract.currency || "").toUpperCase()) fail("conflicting contract identity");
    if (desk && execution.orderRef && !prior.orderRefs.includes(execution.orderRef)) prior.orderRefs.push(execution.orderRef);
    prior.quantity += signed;
    positions.set(key, prior);
  }
  return [...positions.values()].filter((row) => Math.abs(row.quantity) > 1e-9).sort((a, b) => a.symbol.localeCompare(b.symbol));
}

// Halt is host-local. Desks may set the file through the API. Clearing it is
// removing /var/lib/paper-desk-executor/HALT on hsb0. There is no remote halt.
export function activeHalt(localBody) {
  if (String(localBody || "").trim()) return { active: true, source: "local" };
  return { active: false, source: null };
}

export function belongsToDesk(row, desk, legacyClientIds, executorClientId) {
  desk = typeof desk === "string" ? desk.toLowerCase() : null;
  if (!DESKS.includes(desk)) return false;
  const clientId = Number(row.clientId);
  const ref = normalizeOrderRef(row.orderRef);
  if (/^[a-z0-9]+\|\d{6}\|[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/.test(ref)) return ref.split("|")[0] === desk && (clientId === executorClientId || legacyClientIds.includes(clientId));
  if (ref.includes("|")) return false;
  return clientId !== executorClientId && legacyClientIds.includes(clientId);
}

export function assertSideEffect(intent, { getHalt = () => ({ active: false }), now = Date.now } = {}) {
  if (!Number.isFinite(Date.parse(intent.expiresAt)) || Date.parse(intent.expiresAt) <= now()) fail("intent is expired before broker side effect");
  const halt = getHalt();
  if (intent.action === "place" && halt.active) fail("HALT is active: new orders are refused");
  return halt;
}

export function thesisKey(ref) { const [desk, _date, thesis] = normalizeOrderRef(ref).split("|"); return thesis ? `${desk}|${thesis}` : ref; }
