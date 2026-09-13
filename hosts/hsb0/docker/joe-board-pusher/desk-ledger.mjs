import { createHash } from "node:crypto";

import { newYorkPeriodStart } from "./day-baseline.mjs";
import { normalizeEconomicCommission, normalizeEconomicExecution } from "./execution-history.mjs";
import { effectiveExecutionRecords, validateBestAvailableHistoryState } from "./execution-reconciliation.mjs";
import { calculateFamily, mergeExecutionRecords } from "./family-ledger.mjs";
import { isTrustedOfficialFamilyReceipt } from "./family-state.mjs";

const PERIOD_START = "2026-09-10T04:00:00Z";
const METHOD = "owned-lots-current-mark-fx";
const SCOPE = "stage0-virtual-desks-keep-excluded";
const HISTORY_REVISION_METHOD = "sha256-effective-all-desk-economic-history-v1";
const POLICY_METHOD = "effective-dated-client-id-ownership-v1";
const DESKS = ["j", "joe", "joel"];

// Client 22 is bound only from the fixed baseline. The dated broker rows are the
// two 2026-09-10 INTC fills and the four 2026-09-11 INTC/HPE fills, corroborated
// by the Joe desk journals. Shared/read-only registry ranges are deliberately absent.
export const CURRENT_DESK_OWNERSHIP_POLICY = Object.freeze({
  method: POLICY_METHOD,
  periodStart: PERIOD_START,
  scope: SCOPE,
  excludedSymbols: Object.freeze(["SXR8", "TSLA"]),
  keepPositions: Object.freeze([
    Object.freeze({ symbol: "SXR8", quantity: 1401 }),
    Object.freeze({ symbol: "TSLA", quantity: 1 }),
  ]),
  assignments: Object.freeze([
    ...[27, 28, 29, 50, 51, 52, 53, 54, 55, 56].map((clientId) => Object.freeze({
      desk: "j", clientId, fromInclusive: PERIOD_START, toExclusive: null, basis: "existing-j-family-policy",
    })),
    Object.freeze({
      desk: "joe", clientId: 22, fromInclusive: PERIOD_START, toExclusive: null,
      basis: "broker-executions-and-desk-journals-2026-09-10-11",
    }),
  ]),
  emptyDesks: Object.freeze(["joel"]),
});

export const DESK_HISTORY_REVISION_METHOD = HISTORY_REVISION_METHOD;

function stable(value) {
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stable(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function digest(value) {
  return createHash("sha256").update(stable(value)).digest("hex");
}

function instant(value, label) {
  if (typeof value !== "string" ||
      !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$/.test(value)) {
    throw new Error(`${label} must have an explicit timezone`);
  }
  const epoch = Date.parse(value);
  if (!Number.isFinite(epoch)) throw new Error(`${label} is invalid`);
  return new Date(epoch).toISOString();
}

function number(value, label) {
  if (typeof value !== "number" || !Number.isFinite(value) || Math.abs(value) === Number.MAX_VALUE) {
    throw new Error(`${label} must be finite`);
  }
  return value;
}

function canonicalPolicy(value = CURRENT_DESK_OWNERSHIP_POLICY) {
  if (value?.method !== POLICY_METHOD || value?.scope !== SCOPE) throw new Error("desk ownership policy is invalid");
  const normalizedPeriodStart = instant(value.periodStart, "policy periodStart");
  if (Date.parse(normalizedPeriodStart) !== Date.parse(PERIOD_START)) {
    throw new Error(`desk ownership policy must start at ${PERIOD_START}`);
  }
  const periodStart = PERIOD_START;
  const excludedSymbols = [...new Set((value.excludedSymbols || []).map((item) => String(item).trim().toUpperCase()))].sort();
  if (stable(excludedSymbols) !== stable(["SXR8", "TSLA"])) throw new Error("desk ownership policy KEEP exclusions are invalid");
  const keepPositions = (value.keepPositions || []).map((row) => ({
    symbol: String(row?.symbol || "").trim().toUpperCase(),
    quantity: number(row?.quantity, "KEEP quantity"),
  })).sort((left, right) => left.symbol.localeCompare(right.symbol));
  if (keepPositions.length !== 2 || keepPositions.some((row) => !excludedSymbols.includes(row.symbol) || row.quantity === 0) ||
      new Set(keepPositions.map((row) => row.symbol)).size !== keepPositions.length) {
    throw new Error("desk ownership policy exact KEEP positions are invalid");
  }
  const assignments = (value.assignments || []).map((row) => {
    if (!DESKS.includes(row?.desk) || !Number.isSafeInteger(row?.clientId) || row.clientId < 0 ||
        typeof row?.basis !== "string" || !row.basis.trim()) throw new Error("desk ownership assignment is invalid");
    const fromInclusive = instant(row.fromInclusive, "assignment start");
    const toExclusive = row.toExclusive === null ? null : instant(row.toExclusive, "assignment end");
    if (Date.parse(fromInclusive) < Date.parse(periodStart) ||
        (toExclusive !== null && Date.parse(toExclusive) <= Date.parse(fromInclusive))) {
      throw new Error("desk ownership assignment interval is invalid");
    }
    return { desk: row.desk, clientId: row.clientId, fromInclusive, toExclusive, basis: row.basis.trim() };
  }).sort((left, right) => left.clientId - right.clientId || left.fromInclusive.localeCompare(right.fromInclusive) || left.desk.localeCompare(right.desk));
  for (let index = 0; index < assignments.length; index += 1) {
    for (let next = index + 1; next < assignments.length; next += 1) {
      const left = assignments[index];
      const right = assignments[next];
      if (right.clientId !== left.clientId) break;
      const leftEnd = left.toExclusive || "9999-12-31T23:59:59.999Z";
      const rightEnd = right.toExclusive || "9999-12-31T23:59:59.999Z";
      if (left.fromInclusive < rightEnd && right.fromInclusive < leftEnd) {
        throw new Error(`client ${left.clientId} has conflicting desk ownership intervals`);
      }
    }
  }
  const emptyDesks = [...new Set(value.emptyDesks || [])].sort();
  if (emptyDesks.some((desk) => !DESKS.includes(desk))) throw new Error("desk ownership empty-desk declaration is invalid");
  for (const desk of emptyDesks) {
    if (assignments.some((row) => row.desk === desk)) throw new Error(`${desk} cannot be both assigned and explicitly empty`);
  }
  for (const desk of DESKS) {
    if (!assignments.some((row) => row.desk === desk) && !emptyDesks.includes(desk)) {
      throw new Error(`${desk} has neither an ownership assignment nor an explicit empty declaration`);
    }
  }
  return { method: POLICY_METHOD, periodStart, scope: SCOPE, excludedSymbols, keepPositions, assignments, emptyDesks };
}

/** Canonical contract callers can persist before any valuation evidence exists. */
export function deskOwnershipPolicyContract(policy = CURRENT_DESK_OWNERSHIP_POLICY) {
  const canonical = canonicalPolicy(policy);
  return {
    method: METHOD,
    policyMethod: POLICY_METHOD,
    policyHash: digest(canonical),
    scope: SCOPE,
    keepExcluded: true,
  };
}

function classify(row, policy) {
  const matches = policy.assignments.filter((rule) => rule.clientId === row.execution.clientId &&
    rule.fromInclusive <= row.execution.time && (rule.toExclusive === null || row.execution.time < rule.toExclusive));
  if (matches.length !== 1) {
    throw new Error(matches.length ? `client ${row.execution.clientId} has conflicting desk ownership` :
      `execution client ${row.execution.clientId} is unclaimed by the desk ownership policy`);
  }
  return matches[0].desk;
}

function effectiveRows(rows) {
  return mergeExecutionRecords([], rows).map(normalizeEconomicExecution);
}

function economicHistory({ rows, commissions, policy, cutoff, inclusive = true, account }) {
  const through = instant(cutoff, "history cutoff");
  const fees = new Map(commissions.map((row) => {
    const fee = normalizeEconomicCommission(row);
    return [fee.execId, fee];
  }));
  const excluded = new Set(policy.excludedSymbols);
  const economics = [];
  for (const row of rows.filter((item) => inclusive ? item.execution.time <= through : item.execution.time < through)
    .sort((left, right) => left.execution.time.localeCompare(right.execution.time) || left.execution.execId.localeCompare(right.execution.execId))) {
    if (row.execution.acctNumber !== account) throw new Error("execution account does not match the all-desk source");
    if (excluded.has(row.contract.symbol)) continue;
    const desk = classify(row, policy);
    const fee = fees.get(row.execution.execId);
    if (!fee) throw new Error(`missing commission for classified execution ${row.execution.execId}`);
    economics.push({
      desk,
      contract: row.contract,
      execution: row.execution,
      fee: { execId: fee.execId, commission: fee.commission, currency: fee.currency },
    });
  }
  return economics;
}

function historyRevision(source, policy, cutoff, inclusive = true) {
  const economics = economicHistory({ ...source, policy, cutoff, inclusive });
  return digest({ method: HISTORY_REVISION_METHOD, policy, economics });
}

function assertOfficialIdentities(state, source, policy, cutoff, proofObservedAt, inclusive = true) {
  const executionIds = new Set();
  const commissionIds = new Set();
  for (const receipt of state.receipts) {
    if (!isTrustedOfficialFamilyReceipt(receipt) ||
        instant(receipt.capturedAt, "receipt capturedAt") > proofObservedAt) continue;
    for (const id of receipt.executionIds) executionIds.add(id);
    for (const id of receipt.commissionIds) commissionIds.add(id);
  }
  const excluded = new Set(policy.excludedSymbols);
  for (const row of source.rows) {
    if ((inclusive ? row.execution.time > cutoff : row.execution.time >= cutoff) ||
        excluded.has(row.contract.symbol)) continue;
    if (!executionIds.has(row.execution.execId)) {
      throw new Error("effective execution is absent from trusted official receipts");
    }
    if (!commissionIds.has(row.execution.execId)) {
      throw new Error("effective commission is absent from trusted official receipts");
    }
  }
}

function completeCoverage(receipts, fromInclusive, throughExclusive, proofObservedAt) {
  if (fromInclusive === throughExclusive) {
    return { status: "complete", fromInclusive, throughExclusive };
  }
  const intervals = receipts.filter((receipt) => isTrustedOfficialFamilyReceipt(receipt) &&
    instant(receipt.capturedAt, "receipt capturedAt") <= proofObservedAt)
    .map((receipt) => ({
      fromInclusive: instant(receipt.window.fromInclusive, "receipt window start"),
      throughExclusive: instant(receipt.window.toExclusive, "receipt window end"),
      capturedAt: instant(receipt.capturedAt, "receipt capturedAt"),
    }))
    .filter((row) => row.throughExclusive > fromInclusive && row.fromInclusive < throughExclusive)
    .sort((left, right) => left.fromInclusive.localeCompare(right.fromInclusive) || left.throughExclusive.localeCompare(right.throughExclusive));
  let cursor = fromInclusive;
  let start = null;
  for (const interval of intervals) {
    if (interval.capturedAt < interval.throughExclusive) throw new Error("authoritative receipt predates its claimed interval");
    if (interval.throughExclusive <= cursor) continue;
    if (interval.fromInclusive > cursor) break;
    start ??= interval.fromInclusive;
    if (interval.throughExclusive > cursor) cursor = interval.throughExclusive;
    if (cursor >= throughExclusive) return { status: "complete", fromInclusive: start, throughExclusive: cursor };
  }
  throw new Error("authoritative all-account execution coverage is incomplete");
}

function canonicalLedgerSource(ledgerState, account) {
  if (!ledgerState || ledgerState.account !== account || ledgerState.periodStart !== PERIOD_START ||
      !Array.isArray(ledgerState.executions) || !Array.isArray(ledgerState.commissions)) {
    throw new Error("all-account ledger state is invalid");
  }
  if (ledgerState.executions.some((row) => row?.execution?.pendingPriceRevision === true)) {
    throw new Error("all-account ledger contains a pending execution correction");
  }
  const rows = effectiveRows(ledgerState.executions);
  if (rows.some((row) => row.execution.acctNumber !== account)) {
    throw new Error("execution account does not match the all-desk source");
  }
  return { rows, commissions: ledgerState.commissions, account };
}

function canonicalHistorySource(state, account) {
  validateBestAvailableHistoryState(state);
  if (state.account !== account) throw new Error("authoritative history account does not match");
  const effective = effectiveExecutionRecords(state);
  if (effective.some((row) => row?.execution?.pendingPriceRevision === true)) {
    throw new Error("authoritative history contains a pending execution correction");
  }
  return { rows: effective.map(normalizeEconomicExecution), commissions: state.commissions, account };
}

function remapForDesk(rows, policy, desk) {
  const excluded = new Set(policy.excludedSymbols);
  return rows.map((row) => ({
    contract: structuredClone(row.contract),
    execution: {
      ...structuredClone(row.execution),
      clientId: excluded.has(row.contract.symbol) || classify(row, policy) !== desk ? 2 : 1,
    },
  }));
}

function observedKeep(positions, account, policy) {
  const excluded = new Set(policy.excludedSymbols);
  const rows = [];
  for (const row of positions) {
    const suppliedAccount = row?.account ?? row?.accountName ?? row?.acctNumber;
    if (suppliedAccount !== undefined && suppliedAccount !== account) continue;
    const symbol = String(row?.symbol || row?.contract?.symbol || "").trim().toUpperCase();
    if (!excluded.has(symbol)) continue;
    const quantity = number(row?.pos, "observed KEEP quantity");
    if (quantity !== 0) rows.push({ symbol, quantity });
  }
  rows.sort((left, right) => left.symbol.localeCompare(right.symbol));
  if (stable(rows) !== stable(policy.keepPositions)) throw new Error("current KEEP positions do not exactly match the desk ownership policy");
}

function deskValue(result) {
  return {
    equity: result.equity,
    totalPnl: result.totalPnl,
    realizedPnl: result.realizedPnl,
    unrealizedPnl: result.unrealizedPnl,
    positions: structuredClone(result.positions),
  };
}

function roundEur(value) {
  return Math.round((value + Number.EPSILON) * 100) / 100;
}

function currentDayDirectCoverage(ledgerState, ledger, policy, cutoff) {
  const day = newYorkDay(cutoff);
  const dayStart = newYorkPeriodStart(cutoff);
  if (!day || !dayStart || ledgerState?.coverageTradingDay !== day ||
      !Array.isArray(ledgerState?.queryExecutionIdentities)) {
    throw new Error("direct all-account execution coverage metadata is invalid");
  }
  const currentRows = ledger.rows.filter((row) => row.execution.time >= dayStart && row.execution.time <= cutoff);
  const currentById = new Map(currentRows.map((row) => [row.execution.execId, row]));
  const queryIds = ledgerState.queryExecutionIdentities;
  const queryIdSet = new Set(queryIds);
  if (queryIdSet.size !== queryIds.length ||
      queryIds.some((id) => typeof id !== "string" || !currentById.has(id)) ||
      currentRows.some((row) => !queryIdSet.has(row.execution.execId))) {
    throw new Error("direct current-day execution identities are incomplete or outside the covered day");
  }
  const commissionIds = new Set(ledger.commissions.map((row) => normalizeEconomicCommission(row).execId));
  const excluded = new Set(policy.excludedSymbols);
  for (const row of currentRows) {
    if (excluded.has(row.contract.symbol)) continue;
    classify(row, policy);
    if (!commissionIds.has(row.execution.execId)) {
      throw new Error("direct current-day execution is missing its commission");
    }
  }
  return { dayStart, throughInclusive: cutoff };
}

/** Calculate independently attributable J/Joe/Joel EUR equity from complete broker evidence. */
export function calculateDeskEquities({
  ledgerState,
  verifiedHistoryState,
  portfolio,
  positions,
  fx,
  account,
  policy = CURRENT_DESK_OWNERSHIP_POLICY,
  observedAt,
  jResult = null,
} = {}) {
  try {
    if (typeof account !== "string" || !account.trim()) throw new Error("target account is invalid");
    const canonical = canonicalPolicy(policy);
    const cutoff = instant(ledgerState?.coverageThrough, "ledger coverageThrough");
    const sourceAt = instant(observedAt, "source observedAt");
    if (sourceAt < cutoff) throw new Error("source observation predates execution coverage");
    const ledger = canonicalLedgerSource(ledgerState, account);
    const history = canonicalHistorySource(verifiedHistoryState, account);
    if (ledger.rows.some((row) => row.execution.time > cutoff)) {
      throw new Error("live ledger contains an execution after its coverage boundary");
    }
    const proofAt = instant(verifiedHistoryState.updatedAt, "authoritative history updatedAt");
    const directCoverage = currentDayDirectCoverage(ledgerState, ledger, canonical, cutoff);
    completeCoverage(verifiedHistoryState.receipts, canonical.periodStart, directCoverage.dayStart, proofAt);
    assertOfficialIdentities(verifiedHistoryState, history, canonical, directCoverage.dayStart, proofAt, false);
    const priorLedgerRevision = historyRevision(ledger, canonical, directCoverage.dayStart, false);
    const priorOfficialRevision = historyRevision(history, canonical, directCoverage.dayStart, false);
    if (priorLedgerRevision !== priorOfficialRevision) {
      throw new Error("live ledger historical economics do not match authoritative all-account history");
    }
    const ledgerEconomics = economicHistory({ ...ledger, policy: canonical, cutoff });
    const ledgerRevision = historyRevision(ledger, canonical, cutoff);
    observedKeep(positions || [], account, canonical);

    const calculate = (desk) => calculateFamily({
      executions: remapForDesk(ledger.rows, canonical, desk),
      commissions: structuredClone(ledgerState.commissions),
      portfolio: structuredClone(portfolio || []),
      positions: structuredClone(positions || []),
      fx: structuredClone(fx),
      account,
      familyClientIds: [1],
      excludedSymbols: canonical.excludedSymbols,
      periodStart: canonical.periodStart,
      virtualEquity: 5000,
      observedAt: sourceAt,
    });
    const j = calculate("j");
    const joe = calculate("joe");
    if (!j.ok) throw new Error(`J desk calculation unavailable: ${j.reason}`);
    if (!joe.ok) throw new Error(`Joe desk calculation unavailable: ${joe.reason}`);
    const compatibleJ = (result) => ({
      ...deskValue(result), accounting: result.accounting, openPnlEvidence: result.openPnlEvidence,
      executionCount: result.executionCount,
    });
    if (jResult && stable(compatibleJ(j)) !== stable(compatibleJ(jResult))) {
      throw new Error("all-desk J result differs from the existing family result");
    }
    if (!canonical.emptyDesks.includes("joel")) throw new Error("Joel empty ownership is not explicitly declared");
    const joel = { equity: 5000, totalPnl: 0, realizedPnl: 0, unrealizedPnl: 0, positions: [] };
    const desks = { j: deskValue(j), joe: deskValue(joe), joel };
    const equity = {
      j: desks.j.equity,
      joe: desks.joe.equity,
      joel: desks.joel.equity,
      total: roundEur(desks.j.equity + desks.joe.equity + desks.joel.equity),
    };
    const requiredCurrencies = new Set(["EUR"]);
    for (const row of ledgerEconomics) {
      requiredCurrencies.add(row.contract.currency);
      requiredCurrencies.add(row.fee.currency);
    }
    const rateTimes = [...requiredCurrencies].map((currency) => {
      if (!Number.isFinite(fx?.rates?.[currency])) throw new Error(`explicit ${currency}→EUR FX rate is unavailable`);
      return instant(fx?.rateObservedAt?.[currency], `${currency} FX observedAt`);
    });
    const markTimes = [...j.positions, ...joe.positions].map((row) => instant(row.updatedAt, "position mark observedAt"));
    const freshnessTimes = [cutoff, ...rateTimes, ...markTimes];
    if (freshnessTimes.some((value) => value > sourceAt)) throw new Error("all-desk source observation predates an economic input");
    const oldestSourceObservedAt = [...freshnessTimes].sort()[0];
    const sourceContract = deskOwnershipPolicyContract(canonical);
    const policyHash = sourceContract.policyHash;
    return {
      ok: true,
      desks,
      equity,
      sourceObservedAt: sourceAt,
      oldestSourceObservedAt,
      historyRevisionMethod: HISTORY_REVISION_METHOD,
      historyRevision: ledgerRevision,
      executionCoverage: { status: "complete", fromInclusive: canonical.periodStart, throughInclusive: cutoff },
      sourceContract,
      ownershipEvidence: {
        status: "complete",
        policyHash,
        unclaimedExecutionCount: 0,
        exactKeepPositions: structuredClone(canonical.keepPositions),
      },
    };
  } catch (error) {
    return { ok: false, reason: String(error?.message || error) };
  }
}

/** Revision captured with the live family ledger at a valuation candidate. */
export function deskLedgerRevisionAt({ ledgerState, account, policy = CURRENT_DESK_OWNERSHIP_POLICY, throughInclusive } = {}) {
  try {
    const canonical = canonicalPolicy(policy);
    const source = canonicalLedgerSource(ledgerState, account);
    return {
      ok: true,
      historyRevisionMethod: HISTORY_REVISION_METHOD,
      historyRevision: historyRevision(source, canonical, throughInclusive),
      policyHash: digest(canonical),
    };
  } catch (error) {
    return { ok: false, reason: String(error?.message || error) };
  }
}

const newYorkFormatter = new Intl.DateTimeFormat("en-CA", {
  timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit",
  hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
});

function newYorkDay(value) {
  const normalized = instant(value, "New York day source");
  const parts = Object.fromEntries(newYorkFormatter.formatToParts(new Date(normalized))
    .filter((part) => part.type !== "literal").map((part) => [part.type, part.value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
}

function exactNewYorkMidnight(value) {
  const normalized = instant(value, "periodStart");
  const parts = Object.fromEntries(newYorkFormatter.formatToParts(new Date(normalized))
    .filter((part) => part.type !== "literal").map((part) => [part.type, Number(part.value)]));
  if (parts.hour !== 0 || parts.minute !== 0 || parts.second !== 0 || new Date(normalized).getUTCMilliseconds() !== 0) {
    throw new Error("periodStart must be exact America/New_York midnight");
  }
  return normalized;
}

/** Promote a persisted candidate only when official all-desk economics stay unchanged to NY midnight. */
export function buildDeskDayBoundaryEvidence({
  verifiedHistoryState,
  account,
  policy = CURRENT_DESK_OWNERSHIP_POLICY,
  candidateSourceObservedAt,
  candidateHistoryRevision,
  periodStart,
  proofObservedAt,
} = {}) {
  try {
    const canonical = canonicalPolicy(policy);
    const candidateAt = instant(candidateSourceObservedAt, "candidateSourceObservedAt");
    const boundary = exactNewYorkMidnight(periodStart);
    const proofAt = instant(proofObservedAt, "proofObservedAt");
    if (candidateAt > boundary) throw new Error("candidate observation must not follow periodStart");
    if (proofAt < boundary) throw new Error("proofObservedAt must not precede periodStart");
    const history = canonicalHistorySource(verifiedHistoryState, account);
    if (instant(verifiedHistoryState.updatedAt, "authoritative history updatedAt") > proofAt) {
      throw new Error("authoritative history was observed after proofObservedAt");
    }
    const coverage = completeCoverage(verifiedHistoryState.receipts, candidateAt, boundary, proofAt);
    assertOfficialIdentities(verifiedHistoryState, history, canonical, boundary, proofAt);
    if (typeof candidateHistoryRevision !== "string" || !/^[0-9a-f]{64}$/.test(candidateHistoryRevision)) {
      throw new Error("candidateHistoryRevision is invalid");
    }
    const boundaryHistoryRevision = historyRevision(history, canonical, boundary, false);
    if (candidateHistoryRevision !== boundaryHistoryRevision) {
      throw new Error("effective all-desk economic history changed before the day boundary");
    }
    return {
      ok: true,
      periodStart: boundary,
      proofObservedAt: proofAt,
      historyRevisionMethod: HISTORY_REVISION_METHOD,
      candidateHistoryRevision,
      boundaryHistoryRevision,
      executionCoverage: coverage,
      policyHash: digest(canonical),
    };
  } catch (error) {
    return { ok: false, reason: String(error?.message || error) };
  }
}
