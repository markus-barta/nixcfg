import { createHash } from "node:crypto";

export const SCHEMA = "barta.paper-desk-intent.v1";
export const ACCOUNT = "DUR970597";
export const PAPER_PORT = 4002;
export const KEEP = Object.freeze(["SXR8", "TSLA"]);
export const DESKS = Object.freeze(["j", "j5", "joe", "joel"]);
export const LIMITS = Object.freeze({
  perNameRiskEur: 25,
  dailyRiskEur: 50,
  notionalEur: 1000,
  newPerDay: 2,
  concurrent: 3,
  minStopFraction: 0.005,
  fxSafetyBuffer: 1.02,
});

function fail(message) {
  throw new Error(message);
}

function object(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail(`${label} must be an object`);
  return value;
}

function exactKeys(value, allowed, label) {
  const extra = Object.keys(value).filter((key) => !allowed.includes(key));
  if (extra.length) fail(`${label} has unsupported field(s): ${extra.join(", ")}`);
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
  exactKeys(value, ["schema", "intentId", "desk", "action", "createdAt", "expiresAt", "order"], "intent");
  if (value.schema !== SCHEMA) fail(`schema must be ${SCHEMA}`);
  const intentId = text(value.intentId, "intentId", /^[a-zA-Z0-9][a-zA-Z0-9._:-]{7,63}$/);
  const desk = text(value.desk, "desk").toLowerCase();
  if (!DESKS.includes(desk)) fail("desk is not authorized");
  const action = text(value.action, "action").toLowerCase();
  if (!["recon", "place", "flatten"].includes(action)) fail("action is not supported");
  const createdAt = instant(value.createdAt, "createdAt");
  const expiresAt = instant(value.expiresAt, "expiresAt");
  if (createdAt > now + 60_000) fail("createdAt is in the future");
  if (expiresAt <= now) fail("intent is expired");
  if (expiresAt - createdAt > 15 * 60_000) fail("intent validity exceeds 15 minutes");
  if (now - createdAt > 15 * 60_000) fail("intent is stale");
  if (action !== "place" && value.order !== undefined) fail("order is allowed only for place");
  let order = null;
  if (action === "place") {
    order = object(value.order, "order");
    exactKeys(order, ["symbol", "side", "quantity", "limitPrice", "stopPrice", "currency"], "order");
    const symbol = text(order.symbol, "symbol", /^[A-Z][A-Z0-9.]{0,9}$/).toUpperCase();
    if (KEEP.includes(symbol)) fail(`${symbol} is KEEP and can never be traded`);
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
  };
}

export function placementBudget(order, usdToEur) {
  if (typeof usdToEur !== "number" || !Number.isFinite(usdToEur) || usdToEur <= 0) fail("fresh IB USD/EUR rate is required");
  const bufferedFx = usdToEur * LIMITS.fxSafetyBuffer;
  const riskEur = Math.abs(order.limitPrice - order.stopPrice) * order.quantity * bufferedFx;
  const notionalEur = order.limitPrice * order.quantity * bufferedFx;
  return {
    riskEur: Math.round(riskEur * 100) / 100,
    notionalEur: Math.round(notionalEur * 100) / 100,
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

export function evaluatePlacement(intent, snapshot, state, { halt = false, stockType, usdToEur } = {}) {
  if (intent.action !== "place") fail("placement evaluation requires a place intent");
  if (halt) fail("HALT is active: new orders are refused");
  if (!["COMMON", "ADR"].includes(String(stockType || "").toUpperCase())) fail("contract is not proven to be a non-ETF stock");
  const budget = placementBudget(intent.order, usdToEur);
  if (budget.riskEur > LIMITS.perNameRiskEur) fail(`per-name risk ${budget.riskEur} exceeds EUR ${LIMITS.perNameRiskEur}`);
  if (budget.notionalEur > LIMITS.notionalEur) fail(`notional ${budget.notionalEur} exceeds EUR ${LIMITS.notionalEur}`);
  // Daily brakes are keyed from the host clock, never the caller-controlled timestamp.
  const day = newYorkDay();
  if (!Number.isFinite(Date.parse(state.initializedAt)) || newYorkDay(Date.parse(state.initializedAt)) === day) {
    fail("new orders are refused on the ledger initialization day; prior daily risk is unproven");
  }
  const today = (state.placements || []).filter((row) => row.day === day && row.status !== "rejected");
  if (today.length >= LIMITS.newPerDay) fail(`daily new-order limit ${LIMITS.newPerDay} reached`);
  const dailyRisk = today.reduce((sum, row) => sum + Number(row.riskEur || 0), 0);
  if (dailyRisk + budget.riskEur > LIMITS.dailyRiskEur) fail(`daily risk would exceed EUR ${LIMITS.dailyRiskEur}`);
  const symbols = activeSymbols(snapshot);
  if (symbols.has(intent.order.symbol)) fail("symbol already has account position or working order; piling is refused");
  if (symbols.size >= LIMITS.concurrent) fail(`concurrent-name limit ${LIMITS.concurrent} reached`);
  return { ...budget, day, concurrentBefore: symbols.size, usdToEur, fxSafetyBuffer: LIMITS.fxSafetyBuffer };
}

function correctionIdentity(execId) {
  const match = String(execId || "").match(/^(.*\.)(\d+)$/);
  if (!match || match[1] === ".") fail("execution ID has no correction revision");
  return { prefix: match[1], revision: BigInt(match[2]) };
}

export function mergeExecutions(...collections) {
  const latest = new Map();
  for (const row of collections.flat()) {
    if (!row?.contract || !row?.execution) fail("execution ledger row is malformed");
    const id = text(row.execution.execId, "execution execId");
    const identity = correctionIdentity(id);
    const prior = latest.get(identity.prefix);
    if (!prior || identity.revision > prior.revision) latest.set(identity.prefix, { identity, row });
  }
  return [...latest.values()].map(({ row }) => row);
}

export function ownedPositions(executions, ownershipClientIds, account = ACCOUNT) {
  const clients = new Set(ownershipClientIds);
  const positions = new Map();
  for (const row of mergeExecutions(executions)) {
    const contract = row.contract;
    const execution = row.execution;
    if (execution.acctNumber !== account || !clients.has(Number(execution.clientId))) continue;
    const symbol = String(contract.symbol || "").toUpperCase();
    if (KEEP.includes(symbol)) continue;
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
    };
    prior.quantity += signed;
    positions.set(key, prior);
  }
  return [...positions.values()].filter((row) => Math.abs(row.quantity) > 1e-9).sort((a, b) => a.symbol.localeCompare(b.symbol));
}

export function activeHalt(localBody, remoteIssues = []) {
  if (String(localBody || "").trim()) return { active: true, source: "local" };
  const issue = remoteIssues.find((row) => String(row.body || "").trim());
  return issue ? { active: true, source: `github-issue-${issue.number}` } : { active: false, source: null };
}
