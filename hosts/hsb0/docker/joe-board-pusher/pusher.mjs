#!/usr/bin/env node
/**
 * Read-only paper IB client (clientId 50) → household v1 → HTTPS POST inbox.
 * Never connects to live 4001. Never places orders.
 */
import fs from "node:fs";
import net from "node:net";
import { IBApi, EventName } from "@stoqey/ib";
import { projectBook } from "./project.mjs";
import { contractKey, createPositionTracker } from "./positions-state.mjs";

const HOST = "100.64.0.6";
const PORT = 4002;
const LIVE_PORT = 4001;
const CLIENT_ID = 50;
const ACCOUNT = "DUR970597";
const INBOX_URL = "https://cs0.barta.cm/joe/inbox";
const TOKEN_FILE = "/run/secrets/joe-board-push-token";
const RETRY_MS = 5000;

function parseIntervalSec() {
  const raw = process.env.JOE_PUSH_INTERVAL_SEC;
  const n = raw === undefined || raw === "" ? 30 : Number(raw);
  if (!Number.isFinite(n) || n < 5 || n > 3600) return 30;
  return Math.floor(n);
}

const INTERVAL_SEC = parseIntervalSec();

let ib = null;
let connecting = false;
let connected = false;
const positionTracker = createPositionTracker(ACCOUNT);
const state = {
  accounts: null,
  positions: [],
  openOrders: [],
  summary: {},
  portfolio: [],
  lastError: null,
  ts: null,
};

function readToken() {
  try {
    return fs.readFileSync(TOKEN_FILE, "utf8").trim();
  } catch (err) {
    console.error("token file read failed", err && err.code ? err.code : err);
    return "";
  }
}

function portUp(host, port) {
  return new Promise((resolve) => {
    const s = net.connect({ host, port }, () => {
      s.destroy();
      resolve(true);
    });
    s.on("error", () => resolve(false));
    s.setTimeout(800, () => {
      s.destroy();
      resolve(false);
    });
  });
}

function bookSnapshot() {
  state.ts = new Date().toISOString();
  return {
    ts: state.ts,
    source: "joe-board-pusher",
    clientId: CLIENT_ID,
    account: ACCOUNT,
    gateway: connected,
    live4001: false,
    lastError: state.lastError,
    accounts: state.accounts,
    summary: state.summary,
    positions: state.positions.filter((p) => p.pos !== 0),
    positionsCoverage: positionTracker.snapshot(),
    openOrders: state.openOrders,
    portfolio: state.portfolio.filter((p) => p.pos !== 0 || p.realizedPNL),
  };
}

async function pushOnce() {
  const liveUp = await portUp(HOST, LIVE_PORT);
  if (liveUp) {
    console.warn("live 4001 appears up on host — ignoring; this pusher stays on paper", PORT);
  }

  const book = bookSnapshot();
  const snap = projectBook(book, { halt: false });
  const token = readToken();
  if (!token) {
    console.error("push skipped: no token");
    return { ok: false, error: "no token" };
  }

  const res = await fetch(INBOX_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      "User-Agent": "joe-board-pusher/1.0",
    },
    body: JSON.stringify(snap),
  });
  const text = await res.text();
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    body = { raw: text.slice(0, 200) };
  }
  const line = {
    ok: res.ok,
    status: res.status,
    equity: snap.totals.equity,
    generatedAt: snap.generatedAt,
    gateway: connected,
    inbox: body,
  };
  console.log(JSON.stringify(line));
  return line;
}

function attach(api) {
  api.on(EventName.connected, () => {
    connected = true;
    connecting = false;
    state.lastError = null;
    positionTracker.onConnected();
    console.log(JSON.stringify({ event: "connected", host: HOST, port: PORT, clientId: CLIENT_ID }));
    api.reqManagedAccts();
    api.reqPositions();
    api.reqAllOpenOrders();
    api.reqAccountSummary(9501, "All", "NetLiquidation,TotalCashValue,BuyingPower,AccountType");
    api.reqAccountUpdates(true, ACCOUNT);
  });
  api.on(EventName.disconnected, () => {
    connected = false;
    connecting = false;
    state.lastError = "disconnected";
    positionTracker.onDisconnected();
    console.warn(JSON.stringify({ event: "disconnected" }));
    setTimeout(connect, RETRY_MS);
  });
  api.on(EventName.error, (err, code) => {
    const message = String(err && err.message ? err.message : err);
    state.lastError = `${code || ""} ${message}`.trim();
    if (code === 502 || /ECONNREFUSED|connect/i.test(message)) {
      connected = false;
      connecting = false;
    }
    if (code && Number(code) >= 2000) return;
    console.warn(JSON.stringify({ event: "ib_error", code, message: message.slice(0, 160) }));
  });
  api.on(EventName.managedAccounts, (a) => {
    state.accounts = a;
  });
  api.on(EventName.accountSummary, (_reqId, account, tag, value, currency) => {
    state.summary[tag] = { account, value, currency };
  });
  api.on(EventName.position, (account, contract, pos, avgCost) => {
    const observedAt = new Date().toISOString();
    positionTracker.onPosition(account, contract, pos, avgCost, observedAt);
    if (account !== ACCOUNT) return;
    const key = contractKey(contract);
    const row = {
      account,
      contractKey: key,
      symbol: contract.symbol,
      exchange: contract.exchange || contract.primaryExch,
      currency: contract.currency,
      secType: contract.secType,
      pos,
      avgCost,
      observedAt,
    };
    state.positions = state.positions.filter((p) => p.contractKey !== key);
    if (Number(pos) !== 0) state.positions.push(row);
  });
  api.on(EventName.positionEnd, () => {
    positionTracker.onPositionEnd();
  });
  api.on(EventName.updatePortfolio, (contract, pos, marketPrice, marketValue, avgCost, unrealizedPNL, realizedPNL) => {
    const observedAt = new Date().toISOString();
    positionTracker.onPortfolio(
      contract,
      pos,
      marketPrice,
      marketValue,
      avgCost,
      unrealizedPNL,
      realizedPNL,
      observedAt
    );
    const key = contractKey(contract);
    const row = {
      contractKey: key,
      symbol: contract.symbol,
      currency: contract.currency,
      secType: contract.secType,
      exchange: contract.exchange || contract.primaryExch,
      pos,
      marketPrice,
      marketValue,
      avgCost,
      unrealizedPNL,
      realizedPNL,
      observedAt,
    };
    state.portfolio = state.portfolio.filter((p) => p.contractKey !== key);
    if (Number(pos) !== 0 || realizedPNL) state.portfolio.push(row);
  });
  api.on(EventName.openOrder, (orderId, contract, order, orderState) => {
    const row = {
      orderId,
      symbol: contract.symbol,
      action: order.action,
      qty: order.totalQuantity,
      type: order.orderType,
      status: orderState && orderState.status,
      account: order.account,
    };
    state.openOrders = state.openOrders.filter((o) => o.orderId !== orderId);
    state.openOrders.push(row);
  });
}

function connect() {
  if (connecting || connected) return;
  connecting = true;
  try {
    if (ib) {
      try {
        ib.disconnect();
      } catch {}
    }
    ib = new IBApi({ host: HOST, port: PORT, clientId: CLIENT_ID });
    attach(ib);
    ib.connect();
  } catch (e) {
    connecting = false;
    connected = false;
    state.lastError = String(e && e.message ? e.message : e);
    setTimeout(connect, RETRY_MS);
  }
}

function shutdown() {
  try {
    if (ib) ib.disconnect();
  } catch {}
  process.exit(0);
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);

connect();

setTimeout(() => {
  pushOnce().catch((e) => console.error("push error", e.message || e));
}, 8000);

setInterval(() => {
  pushOnce().catch((e) => console.error("push error", e.message || e));
}, INTERVAL_SEC * 1000);

setInterval(() => {
  if (!connected && !connecting) connect();
}, 60000);

console.log(
  JSON.stringify({
    service: "joe-board-pusher",
    host: HOST,
    port: PORT,
    clientId: CLIENT_ID,
    intervalSec: INTERVAL_SEC,
    inbox: INBOX_URL,
  })
);
