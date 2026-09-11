/** Project IB book state → inspr.joe.household.v1 (mirrors joe-household-sync.py). */

import { currencyCode, deskForSymbol, strictFinite } from "./positions-state.mjs";

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
  const sourceTimes = [book.ts];
  if (familyAccepted) sourceTimes.push(family.observedAt);
  const latestSourceMs = Math.max(...sourceTimes.map((value) => new Date(value || "").getTime()));
  const brokerSnapshotAt = new Date(latestSourceMs);
  if (Number.isNaN(brokerSnapshotAt.getTime())) return null;
  const publisherAt = opts.publisherAt || opts.now || new Date();
  const gen = formatViennaIso(brokerSnapshotAt);
  const heartbeat = formatViennaIso(publisherAt);

  const summary = book.summary || {};
  const bookObservedAt = new Date(book.ts).toISOString();
  const accountEquity = brokerNetLiquidation(summary);
  const publisherMs = new Date(publisherAt).getTime();
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

  const jPnl = familyUnavailable
    ? null
    : familyRuntimeEnabled
    ? round2(family.totalPnl)
    : round2(
      (() => {
        const p = portfolio.find((x) => x.symbol === "INTC");
        return p ? fnum(p.realizedPNL) + fnum(p.unrealizedPNL) : 0;
      })()
    );
  const joePnl = 0.0;
  // Stage-0 attributed only — grandfathered SXR8/TSLA×1 excluded from money.
  const joelPnl = round2(
    stage0Rows.reduce((s, p) => s + fnum(p.unrealizedPNL) + fnum(p.realizedPNL), 0)
  );
  const jEquity = familyUnavailable
    ? null
    : familyRuntimeEnabled
      ? round2(family.equity)
      : round2(VIRTUAL_EQUITY + jPnl);
  const joeEquity = round2(VIRTUAL_EQUITY + joePnl);
  const joelEquity = round2(VIRTUAL_EQUITY + joelPnl);

  const deskPositions = buildDeskPositions(book.positionsCoverage);

  const desks = [
    {
      id: "j",
      label: "J",
      state: familyUnavailable
        ? "stuck"
        : familyRuntimeEnabled && family.positions.length ? "working" : "sit-out",
      stateSince: null,
      action: familyUnavailable
        ? `J accounting unavailable — ${familyUnavailableReason}`
        : familyRuntimeEnabled
        ? "J + J2–J5; verified since 10 Sep; net fees; EUR at observed FX; earlier results unavailable."
        : "Virt book €5k; flat — no open J broker position.",
      learning: {
        status: familyAccepted && family.positions.length ? "steady" : "learning",
        headline: familyUnavailable
          ? "J family accounting unavailable"
          : familyRuntimeEnabled ? "J family execution ledger" : "Shared broker book",
        detail: familyUnavailable
          ? `No verified J result is published: ${familyUnavailableReason}`
          : familyRuntimeEnabled
          ? "J + J2–J5; verified since 10 Sep; net fees; EUR at observed FX; earlier results unavailable."
          : "Virt book €5k; no open J names on the shared broker account.",
        iteration: null,
      },
      money: { equity: jEquity, dayPnl: null, totalPnl: jPnl },
      ...(familyAccepted ? { accounting: family.accounting } : {}),
      ...(familyBackfill ? { backfill: familyBackfill } : {}),
      heartbeatAt: heartbeat,
      issues: familyUnavailable ? [`J accounting unavailable: ${familyUnavailableReason}`] : [],
    },
    {
      id: "joe",
      label: "Joe",
      state: "sit-out",
      stateSince: null,
      action: "Virt book €5k; flat — no open Joe broker names.",
      learning: {
        status: "learning",
        headline: "Empty Joe sleeve",
        detail: "Virt book €5k; no open Joe names today.",
        iteration: null,
      },
      money: { equity: joeEquity, dayPnl: null, totalPnl: joePnl },
      heartbeatAt: heartbeat,
      issues: [],
    },
    {
      id: "joel",
      label: "Joel",
      state: positions.length ? "working" : "sit-out",
      stateSince: null,
      action: positions.length
        ? `Holding ${posTxt}. Legacy paper (${legacyTxt}) is outside Stage-0 money until Faber exit (CONFIG). Stage-0 stand = virt €${VIRTUAL_EQUITY.toLocaleString("en-US")} + Stage-0 PnL, separate from ${accountEquityText}.`
        : `Flat in virt book. Desk equity is Stage-0 virtual €${VIRTUAL_EQUITY.toLocaleString("en-US")}; ${accountEquityText}.`,
      learning: {
        status: positions.length ? "steady" : "learning",
        headline: legacyRows.length
          ? "Virt €5k Stage-0 + open legacy names"
          : "Virt €5k Stage-0 book",
        detail: legacyRows.length
          ? `Legacy held (${legacyTxt}), broker MV ~€${joelMv.toLocaleString("en-US", { minimumFractionDigits: 2 })} — excluded from Stage-0 since-start/stand. Stage-0-attributed PnL €${joelPnl.toLocaleString("en-US", { minimumFractionDigits: 2 })} (open Stage-0 MV ~€${stage0Mv.toLocaleString("en-US", { minimumFractionDigits: 2 })}); stand = virt €5k + that PnL.`
          : `Since-start PnL €${joelPnl.toLocaleString("en-US", { minimumFractionDigits: 2 })}; stand = virt €5k + PnL.`,
        iteration: null,
      },
      money: { equity: joelEquity, dayPnl: null, totalPnl: joelPnl },
      historyBasis: JOEL_HISTORY_BASIS,
      heartbeatAt: heartbeat,
      issues: [],
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

  const issues = [];
  if (halt) issues.push("HALT is on");
  if (!gwOk) issues.push(String(book.lastError || "Gateway down"));
  if (issues.length) {
    desks[1].state = "stuck";
    desks[1].issues = issues;
    desks[1].action = issues.join("; ");
  }

  const totals = {
    equity: familyUnavailable ? null : round2(jEquity + joeEquity + joelEquity),
    dayPnl: null,
    totalPnl: familyUnavailable ? null : round2(jPnl + joePnl + joelPnl),
  };

  return {
    schema: "inspr.joe.household.v1",
    generatedAt: gen,
    mode: "PAPER",
    currency: "EUR",
    brokerAccount,
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
