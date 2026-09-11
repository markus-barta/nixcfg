import fs from "node:fs";
import path from "node:path";

import {
  bestAvailableHistoryDigest,
  effectiveExecutionRecords,
  reconcileExecutionCapture,
  validateBestAvailableHistoryState,
} from "./execution-reconciliation.mjs";

const MAX_STATE_BYTES = 32 * 1024 * 1024;
const MAX_CAPTURED_SUBTOTAL_POINTS = 2048;

function clone(value) {
  return structuredClone(value);
}

function iso(value) {
  const epoch = Date.parse(value || "");
  return Number.isFinite(epoch) ? new Date(epoch).toISOString() : null;
}

const newYorkFormatter = new Intl.DateTimeFormat("en-CA", {
  timeZone: "America/New_York",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hourCycle: "h23",
});

function executionInstant(value) {
  if (typeof value !== "string") return null;
  if (/^\d{4}-\d{2}-\d{2}T/.test(value)) return iso(value);
  const match = value.match(/^(\d{4})(\d{2})(\d{2})\s+(\d{2}):(\d{2}):(\d{2})\s+(?:US\/Eastern|America\/New_York)$/);
  if (!match) return null;
  const expected = match.slice(1).map(Number);
  const naive = Date.UTC(expected[0], expected[1] - 1, expected[2], expected[3], expected[4], expected[5]);
  const candidates = [];
  for (let offset = -14 * 60; offset <= 14 * 60; offset += 15) {
    const candidate = naive - offset * 60_000;
    const parts = {};
    for (const part of newYorkFormatter.formatToParts(new Date(candidate))) {
      if (part.type !== "literal") parts[part.type] = Number(part.value);
    }
    const actual = [parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second];
    if (actual.every((part, index) => part === expected[index])) candidates.push(candidate);
  }
  return candidates.length === 1 ? new Date(candidates[0]).toISOString() : null;
}

function contractKey(contract) {
  if (Number.isSafeInteger(contract?.conId) && contract.conId > 0) return `conId:${contract.conId}`;
  const symbol = String(contract?.symbol || "").trim().toUpperCase();
  const type = String(contract?.secType || "").trim().toUpperCase();
  const currency = String(contract?.currency || "").trim().toUpperCase();
  return symbol && type && currency ? `${symbol}:${type}:${currency}` : "unknown-contract";
}

function includedFamilyRows(state) {
  const ids = new Set(state.classifier.familyClientIds);
  const excluded = new Set(state.classifier.excludedSymbols);
  return effectiveExecutionRecords(state).filter((row) =>
    ids.has(row.execution.clientId) && !excluded.has(String(row.contract.symbol || "").trim().toUpperCase()));
}

function latestVerifiedPeriod(coverage) {
  const intervals = coverage.completeIntervals;
  if (!intervals.length) return null;
  const latest = [...intervals].sort((a, b) => b.toExclusive.localeCompare(a.toExclusive))[0];
  return clone(latest);
}

function sideQuantity(row) {
  return row.execution.side === "BUY" || row.execution.side === "BOT"
    ? row.execution.shares
    : -row.execution.shares;
}

function addMoney(totals, currency, amount) {
  totals.set(currency, (totals.get(currency) || 0) + amount);
}

function addRealizedEvent(events, row, currency, amount) {
  if (amount === 0) return;
  events.push({
    at: executionInstant(row.execution.time),
    currency,
    delta: amount,
  });
}

function capturedSubtotalCurve(events, nativeRealizedPnl) {
  if (nativeRealizedPnl.length !== 1 || events.some((event) => event.at === null)) {
    return { points: [], pointsTruncated: false };
  }
  const [{ currency, realizedPnl }] = nativeRealizedPnl;
  if (events.some((event) => event.currency !== currency)) {
    return { points: [], pointsTruncated: false };
  }
  const deltas = new Map();
  for (const event of events) addMoney(deltas, event.at, event.delta);
  let cumulative = 0;
  const points = [...deltas.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([at, delta]) => {
      cumulative += delta;
      return { at, realizedPnl: cumulative };
    });
  if (points.length > 0) {
    const tolerance = Math.max(1, Math.abs(realizedPnl)) * 1e-10;
    if (Math.abs(points.at(-1).realizedPnl - realizedPnl) > tolerance) {
      return { points: [], pointsTruncated: false };
    }
    points.at(-1).realizedPnl = realizedPnl;
  }
  return {
    points: points.slice(-MAX_CAPTURED_SUBTOTAL_POINTS),
    pointsTruncated: points.length > MAX_CAPTURED_SUBTOTAL_POINTS,
  };
}

function missingOpeningLots(rows, fees) {
  const netByContract = new Map();
  const missing = [];
  const batches = new Map();
  for (const row of rows) {
    const key = `${contractKey(row.contract)}\u0000${executionInstant(row.execution.time)}`;
    if (!batches.has(key)) batches.set(key, []);
    batches.get(key).push(row);
  }
  for (const batch of batches.values()) {
    const key = contractKey(batch[0].contract);
    const prior = netByContract.get(key) || 0;
    const buys = batch.filter((row) => sideQuantity(row) > 0);
    const sells = batch.filter((row) => sideQuantity(row) < 0);
    const buyQuantity = buys.reduce((sum, row) => sum + row.execution.shares, 0);
    const sellQuantity = sells.reduce((sum, row) => sum + row.execution.shares, 0);
    const realizedBuys = buys.filter((row) => Number.isFinite(fees.get(row.execution.execId)?.realizedPNL) && fees.get(row.execution.execId).realizedPNL !== 0);
    const realizedSells = sells.filter((row) => Number.isFinite(fees.get(row.execution.execId)?.realizedPNL) && fees.get(row.execution.execId).realizedPNL !== 0);
    const realizedBuyQuantity = realizedBuys.reduce((sum, row) => sum + row.execution.shares, 0);
    const realizedSellQuantity = realizedSells.reduce((sum, row) => sum + row.execution.shares, 0);
    const missingShort = Math.max(0, realizedBuyQuantity - Math.max(-prior, 0) - sellQuantity);
    const missingLong = Math.max(0, realizedSellQuantity - Math.max(prior, 0) - buyQuantity);
    if (missingShort > 0) missing.push({
      contractKey: key,
      quantity: missingShort,
      firstExecutionId: realizedBuys[0].execution.execId,
    });
    if (missingLong > 0) missing.push({
      contractKey: key,
      quantity: missingLong,
      firstExecutionId: realizedSells[0].execution.execId,
    });
    netByContract.set(key, prior + buyQuantity - sellQuantity);
  }
  return missing.sort((a, b) => a.contractKey.localeCompare(b.contractKey) || a.firstExecutionId.localeCompare(b.firstExecutionId));
}

function fifoCapturedSubtotal(rows, fees) {
  const lots = new Map();
  const totals = new Map();
  const events = [];
  let matchedQuantity = 0;
  for (const row of rows) {
    const report = fees.get(row.execution.execId);
    if (!report) return { method: "unavailable-missing-fee", totals: new Map(), events: [], matchedQuantity: 0 };
    if (report.currency !== row.contract.currency) {
      return { method: "unavailable-cross-currency-fee", totals: new Map(), events: [], matchedQuantity: 0 };
    }
    const multiplier = Number(row.contract.multiplier || 1);
    if (!Number.isFinite(multiplier) || multiplier <= 0) {
      return { method: "unavailable-multiplier", totals: new Map(), events: [], matchedQuantity: 0 };
    }
    const key = contractKey(row.contract);
    const queue = lots.get(key) || [];
    let remaining = sideQuantity(row);
    const closeFeePerUnit = report.commission / Math.abs(remaining);
    while (remaining !== 0 && queue.length && queue[0].quantity * remaining < 0) {
      const opening = queue[0];
      const quantity = Math.min(Math.abs(remaining), Math.abs(opening.quantity));
      const gross = opening.quantity > 0
        ? (row.execution.price - opening.price) * quantity * multiplier
        : (opening.price - row.execution.price) * quantity * multiplier;
      const net = gross - opening.feePerUnit * quantity - closeFeePerUnit * quantity;
      addMoney(totals, row.contract.currency, net);
      addRealizedEvent(events, row, row.contract.currency, net);
      matchedQuantity += quantity;
      opening.quantity += opening.quantity > 0 ? -quantity : quantity;
      remaining += remaining > 0 ? -quantity : quantity;
      if (opening.quantity === 0) queue.shift();
    }
    if (remaining !== 0) queue.push({
      quantity: remaining,
      price: row.execution.price,
      feePerUnit: closeFeePerUnit,
    });
    lots.set(key, queue);
  }
  return { method: "captured-fifo-matched-roundtrips", totals, events, matchedQuantity };
}

function capturedOpenQuantities(rows) {
  const balances = new Map();
  for (const row of rows) {
    const key = contractKey(row.contract);
    const prior = balances.get(key) || { contractKey: key, symbol: row.contract.symbol, quantity: 0 };
    prior.quantity += sideQuantity(row);
    balances.set(key, prior);
  }
  return [...balances.values()]
    .filter((item) => Math.abs(item.quantity) > 1e-9)
    .sort((a, b) => a.contractKey.localeCompare(b.contractKey));
}

/** Calculate a native-currency subtotal; no caller-supplied PnL or FX is accepted. */
export function calculateCapturedRealizedSubtotal(state) {
  validateBestAvailableHistoryState(state);
  const rows = includedFamilyRows(state)
    .sort((left, right) => (executionInstant(left.execution.time) || "").localeCompare(executionInstant(right.execution.time) || "") ||
      left.execution.execId.localeCompare(right.execution.execId));
  const fees = new Map(state.commissions.map((row) => [row.execId, row]));
  const { method, totals, events, matchedQuantity } = fifoCapturedSubtotal(rows, fees);
  const nativeRealizedPnl = [...totals.entries()]
    .map(([currency, realizedPnl]) => ({ currency, realizedPnl }))
    .sort((a, b) => a.currency.localeCompare(b.currency));
  const curve = capturedSubtotalCurve(events, nativeRealizedPnl);
  return {
    method,
    nativeRealizedPnl,
    ...curve,
    matchedQuantity,
    endingOpenQuantities: capturedOpenQuantities(rows),
    missingOpeningLots: missingOpeningLots(rows, fees),
  };
}

/**
 * Project only claims supported by durable capture receipts. A captured subtotal
 * is deliberately separate from complete J equity and must bind this exact state.
 */
export function projectBestAvailableHistory({ state, fullAccounting = null } = {}) {
  validateBestAvailableHistoryState(state);
  const familyRows = includedFamilyRows(state);
  const familyIds = new Set(familyRows.map((row) => row.execution.execId));
  const matchingFees = state.commissions.filter((row) => familyIds.has(row.execId));
  const executionIds = new Set(state.executions.map((row) => row.execution.execId));
  const orphanCommissionIds = state.commissions
    .filter((row) => !executionIds.has(row.execId))
    .map((row) => row.execId)
    .sort();
  const times = familyRows.map((row) => executionInstant(row.execution.time)).filter(Boolean).sort();
  const calculatedSubtotal = calculateCapturedRealizedSubtotal(state);
  const singleCurrency = calculatedSubtotal.nativeRealizedPnl.length === 1
    ? calculatedSubtotal.nativeRealizedPnl[0]
    : null;
  const completeCoverage = state.coverage.status === "complete" && state.coverage.gaps.length === 0;
  const completeAccounting = completeCoverage &&
    fullAccounting?.complete === true &&
    fullAccounting.historyDigest === bestAvailableHistoryDigest(state) &&
    Number.isFinite(fullAccounting.equity);

  return {
    ok: true,
    status: completeAccounting ? "COMPLETE" : "BEST_AVAILABLE",
    equity: completeAccounting ? fullAccounting.equity : null,
    capturedSubtotal: {
      currency: singleCurrency?.currency || null,
      realizedPnl: singleCurrency?.realizedPnl ?? null,
      nativeRealizedPnl: calculatedSubtotal.nativeRealizedPnl,
      points: calculatedSubtotal.points,
      pointsTruncated: calculatedSubtotal.pointsTruncated,
      method: calculatedSubtotal.method,
      matchedQuantity: calculatedSubtotal.matchedQuantity,
      endingOpenQuantities: calculatedSubtotal.endingOpenQuantities,
      executionCount: familyRows.length,
      commissionCount: matchingFees.length,
      fromInclusive: times[0] || null,
      throughInclusive: times.at(-1) || null,
    },
    coverage: clone(state.coverage),
    missingOpeningLots: calculatedSubtotal.missingOpeningLots,
    orphanCommissionIds,
    latestVerifiedPeriod: latestVerifiedPeriod(state.coverage),
    receiptIds: state.receipts.map((receipt) => receipt.receiptId),
  };
}

function readBoundedFile(filePath, fsImpl) {
  let handle;
  try {
    handle = fsImpl.openSync(filePath, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    const stat = fsImpl.fstatSync(handle);
    if (!stat.isFile() || stat.size <= 0 || stat.size > MAX_STATE_BYTES) {
      return { ok: false, reason: "family history state has an invalid size" };
    }
    const bytes = Buffer.alloc(stat.size + 1);
    let count = 0;
    while (count < bytes.length) {
      const read = fsImpl.readSync(handle, bytes, count, bytes.length - count, null);
      if (read === 0) break;
      count += read;
    }
    if (count !== stat.size) return { ok: false, reason: "family history state changed size during read" };
    return { ok: true, source: bytes.subarray(0, count).toString("utf8") };
  } catch (error) {
    if (error?.code === "ENOENT") return { ok: true, source: null };
    return { ok: false, reason: `family history state read failed: ${error?.code || error}` };
  } finally {
    if (handle !== undefined) fsImpl.closeSync(handle);
  }
}

export function createFileFamilyHistoryStore(filePath, fsImpl = fs) {
  if (typeof filePath !== "string" || !path.isAbsolute(filePath)) {
    throw new TypeError("family history state path must be absolute");
  }
  return {
    load() {
      const result = readBoundedFile(filePath, fsImpl);
      if (!result.ok || result.source === null) return result.source === null ? { ok: true, state: null } : result;
      try {
        const state = JSON.parse(result.source);
        validateBestAvailableHistoryState(state);
        return { ok: true, state };
      } catch (error) {
        return { ok: false, reason: `family history state is invalid: ${error.message}` };
      }
    },
    save(state) {
      validateBestAvailableHistoryState(state);
      const body = `${JSON.stringify(state, null, 2)}\n`;
      if (Buffer.byteLength(body) > MAX_STATE_BYTES) throw new Error("family history state exceeds size limit");
      const directory = path.dirname(filePath);
      const temporary = path.join(directory, `.${path.basename(filePath)}.${process.pid}.tmp`);
      let handle;
      try {
        handle = fsImpl.openSync(temporary, "wx", 0o600);
        fsImpl.writeFileSync(handle, body, "utf8");
        fsImpl.fsyncSync(handle);
        fsImpl.closeSync(handle);
        handle = undefined;
        fsImpl.renameSync(temporary, filePath);
        const directoryHandle = fsImpl.openSync(directory, "r");
        try { fsImpl.fsyncSync(directoryHandle); } finally { fsImpl.closeSync(directoryHandle); }
      } catch (error) {
        if (handle !== undefined) {
          try { fsImpl.closeSync(handle); } catch {}
        }
        try { fsImpl.unlinkSync(temporary); } catch {}
        throw error;
      }
    },
  };
}

/** Async capture loop. Coverage gaps are reportable state, never a latch. */
export function createFamilyHistoryIngestor({
  store,
  fetchCapture,
  retryMs = 30_000,
  setTimer = setTimeout,
  clearTimer = clearTimeout,
  hooks = {},
} = {}) {
  if (!store || typeof fetchCapture !== "function" || !Number.isSafeInteger(retryMs) || retryMs <= 0) {
    throw new TypeError("history store, fetchCapture and positive retryMs are required");
  }
  const loaded = store.load();
  let state = loaded.ok ? loaded.state : null;
  let fatalReason = loaded.ok ? null : loaded.reason;
  let lastError = fatalReason;
  let inFlight = false;
  let stopped = false;
  let timer = null;

  function schedule() {
    if (stopped || fatalReason || timer !== null) return;
    timer = setTimer(() => {
      timer = null;
      void pollNow();
    }, retryMs);
  }

  async function pollNow() {
    if (stopped || fatalReason || inFlight) return false;
    inFlight = true;
    try {
      const item = await fetchCapture();
      const next = reconcileExecutionCapture({ prior: state, capture: item.capture, target: item.target });
      store.save(next);
      state = clone(next);
      lastError = null;
      hooks.onUpdated?.(clone(state));
      return true;
    } catch (error) {
      lastError = error?.message || String(error);
      hooks.onUnavailable?.(lastError);
      return false;
    } finally {
      inFlight = false;
      schedule();
    }
  }

  return {
    pollNow,
    stop() {
      stopped = true;
      if (timer !== null) clearTimer(timer);
      timer = null;
    },
    get requestInFlight() { return inFlight; },
    get fatalReason() { return fatalReason; },
    get lastError() { return lastError; },
    inspectState() { return state ? clone(state) : null; },
  };
}
