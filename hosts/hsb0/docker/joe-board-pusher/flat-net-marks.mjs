/**
 * Shared-account mark source for open virtual lots whose broker net is flat.
 * IB account-portfolio callbacks omit a contract once the account quantity is
 * zero. An explicit market-data tick is the mark; nothing here invents a price,
 * a SOD baseline, or a DAY value. Exclusive-mode callers never use this path.
 */

const ALWAYS_EXCLUDED = new Set(["SXR8", "TSLA"]);
const QUANTITY_EPSILON = 1e-9;
// Broker-published last/close prices only. Bid/ask midpoints are not observed marks.
const ACCEPTED_TICK_TYPES = new Set([4, 9, 68, 75]);

function finiteNumber(value) {
  return typeof value === "number" && Number.isFinite(value) && Math.abs(value) !== Number.MAX_VALUE
    ? value
    : null;
}

function positivePrice(value) {
  const number = finiteNumber(value);
  return number !== null && number > 0 ? number : null;
}

function symbolOf(contract) {
  return typeof contract?.symbol === "string" ? contract.symbol.trim().toUpperCase() : "";
}

export function contractKey(contract) {
  const conId = Number(contract?.conId);
  if (Number.isInteger(conId) && conId > 0) return `conId:${conId}`;
  const symbol = symbolOf(contract);
  const secType = typeof contract?.secType === "string" ? contract.secType.trim().toUpperCase() : "";
  const currency = typeof contract?.currency === "string" ? contract.currency.trim().toUpperCase() : "";
  return symbol && secType && currency ? `${symbol}:${secType}:${currency}` : null;
}

function honestMark(row) {
  const price = positivePrice(row?.marketPrice);
  const observedAt = typeof row?.markObservedAt === "string" ? row.markObservedAt : "";
  if (price === null || Number.isNaN(Date.parse(observedAt))) return null;
  return { marketPrice: price, markObservedAt: observedAt };
}

function signedQuantity(execution) {
  const shares = finiteNumber(execution?.shares);
  if (shares === null || shares <= 0) return null;
  const side = typeof execution?.side === "string" ? execution.side.trim().toUpperCase() : "";
  if (side === "BOT" || side === "BUY") return shares;
  if (side === "SLD" || side === "SELL") return -shares;
  return null;
}

function flat(value) {
  return Math.abs(value) <= QUANTITY_EPSILON;
}

/**
 * Contracts where a virtual desk is still open, the account net is flat, and
 * the portfolio has no explicit positive price clock. KEEP symbols are never
 * selected. A usable portfolio row, including a zero-quantity row, suppresses
 * the request.
 */
export function contractsNeedingFlatNetMarks({
  executions = [],
  positions = [],
  portfolio = [],
  account,
  familyClientIds = [],
  excludedSymbols = [],
} = {}) {
  const excluded = new Set([...ALWAYS_EXCLUDED, ...excludedSymbols.map((value) => String(value).trim().toUpperCase())]);
  const familyIds = new Set(familyClientIds);
  const positionQty = new Map();
  for (const row of positions) {
    const key = contractKey(row?.contract);
    const qty = finiteNumber(row?.pos);
    if (!key || qty === null || excluded.has(symbolOf(row.contract))) continue;
    positionQty.set(key, qty);
  }
  const marked = new Set();
  for (const row of portfolio) {
    const key = contractKey(row?.contract);
    if (key && honestMark(row)) marked.add(key);
  }
  const nets = new Map();
  for (const record of executions) {
    if (record?.execution?.acctNumber !== account) continue;
    const contract = record.contract;
    const symbol = symbolOf(contract);
    if (!symbol || excluded.has(symbol)) continue;
    const key = contractKey(contract);
    const signed = signedQuantity(record.execution);
    if (!key || signed === null) continue;
    const bucket = nets.get(key) || { contract, family: 0, other: 0 };
    const clientId = record.execution.clientId;
    if (familyIds.has(clientId)) bucket.family += signed;
    else bucket.other += signed;
    bucket.contract = contract;
    nets.set(key, bucket);
  }
  const needed = [];
  for (const [key, bucket] of nets) {
    const observed = positionQty.has(key) ? positionQty.get(key) : 0;
    const replayed = bucket.family + bucket.other;
    if (flat(observed) && flat(replayed) && (!flat(bucket.family) || !flat(bucket.other)) && !marked.has(key)) {
      needed.push({ key, contract: bucket.contract });
    }
  }
  needed.sort((left, right) => left.key.localeCompare(right.key));
  return needed;
}

/** Append explicit flat-net marks without replacing a broker portfolio row. */
export function mergeFlatNetMarks(portfolio = [], marks = []) {
  const rows = portfolio.map((row) => ({ ...row, contract: row.contract ? { ...row.contract } : row.contract }));
  const present = new Set(rows.map((row) => contractKey(row.contract)).filter(Boolean));
  for (const mark of marks) {
    const key = contractKey(mark?.contract);
    const honest = honestMark(mark);
    if (!key || !honest || present.has(key) || ALWAYS_EXCLUDED.has(symbolOf(mark.contract))) continue;
    present.add(key);
    rows.push({
      contract: { ...mark.contract },
      symbol: symbolOf(mark.contract),
      pos: 0,
      marketPrice: honest.marketPrice,
      markObservedAt: honest.markObservedAt,
      observedAt: honest.markObservedAt,
      markSource: "flat-net-market-data",
    });
  }
  return rows;
}

/**
 * Paper market-data subscription for the contracts selected above.
 * Only an accepted tick records a price and moves its clock. Resubscribe
 * requests a new explicit callback; it does not refresh the previous clock.
 */
export function createFlatNetMarkController({
  request,
  cancel,
  setMarketDataType,
  onEvent = () => {},
  now = () => new Date().toISOString(),
  tickerIdStart = 9801,
  refreshAfterMs = 240_000,
} = {}) {
  if (typeof request !== "function" || typeof cancel !== "function") {
    throw new TypeError("request and cancel are required");
  }
  const byKey = new Map();
  let nextTickerId = tickerIdStart;
  let marketDataTypeSet = false;

  function drop(entry) {
    try { cancel(entry.tickerId); } catch {}
    byKey.delete(entry.key);
  }

  return {
    reset() {
      for (const entry of byKey.values()) drop(entry);
      marketDataTypeSet = false;
    },

    sync(contracts = []) {
      const wanted = new Map(contracts.map((row) => [row.key, row]));
      for (const entry of [...byKey.values()]) {
        if (!wanted.has(entry.key)) drop(entry);
      }
      const observedNow = Date.parse(now());
      for (const row of wanted.values()) {
        const existing = byKey.get(row.key);
        const age = existing?.markObservedAt ? observedNow - Date.parse(existing.markObservedAt) : 0;
        if (existing && !(Number.isFinite(age) && age >= refreshAfterMs)) continue;
        if (existing) {
          try { cancel(existing.tickerId); } catch {}
        }
        if (!marketDataTypeSet && typeof setMarketDataType === "function") {
          setMarketDataType(4);
          marketDataTypeSet = true;
        }
        const tickerId = existing?.tickerId || nextTickerId++;
        const entry = existing || { key: row.key, contract: row.contract, tickerId, marketPrice: null, markObservedAt: null };
        entry.contract = row.contract;
        entry.tickerId = tickerId;
        byKey.set(row.key, entry);
        try {
          request(tickerId, row.contract);
          onEvent({ event: "flat_net_mark_requested", tickerId });
        } catch {
          onEvent({ event: "flat_net_mark_request_failed", tickerId });
        }
      }
    },

    onTick(tickerId, tickType, price) {
      if (!ACCEPTED_TICK_TYPES.has(Number(tickType))) return false;
      const marketPrice = positivePrice(price);
      if (marketPrice === null) return false;
      const entry = [...byKey.values()].find((row) => row.tickerId === tickerId);
      if (!entry) return false;
      entry.marketPrice = marketPrice;
      entry.markObservedAt = now();
      onEvent({ event: "flat_net_mark_observed", tickerId });
      return true;
    },

    marks() {
      return [...byKey.values()]
        .filter((entry) => honestMark(entry))
        .map((entry) => ({
          contract: { ...entry.contract },
          marketPrice: entry.marketPrice,
          markObservedAt: entry.markObservedAt,
        }));
    },
  };
}
