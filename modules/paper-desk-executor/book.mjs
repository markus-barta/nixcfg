import { ACCOUNT, KEEP, RETIRED_EXECUTOR_CLIENT_IDS, activityAttribution, validateKey } from "./policy.mjs";
import { deskPositions, openMarketDataSession } from "./ib.mjs";
import { attributionConfig, foreignPositions } from "./attribution.mjs";
import { MARKET_DATA_CLIENT_ID } from "./market-data.mjs";

export const BOOK_CLIENT_ID = 708;
const TTL_MS = 15_000;
const MAX_PENDING = 16;
const INFORMATIONAL_CODES = new Set([2100, 2104, 2106, 2107, 2108, 2119, 2158]);
const SUMMARY_TAGS = "NetLiquidation,TotalCashValue,BuyingPower,AccountType";
const failure = (statusCode, reason) => Object.assign(new Error(reason), { statusCode, body: { status: statusCode === 429 ? "rate_limited" : statusCode === 400 ? "rejected" : "unavailable", ...(reason ? { reason } : {}) } });
const unavailable = () => failure(503, "IB paper book snapshot is unavailable");

function pause(ms, signal) {
  signal.throwIfAborted();
  if (ms <= 0) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const finish = (error) => { clearTimeout(timer); signal.removeEventListener("abort", abort); if (error) reject(error); else resolve(); };
    const abort = () => finish(signal.reason);
    const timer = setTimeout(() => finish(), ms);
    signal.addEventListener("abort", abort, { once: true });
  });
}

async function snapshot(session, id, signal, accountEnabled) {
  const { api, events } = session;
  const positions = new Map(), orders = new Map(), summary = new Map();
  const done = new Set();
  let accounts = [];
  let positionsRequested = false, ordersRequested = false, summaryRequested = false;
  const result = () => ({ accounts, positions: [...positions.values()], openOrders: [...orders.values()], summary: Object.fromEntries(summary) });
  const contractFields = (contract) => ({ conId: Number(contract.conId), symbol: contract.symbol, exchange: contract.exchange || contract.primaryExch, primaryExch: contract.primaryExch || "", currency: contract.currency, secType: contract.secType });
  const key = (account, contract) => `${account}:${contract.conId}:${contract.symbol}:${contract.currency}`;
  signal.throwIfAborted();
  let listeners = [];
  let abort;
  try {
    return await new Promise((resolve, reject) => {
      let settled = false;
      const finish = (error) => { if (settled) return; settled = true; if (error) reject(error); else resolve(result()); };
      const completed = (name) => { done.add(name); if (done.size === (accountEnabled ? 3 : 2)) finish(); };
      abort = () => finish(signal.reason);
      listeners = [
        [events.error, (_error, code) => { if (!INFORMATIONAL_CODES.has(Number(code))) finish(Object.assign(unavailable(), { ibCode: Number(code) })); }],
        [events.disconnected, () => finish(unavailable())],
        [events.managedAccounts, (raw) => {
          if (accounts.length) return;
          accounts = String(raw || "").split(",").map((value) => value.trim()).filter(Boolean);
          if (accounts.length !== 1 || accounts[0] !== ACCOUNT) { finish(unavailable()); return; }
          try {
            positionsRequested = true; api.reqPositions();
            ordersRequested = true; api.reqAllOpenOrders();
            if (accountEnabled) { summaryRequested = true; api.reqAccountSummary(id, "All", SUMMARY_TAGS); }
          } catch { finish(unavailable()); }
        }],
        [events.position, (account, contract, pos, avgCost) => { if (account === ACCOUNT) positions.set(key(account, contract), { account, ...contractFields(contract), pos: Number(pos), avgCost: Number(avgCost) }); }],
        [events.positionEnd, () => { if (positionsRequested) completed("positions"); }],
        [events.openOrder, (orderId, contract, order, orderState) => {
          if (order.account !== ACCOUNT) return;
          orders.set(`${order.clientId}:${orderId}`, { account: order.account, ...contractFields(contract), orderId: Number(orderId), permId: Number(order.permId) || null, clientId: Number(order.clientId), orderRef: order.orderRef || "", action: order.action, qty: Number(order.totalQuantity), type: order.orderType, parentId: Number(order.parentId) || 0, status: orderState?.status || "" });
        }],
        [events.openOrderEnd, () => { if (ordersRequested) completed("orders"); }],
        [events.accountSummary, (reqId, account, tag, value, currency) => { if (Number(reqId) === id && account === ACCOUNT && SUMMARY_TAGS.split(",").includes(tag)) summary.set(tag, { account, value, currency }); }],
        [events.accountSummaryEnd, (reqId) => { if (Number(reqId) === id && summaryRequested) completed("summary"); }],
      ];
      for (const [name, listener] of listeners) api.on(name, listener);
      signal.addEventListener("abort", abort, { once: true });
      try { api.reqManagedAccts(); } catch { finish(unavailable()); }
    });
  } finally {
    for (const [name, listener] of listeners) api.off(name, listener);
    signal.removeEventListener("abort", abort);
    if (positionsRequested) { try { api.cancelPositions(); } catch { /* Disconnect releases reads too. */ } }
    if (summaryRequested) { try { api.cancelAccountSummary(id); } catch { /* best effort */ } }
  }
}

function bookBody(raw, endpoint, ledger, config, cached) {
  const broker = { account: ACCOUNT, positions: raw.positions.map((row) => ({ ...row, position: row.pos })) };
  const known = ledger.ownershipComplete === true ? deskPositions(ledger.executions || [], config.ownership, config.executorClientId, broker, config) : [];
  const foreign = foreignPositions(ledger.executions || [], config);
  const annotate = (row) => {
    const desks = known.filter((position) => position.conId === row.conId);
    const keep = KEEP.includes(row.symbol);
    const needsAttribution = !keep && (foreign.some((position) => position.conId === row.conId && position.needsAttribution) || Math.abs(row.pos - desks.reduce((sum, position) => sum + position.quantity, 0)) > 1e-9);
    return { ...row, desks, desk: !keep && !needsAttribution && desks.length === 1 ? desks[0].desk : null, foreign: needsAttribution, needsAttribution, keep };
  };
  const common = { status: "ok", source: "ib", account: ACCOUNT, gateway: true, observedAt: raw.observedAt, attributionObservedAt: ledger.concurrentObservedAt || null, ownershipComplete: ledger.ownershipComplete === true, cached };
  if (endpoint === "positions") return { ...common, positions: raw.positions.map(annotate), deskPositions: known, foreignPositions: foreign };
  if (endpoint === "open-orders") return { ...common, openOrders: raw.openOrders.map((row) => ({ ...row, ...activityAttribution(row, config), keep: KEEP.includes(row.symbol) })) };
  return { ...common, accounts: raw.accounts, summary: raw.summary, values: Object.entries(raw.summary).map(([tag, value]) => ({ tag, ...value })), portfolio: raw.positions.map((row) => annotate({ ...row, marketPrice: null, marketValue: null, unrealizedPNL: null, realizedPNL: null })) };
}

export function createBook(options = {}) {
  const now = options.now || Date.now;
  const elapsed = options.monotonicNow || (() => performance.now());
  const clientId = options.clientId ?? Number(process.env.IB_DESK_BOOK_CLIENT_ID || BOOK_CLIENT_ID);
  const accountEnabled = options.accountEnabled ?? (process.env.PAPER_DESK_BOOK_ACCOUNT_ENABLED === "true");
  const config = attributionConfig({ clientIds: options.orderClientIds, ownership: options.ownershipClientIds, foreignAlertSince: options.foreignAlertSince });
  const marketClientId = options.marketDataClientId ?? Number(process.env.IB_DESK_MARKET_DATA_CLIENT_ID || MARKET_DATA_CLIENT_ID);
  if (!Number.isSafeInteger(clientId) || clientId <= 0 || [...config.ownClientIds, ...RETIRED_EXECUTOR_CLIENT_IDS, ...Object.values(config.ownership).flat(), marketClientId, MARKET_DATA_CLIENT_ID, 40, 92, 94].some((id) => Number(id) === clientId)) throw new Error("book client ID must be distinct from every order, market data, legacy book and pusher client ID");
  const timeoutMs = options.timeoutMs ?? 12_000;
  const reconnectDelayMs = options.reconnectDelayMs ?? 1000;
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0 || !Number.isFinite(reconnectDelayMs) || reconnectDelayMs < 0) throw new Error("book timeouts are invalid");
  const queueWaitMs = timeoutMs + 2 * reconnectDelayMs + 100;
  const runtime = options.runtime || {};
  const readLedger = options.readLedger || (() => ({ executions: [] }));
  let cache, disconnectedAt = -Infinity, cooldownUntil = 0, pending = 0, requestId = 895000;
  let tokens = 6, tokenAt = now(), chain = Promise.resolve();
  const limited = (ms) => Object.assign(failure(429), { body: { status: "rate_limited", retry_after_s: Math.max(1, Math.ceil(ms / 1000)) } });
  const hit = () => cache && now() < cache.expiresAt;
  async function read(endpoint, params = new URLSearchParams(), { signal: clientSignal } = {}) {
    try {
      if (!["positions", "open-orders", "account"].includes(endpoint) || [...params.keys()].some((key) => key !== "desk") || params.getAll("desk").length > 1) throw failure(400, "book query is invalid");
      if (params.has("desk")) {
        try { validateKey(params.get("desk"), "desk"); } catch { throw failure(400, "desk is invalid"); }
      }
      if (endpoint === "account" && !accountEnabled) throw failure(503, "account book reads are disabled until OPS verifies pusher coexistence");
      if (clientSignal?.aborted) throw unavailable();
      if (hit()) return { statusCode: 200, body: bookBody(cache.raw, endpoint, await readLedger(), config, true) };
      if (pending >= MAX_PENDING) throw limited(queueWaitMs);
      pending += 1;
      const controller = new AbortController();
      const { signal } = controller;
      const abort = () => controller.abort(unavailable());
      clientSignal?.addEventListener("abort", abort, { once: true });
      let timer;
      const deadline = new Promise((_resolve, reject) => {
        signal.addEventListener("abort", () => reject(signal.reason), { once: true });
        timer = setTimeout(() => controller.abort(limited(queueWaitMs)), queueWaitMs);
      });
      const work = async () => {
        signal.throwIfAborted();
        clearTimeout(timer);
        if (hit()) return { raw: cache.raw, cached: true };
        const time = now();
        tokens = Math.min(6, tokens + Math.max(0, time - tokenAt) / 1000); tokenAt = time;
        if (time < cooldownUntil) throw limited(cooldownUntil - time);
        const readCost = accountEnabled ? 4 : 3;
        if (tokens < readCost) throw limited((readCost - tokens) * 1000);
        tokens -= readCost;
        timer = setTimeout(() => controller.abort(unavailable()), timeoutMs + 2 * reconnectDelayMs);
        let session;
        try {
          for (let attempt = 0; attempt < 2; attempt += 1) {
            await pause(Math.max(0, Math.ceil(disconnectedAt + reconnectDelayMs - elapsed())), signal);
            try { session = await openMarketDataSession(clientId, runtime, signal); break; }
            catch (error) { disconnectedAt = elapsed(); if (Number(error?.ibCode) !== 326 || attempt === 1) throw error; }
          }
          signal.throwIfAborted();
          const raw = { ...await snapshot(session, ++requestId, signal, accountEnabled), observedAt: new Date(now()).toISOString() };
          signal.throwIfAborted();
          cache = { raw, expiresAt: now() + TTL_MS };
          return { raw, cached: false };
        } finally {
          if (session) { session.close(); disconnectedAt = elapsed(); }
        }
      };
      const run = chain.then(work, work);
      chain = run.then(() => {}, () => {});
      try {
        const result = await Promise.race([run, deadline]);
        signal.throwIfAborted();
        return { statusCode: 200, body: bookBody(result.raw, endpoint, await readLedger(), config, result.cached) };
      } finally { clearTimeout(timer); clientSignal?.removeEventListener("abort", abort); pending -= 1; }
    } catch (error) {
      if (Number(error?.ibCode) === 100) cooldownUntil = now() + 600_000;
      const safe = error?.body ? error : unavailable();
      return { statusCode: safe.statusCode, body: safe.body };
    }
  }
  return { clientId, read };
}
