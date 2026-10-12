import { DESKS } from "./policy.mjs";
import { openMarketDataSession, resolveStock } from "./ib.mjs";

export const MARKET_DATA_CLIENT_ID = 707;
const QUOTE_TTL = 15_000;
const BARS_TTL = 60_000;
const CONTRACT_TTL = 3_600_000;
const RECONNECT_DELAY = 1000;
const HISTORY_WINDOW = 600_000;
const HISTORY_SPACING = 15_000;
const TOKEN_CAPACITY = 6;
const TOKEN_INTERVAL = 1000;
const MAX_PENDING = 16;
const MAX_CACHE_SYMBOLS = 256;
const INFORMATIONAL_CODES = new Set([2104, 2106, 2107, 2108, 2119, 2158]);
const PRICE_FIELDS = new Map([[1, "bid"], [2, "ask"], [4, "last"], [9, "close"], [66, "bid"], [67, "ask"], [68, "last"], [75, "close"]]);
const DATA_TYPES = new Map([[1, "realtime"], [2, "frozen"], [3, "delayed"], [4, "delayed-frozen"]]);

export function validMarketSymbol(symbol) {
  return typeof symbol === "string" && symbol.match(/^[A-Z][A-Z0-9.]{0,9}$/)?.[0] === symbol;
}

class DataError extends Error {
  constructor(statusCode, body) {
    super(body.reason || body.status);
    this.statusCode = statusCode;
    this.body = body;
  }
}
const unavailable = (reason) => new DataError(503, { status: "unavailable", reason });
const rateLimited = (milliseconds) => new DataError(429, { status: "rate_limited", retry_after_s: Math.max(1, Math.ceil(milliseconds / 1000)) });

function brokerFailure(code, message = "") {
  if (Number(code) === 162) {
    if (/pac(e|ing)|too many/i.test(message)) return unavailable("IB historical pacing limit (162)");
    if (/permission|subscri/i.test(message)) return unavailable("IB historical data permissions are unavailable (162)");
    return unavailable("IB historical data is unavailable (162: no data, pacing or permissions)");
  }
  const reasons = new Map([
    [100, "IB request pacing limit (100)"],
    [354, "IB market data permissions are unavailable (354)"],
    [420, "IB market data pacing limit (420)"],
    [10089, "IB market data subscription is unavailable (10089)"],
    [10167, "IB offered delayed data but no usable prices arrived (10167)"],
    [10168, "IB delayed market data is not enabled (10168)"],
    [1100, "IB upstream connection is unavailable (1100)"],
    [2110, "IB upstream connection is unavailable (2110)"],
  ]);
  return unavailable(reasons.get(Number(code)) || "IB market data request failed");
}

function query(endpoint, params) {
  const reject = (reason) => { throw new DataError(400, { status: "rejected", reason }); };
  const symbol = params.get("symbol");
  const desk = params.get("desk");
  if (params.getAll("symbol").length !== 1 || !validMarketSymbol(symbol)) reject("symbol must be an uppercase US stock symbol");
  if (params.getAll("desk").length !== 1 || !DESKS.includes(desk)) reject("desk must be one of the configured desks");
  let count = 24;
  if (endpoint === "bars" && params.has("count")) {
    const value = params.get("count");
    if (params.getAll("count").length !== 1 || !/^[1-9][0-9]?$/.test(value) || String(Number(value)) !== value || Number(value) > 78) reject("count must be an integer from 1 to 78");
    count = Number(value);
  }
  return { symbol, desk, count };
}

const nyClock = new Intl.DateTimeFormat("en-CA", {
  timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
});
function nyParts(now) {
  return Object.fromEntries(nyClock.formatToParts(new Date(now)).filter((part) => part.type !== "literal").map((part) => [part.type, Number(part.value)]));
}
function nyInstant(date, minutes) {
  const target = Date.UTC(Number(date.slice(0, 4)), Number(date.slice(4, 6)) - 1, Number(date.slice(6, 8)), Math.floor(minutes / 60), minutes % 60);
  let result = target;
  for (let i = 0; i < 2; i += 1) {
    const p = nyParts(result);
    result += target - Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
  }
  return result;
}
function schedule(resolved) {
  const days = new Map();
  if (!["", "US/Eastern", "America/New_York", "EST"].includes(resolved.timeZoneId)) return days;
  for (const item of resolved.liquidHours.split(";")) {
    const match = item.match(/^(\d{8}):(.*)$/);
    if (!match) continue;
    if (match[2] === "CLOSED") { days.set(match[1], []); continue; }
    const windows = [];
    for (const part of match[2].split(",")) {
      const window = part.match(/^(\d{2})(\d{2})-(?:(\d{8}):)?(\d{2})(\d{2})$/);
      if (!window) continue;
      const start = nyInstant(match[1], Number(window[1]) * 60 + Number(window[2]));
      const end = nyInstant(window[3] || match[1], Number(window[4]) * 60 + Number(window[5]));
      if (end > start) windows.push([start, end]);
    }
    if (windows.length) days.set(match[1], windows);
  }
  return days;
}
function dayKey(date) { return date.toISOString().slice(0, 10).replaceAll("-", ""); }
function windowsFor(date, days) {
  const key = dayKey(date);
  if (days.has(key)) return days.get(key);
  if ([0, 6].includes(date.getUTCDay())) return [];
  return [[nyInstant(key, 570), nyInstant(key, 960)]];
}
function marketClock(resolved, now, count) {
  const p = nyParts(now);
  const date = new Date(Date.UTC(p.year, p.month - 1, p.day));
  const days = schedule(resolved);
  const closed = !windowsFor(date, days).some(([start, end]) => now >= start && now < end);
  let remaining = count * 300_000;
  let cursor = now;
  // Duration is wall-clock time, even with useRTH=1. Include overnight/weekend
  // gaps and IB's supplied CLOSED/short-session days instead of losing bars.
  for (let i = 0; i < 30 && remaining > 0; i += 1) {
    for (const [start, end] of [...windowsFor(date, days)].reverse()) {
      const last = Math.min(now, end);
      const available = Math.max(0, last - start);
      if (available >= remaining) { cursor = last - remaining; remaining = 0; break; }
      remaining -= available;
    }
    if (remaining > 0) date.setUTCDate(date.getUTCDate() - 1);
  }
  const seconds = Math.max(300, Math.ceil((now - cursor) / 1000));
  return { closed, duration: seconds <= 86_400 ? `${seconds} S` : `${Math.ceil(seconds / 86_400)} D` };
}

function ibRequest(session, { id, signal, subscribe, start, cancel, onError }) {
  signal.throwIfAborted();
  let requested = false;
  return new Promise((resolve, reject) => {
    let settled = false;
    let listeners = [];
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      for (const [name, listener] of listeners) session.api.off(name, listener);
      signal.removeEventListener("abort", abort);
      if (error) reject(error); else resolve(value);
    };
    const abort = () => finish(signal.reason);
    listeners = [
      ...subscribe(finish),
      [session.events.disconnected, () => finish(unavailable("IB market data connection closed"))],
      [session.events.error, (error, code, requestId) => {
        const numeric = Number(code);
        if (INFORMATIONAL_CODES.has(numeric)) return;
        if (Number(requestId) !== id && ![100, 1100, 2110].includes(numeric)) return;
        if (onError?.(numeric, error) === true) return;
        finish(brokerFailure(numeric, String(error?.message || error)));
      }],
    ];
    for (const [name, listener] of listeners) session.api.on(name, listener);
    signal.addEventListener("abort", abort, { once: true });
    try { requested = true; start(); } catch { finish(unavailable("IB market data request failed")); }
  }).finally(() => {
    if (requested) { try { cancel(id); } catch { /* disconnect also releases the request */ } }
  });
}

function pause(milliseconds, signal) {
  signal.throwIfAborted();
  if (milliseconds <= 0) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const finish = (error) => {
      clearTimeout(timer);
      signal.removeEventListener("abort", abort);
      if (error) reject(error); else resolve();
    };
    const abort = () => finish(signal.reason);
    const timer = setTimeout(() => finish(), milliseconds);
    signal.addEventListener("abort", abort, { once: true });
  });
}

function price(value) {
  if (value === null || value === undefined || value === "") return null;
  const numeric = Number(value);
  return Number.isFinite(numeric) && numeric > 0 && numeric < 1e100 ? numeric : null;
}
async function snapshot(session, contract, type, id, signal, onWarning) {
  const values = { bid: null, ask: null, last: null, close: null };
  let actualType = type;
  let announced = false;
  let warning = null;
  return ibRequest(session, {
    id, signal,
    start: () => { session.api.reqMarketDataType(type); session.api.reqMktData(id, contract, "", true, false); },
    cancel: (requestId) => session.api.cancelMktData(requestId),
    onError: (code) => {
      if (![354, 10089, 10167].includes(code)) return false;
      warning = code;
      onWarning(code);
      return true; // IB may warn about live permissions, then deliver delayed ticks.
    },
    subscribe: (finish) => [
      [session.events.marketDataType, (requestId, value) => {
        if (Number(requestId) !== id) return;
        if (!DATA_TYPES.has(Number(value))) { finish(unavailable("IB returned an unsupported market data type")); return; }
        actualType = Number(value); announced = true;
      }],
      [session.events.tickPrice, (requestId, field, value) => {
        const name = PRICE_FIELDS.get(Number(field));
        if (Number(requestId) !== id || !name) return;
        values[name] = price(value);
        if (!announced) actualType = Number(field) >= 66 ? type : 1;
      }],
      [session.events.tickSnapshotEnd, (requestId) => {
        if (Number(requestId) !== id) return;
        if (warning && Object.values(values).every((value) => value === null)) finish(brokerFailure(warning));
        else finish(null, { ...values, marketDataType: DATA_TYPES.get(actualType) });
      }],
    ],
  });
}

function barTime(value) {
  // formatDate=2 explicitly requests Unix seconds; never interpret the
  // Gateway's timezone-dependent date strings as workstation-local time.
  if (!/^\d{9,11}$/.test(String(value))) throw unavailable("IB returned an invalid historical bar timestamp");
  const seconds = Number(value);
  if (!Number.isSafeInteger(seconds) || seconds <= 0) throw unavailable("IB returned an invalid historical bar timestamp");
  return new Date(seconds * 1000).toISOString();
}
function barNumber(value, volume = false) {
  const numeric = Number(value);
  if (value === null || value === undefined || value === "" || !Number.isFinite(numeric) || numeric < 0 || numeric >= 1e100 || (!volume && numeric === 0)) throw unavailable("IB returned an invalid historical bar value");
  return numeric;
}
async function history(session, contract, duration, count, id, signal, now) {
  const bars = new Map();
  return ibRequest(session, {
    id, signal,
    start: () => session.api.reqHistoricalData(id, contract, "", duration, "5 mins", "TRADES", 1, 2, false),
    cancel: (requestId) => session.api.cancelHistoricalData(requestId),
    subscribe: (finish) => [
      [session.events.historicalData, (requestId, time, open, high, low, close, volume) => {
        if (Number(requestId) !== id) return;
        // Older @stoqey/ib transports signal completion with a synthetic
        // finished row rather than exporting historicalDataEnd.
        if (/^finished(?:-|$)/.test(String(time)) && [open, high, low, close, volume].every((value) => Number(value) === -1)) {
          finish(null, [...bars.values()].sort((a, b) => a.t.localeCompare(b.t)));
          return;
        }
        try {
          // @stoqey/ib's pinned runtime emits positional bar fields.
          const row = { t: barTime(time), o: barNumber(open), h: barNumber(high), l: barNumber(low), c: barNumber(close), v: barNumber(volume, true) };
          if (row.l > Math.min(row.o, row.c) || row.h < Math.max(row.o, row.c) || row.l > row.h) throw unavailable("IB returned inconsistent historical bar prices");
          // Mark the captured row before waiting for historicalDataEnd:
          // crossing a bar boundary cannot complete an earlier snapshot.
          const received = now();
          const start = Date.parse(row.t);
          if (start <= received && received < start + 300_000) row.partial = true;
          bars.set(row.t, row);
          // Retain only the newest N even if IB rounds a duration to a session.
          if (bars.size > count) bars.delete([...bars.keys()].sort()[0]);
        } catch (error) { finish(error); }
      }],
      ...(session.events.historicalDataEnd ? [[session.events.historicalDataEnd, (requestId) => {
        if (Number(requestId) === id) finish(null, [...bars.values()].sort((a, b) => a.t.localeCompare(b.t)));
      }]] : []),
    ],
  });
}

export function createMarketData(options = {}) {
  const now = options.now || Date.now;
  const elapsed = options.monotonicNow || (() => performance.now());
  // IB's natural snapshot end is ~11 seconds. Leave one second of headroom;
  // the deadline starts on leaving our queue and includes reconnect backoff,
  // connection, lookup and data callbacks.
  const timeoutMs = options.timeoutMs ?? 12_000;
  const reconnectDelayMs = options.reconnectDelayMs ?? RECONNECT_DELAY;
  const clientId = options.clientId ?? Number(process.env.IB_DESK_MARKET_DATA_CLIENT_ID || MARKET_DATA_CLIENT_ID);
  const orderIds = Object.values(options.orderClientIds ?? JSON.parse(process.env.IB_DESK_CLIENT_IDS || '{"recon":700,"executor":705}'));
  const ownershipIds = Object.values(options.ownershipClientIds ?? JSON.parse(process.env.IB_DESK_OWNERSHIP_CLIENT_IDS || "{}")).flat();
  if (!Number.isSafeInteger(clientId) || clientId <= 0 || [...orderIds, ...ownershipIds, 92, 94, 700, 701, 702, 703, 704, 705, 706].some((id) => Number(id) === clientId)) throw new Error("market data client ID must be distinct from every order and pusher client ID");
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new Error("market data timeout must be positive");
  if (!Number.isFinite(reconnectDelayMs) || reconnectDelayMs < 0) throw new Error("market data reconnect delay must be nonnegative");
  const runtime = options.runtime || {};
  const cache = { quote: new Map(), bars: new Map() };
  const contracts = new Map();
  const historicalTimes = [];
  const lastHistorical = new Map();
  let tokens = TOKEN_CAPACITY;
  let tokenTime = now();
  let chain = Promise.resolve();
  let pending = 0;
  let requestId = 890000;
  let cooldownUntil = 0;
  let disconnectedAt = -Infinity;

  function takeToken() {
    const time = now();
    if (time < cooldownUntil) throw rateLimited(cooldownUntil - time);
    tokens = Math.min(TOKEN_CAPACITY, tokens + Math.max(0, time - tokenTime) / TOKEN_INTERVAL);
    tokenTime = time;
    if (tokens < 1) throw rateLimited((1 - tokens) * TOKEN_INTERVAL);
    tokens -= 1;
  }
  function checkHistory(conId) {
    const time = now();
    while (historicalTimes.length && historicalTimes[0] <= time - HISTORY_WINDOW) historicalTimes.shift();
    for (const [key, stamp] of lastHistorical) if (stamp <= time - HISTORY_SPACING) lastHistorical.delete(key);
    const prior = lastHistorical.get(conId);
    // Stronger than identical-request pacing: all counts/desks for a contract
    // share this interval, including failed or timed-out historical requests.
    if (prior !== undefined) throw rateLimited(prior + HISTORY_SPACING - time);
    if (historicalTimes.length >= 60) throw rateLimited(historicalTimes[0] + HISTORY_WINDOW - time);
  }
  function takeHistory(conId) {
    checkHistory(conId);
    const time = now();
    historicalTimes.push(time);
    lastHistorical.set(conId, time);
  }
  function cachedContract(symbol) {
    const item = contracts.get(symbol);
    if (!item || item.expiresAt <= now()) { contracts.delete(symbol); return null; }
    return item.resolved;
  }
  function rememberContract(symbol, resolved) {
    contracts.delete(symbol);
    if (contracts.size >= MAX_CACHE_SYMBOLS) contracts.delete(contracts.keys().next().value);
    contracts.set(symbol, { resolved, expiresAt: now() + CONTRACT_TTL });
  }
  async function connect(signal) {
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const readyAt = disconnectedAt + reconnectDelayMs;
      while (elapsed() < readyAt) await pause(Math.ceil(readyAt - elapsed()), signal);
      signal.throwIfAborted();
      try { return await openMarketDataSession(clientId, runtime, signal); }
      catch (error) {
        // openMarketDataSession closes even a failed handshake. Give the
        // Gateway time to release this ID; retry only an ID-in-use error once.
        disconnectedAt = elapsed();
        if (Number(error?.ibCode) !== 326 || attempt === 1) throw error;
      }
    }
  }
  function cached(endpoint, symbol, count) {
    const item = cache[endpoint].get(symbol);
    if (!item || item.expiresAt <= now() || (endpoint === "bars" && item.count < count)) return null;
    return { ...item.body, ...(endpoint === "bars" ? { bars: item.body.bars.slice(-count) } : {}), cached: true };
  }
  function remember(endpoint, symbol, count, body) {
    const entries = cache[endpoint];
    entries.delete(symbol);
    if (entries.size >= MAX_CACHE_SYMBOLS) entries.delete(entries.keys().next().value);
    entries.set(symbol, { count, body, expiresAt: now() + (endpoint === "quote" ? QUOTE_TTL : BARS_TTL) });
  }
  async function read(endpoint, params) {
    let warningCode;
    try {
      const { symbol, count } = query(endpoint, params);
      const hit = cached(endpoint, symbol, count);
      if (hit) return { statusCode: 200, body: hit };
      if (pending >= MAX_PENDING) throw rateLimited(timeoutMs);
      pending += 1;
      const work = async () => {
        const reused = cached(endpoint, symbol, count);
        if (reused) return reused;
        const known = cachedContract(symbol);
        // Refuse history pacing before any connection or contract lookup.
        // A first lookup supplies the conId; check it again before dispatch
        // in case another symbol resolved to the same contract.
        if (endpoint === "bars") checkHistory(known?.contract.conId);
        takeToken(); // Reserve the data call before opening a socket.
        if (!known) takeToken(); // An uncached contract lookup also costs a token.
        const controller = new AbortController();
        const { signal } = controller;
        const deadline = elapsed() + timeoutMs;
        const timeoutError = () => unavailable(warningCode ? `IB market data request timed out after permissions warning (${warningCode})` : "IB market data request timed out");
        const checkDeadline = () => {
          if (elapsed() >= deadline && !signal.aborted) controller.abort(timeoutError());
          signal.throwIfAborted();
        };
        const timer = setTimeout(() => controller.abort(timeoutError()), timeoutMs);
        let session;
        try {
          session = await connect(signal);
          checkDeadline();
          const resolved = known || await resolveStock(session, symbol, ++requestId, { readOnly: true, signal });
          if (!known) rememberContract(symbol, resolved);
          checkDeadline();
          const clock = marketClock(resolved, now(), count);
          let body;
          if (endpoint === "quote") {
            const onWarning = (code) => { warningCode = code; };
            let quote = await snapshot(session, resolved.contract, clock.closed ? 4 : 3, ++requestId, signal, onWarning);
            if (!clock.closed && quote.marketDataType === "delayed" && ["bid", "ask", "last", "close"].every((name) => quote[name] === null)) {
              takeToken();
              quote = await snapshot(session, resolved.contract, 4, ++requestId, signal, onWarning);
            }
            body = { symbol, conId: resolved.contract.conId, ...quote, observedAt: new Date(now()).toISOString(), source: "ib", cached: false };
          } else {
            takeHistory(resolved.contract.conId);
            const bars = await history(session, resolved.contract, clock.duration, count, ++requestId, signal, now);
            body = { symbol, conId: resolved.contract.conId, barSize: "5m", bars, observedAt: new Date(now()).toISOString(), cached: false };
          }
          checkDeadline();
          remember(endpoint, symbol, count, body);
          return body;
        } finally {
          clearTimeout(timer);
          if (session) {
            session.close();
            disconnectedAt = elapsed();
          }
        }
      };
      // This promise chain belongs solely to data; the server's intent lock is
      // never acquired. Queued work gets its own full deadline when it starts;
      // retain the lock until cancellation and disconnect have both finished.
      const run = chain.then(work, work);
      chain = run.then(() => {}, () => {});
      try { return { statusCode: 200, body: await run }; }
      finally { pending -= 1; }
    } catch (error) {
      if (error?.code === "contract_not_found") return { statusCode: 404, body: { status: "not_found", reason: "symbol has no unique USD stock contract" } };
      if (error?.code === "market_data_timeout") error = unavailable("IB contract lookup timed out");
      if (error?.ibCode) error = brokerFailure(error.ibCode);
      if (!(error instanceof DataError)) error = unavailable("IB market data request failed");
      if (/IB .*pacing limit/.test(error.body.reason || "")) cooldownUntil = now() + HISTORY_WINDOW;
      return { statusCode: error.statusCode, body: error.body };
    }
  }
  return { clientId, read };
}
