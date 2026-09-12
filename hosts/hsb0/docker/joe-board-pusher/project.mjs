/** Project IB book state → inspr.joe.household.v1 (mirrors joe-household-sync.py). */

import { currencyCode, deskForSymbol, strictFinite } from "./positions-state.mjs";
import { DAY_PNL_METHOD } from "./day-baseline.mjs";
import {
  CURRENT_DESK_OWNERSHIP_POLICY,
  DESK_HISTORY_REVISION_METHOD,
  deskOwnershipPolicyContract,
} from "./desk-ledger.mjs";

const JOEL_SYMBOLS = new Set(["SXR8", "TSLA"]);
const VIRTUAL_EQUITY = 5000.0;
const STALE_AFTER = 300;
const MAPPED_DESK_IDS = ["j", "joel"];
const JOEL_HISTORY_BASIS = "joel.stage0-keep-excluded.v1";
const MAX_BACKFILL_COUNT = 1_000_000;
const MAX_BACKFILL_POINTS = 2048;
const BACKFILL_ENDPOINT_TOLERANCE = 0.000001;
const CAPTURED_FIFO_METHOD = "captured-fifo-matched-roundtrips";
const FAMILY_HISTORY_STATUS = new Set(["BEST_AVAILABLE", "COMPLETE"]);
const DESK_IDS = ["j", "joe", "joel"];
const DESK_PROVIDER_CONTRACT = deskOwnershipPolicyContract(CURRENT_DESK_OWNERSHIP_POLICY);
// CONFIG.md Grandfather (Markus 2026-09-04): existing paper SXR8 lot + leftover
// TSLA×1 stay outside Stage-0 Joel book money / since-start / stand / totals
// until Faber exit. Still mentioned in action/learning text.

function fnum(x, fallback = 0) {
  const n = Number(x);
  return Number.isFinite(n) ? n : fallback;
}

function sleeveMv(portfolio, symbols) {
  return round2(
    portfolio
      .filter((p) => symbols.has(p.symbol) && fnum(p.pos) !== 0)
      .reduce((s, p) => s + fnum(p.marketValue), 0)
  );
}

function round2(n) {
  return Math.round(n * 100) / 100;
}

function brokerNetLiquidation(summary) {
  const row = summary?.NetLiquidation;
  if (!row || currencyCode(row.currency) !== "EUR") return null;
  if (typeof row.value !== "string" && typeof row.value !== "number") return null;
  if (typeof row.value === "string" && row.value.trim() === "") return null;
  const value = Number(row.value);
  if (!Number.isFinite(value) || Math.abs(value) === Number.MAX_VALUE) return null;
  return round2(value);
}

function boundedCount(value) {
  return Number.isInteger(value) && value >= 0 && value <= MAX_BACKFILL_COUNT
    ? value
    : null;
}

function normalizedIso(value) {
  if (typeof value !== "string") return null;
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(Z|([+-])(\d{2}):(\d{2}))$/.exec(value);
  if (!match) return null;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = Number(match[6]);
  const leap = (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
  const monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (month < 1 || month > 12 || day < 1 || day > monthDays[month - 1] ||
      hour > 23 || minute > 59 || second > 59) return null;
  if (match[7] !== "Z") {
    const offsetHour = Number(match[9]);
    const offsetMinute = Number(match[10]);
    if (offsetHour > 14 || offsetMinute > 59 || (offsetHour === 14 && offsetMinute !== 0)) return null;
  }
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? new Date(ms).toISOString() : null;
}

function normalizedInterval(value, inclusiveEnd = false) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const fromInclusive = normalizedIso(value.fromInclusive);
  const endKey = inclusiveEnd ? "throughInclusive" : "toExclusive";
  const end = normalizedIso(value[endKey]);
  if (!fromInclusive || !end) return null;
  const fromMs = Date.parse(fromInclusive);
  const endMs = Date.parse(end);
  if (inclusiveEnd ? fromMs > endMs : fromMs >= endMs) return null;
  return { fromInclusive, [endKey]: end };
}

function validIntervalList(value) {
  return Array.isArray(value) && value.length <= MAX_BACKFILL_COUNT &&
    value.every((interval) => normalizedInterval(interval) !== null);
}

function projectCapturedPoints(captured, captureInterval) {
  const hasPoints = Object.prototype.hasOwnProperty.call(captured, "points");
  const hasTruncated = Object.prototype.hasOwnProperty.call(captured, "pointsTruncated");
  if (!hasPoints && !hasTruncated) return {};
  if (!hasPoints || !hasTruncated || !Array.isArray(captured.points) ||
      captured.points.length > MAX_BACKFILL_POINTS || typeof captured.pointsTruncated !== "boolean") {
    return null;
  }
  const fromMs = Date.parse(captureInterval.fromInclusive);
  const throughMs = Date.parse(captureInterval.throughInclusive);
  let priorMs = null;
  const points = [];
  for (const point of captured.points) {
    if (!point || typeof point !== "object" || Array.isArray(point) ||
        Object.keys(point).some((key) => key !== "at" && key !== "realizedPnl") ||
        !Object.prototype.hasOwnProperty.call(point, "at") ||
        !Object.prototype.hasOwnProperty.call(point, "realizedPnl") ||
        !Number.isFinite(point.realizedPnl)) {
      return null;
    }
    const at = normalizedIso(point.at);
    if (!at) return null;
    const atMs = Date.parse(at);
    if (atMs < fromMs || atMs > throughMs || (priorMs !== null && atMs <= priorMs)) return null;
    points.push({ at, realizedPnl: point.realizedPnl });
    priorMs = atMs;
  }
  if (captured.pointsTruncated && points.length === 0) return null;
  if (points.length === 0) {
    if (captured.realizedPnl !== null) return null;
  } else if (!Number.isFinite(captured.realizedPnl) ||
             Math.abs(points.at(-1).realizedPnl - captured.realizedPnl) > BACKFILL_ENDPOINT_TOLERANCE) {
    return null;
  }
  return { points, pointsTruncated: captured.pointsTruncated };
}

function projectFamilyHistory(familyHistory) {
  if (!familyHistory || familyHistory.ok !== true ||
      !FAMILY_HISTORY_STATUS.has(familyHistory.status)) return null;
  const captured = familyHistory.capturedSubtotal;
  const realizedPnl = captured?.realizedPnl;
  const currency = captured?.currency;
  const executionCount = boundedCount(captured?.executionCount);
  const commissionCount = boundedCount(captured?.commissionCount);
  const captureInterval = normalizedInterval(captured, true);
  const coverage = familyHistory.coverage;
  const target = normalizedInterval(coverage?.target);
  if (!(realizedPnl === null || Number.isFinite(realizedPnl)) ||
      !["USD", "EUR", null].includes(currency) ||
      (Number.isFinite(realizedPnl) && currency === null) ||
      executionCount === null || commissionCount === null || !captureInterval || !target ||
      !validIntervalList(coverage?.completeIntervals) ||
      !validIntervalList(coverage?.knownIntervals) ||
      !Array.isArray(coverage?.gaps) || coverage.gaps.length > MAX_BACKFILL_COUNT ||
      !Array.isArray(familyHistory.missingOpeningLots) ||
      !Array.isArray(familyHistory.orphanCommissionIds)) {
    return null;
  }
  const gaps = coverage.gaps.map((gap) => normalizedInterval(gap));
  if (gaps.some((gap) => gap === null) ||
      coverage.gaps.some((gap) => typeof gap.reason !== "string" || !gap.reason.trim())) {
    return null;
  }
  const missingOpeningLotCount = boundedCount(familyHistory.missingOpeningLots.length);
  const orphanCommissionCount = boundedCount(familyHistory.orphanCommissionIds.length);
  if (missingOpeningLotCount === null || orphanCommissionCount === null) return null;
  const capturedPoints = projectCapturedPoints(captured, captureInterval);
  if (capturedPoints === null) return null;
  const method = Number.isFinite(realizedPnl) && captured.method === CAPTURED_FIFO_METHOD
    ? CAPTURED_FIFO_METHOD
    : null;
  return {
    status: familyHistory.status,
    fullTotalAvailable: familyHistory.status === "COMPLETE" && Number.isFinite(familyHistory.equity) &&
      gaps.length === 0 && missingOpeningLotCount === 0 && orphanCommissionCount === 0,
    capturedSubtotal: {
      realizedPnl,
      currency,
      method,
      executionCount,
      commissionCount,
      ...captureInterval,
      ...capturedPoints,
    },
    coverage: {
      target,
      completeIntervalCount: coverage.completeIntervals.length,
      knownIntervalCount: coverage.knownIntervals.length,
      gapCount: gaps.length,
      firstGap: gaps[0] || null,
    },
    missingOpeningLotCount,
    orphanCommissionCount,
  };
}

/** True for grandfathered paper names excluded from Stage-0 money. */
export function isGrandfathered(p) {
  const sym = p.symbol;
  const pos = Math.abs(fnum(p.pos));
  if (sym === "SXR8") return true; // Faber lot until exit
  if (sym === "TSLA" && pos === 1) return true; // leftover single share
  return false;
}

function stage0JoelRows(portfolio) {
  return portfolio.filter((p) => JOEL_SYMBOLS.has(p.symbol) && !isGrandfathered(p));
}

function unavailablePnlSource(kind, detail) {
  return {
    status: "unavailable",
    method: null,
    currency: "EUR",
    scope: "virtual-desks",
    observedAt: null,
    ...(kind === "day" ? { periodStart: null } : {}),
    detail: String(detail).slice(0, 160),
  };
}

function hasExactKeys(value, keys) {
  return Boolean(value && typeof value === "object" && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...keys].sort()));
}

function normalizedDeskEquities(value, family) {
  if (!value || value.ok !== true || !hasExactKeys(value.equity, [...DESK_IDS, "total"]) ||
      !hasExactKeys(value.desks, DESK_IDS)) return null;
  const contract = value.sourceContract;
  if (!hasExactKeys(contract, ["method", "policyMethod", "policyHash", "scope", "keepExcluded"]) ||
      Object.entries(DESK_PROVIDER_CONTRACT).some(([key, expected]) => contract[key] !== expected) ||
      value.historyRevisionMethod !== DESK_HISTORY_REVISION_METHOD ||
      !/^[0-9a-f]{64}$/.test(value.historyRevision || "") ||
      value.ownershipEvidence?.status !== "complete" ||
      value.ownershipEvidence.policyHash !== DESK_PROVIDER_CONTRACT.policyHash ||
      value.ownershipEvidence.unclaimedExecutionCount !== 0 ||
      value.executionCoverage?.status !== "complete") return null;
  const sourceObservedAt = normalizedIso(value.sourceObservedAt);
  const oldestSourceObservedAt = normalizedIso(value.oldestSourceObservedAt);
  const coverageFrom = normalizedIso(value.executionCoverage.fromInclusive);
  const coverageThrough = normalizedIso(value.executionCoverage.throughInclusive);
  if (!sourceObservedAt || !oldestSourceObservedAt || !coverageFrom || !coverageThrough ||
      coverageFrom > coverageThrough || oldestSourceObservedAt > coverageThrough || coverageThrough > sourceObservedAt) return null;

  const desks = {};
  for (const id of DESK_IDS) {
    const desk = value.desks[id];
    if (!desk || !Array.isArray(desk.positions) ||
        [desk.equity, desk.totalPnl, desk.realizedPnl, desk.unrealizedPnl].some((item) => !Number.isFinite(item)) ||
        Math.abs(round2(desk.realizedPnl + desk.unrealizedPnl) - round2(desk.totalPnl)) > 0.001 ||
        Math.abs(round2(VIRTUAL_EQUITY + desk.totalPnl) - round2(desk.equity)) > 0.001 ||
        desk.positions.some((row) => !Number.isFinite(row?.openPnl) ||
          !normalizedIso(row.updatedAt) || normalizedIso(row.updatedAt) > sourceObservedAt) ||
        Math.abs(round2(desk.positions.reduce((sum, row) => sum + row.openPnl, 0)) - round2(desk.unrealizedPnl)) > 0.001) {
      return null;
    }
    desks[id] = {
      equity: round2(desk.equity),
      totalPnl: round2(desk.totalPnl),
      realizedPnl: round2(desk.realizedPnl),
      unrealizedPnl: round2(desk.unrealizedPnl),
      positions: structuredClone(desk.positions),
    };
  }
  if ([family.equity, family.totalPnl, family.realizedPnl, family.unrealizedPnl]
    .some((item, index) => round2(item) !== [desks.j.equity, desks.j.totalPnl, desks.j.realizedPnl, desks.j.unrealizedPnl][index]) ||
      JSON.stringify(family.positions) !== JSON.stringify(desks.j.positions)) return null;
  if (Object.values(value.equity).some((item) => !Number.isFinite(item))) return null;
  const equity = Object.fromEntries(DESK_IDS.map((id) => [id, round2(value.equity[id])]));
  equity.total = round2(value.equity.total);
  if (DESK_IDS.some((id) => equity[id] !== desks[id].equity) ||
      Math.abs(round2(DESK_IDS.reduce((sum, id) => sum + equity[id], 0)) - equity.total) > 0.001) return null;
  return { desks, equity, sourceObservedAt, oldestSourceObservedAt };
}

function normalizedRetainedDeskEquity(value) {
  if (!value || !hasExactKeys(value.equity, [...DESK_IDS, "total"])) return null;
  const provenance = value.provenance;
  if (provenance?.method !== DESK_PROVIDER_CONTRACT.method ||
      provenance?.classifier?.method !== DESK_PROVIDER_CONTRACT.policyMethod ||
      provenance?.classifier?.policyHash !== DESK_PROVIDER_CONTRACT.policyHash ||
      provenance?.historyRevisionMethod !== DESK_HISTORY_REVISION_METHOD ||
      provenance?.scope !== DESK_PROVIDER_CONTRACT.scope || provenance?.keepExcluded !== true ||
      !/^[0-9a-f]{64}$/.test(provenance?.historyRevision || "") ||
      provenance?.executionCoverage?.status !== "complete") return null;
  const sourceObservedAt = normalizedIso(value.sourceObservedAt);
  const oldestSourceObservedAt = normalizedIso(value.oldestSourceObservedAt);
  const coverageThrough = normalizedIso(provenance.executionCoverage.throughInclusive);
  if (!sourceObservedAt || !oldestSourceObservedAt || !coverageThrough ||
      oldestSourceObservedAt > coverageThrough || coverageThrough > sourceObservedAt ||
      Object.values(value.equity).some((item) => !Number.isFinite(item))) return null;
  const equity = Object.fromEntries(DESK_IDS.map((id) => [id, round2(value.equity[id])]));
  equity.total = round2(value.equity.total);
  if (Math.abs(round2(DESK_IDS.reduce((sum, id) => sum + equity[id], 0)) - equity.total) > 0.001) return null;
  const desks = Object.fromEntries(DESK_IDS.map((id) => [id, {
    equity: equity[id],
    totalPnl: round2(equity[id] - VIRTUAL_EQUITY),
    positions: null,
  }]));
  return { desks, equity, sourceObservedAt, oldestSourceObservedAt, retained: true };
}

function normalizedDayPnl(value) {
  if (!value || value.ok !== true || !value.values || !value.source) return null;
  const keys = ["j", "joe", "joel", "total"];
  if (Object.keys(value.values).length !== keys.length || keys.some((key) => !Number.isFinite(value.values[key]))) {
    return null;
  }
  const values = Object.fromEntries(keys.map((key) => [key, round2(value.values[key])]));
  if (Math.abs(values.j + values.joe + values.joel - values.total) > 0.001) return null;
  const source = value.source;
  const observedAt = normalizedIso(source.observedAt);
  const periodStart = normalizedIso(source.periodStart);
  const baselineSourceAt = normalizedIso(value.evidence?.sourceObservedAt);
  const oldestSourceAt = normalizedIso(value.evidence?.oldestSourceObservedAt);
  const proofObservedAt = normalizedIso(value.evidence?.proofObservedAt);
  if (source.status !== "available" || source.method !== DAY_PNL_METHOD ||
      source.currency !== "EUR" || source.scope !== "virtual-desks" ||
      !observedAt || !periodStart || !baselineSourceAt || !oldestSourceAt || !proofObservedAt ||
      baselineSourceAt > periodStart || oldestSourceAt > baselineSourceAt ||
      proofObservedAt < periodStart || observedAt < periodStart ||
      !Number.isSafeInteger(value.evidence.ageAtBoundaryMs) || value.evidence.ageAtBoundaryMs < 0 ||
      !Number.isSafeInteger(value.evidence.maxAgeMs) || value.evidence.maxAgeMs <= 0 ||
      value.evidence.ageAtBoundaryMs > value.evidence.maxAgeMs ||
      value.evidence.ageAtBoundaryMs !== Date.parse(periodStart) - Date.parse(oldestSourceAt) ||
      typeof value.evidence.historyRevisionMethod !== "string" || !value.evidence.historyRevisionMethod ||
      !/^[0-9a-f]{64}$/.test(value.evidence.historyRevision)) {
    return null;
  }
  return {
    values,
    source: {
      status: "available",
      method: DAY_PNL_METHOD,
      currency: "EUR",
      scope: "virtual-desks",
      observedAt,
      periodStart,
      detail: String(source.detail || "Verified New York SOD virtual-equity delta.").slice(0, 160),
    },
  };
}

function dayPnlProjection(gatewayOk, supplied) {
  if (gatewayOk) {
    const available = normalizedDayPnl(supplied);
    if (available) return available;
  }
  const suppliedReason = supplied?.ok === false && supplied.source?.status === "unavailable" &&
    typeof supplied.source.detail === "string" ? supplied.source.detail : null;
  return {
    values: { j: null, joe: null, joel: null, total: null },
    source: unavailablePnlSource(
      "day",
      gatewayOk
        ? suppliedReason || "Exact America/New_York SOD virtual-equity baseline pending; account DailyPnL includes KEEP."
        : "Paper Gateway unavailable; exact America/New_York SOD virtual-equity baseline unavailable."
    ),
  };
}

function openPnlUnavailable(detail) {
  return {
    values: { j: null, joe: null, joel: null, total: null },
    source: unavailablePnlSource("open", detail),
  };
}

function openEvidenceRow(row) {
  if (typeof row?.symbol !== "string" || !row.symbol || !Number.isFinite(row.quantity) || row.quantity === 0) {
    return null;
  }
  if (typeof row.contractKey !== "string" || !row.contractKey) return null;
  return `${row.contractKey}\u0000${row.symbol}\u0000${row.quantity}`;
}

function currentExcludedRows(rows) {
  const result = [];
  for (const row of rows) {
    const symbol = String(row?.symbol || row?.contract?.symbol || "").trim().toUpperCase();
    const quantity = strictFinite(row?.pos);
    if (!JOEL_SYMBOLS.has(symbol) || quantity === undefined || quantity === 0) continue;
    const conId = row?.contract?.conId;
    const contractKey = Number.isInteger(conId) && conId > 0 ? `conId:${conId}` : `excluded:${symbol}`;
    result.push({ contractKey, symbol, quantity });
  }
  return result.sort((left, right) => left.contractKey.localeCompare(right.contractKey));
}

function openPnlProjection(book, { gatewayOk, brokerFresh, familyAccepted, family, deskEquities, publisherMs }) {
  if (!gatewayOk) return openPnlUnavailable("Paper Gateway unavailable; IB unrealized P&L unavailable.");
  if (!brokerFresh) return openPnlUnavailable("Broker book is stale; fresh IB unrealized P&L unavailable.");
  if (book.positionsCoverage?.status !== "complete") {
    return openPnlUnavailable("Complete broker position coverage unavailable for OPEN allocation.");
  }
  if (deskEquities) {
    const sourceAge = publisherMs - Date.parse(deskEquities.sourceObservedAt);
    const oldestAge = publisherMs - Date.parse(deskEquities.oldestSourceObservedAt);
    if (!Number.isFinite(sourceAge) || sourceAge < 0 || !Number.isFinite(oldestAge) ||
        oldestAge < 0 || oldestAge > STALE_AFTER * 1000) {
      return openPnlUnavailable("All-desk OPEN marks, FX, or execution coverage are stale or unavailable.");
    }
    const values = Object.fromEntries(DESK_IDS.map((id) => [id, deskEquities.desks[id].unrealizedPnl]));
    values.total = round2(DESK_IDS.reduce((sum, id) => sum + values[id], 0));
    return {
      values,
      source: {
        status: "available",
        method: DESK_PROVIDER_CONTRACT.method,
        currency: "EUR",
        scope: "virtual-desks",
        observedAt: deskEquities.sourceObservedAt,
        detail: "Execution-owned desk lots use current broker marks and explicit quote-to-EUR FX; exact KEEP is excluded.",
      },
    };
  }
  if (!familyAccepted) return openPnlUnavailable("Complete owned-lot J accounting unavailable for OPEN.");
  const evidence = family.openPnlEvidence;
  if (!evidence || evidence.method !== "owned-lots-current-mark-fx" ||
      evidence.currency !== "EUR" || evidence.ownershipCoverage !== "complete" ||
      !Array.isArray(evidence.residualNonKeepPositions) || !Array.isArray(evidence.excludedPositions) ||
      family.positions.some((row) => !Number.isFinite(row.openPnl))) {
    return openPnlUnavailable("Complete owned-lot OPEN evidence unavailable.");
  }
  const evidenceRows = [...evidence.residualNonKeepPositions, ...evidence.excludedPositions];
  if (evidenceRows.some((row) => openEvidenceRow(row) === null)) {
    return openPnlUnavailable("Complete owned-lot OPEN evidence unavailable.");
  }
  const sourceAge = publisherMs - new Date(family.observedAt).getTime();
  if (!Number.isFinite(sourceAge) || sourceAge < 0) {
    return openPnlUnavailable("OPEN evidence timestamp is missing or in the future.");
  }
  if (family.positions.some((row) => {
    const age = publisherMs - new Date(row.updatedAt).getTime();
    return !Number.isFinite(age) || age < 0 || age > STALE_AFTER * 1000;
  })) {
    return openPnlUnavailable("Current J position marks are stale or unavailable.");
  }
  if (evidence.residualNonKeepPositions.length !== 0) {
    return openPnlUnavailable("Non-KEEP broker positions remain outside proven desk ownership.");
  }
  if (evidence.excludedPositions.some((row) =>
    !Number.isFinite(row?.quantity) || row.quantity === 0 ||
    !isGrandfathered({ symbol: row.symbol, pos: row.quantity }))) {
    return openPnlUnavailable("Excluded broker positions are not exact configured KEEP.");
  }
  const provenExcluded = evidence.excludedPositions.map(openEvidenceRow).sort();
  const observedExcluded = currentExcludedRows(book.positionsCoverage.rows).map(openEvidenceRow).sort();
  if (JSON.stringify(provenExcluded) !== JSON.stringify(observedExcluded)) {
    return openPnlUnavailable("Current excluded broker positions do not match the OPEN ownership proof.");
  }
  const j = round2(family.unrealizedPnl);
  if (round2(family.positions.reduce((sum, row) => sum + row.openPnl, 0)) !== j) {
    return openPnlUnavailable("Per-position J OPEN does not reconcile with its desk total.");
  }
  return {
    values: { j, joe: 0, joel: 0, total: j },
    source: {
      status: "available",
      method: "owned-lots-current-mark-fx",
      currency: "EUR",
      scope: "virtual-desks",
      observedAt: family.observedAt,
      detail: "J owned lots use current broker marks and explicit quote-to-EUR FX; Joe and Joel are proven flat outside exact KEEP.",
    },
  };
}

function accountingScopeFor(row) {
  if (isGrandfathered({ symbol: row.symbol, pos: row.pos })) return "legacy";
  return "stage0";
}

/** Serialize one broker row for a mapped desk. Omits unverified monetary fields. */
export function serializePositionRow(row, deskId) {
  const qty = strictFinite(row.pos);
  if (qty === undefined || qty === 0 || deskForSymbol(row.symbol) !== deskId) return null;
  const out = {
    desk: deskId,
    symbol: row.symbol,
    side: qty > 0 ? "Long" : "Short",
    quantity: qty,
    accountingScope: accountingScopeFor(row),
    dayPnl: null,
    openPnl: null,
  };
  const currency = currencyCode(row.currency);
  const mark = strictFinite(row.marketPrice);
  if (currency) out.currency = currency;
  if (mark !== undefined && currency) {
    out.mark = mark;
    if (row.markObservedAt) out.updatedAt = row.markObservedAt;
  } else if (row.positionObservedAt || row.observedAt) {
    out.updatedAt = row.positionObservedAt || row.observedAt;
  }
  return out;
}

/** Build per-desk positions for mapped desks only when subscription coverage is complete. */
export function buildDeskPositions(coverage) {
  if (!coverage || coverage.status !== "complete") return null;
  const byDesk = { j: [], joel: [] };
  for (const row of coverage.rows || []) {
    const deskId = deskForSymbol(row.symbol);
    if (!deskId) continue;
    const serialized = serializePositionRow(row, deskId);
    if (serialized) byDesk[deskId].push(serialized);
  }
  for (const deskId of MAPPED_DESK_IDS) {
    byDesk[deskId].sort((a, b) => a.symbol.localeCompare(b.symbol));
  }
  return byDesk;
}

export function projectBook(book, opts = {}) {
  const familyRuntimeEnabled = Boolean(opts.familyRuntimeEnabled);
  const family = opts.family;
  const familyComplete = Boolean(family && family.ok === true &&
    [family.equity, family.totalPnl, family.realizedPnl, family.unrealizedPnl].every(Number.isFinite) &&
    Array.isArray(family.positions) && family.accounting?.method === "execution-fifo-net-current-fx");
  const familyAccepted = familyRuntimeEnabled && familyComplete;
  const familyUnavailable = familyRuntimeEnabled && !familyComplete;
  const familyUnavailableReason = String(family?.reason || "verified family accounting unavailable").slice(0, 160);
  const familyBackfill = projectFamilyHistory(opts.familyHistory);
  const publisherAt = opts.publisherAt || opts.now || new Date();
  const publisherMs = new Date(publisherAt).getTime();
  const deskCandidate = familyAccepted ? normalizedDeskEquities(opts.deskEquities, family) : null;
  const retainedDeskEquity = familyRuntimeEnabled ? normalizedRetainedDeskEquity(opts.retainedDeskEquity) : null;
  const deskEquities = deskCandidate || retainedDeskEquity;
  const deskSourceAge = publisherMs - Date.parse(deskCandidate?.oldestSourceObservedAt || "");
  const currentDeskEquities = Boolean(book.gateway) && Number.isFinite(deskSourceAge) &&
    deskSourceAge >= 0 && deskSourceAge <= STALE_AFTER * 1000 ? deskCandidate : null;
  const sourceTimes = [book.ts];
  if (familyAccepted) sourceTimes.push(family.observedAt);
  if (deskEquities) sourceTimes.push(deskEquities.sourceObservedAt);
  const latestSourceMs = Math.max(...sourceTimes.map((value) => new Date(value || "").getTime()));
  const brokerSnapshotAt = new Date(latestSourceMs);
  if (Number.isNaN(brokerSnapshotAt.getTime())) return null;
  const gen = formatViennaIso(brokerSnapshotAt);
  const heartbeat = formatViennaIso(publisherAt);

  const summary = book.summary || {};
  const bookObservedAt = new Date(book.ts).toISOString();
  const accountEquity = brokerNetLiquidation(summary);
  const brokerAgeMs = publisherMs - new Date(bookObservedAt).getTime();
  const brokerObservationFresh = Number.isFinite(brokerAgeMs) && brokerAgeMs <= STALE_AFTER * 1000;
  const portfolio = book.portfolio || [];
  const positions = (book.positions || []).filter((p) => fnum(p.pos) !== 0);
  const bookTs = book.ts || null;
  const gwOk = Boolean(book.gateway);
  const brokerAccount = {
    equity: accountEquity,
    currency: "EUR",
    observedAt: bookObservedAt,
    scope: "paper-account-including-keep",
    status: accountEquity !== null && gwOk && brokerObservationFresh ? "available" : "unavailable",
  };
  const dayPnl = dayPnlProjection(gwOk, opts.dayPnl);
  const openPnl = openPnlProjection(book, {
    gatewayOk: gwOk,
    brokerFresh: brokerObservationFresh,
    familyAccepted,
    family,
    deskEquities: currentDeskEquities,
    publisherMs,
  });
  const accountEquityText = accountEquity === null
    ? "Paper account equity unavailable"
    : `paper account equity €${accountEquity.toLocaleString("en-US", { minimumFractionDigits: 2 })}, including KEEP`;
  const halt = Boolean(opts.halt);
  const haltRaw = opts.haltReason || "";
  const posTxt = positions.map((p) => `${p.symbol}×${p.pos}`).join(", ") || "flat";
  const legacyRows = portfolio.filter((p) => isGrandfathered(p) && fnum(p.pos) !== 0);
  const legacyTxt =
    legacyRows.map((p) => `${p.symbol}×${p.pos}`).join(", ") || "none";
  const joelMv = sleeveMv(portfolio, JOEL_SYMBOLS);
  const stage0Rows = stage0JoelRows(portfolio);
  const stage0Mv = round2(stage0Rows.reduce((s, p) => s + fnum(p.marketValue), 0));

  const legacyJoelPnl = round2(
    stage0Rows.reduce((sum, row) => sum + fnum(row.unrealizedPNL) + fnum(row.realizedPNL), 0)
  );
  const deskEvidenceUnavailable = familyRuntimeEnabled && !deskEquities;
  const deskEvidenceStale = Boolean(familyRuntimeEnabled && deskEquities && !currentDeskEquities);
  const retainedDeskDetail = deskEvidenceStale
    ? `Carried all-desk equity uses inputs as old as ${deskEquities.oldestSourceObservedAt}; current valuation unavailable.`
    : null;
  const moneyEvidence = deskEquities ? {
    status: currentDeskEquities ? "observed" : "carried",
    // A newer execution check recalculates the vector, but does not refresh its prices/FX.
    observedAt: currentDeskEquities ? deskEquities.sourceObservedAt : deskEquities.oldestSourceObservedAt,
  } : null;
  const jPnl = deskEquities
    ? deskEquities.desks.j.totalPnl
    : familyUnavailable
    ? null
    : familyRuntimeEnabled
    ? round2(family.totalPnl)
    : round2(
      (() => {
        const p = portfolio.find((x) => x.symbol === "INTC");
        return p ? fnum(p.realizedPNL) + fnum(p.unrealizedPNL) : 0;
      })()
    );
  const joePnl = deskEquities ? deskEquities.desks.joe.totalPnl : familyRuntimeEnabled ? null : 0;
  const joelPnl = deskEquities ? deskEquities.desks.joel.totalPnl : familyRuntimeEnabled ? null : legacyJoelPnl;
  const jEquity = deskEquities
    ? deskEquities.desks.j.equity
    : familyUnavailable
    ? null
    : familyRuntimeEnabled
      ? round2(family.equity)
      : round2(VIRTUAL_EQUITY + jPnl);
  const joeEquity = deskEquities ? deskEquities.desks.joe.equity : familyRuntimeEnabled ? null : round2(VIRTUAL_EQUITY + joePnl);
  const joelEquity = deskEquities ? deskEquities.desks.joel.equity : familyRuntimeEnabled ? null : round2(VIRTUAL_EQUITY + joelPnl);

  const deskPositions = buildDeskPositions(book.positionsCoverage);

  const desks = [
    {
      id: "j",
      label: "J",
      state: deskEvidenceStale
        ? "stuck"
        : familyUnavailable
        ? "stuck"
        : familyRuntimeEnabled && family.positions.length ? "working" : "sit-out",
      stateSince: null,
      action: deskEvidenceStale
        ? retainedDeskDetail
        : familyUnavailable
        ? `J accounting unavailable — ${familyUnavailableReason}`
        : familyRuntimeEnabled
        ? "J + J2–J5; verified since 10 Sep; net fees; EUR at observed FX; earlier results unavailable."
        : "Virt book €5k; flat — no open J broker position.",
      learning: {
        status: deskEvidenceStale ? "blocked" : familyAccepted && family.positions.length ? "steady" : "learning",
        headline: deskEvidenceStale
          ? "J current all-desk valuation unavailable"
          : familyUnavailable
          ? "J family accounting unavailable"
          : familyRuntimeEnabled ? "J family execution ledger" : "Shared broker book",
        detail: deskEvidenceStale
          ? retainedDeskDetail
          : familyUnavailable
          ? `No verified J result is published: ${familyUnavailableReason}`
          : familyRuntimeEnabled
          ? "J + J2–J5; verified since 10 Sep; net fees; EUR at observed FX; earlier results unavailable."
          : "Virt book €5k; no open J names on the shared broker account.",
        iteration: null,
      },
      money: { equity: jEquity, dayPnl: dayPnl.values.j, totalPnl: jPnl, openPnl: openPnl.values.j },
      ...(moneyEvidence ? { moneyEvidence } : {}),
      ...(familyAccepted ? { accounting: family.accounting } : {}),
      ...(familyBackfill ? { backfill: familyBackfill } : {}),
      heartbeatAt: heartbeat,
      issues: [
        ...(familyUnavailable ? [`J accounting unavailable: ${familyUnavailableReason}`] : []),
        ...(retainedDeskDetail ? [retainedDeskDetail] : []),
      ],
    },
    {
      id: "joe",
      label: "Joe",
      state: deskEvidenceUnavailable
        ? "stuck"
        : deskEvidenceStale
          ? "stuck"
          : deskEquities?.desks.joe.positions.length ? "working" : "sit-out",
      stateSince: null,
      action: deskEvidenceUnavailable
        ? "Joe accounting unavailable — complete execution-owned desk evidence unavailable."
        : deskEvidenceStale
          ? retainedDeskDetail
        : deskEquities
          ? `Verified execution-owned book; since-start PnL €${joePnl.toLocaleString("en-US", { minimumFractionDigits: 2 })}.`
          : "Virt book €5k; flat — no open Joe broker names.",
      learning: {
        status: deskEvidenceUnavailable || deskEvidenceStale ? "blocked" : "learning",
        headline: deskEvidenceUnavailable || deskEvidenceStale ? "Joe current valuation unavailable" : "Joe execution-owned sleeve",
        detail: deskEvidenceUnavailable
          ? "No Joe equity or since-start PnL is published without complete all-desk ownership evidence."
          : deskEvidenceStale
            ? retainedDeskDetail
          : deskEquities
            ? "Complete official history assigns Joe fills by effective dated client ownership; exact KEEP is excluded."
            : "Virt book €5k; no open Joe names today.",
        iteration: null,
      },
      money: { equity: joeEquity, dayPnl: dayPnl.values.joe, totalPnl: joePnl, openPnl: openPnl.values.joe },
      ...(moneyEvidence ? { moneyEvidence } : {}),
      heartbeatAt: heartbeat,
      issues: deskEvidenceUnavailable
        ? ["Joe accounting unavailable: complete all-desk evidence unavailable"]
        : retainedDeskDetail ? [retainedDeskDetail] : [],
    },
    {
      id: "joel",
      label: "Joel",
      state: deskEvidenceUnavailable || deskEvidenceStale ? "stuck" : positions.length ? "working" : "sit-out",
      stateSince: null,
      action: deskEvidenceUnavailable
        ? "Joel Stage-0 accounting unavailable — complete all-desk ownership evidence unavailable."
        : deskEvidenceStale
          ? retainedDeskDetail
        : positions.length
        ? `Holding ${posTxt}. Legacy paper (${legacyTxt}) is outside Stage-0 money until Faber exit (CONFIG). Stage-0 stand = virt €${VIRTUAL_EQUITY.toLocaleString("en-US")} + Stage-0 PnL, separate from ${accountEquityText}.`
        : `Flat in virt book. Desk equity is Stage-0 virtual €${VIRTUAL_EQUITY.toLocaleString("en-US")}; ${accountEquityText}.`,
      learning: {
        status: deskEvidenceUnavailable || deskEvidenceStale ? "blocked" : positions.length ? "steady" : "learning",
        headline: deskEvidenceUnavailable || deskEvidenceStale
          ? "Joel Stage-0 accounting unavailable"
          : legacyRows.length
          ? "Virt €5k Stage-0 + open legacy names"
          : "Virt €5k Stage-0 book",
        detail: deskEvidenceUnavailable
          ? "Legacy KEEP remains visible, but no Joel Stage-0 money is published without complete all-desk ownership evidence."
          : deskEvidenceStale
            ? retainedDeskDetail
          : legacyRows.length
          ? `Legacy held (${legacyTxt}), broker MV ~€${joelMv.toLocaleString("en-US", { minimumFractionDigits: 2 })} — excluded from Stage-0 since-start/stand. Stage-0-attributed PnL €${joelPnl.toLocaleString("en-US", { minimumFractionDigits: 2 })} (open Stage-0 MV ~€${stage0Mv.toLocaleString("en-US", { minimumFractionDigits: 2 })}); stand = virt €5k + that PnL.`
          : `Since-start PnL €${joelPnl.toLocaleString("en-US", { minimumFractionDigits: 2 })}; stand = virt €5k + PnL.`,
        iteration: null,
      },
      money: { equity: joelEquity, dayPnl: dayPnl.values.joel, totalPnl: joelPnl, openPnl: openPnl.values.joel },
      ...(moneyEvidence ? { moneyEvidence } : {}),
      historyBasis: JOEL_HISTORY_BASIS,
      heartbeatAt: heartbeat,
      issues: deskEvidenceUnavailable
        ? ["Joel accounting unavailable: complete all-desk evidence unavailable"]
        : retainedDeskDetail ? [retainedDeskDetail] : [],
    },
  ];

  if (deskPositions) {
    for (const desk of desks) {
      if (familyRuntimeEnabled && desk.id === "j") continue;
      if (Object.prototype.hasOwnProperty.call(deskPositions, desk.id)) {
        desk.positions = deskPositions[desk.id];
      }
    }
  }
  if (familyAccepted) {
    desks[0].positions = family.positions.map((row) => ({ ...row, dayPnl: null }));
  }
  if (deskCandidate) {
    desks[1].positions = deskCandidate.desks.joe.positions.map((row) => ({
      ...row,
      desk: "joe",
      dayPnl: null,
    }));
  }
  if (openPnl.source.status === "unavailable") {
    for (const desk of desks) {
      if (Array.isArray(desk.positions)) {
        desk.positions = desk.positions.map((row) => ({ ...row, openPnl: null }));
      }
    }
  }

  const issues = [];
  if (halt) issues.push("HALT is on");
  if (!gwOk) issues.push(String(book.lastError || "Gateway down"));
  if (issues.length) {
    desks[1].state = "stuck";
    desks[1].issues = issues;
    desks[1].action = issues.join("; ");
  }

  const totals = {
    equity: familyUnavailable || deskEvidenceUnavailable ? null : round2(jEquity + joeEquity + joelEquity),
    dayPnl: dayPnl.values.total,
    totalPnl: familyUnavailable || deskEvidenceUnavailable ? null : round2(jPnl + joePnl + joelPnl),
    openPnl: openPnl.values.total,
  };

  return {
    schema: "inspr.joe.household.v1",
    generatedAt: gen,
    mode: "PAPER",
    currency: "EUR",
    brokerAccount,
    pnlSources: { day: dayPnl.source, open: openPnl.source },
    source: {
      label: "hsb0 joe-board-pusher (paper Gateway projection)",
      revision: familyAccepted ? brokerSnapshotAt.toISOString() : bookTs,
    },
    safety: {
      halt,
      haltReason: halt ? haltRaw || "HALT" : null,
      staleAfterSeconds: STALE_AFTER,
      gateway: {
        status: gwOk ? "ok" : "down",
        detail: gwOk ? "Paper gateway answering" : book.lastError || "Gateway down",
        lastSeenAt: book.gatewayLastSeenAt || null,
      },
    },
    desks,
    totals,
  };
}

function formatViennaIso(date) {
  const fmt = new Intl.DateTimeFormat("en-US", {
    timeZone: "Europe/Vienna",
    timeZoneName: "shortOffset",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  });
  const parts = Object.fromEntries(fmt.formatToParts(date).map((p) => [p.type, p.value]));
  let off = parts.timeZoneName || "GMT+2";
  const m = /GMT([+-])(\d{1,2})(?::?(\d{2}))?/.exec(off);
  let offset = "+02:00";
  if (m) {
    offset = `${m[1]}${m[2].padStart(2, "0")}:${(m[3] || "00").padStart(2, "0")}`;
  }
  return `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}:${parts.second}${offset}`;
}
