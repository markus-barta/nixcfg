import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

import { EXECUTION_QUERY_REQUEST_SCHEMA } from "./execution-history.mjs";

const STATE_SCHEMA = "inspr.joe.family-execution-ledger.v2";
const LEGACY_SCHEMA = "inspr.joe.family-execution-ledger.v1";
const ACTIVATION_SCHEMA = "inspr.joe.family-execution-ledger.activation.v1";
const MAX_STATE_BYTES = 16 * 1024 * 1024;
const MAX_RECORDS = 50_000;
const MAX_QUERY_DATES = 7;
const BASELINE_PERIOD_START = "2026-09-10T04:00:00Z";
const BASELINE_NEW_YORK_DAY = "2026-09-10";
const executionEpochCache = new Map();

function clone(value) {
  return structuredClone(value);
}

function stable(value) {
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${stable(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function same(left, right) {
  return stable(left) === stable(right);
}

function iso(value) {
  const epoch = Date.parse(value || "");
  return Number.isFinite(epoch) ? new Date(epoch).toISOString() : null;
}

function sha256(source) {
  return createHash("sha256").update(source).digest("hex");
}

function finite(value, label, { positive = false } = {}) {
  if (typeof value !== "number" || !Number.isFinite(value) || Math.abs(value) === Number.MAX_VALUE) {
    throw new Error(`${label} is not finite`);
  }
  if (positive && value <= 0) throw new Error(`${label} is not positive`);
  return value;
}

function requiredText(value, label) {
  if (typeof value !== "string" || !value.trim()) throw new Error(`${label} is invalid`);
  return value.trim();
}

function currency(value, label) {
  const code = requiredText(value, label).toUpperCase();
  if (!/^[A-Z]{3}$/.test(code)) throw new Error(`${label} is invalid`);
  return code;
}

function contractMultiplier(value, secType) {
  if (
    secType === "STK" &&
    (value === "" || value === 0 || value === 1 || value === "0" || value === "1" || value === null)
  ) {
    return 1;
  }
  if (value === null) return null;
  if (typeof value === "string") {
    if (value.length > 256 || [...value].some((character) => character.codePointAt(0) < 32)) {
      throw new Error("contract multiplier is invalid or too long");
    }
    return value;
  }
  return finite(value, "contract multiplier");
}

function normalizeContract(contract) {
  if (!contract || typeof contract !== "object") throw new Error("execution contract is malformed");
  const secType = requiredText(contract.secType, "contract secType").toUpperCase();
  if (!Number.isSafeInteger(contract.conId) || contract.conId <= 0) {
    throw new Error("contract conId is invalid");
  }
  return {
    conId: contract.conId,
    symbol: requiredText(contract.symbol, "contract symbol").toUpperCase(),
    secType,
    currency: currency(contract.currency, "contract currency"),
    multiplier: contractMultiplier(contract.multiplier, secType),
  };
}

function normalizeExecutionRecord(row, account) {
  if (!row || typeof row !== "object" || !row.execution) {
    throw new Error("execution record is malformed");
  }
  const execution = row.execution;
  if (requiredText(execution.acctNumber, "execution account") !== account) {
    throw new Error("execution account mismatch");
  }
  if (!Number.isSafeInteger(execution.clientId) || execution.clientId < 0) {
    throw new Error("execution clientId is invalid");
  }
  const rawSide = requiredText(execution.side, "execution side").toUpperCase();
  const side = { BOT: "BUY", BUY: "BUY", SLD: "SELL", SELL: "SELL" }[rawSide];
  if (!side) {
    throw new Error("execution side is unsupported");
  }
  const pendingPriceRevision = execution.pendingPriceRevision ?? false;
  if (typeof pendingPriceRevision !== "boolean") {
    throw new Error("execution pendingPriceRevision is invalid");
  }
  const normalized = {
    contract: normalizeContract(row.contract),
    execution: {
      execId: requiredText(execution.execId, "execution execId"),
      time: requiredText(execution.time, "execution time"),
      acctNumber: account,
      clientId: execution.clientId,
      side,
      shares: finite(execution.shares, "execution shares", { positive: true }),
      price: finite(execution.price, "execution price", { positive: true }),
      pendingPriceRevision,
    },
  };
  if (executionEpoch(normalized) === null) throw new Error("execution time is invalid or ambiguous");
  return normalized;
}

function normalizeCommission(report) {
  if (!report || typeof report !== "object") throw new Error("commission is malformed");
  return {
    execId: requiredText(report.execId, "commission execId"),
    commission: finite(report.commission, "commission amount"),
    currency: currency(report.currency, "commission currency"),
  };
}

function correctionIdentity(rowOrId) {
  const id = typeof rowOrId === "string" ? rowOrId : rowOrId?.execution?.execId;
  const match = id?.match(/^(.*\.)(\d+)$/);
  if (!match || match[1] === ".") throw new Error("execution ID has no correction segment");
  return { id, prefix: match[1], revision: BigInt(match[2]) };
}

function latestIdentities(rows) {
  const latest = new Map();
  for (const row of rows) {
    const identity = correctionIdentity(row);
    const prior = latest.get(identity.prefix);
    if (prior && identity.revision === prior.revision && identity.id !== prior.id) {
      throw new Error("conflicting correction revision");
    }
    if (!prior || identity.revision > prior.revision) latest.set(identity.prefix, identity);
  }
  return [...latest.values()].sort((left, right) => left.id.localeCompare(right.id));
}

function missingIdentities(priorIds, currentRows) {
  const current = new Map(latestIdentities(currentRows).map((identity) => [identity.prefix, identity]));
  return priorIds.filter((id) => {
    const prior = correctionIdentity(id);
    const next = current.get(prior.prefix);
    return !next || next.revision < prior.revision;
  });
}

function mergeRows(existing, incoming, identify, label) {
  const rows = [...existing];
  const byId = new Map(existing.map((row, index) => [identify(row), { row, index }]));
  let changed = false;
  for (const row of incoming) {
    const id = identify(row);
    const prior = byId.get(id);
    if (prior) {
      if (!same(prior.row, row)) throw new Error(`conflicting ${label} ${id}`);
      continue;
    }
    byId.set(id, { row, index: rows.length });
    rows.push(row);
    changed = true;
  }
  if (rows.length > MAX_RECORDS) throw new Error(`${label} ledger exceeds record limit`);
  return { rows, changed };
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

function newYorkParts(epoch) {
  const result = {};
  for (const part of newYorkFormatter.formatToParts(new Date(epoch))) {
    if (part.type !== "literal") result[part.type] = Number(part.value);
  }
  return [result.year, result.month, result.day, result.hour, result.minute, result.second];
}

function newYorkDay(value) {
  const epoch = Date.parse(value || "");
  if (!Number.isFinite(epoch)) return null;
  const [year, month, day] = newYorkParts(epoch);
  return `${year}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
}

function validCalendarDay(year, month, day) {
  const parsed = new Date(Date.UTC(year, month - 1, day));
  return parsed.getUTCFullYear() === year &&
    parsed.getUTCMonth() === month - 1 &&
    parsed.getUTCDate() === day;
}

function compactDay(day) {
  const match = typeof day === "string" ? day.match(/^(\d{4})-(\d{2})-(\d{2})$/) : null;
  if (!match || !validCalendarDay(Number(match[1]), Number(match[2]), Number(match[3]))) return null;
  return `${match[1]}${match[2]}${match[3]}`;
}

function expandedDay(day) {
  const match = typeof day === "string" ? day.match(/^(\d{4})(\d{2})(\d{2})$/) : null;
  if (!match || !validCalendarDay(Number(match[1]), Number(match[2]), Number(match[3]))) return null;
  return `${match[1]}-${match[2]}-${match[3]}`;
}

function dayRange(first, last) {
  const start = expandedDay(first);
  const end = expandedDay(last);
  if (!start || !end || start > end) throw new Error("execution coverage day range is invalid");
  const days = [];
  let cursor = new Date(`${start}T12:00:00Z`);
  while (cursor.toISOString().slice(0, 10) <= end) {
    days.push(cursor.toISOString().slice(0, 10).replaceAll("-", ""));
    if (days.length > MAX_QUERY_DATES) throw new Error("execution gap exceeds bounded exact-date query capacity");
    cursor = new Date(cursor.getTime() + 86_400_000);
  }
  return days;
}

function persistedDayRange(first, last) {
  const start = expandedDay(first);
  const end = expandedDay(last);
  if (!start || !end || start > end) throw new Error("persisted coverage day range is invalid");
  const days = [];
  let cursor = new Date(`${start}T12:00:00Z`);
  while (cursor.toISOString().slice(0, 10) <= end) {
    days.push(cursor.toISOString().slice(0, 10));
    if (days.length > MAX_RECORDS) throw new Error("persisted coverage day range exceeds state bound");
    cursor = new Date(cursor.getTime() + 86_400_000);
  }
  return days;
}

function executionEpoch(row) {
  const source = row?.execution?.time;
  if (typeof source === "string" && executionEpochCache.has(source)) {
    return executionEpochCache.get(source);
  }
  const match = source?.match(
    /^(\d{4})(\d{2})(\d{2})\s+(\d{2}):(\d{2}):(\d{2})\s+(?:US\/Eastern|America\/New_York)$/
  );
  if (!match) return null;
  const parts = match.slice(1).map(Number);
  const naive = Date.UTC(parts[0], parts[1] - 1, parts[2], parts[3], parts[4], parts[5]);
  const matches = [];
  for (let offset = -14 * 60; offset <= 14 * 60; offset += 15) {
    const candidate = naive - offset * 60_000;
    if (newYorkParts(candidate).every((value, index) => value === parts[index])) {
      matches.push(candidate);
    }
  }
  const result = matches.length === 1 ? matches[0] : null;
  if (executionEpochCache.size >= MAX_RECORDS) executionEpochCache.clear();
  executionEpochCache.set(source, result);
  return result;
}

function normalizedClassifier(familyClientIds, excludedSymbols) {
  if (!familyClientIds || !excludedSymbols) throw new TypeError("family classifier is required");
  const ids = [...familyClientIds].map(Number);
  if (!ids.length || ids.some((value) => !Number.isSafeInteger(value) || value < 0)) {
    throw new TypeError("family classifier has invalid client IDs");
  }
  const symbols = [...excludedSymbols].map((value) => String(value).trim().toUpperCase());
  if (symbols.some((value) => !value)) throw new TypeError("family classifier has invalid excluded symbols");
  return {
    familyClientIds: [...new Set(ids)].sort((left, right) => left - right),
    excludedSymbols: [...new Set(symbols)].sort(),
  };
}

function identityDigest(ids) {
  return sha256(`${[...ids].sort().join("\n")}\n`);
}

function validFamilyResult(result) {
  if (result === null || result === undefined) return null;
  if (!result || result.ok !== true || !iso(result.observedAt) || !Array.isArray(result.positions)) {
    return "persisted family projection is invalid";
  }
  for (const field of ["equity", "totalPnl", "realizedPnl", "unrealizedPnl"]) {
    if (!Number.isFinite(result[field])) return "persisted family projection is invalid";
  }
  return null;
}

function canonicalLedgerRows(value, account) {
  if (!Array.isArray(value.executions) || value.executions.length > MAX_RECORDS) {
    throw new Error("execution ledger is invalid");
  }
  if (!Array.isArray(value.commissions) || value.commissions.length > MAX_RECORDS) {
    throw new Error("commission ledger is invalid");
  }
  const executions = value.executions.map((row) => normalizeExecutionRecord(row, account));
  const commissions = value.commissions.map(normalizeCommission);
  const executionMerge = mergeRows([], executions, (row) => row.execution.execId, "execution");
  const commissionMerge = mergeRows([], commissions, (row) => row.execId, "commission");
  if (executionMerge.rows.length !== executions.length) {
    throw new Error("duplicate execution ledger identity");
  }
  if (commissionMerge.rows.length !== commissions.length) {
    throw new Error("duplicate commission ledger identity");
  }
  return { executions, commissions };
}

function validateCommissionCoverage(rows, classifier) {
  const executionIds = new Set(rows.executions.map((row) => row.execution.execId));
  if (rows.commissions.some((report) => !executionIds.has(report.execId))) {
    throw new Error("commission has no matching execution");
  }
  const familyIds = new Set(classifier.familyClientIds);
  const excluded = new Set(classifier.excludedSymbols);
  const feeIds = new Set(rows.commissions.map((report) => report.execId));
  if (rows.executions.some((row) =>
    familyExecution(row, familyIds, excluded) && !feeIds.has(row.execution.execId))) {
    throw new Error("family execution has no matching commission");
  }
}

function validateLegacyState(value, account, periodStart, classifier) {
  if (!value || value.schema !== LEGACY_SCHEMA || value.version !== 1) {
    throw new Error("unsupported v1 family state schema");
  }
  if (value.account !== account || value.periodStart !== periodStart) {
    throw new Error("v1 family state configuration mismatch");
  }
  const persistedClassifier = normalizedClassifier(
    value.classifier?.familyClientIds || [],
    value.classifier?.excludedSymbols || []
  );
  if (!same(value.classifier, persistedClassifier)) throw new Error("v1 family classifier is not canonical");
  if (!same(persistedClassifier, classifier)) throw new Error("v1 family classifier mismatch");
  if (!iso(value.initializedAt) || !iso(value.ledgerObservedAt) || !iso(value.coverageThrough)) {
    throw new Error("v1 family state timestamps are invalid");
  }
  const rows = canonicalLedgerRows(value, account);
  validateCommissionCoverage(rows, classifier);
  if (!Array.isArray(value.queryExecutionIdentities) ||
      value.queryExecutionIdentities.length > MAX_RECORDS) {
    throw new Error("v1 execution coverage identities are invalid");
  }
  const canonicalIdentities = latestIdentities(value.queryExecutionIdentities).map(({ id }) => id);
  if (!same(canonicalIdentities, value.queryExecutionIdentities)) {
    throw new Error("v1 execution coverage identities are not canonical");
  }
  if (missingIdentities(value.queryExecutionIdentities, rows.executions).length) {
    throw new Error("v1 execution coverage identities are absent from its ledger");
  }
  const coverageDay = compactDay(
    value.coverageTradingDay || newYorkDay(value.coverageThrough)
  );
  if (!coverageDay || expandedDay(coverageDay) !== newYorkDay(value.coverageThrough)) {
    throw new Error("v1 execution coverage day is invalid");
  }
  const familyError = validFamilyResult(value.family);
  if (familyError || value.family?.positions?.length > MAX_RECORDS) throw new Error(familyError || "persisted family projection exceeds limit");
  return {
    account,
    periodStart,
    classifier,
    initializedAt: iso(value.initializedAt),
    ledgerObservedAt: iso(value.ledgerObservedAt),
    coverageThrough: iso(value.coverageThrough),
    coverageDay,
    latestIdentities: [...value.queryExecutionIdentities],
    executions: rows.executions,
    commissions: rows.commissions,
    family: value.family ? clone(value.family) : null,
  };
}

function validateV2State(value, account, periodStart, classifier) {
  if (!value || value.schema !== STATE_SCHEMA || value.version !== 2) {
    throw new Error("unsupported v2 family state schema");
  }
  if (value.account !== account || value.periodStart !== periodStart) {
    throw new Error("v2 family state configuration mismatch");
  }
  const persistedClassifier = normalizedClassifier(
    value.classifier?.familyClientIds || [],
    value.classifier?.excludedSymbols || []
  );
  if (!same(value.classifier, persistedClassifier)) throw new Error("v2 family classifier is not canonical");
  if (!same(persistedClassifier, classifier)) throw new Error("v2 family classifier mismatch");
  if (!iso(value.initializedAt) || !iso(value.ledgerObservedAt)) {
    throw new Error("v2 family state timestamps are invalid");
  }
  const rows = canonicalLedgerRows(value, account);
  validateCommissionCoverage(rows, classifier);
  if (!same(rows.executions, value.executions) || !same(rows.commissions, value.commissions)) {
    throw new Error("v2 family state is not canonical");
  }
  const coverage = value.coverage;
  if (
    !coverage ||
    coverage.timeZone !== "America/New_York" ||
    coverage.periodStart !== periodStart ||
    coverage.contiguousFromDay !== BASELINE_NEW_YORK_DAY ||
    !iso(coverage.observedThrough) ||
    compactDay(coverage.throughDay) === null ||
    !coverage.days || typeof coverage.days !== "object" || Array.isArray(coverage.days)
  ) {
    throw new Error("v2 execution coverage metadata is invalid");
  }
  const expectedDays = persistedDayRange(
    compactDay(BASELINE_NEW_YORK_DAY),
    compactDay(coverage.throughDay)
  );
  if (!same(Object.keys(coverage.days).sort(), expectedDays)) {
    throw new Error("v2 execution coverage has a missing or unexpected day");
  }
  for (const [day, record] of Object.entries(coverage.days)) {
    if (compactDay(day) === null || !record || typeof record !== "object") {
      throw new Error("v2 execution coverage day is invalid");
    }
    if (!iso(record.lastRequestedAt) || !iso(record.lastEndedAt) ||
        !Array.isArray(record.latestCorrectionExecIds)) {
      throw new Error("v2 execution coverage day is invalid");
    }
    const sorted = [...record.latestCorrectionExecIds].sort();
    const dayRows = rows.executions.filter((row) => dayForExecution(row) === day);
    const canonicalIdentities = latestIdentities(dayRows).map(({ id }) => id);
    if (!same(sorted, record.latestCorrectionExecIds) ||
        !same(canonicalIdentities, sorted) ||
        record.identityDigest !== identityDigest(sorted) ||
        !Number.isSafeInteger(record.executionCount) || record.executionCount < 0 ||
        record.knownNonEmptyReplay !== (record.executionCount > 0)) {
      throw new Error("v2 execution coverage day is not canonical");
    }
  }
  if (maxIso(Object.values(coverage.days).map((record) => record.lastEndedAt)) !==
      iso(coverage.observedThrough)) {
    throw new Error("v2 execution coverage watermark is inconsistent");
  }
  const evidence = coverage.historyEvidence;
  if (
    !evidence ||
    !["provisional", "cross_midnight", "over_24h"].includes(evidence.status) ||
    !Number.isSafeInteger(evidence.serverVersion) || evidence.serverVersion < 200 ||
    typeof evidence.sdkVersion !== "string" || !evidence.sdkVersion ||
    typeof evidence.helperSessionId !== "string" || !evidence.helperSessionId ||
    compactDay(evidence.anchorDay) === null ||
    !iso(evidence.anchorExecutionAt) ||
    !/^[0-9a-f]{64}$/.test(evidence.anchorIdentityDigest) ||
    !iso(evidence.provenAt)
  ) {
    throw new Error("v2 history evidence is invalid");
  }
  const anchorAt = iso(evidence.anchorExecutionAt);
  if (!rows.executions.some((row) =>
    dayForExecution(row) === evidence.anchorDay &&
    new Date(executionEpoch(row)).toISOString() === anchorAt)) {
    throw new Error("v2 history evidence anchor is absent from ledger");
  }
  const familyError = validFamilyResult(value.family);
  if (familyError || value.family?.positions?.length > MAX_RECORDS) throw new Error(familyError || "persisted family projection exceeds limit");
  if (value.migration && (
    value.migration.sourceSchema !== LEGACY_SCHEMA ||
    !/^[a-f0-9]{64}$/.test(value.migration.sourceDigest || "") ||
    !iso(value.migration.sourceCoverageThrough)
  )) {
    throw new Error("v2 migration evidence is invalid");
  }
  return { ...value, executions: rows.executions, commissions: rows.commissions };
}

function readStateFile(filePath, fsImpl) {
  let handle;
  try {
    handle = fsImpl.openSync(
      filePath,
      fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK
    );
    const stat = fsImpl.fstatSync(handle);
    if (!stat.isFile() || stat.size <= 0 || stat.size > MAX_STATE_BYTES) {
      return { ok: false, reason: "family ledger state has an invalid size" };
    }
    const bytes = Buffer.alloc(stat.size + 1);
    let count = 0;
    while (count < bytes.length) {
      const read = fsImpl.readSync(handle, bytes, count, bytes.length - count, null);
      if (read === 0) break;
      count += read;
    }
    if (count !== stat.size) {
      return { ok: false, reason: "family ledger state changed size during read" };
    }
    return { ok: true, source: bytes.subarray(0, count).toString("utf8") };
  } catch (error) {
    if (error?.code === "ENOENT") return { ok: true, source: null };
    return { ok: false, reason: `family ledger state read failed: ${error?.code || error}` };
  } finally {
    if (handle !== undefined) fsImpl.closeSync(handle);
  }
}

function economicallyContains(state, legacy) {
  const executions = new Map(state.executions.map((row) => [row.execution.execId, row]));
  for (const row of legacy.executions) {
    if (!executions.has(row.execution.execId) || !same(executions.get(row.execution.execId), row)) {
      return false;
    }
  }
  const commissions = new Map(state.commissions.map((row) => [row.execId, row]));
  for (const row of legacy.commissions) {
    if (!commissions.has(row.execId) || !same(commissions.get(row.execId), row)) return false;
  }
  return true;
}

function sameEconomicIds(left, right) {
  const executionIds = (value) => value.executions.map((row) => row.execution.execId).sort();
  const commissionIds = (value) => value.commissions.map((row) => row.execId).sort();
  return same(executionIds(left), executionIds(right)) &&
    same(commissionIds(left), commissionIds(right));
}

export function createFileFamilyStateStore(
  filePath,
  { legacyPath = null, fsImpl = fs } = {}
) {
  if (typeof filePath !== "string" || !path.isAbsolute(filePath)) {
    throw new TypeError("family v2 state path must be absolute");
  }
  if (legacyPath !== null && (typeof legacyPath !== "string" || !path.isAbsolute(legacyPath))) {
    throw new TypeError("family v1 backup path must be absolute");
  }
  const activationPath = `${filePath}.activated`;

  function activationDigest(source) {
    if (source === null) return null;
    const value = JSON.parse(source);
    if (value?.schema !== ACTIVATION_SCHEMA || !/^[0-9a-f]{64}$/.test(value.sourceDigest || "")) {
      throw new Error("family v2 activation marker is invalid");
    }
    return value.sourceDigest;
  }

  function save(state) {
    validateV2State(state, state?.account, state?.periodStart, state?.classifier);
    if (state.migration) {
      if (!legacyPath) throw new Error("immutable v1 backup path is unavailable");
      const backup = readStateFile(legacyPath, fsImpl);
      if (!backup.ok || backup.source === null) {
        throw new Error(backup.reason || "immutable v1 backup is missing");
      }
      if (sha256(backup.source) !== state.migration.sourceDigest) {
        throw new Error("immutable v1 backup changed after migration");
      }
    }
    const body = `${JSON.stringify(state, null, 2)}\n`;
    if (Buffer.byteLength(body) > MAX_STATE_BYTES) {
      throw new Error("family v2 state exceeds size limit");
    }
    const directory = path.dirname(filePath);
    const temporary = path.join(directory, `.${path.basename(filePath)}.${process.pid}.tmp`);
    let handle;
    try {
      handle = fsImpl.openSync(temporary, "w", 0o600);
      fsImpl.writeFileSync(handle, body, "utf8");
      fsImpl.fsyncSync(handle);
      fsImpl.closeSync(handle);
      handle = undefined;
      fsImpl.renameSync(temporary, filePath);
      const directoryHandle = fsImpl.openSync(directory, "r");
      try {
        fsImpl.fsyncSync(directoryHandle);
      } finally {
        fsImpl.closeSync(directoryHandle);
      }
    } catch (error) {
      if (handle !== undefined) {
        try { fsImpl.closeSync(handle); } catch {}
      }
      try { fsImpl.unlinkSync(temporary); } catch {}
      throw error;
    }
    if (state.migration) {
      const marker = readStateFile(activationPath, fsImpl);
      if (!marker.ok) throw new Error(marker.reason);
      const expected = state.migration.sourceDigest;
      if (marker.source !== null) {
        if (activationDigest(marker.source) !== expected) {
          throw new Error("family v2 activation marker conflicts with migration");
        }
      } else {
        const body = `${JSON.stringify({ schema: ACTIVATION_SCHEMA, sourceDigest: expected })}\n`;
        const handle = fsImpl.openSync(activationPath, "wx", 0o600);
        try {
          fsImpl.writeFileSync(handle, body, "utf8");
          fsImpl.fsyncSync(handle);
        } finally {
          fsImpl.closeSync(handle);
        }
        const directoryHandle = fsImpl.openSync(path.dirname(activationPath), "r");
        try { fsImpl.fsyncSync(directoryHandle); } finally { fsImpl.closeSync(directoryHandle); }
      }
    }
  }

  function load({ account, periodStart, classifier }) {
    const canonicalClassifier = normalizedClassifier(
      classifier?.familyClientIds || [],
      classifier?.excludedSymbols || []
    );
    const active = readStateFile(filePath, fsImpl);
    if (!active.ok) return active;
    const activation = readStateFile(activationPath, fsImpl);
    if (!activation.ok) return activation;
    let recordedActivation = null;
    try {
      recordedActivation = activationDigest(activation.source);
    } catch (error) {
      return { ok: false, reason: error.message };
    }

    let legacy = null;
    let legacySource = null;
    if (legacyPath) {
      const backup = readStateFile(legacyPath, fsImpl);
      if (!backup.ok) return { ok: false, reason: `v1 backup: ${backup.reason}` };
      legacySource = backup.source;
      if (legacySource !== null) {
        try {
          legacy = validateLegacyState(
            JSON.parse(legacySource),
            account,
            periodStart,
            canonicalClassifier
          );
        } catch (error) {
          return { ok: false, reason: `v1 backup is invalid: ${error.message}` };
        }
      }
    }

    if (active.source === null) {
      if (recordedActivation) {
        return { ok: false, reason: "family v2 state is missing after migration activation" };
      }
      return {
        ok: true,
        state: null,
        legacy: legacy ? { ...legacy, sourceDigest: sha256(legacySource) } : null,
      };
    }

    let state;
    try {
      state = validateV2State(
        JSON.parse(active.source),
        account,
        periodStart,
        canonicalClassifier
      );
    } catch (error) {
      return { ok: false, reason: `v2 state is invalid: ${error.message}` };
    }
    if (recordedActivation && !state.migration) {
      return { ok: false, reason: "family v2 activation marker requires migration metadata" };
    }

    if (state.migration) {
      if (recordedActivation && recordedActivation !== state.migration.sourceDigest) {
        return { ok: false, reason: "family v2 activation marker conflicts with migration" };
      }
      if (!legacy || !legacySource) {
        return { ok: false, reason: "immutable v1 backup is missing after migration" };
      }
      if (
        state.migration.sourceSchema !== LEGACY_SCHEMA ||
        state.migration.sourceDigest !== sha256(legacySource) ||
        state.migration.sourceCoverageThrough !== legacy.coverageThrough
      ) {
        return { ok: false, reason: "immutable v1 backup changed after migration" };
      }
      if (!economicallyContains(state, legacy)) {
        return { ok: false, reason: "v1/v2 economic history conflicts" };
      }
    }
    return { ok: true, state, legacy: null };
  }

  return { load, save };
}

function baseCurrencyProven(book, account) {
  const nlv = book?.summary?.NetLiquidation;
  return nlv?.account === account && String(nlv.currency || "").toUpperCase() === "EUR";
}

function maxIso(values) {
  return values.map(iso).filter(Boolean).sort().at(-1) || null;
}

function contractIdentity(contract) {
  return Number.isSafeInteger(contract?.conId) && contract.conId > 0
    ? `conId:${contract.conId}`
    : null;
}

function dayForExecution(row) {
  const value = row?.execution?.time;
  const match = typeof value === "string" ? value.match(/^(\d{4})(\d{2})(\d{2})/) : null;
  return match ? `${match[1]}-${match[2]}-${match[3]}` : null;
}

function familyExecution(row, familyIds, excluded) {
  const symbol = String(row?.contract?.symbol || "").trim().toUpperCase();
  return familyIds.has(row?.execution?.clientId) && !excluded.has(symbol);
}

function dayCoverage(request) {
  const identities = latestIdentities(request.executions).map(({ id }) => id);
  return {
    lastRequestedAt: request.requestedAt,
    lastEndedAt: request.endedAt,
    latestCorrectionExecIds: identities,
    identityDigest: identityDigest(identities),
    executionCount: request.executions.length,
    knownNonEmptyReplay: request.executions.length > 0,
  };
}

function stateAnchorRows(source) {
  return source?.executions || [];
}

function latestKnownAnchorDay(source, gapStart) {
  let latest = null;
  for (const row of stateAnchorRows(source)) {
    const epoch = executionEpoch(row);
    if (epoch !== null && epoch <= gapStart && (!latest || epoch > latest.epoch)) {
      latest = { row, epoch };
    }
  }
  return latest ? dayForExecution(latest.row) : null;
}

function findAnchor(source, requests, gapStart) {
  const responseByDay = new Map(requests.map((request) => [
    expandedDay(request.date),
    new Map(latestIdentities(request.executions).map((identity) => [identity.prefix, identity])),
  ]));
  let latest = null;
  for (const row of stateAnchorRows(source)) {
    const identity = correctionIdentity(row);
    const epoch = executionEpoch(row);
    if (epoch === null || epoch > gapStart) continue;
    const replayed = responseByDay.get(dayForExecution(row))?.get(identity.prefix);
    if (replayed && replayed.revision >= identity.revision && (!latest || epoch > latest.epoch)) {
      latest = { row, identity, epoch };
    }
  }
  return latest;
}

function persistedDayIdentities(source, day) {
  if (source?.coverage?.days?.[day]) {
    return source.coverage.days[day].latestCorrectionExecIds;
  }
  if (source?.coverageDay === compactDay(day)) return source.latestIdentities;
  return [];
}

function buildAcceptedState({
  priorState,
  legacy,
  result,
  account,
  periodStart,
  classifier,
  familyIds,
  excluded,
}) {
  const source = priorState || legacy;
  const requests = result.requests;
  const first = requests[0];
  const observedThrough = maxIso(requests.map((request) => request.endedAt));
  if (!observedThrough) throw new Error("history result has no observation watermark");

  for (const request of requests) {
    const day = expandedDay(request.date);
    const known = persistedDayIdentities(source, day);
    if (known.length && missingIdentities(known, request.executions).length) {
      throw new Error(`retention_loss: ${day} lost previously observed identities`);
    }
  }

  const gapStart = Date.parse(
    priorState?.coverage?.observedThrough || legacy?.coverageThrough || periodStart
  );
  const priorEvidence = priorState?.coverage?.historyEvidence;
  const sourceChanged = Boolean(priorState) && (
    priorEvidence.helperSessionId !== result.helperSessionId ||
    priorEvidence.serverVersion !== result.serverVersion ||
    priorEvidence.sdkVersion !== result.sdkVersion
  );
  const crossesDay = Boolean(source) &&
    compactDay(newYorkDay(new Date(gapStart).toISOString())) !== requests.at(-1).date;
  const needsAnchor = Boolean(legacy || sourceChanged || crossesDay);
  let anchor = source ? findAnchor(source, requests, gapStart) : null;

  if (!source) {
    if (first.date !== compactDay(BASELINE_NEW_YORK_DAY) || first.executions.length === 0) {
      throw new Error("retention_loss: empty or unanchored historical response");
    }
    anchor = first.executions
      .map((row) => ({ row, identity: correctionIdentity(row), epoch: executionEpoch(row) }))
      .filter(({ epoch }) => epoch !== null && epoch <= Date.parse(observedThrough))
      .sort((left, right) => left.epoch - right.epoch)[0];
  }
  if ((needsAnchor || !source) && !anchor) {
    throw new Error("retention_loss: recovery response did not replay a known pre-gap anchor");
  }
  const replayedAnchor = Boolean(anchor);
  const persistedAnchorEpoch = Date.parse(priorEvidence?.anchorExecutionAt || "");
  const persistedAnchorRow = source?.executions?.find((row) =>
    dayForExecution(row) === priorEvidence?.anchorDay &&
    executionEpoch(row) === persistedAnchorEpoch);
  anchor ||= {
    row: persistedAnchorRow || source.executions[0],
    identity: correctionIdentity(persistedAnchorRow || source.executions[0]),
    epoch: executionEpoch(persistedAnchorRow || source.executions[0]),
  };
  if (!anchor.row || anchor.epoch === null) {
    throw new Error("retention_loss: no valid execution anchor is available");
  }
  const anchorRequest = requests.find((request) =>
    expandedDay(request.date) === dayForExecution(anchor.row));
  if (replayedAnchor && !anchorRequest) {
    throw new Error("retention_loss: anchor date is absent from recovery response");
  }
  const anchorIdentityDigest = anchorRequest
    ? identityDigest(anchorRequest.executions.map((row) => row.execution.execId))
    : priorEvidence?.anchorIdentityDigest;
  if (!anchorIdentityDigest) {
    throw new Error("retention_loss: anchor identity evidence is unavailable");
  }

  const incomingExecutions = requests.flatMap((request) => request.executions)
    .map((row) => normalizeExecutionRecord(row, account));
  const incomingCommissions = result.commissions.map(normalizeCommission);
  const executionMerge = mergeRows(
    source?.executions || [],
    incomingExecutions,
    (row) => row.execution.execId,
    "execution"
  );
  const commissionMerge = mergeRows(
    source?.commissions || [],
    incomingCommissions,
    (row) => row.execId,
    "commission"
  );
  const fees = new Set(commissionMerge.rows.map((report) => report.execId));
  const missingFees = incomingExecutions
    .filter((row) => familyExecution(row, familyIds, excluded))
    .map((row) => row.execution.execId)
    .filter((id) => !fees.has(id));
  if (missingFees.length) {
    throw new Error(`history result is missing fees for ${missingFees.length} family executions`);
  }

  const days = clone(priorState?.coverage?.days || {});
  for (const request of requests) days[expandedDay(request.date)] = dayCoverage(request);
  const changed = !priorState || executionMerge.changed || commissionMerge.changed;
  const ageMs = Date.parse(observedThrough) - anchor.epoch;
  const status = !replayedAnchor && priorEvidence
    ? priorEvidence.status
    : ageMs > 86_400_000
      ? "over_24h"
      : crossesDay || sourceChanged || legacy
        ? "cross_midnight"
        : "provisional";

  return {
    schema: STATE_SCHEMA,
    version: 2,
    account,
    periodStart,
    classifier,
    initializedAt: source?.initializedAt || observedThrough,
    ledgerObservedAt: changed
      ? observedThrough
      : priorState?.ledgerObservedAt || legacy?.ledgerObservedAt || observedThrough,
    coverage: {
      timeZone: "America/New_York",
      periodStart,
      contiguousFromDay: BASELINE_NEW_YORK_DAY,
      observedThrough,
      throughDay: expandedDay(requests.at(-1).date),
      days,
      historyEvidence: {
        status,
        serverVersion: result.serverVersion,
        sdkVersion: result.sdkVersion,
        helperSessionId: result.helperSessionId,
        anchorDay: dayForExecution(anchor.row),
        anchorExecutionAt: new Date(anchor.epoch).toISOString(),
        anchorIdentityDigest,
        provenAt: observedThrough,
      },
    },
    executions: executionMerge.rows,
    commissions: commissionMerge.rows,
    family: priorState?.family || null,
    ...(legacy ? {
      migration: {
        sourceSchema: LEGACY_SCHEMA,
        sourceDigest: legacy.sourceDigest,
        sourceCoverageThrough: legacy.coverageThrough,
      },
    } : priorState?.migration ? { migration: priorState.migration } : {}),
  };
}

export function createFamilySessionAdapter({
  targetAccount,
  familyClientIds,
  excludedSymbols = ["SXR8", "TSLA"],
  periodStart = BASELINE_PERIOD_START,
  calculateFamily,
  eventNames,
  store,
  history,
  pollIntervalMs = 30_000,
  fxFreshMs = 300_000,
  now = () => new Date().toISOString(),
  setTimer = setTimeout,
  clearTimer = clearTimeout,
  requestManagedAccounts = true,
  hooks = {},
}) {
  if (!targetAccount || typeof calculateFamily !== "function" || !eventNames || !store || !history) {
    throw new TypeError("targetAccount, calculator, events, store and history are required");
  }
  const classifier = normalizedClassifier(familyClientIds, excludedSymbols);
  const familyIds = new Set(classifier.familyClientIds);
  const excluded = new Set(classifier.excludedSymbols);
  const loaded = store.load({ account: targetAccount, periodStart, classifier });
  let state = loaded.ok && loaded.state ? clone(loaded.state) : null;
  let legacy = loaded.ok && loaded.legacy ? clone(loaded.legacy) : null;
  let pendingMigration = null;
  let blockedReason = loaded.ok ? null : loaded.reason;
  let lastUnavailable = null;
  let activeApi = null;
  let connected = false;
  let managed = false;
  let historyReady = false;
  let inFlight = false;
  let generation = 0;
  let cycleSequence = 0;
  let registrations = [];
  let pollTimer = null;
  let fxInitialComplete = false;
  let fxBuffer = new Map();
  let fxRates = new Map();

  function unavailable(reason) {
    lastUnavailable = reason;
    hooks.onUnavailable?.(reason);
  }

  function clearPoll() {
    if (pollTimer !== null) clearTimer(pollTimer);
    pollTimer = null;
  }

  function schedulePoll() {
    clearPoll();
    if (!connected || !managed || blockedReason) return;
    pollTimer = setTimer(() => {
      pollTimer = null;
      pollNow();
    }, pollIntervalMs);
  }

  function cleanupListeners() {
    for (const item of registrations) item.api.off?.(item.name, item.handler);
    registrations = [];
  }

  function persist(next) {
    try {
      store.save(next);
      state = clone(next);
      return true;
    } catch (error) {
      blockedReason = `family v2 state write failed: ${error.message}`;
      unavailable(blockedReason);
      return false;
    }
  }

  function earliestPendingDay(source) {
    const currentIds = new Set(latestIdentities(source?.executions || []).map(({ id }) => id));
    return source?.executions
      ?.filter((row) => currentIds.has(row.execution.execId) && row.execution.pendingPriceRevision)
      .map(dayForExecution)
      .filter(Boolean)
      .sort()[0] || null;
  }

  function requiredDates() {
    const current = compactDay(newYorkDay(now()));
    if (!current) throw new Error("current New York day is unavailable");
    let start;
    if (state) {
      const coverageDay = compactDay(state.coverage.throughDay);
      const sameHelperSession = history.sessionId &&
        history.sessionId === state.coverage.historyEvidence.helperSessionId;
      if (!sameHelperSession || coverageDay !== current) {
        const gapStart = Date.parse(state.coverage.observedThrough);
        const anchorDay = compactDay(latestKnownAnchorDay(state, gapStart));
        if (!anchorDay) throw new Error("no known execution anchor precedes the recovery gap");
        start = anchorDay;
      } else {
        start = current;
      }
      const pending = compactDay(earliestPendingDay(state));
      if (pending && pending < start) start = pending;
    } else if (legacy) {
      start = legacy.coverageDay;
    } else {
      start = compactDay(BASELINE_NEW_YORK_DAY);
    }
    return dayRange(start, current);
  }

  function pollNow() {
    if (!connected || !managed || blockedReason || inFlight) return false;
    let specificDates;
    try {
      specificDates = requiredDates();
    } catch (error) {
      blockedReason = `retention_loss: ${error.message}`;
      unavailable(blockedReason);
      return false;
    }
    cycleSequence += 1;
    const attachedGeneration = generation;
    const cycleId = `family-history-${attachedGeneration}-${cycleSequence}`;
    inFlight = true;
    historyReady = false;
    lastUnavailable = "official execution history query incomplete";
    history.query({
      schema: EXECUTION_QUERY_REQUEST_SCHEMA,
      cycleId,
      account: targetAccount,
      specificDates,
    }).then((result) => {
      if (generation !== attachedGeneration || !connected) return;
      try {
        const next = buildAcceptedState({
          priorState: state,
          legacy,
          result,
          account: targetAccount,
          periodStart,
          classifier,
          familyIds,
          excluded,
        });
        const changed = !state || next.ledgerObservedAt !== state.ledgerObservedAt;
        if (legacy && !state) {
          pendingMigration = next;
        } else if (!persist(next)) {
          return;
        }
        historyReady = true;
        lastUnavailable = null;
        hooks.onLedgerUpdated?.({
          changed,
          observedAt: next.ledgerObservedAt,
        });
      } catch (error) {
        const reason = error.message;
        if (reason.startsWith("retention_loss:") || reason.includes("conflicting")) {
          blockedReason = reason;
        }
        unavailable(reason);
      }
    }).catch((error) => {
      if (generation !== attachedGeneration) return;
      unavailable(`official execution history unavailable: ${error.message}`);
    }).finally(() => {
      if (generation !== attachedGeneration) return;
      inFlight = false;
      schedulePoll();
    });
    return true;
  }

  function recordFx(codeValue, rateValue) {
    const code = String(codeValue || "").trim().toUpperCase();
    const rate = Number(rateValue);
    const observedAt = iso(now());
    if (!/^[A-Z]{3}$/.test(code) || !Number.isFinite(rate) || rate <= 0 || !observedAt) {
      return;
    }
    const item = { rate, observedAt };
    if (fxInitialComplete) fxRates.set(code, item);
    else fxBuffer.set(code, item);
  }

  function attach(api) {
    cleanupListeners();
    clearPoll();
    generation += 1;
    const attachedGeneration = generation;
    activeApi = api;
    connected = false;
    managed = false;
    historyReady = false;
    inFlight = false;
    fxInitialComplete = false;
    fxBuffer = new Map();
    fxRates = new Map();

    const on = (name, callback) => {
      if (!name) return;
      const handler = (...args) => {
        if (activeApi === api && generation === attachedGeneration) callback(...args);
      };
      api.on(name, handler);
      registrations.push({ api, name, handler });
    };

    on(eventNames.connected, () => {
      connected = true;
      if (requestManagedAccounts) api.reqManagedAccts();
    });
    on(eventNames.managedAccounts, (accounts) => {
      const known = String(accounts || "").split(",").map((value) => value.trim());
      if (!known.includes(targetAccount)) {
        blockedReason = "configured family account is not managed by the Node session";
        unavailable(blockedReason);
        return;
      }
      managed = true;
      pollNow();
    });
    on(eventNames.updateAccountValue, (key, value, code, account) => {
      if (account === targetAccount && key === "ExchangeRate") recordFx(code, value);
    });
    on(eventNames.accountDownloadEnd, (account) => {
      if (account !== targetAccount) return;
      for (const [code, item] of fxBuffer) fxRates.set(code, item);
      fxBuffer = new Map();
      fxInitialComplete = true;
    });
    on(eventNames.disconnected, () => {
      if (generation !== attachedGeneration) return;
      generation += 1;
      connected = false;
      managed = false;
      historyReady = false;
      inFlight = false;
      fxRates = new Map();
      fxBuffer = new Map();
      fxInitialComplete = false;
      clearPoll();
      cleanupListeners();
      activeApi = null;
      history.stop("Node broker disconnected");
      unavailable("broker disconnected; fresh official history and FX required");
    });
    return attachedGeneration;
  }

  function requiredCurrencies(source) {
    const currencies = new Set(["EUR"]);
    const familyIdsForFees = new Set();
    for (const row of source.executions) {
      if (!familyExecution(row, familyIds, excluded)) continue;
      currencies.add(row.contract.currency);
      familyIdsForFees.add(row.execution.execId);
    }
    for (const report of source.commissions) {
      if (familyIdsForFees.has(report.execId)) currencies.add(report.currency);
    }
    return currencies;
  }

  function calculatorLedger(source) {
    const executions = source.executions.filter((row) =>
      row.contract.secType === "STK" || familyExecution(row, familyIds, excluded));
    const executionIds = new Set(executions.map((row) => row.execution.execId));
    return {
      executions: clone(executions),
      commissions: clone(source.commissions.filter((row) => executionIds.has(row.execId))),
    };
  }

  function calculatorArgs(source, book) {
    if (!baseCurrencyProven(book, targetAccount)) {
      throw new Error("target account base currency is not proven EUR");
    }
    if (book?.positionsCoverage?.status !== "complete") {
      throw new Error("current broker positions are incomplete");
    }
    const currentEpoch = Date.parse(now());
    if (!Number.isFinite(currentEpoch)) throw new Error("FX freshness time is unavailable");
    const rates = {};
    const rateTimes = [];
    for (const code of requiredCurrencies(source)) {
      const item = fxRates.get(code);
      const age = item ? currentEpoch - Date.parse(item.observedAt) : Number.POSITIVE_INFINITY;
      if (!item || !Number.isFinite(age) || age < 0 || age > fxFreshMs) {
        throw new Error(`fresh explicit ${code}→EUR FX rate unavailable`);
      }
      rates[code] = item.rate;
      rateTimes.push(item.observedAt);
    }
    const affected = new Set(
      source.executions
        .filter((row) => familyExecution(row, familyIds, excluded))
        .map((row) => contractIdentity(row.contract))
        .filter(Boolean)
    );
    const marketTimes = (book.portfolio || [])
      .filter((row) => affected.has(contractIdentity(row.contract)))
      .flatMap((row) => [row.markObservedAt, row.observedAt]);
    const observedAt = maxIso([source.ledgerObservedAt, ...rateTimes, ...marketTimes]);
    if (!observedAt) throw new Error("family economic observation timestamp is unavailable");
    const ledger = calculatorLedger(source);
    return {
      ...ledger,
      portfolio: clone(book.portfolio || []),
      positions: clone(book.positionsCoverage.rows || []),
      fx: { baseCurrency: "EUR", rates, observedAt: maxIso(rateTimes) },
      account: targetAccount,
      familyClientIds: [...familyIds],
      excludedSymbols: [...excluded],
      periodStart,
      virtualEquity: 5000,
      observedAt,
    };
  }

  function project(book) {
    if (blockedReason) return { ok: false, reason: blockedReason };
    const source = pendingMigration || state;
    if (!source) return { ok: false, reason: "official family history has no anchored state" };
    if (!connected || !historyReady) {
      return { ok: false, reason: lastUnavailable || "fresh complete official history unavailable" };
    }
    if (source.coverage.throughDay !== newYorkDay(now())) {
      return { ok: false, reason: "official execution history has not covered the current New York day" };
    }
    if (pendingMigration && (!legacy || !economicallyContains(pendingMigration, legacy))) {
      blockedReason = "v1/v2 migration does not preserve legacy economics";
      unavailable(blockedReason);
      return { ok: false, reason: blockedReason };
    }

    let args;
    let result;
    try {
      args = calculatorArgs(source, book);
      result = calculateFamily(args);
    } catch (error) {
      return { ok: false, reason: error.message };
    }
    const invalid = validFamilyResult(result);
    if (invalid) return { ok: false, reason: invalid };
    const normalized = { ...clone(result), observedAt: iso(result.observedAt) };

    if (pendingMigration) {
      if (sameEconomicIds(pendingMigration, legacy)) {
        let legacyResult;
        try {
          const legacyLedger = calculatorLedger(legacy);
          legacyResult = calculateFamily({
            ...args,
            ...legacyLedger,
          });
        } catch (error) {
          return { ok: false, reason: `v1 migration comparison failed: ${error.message}` };
        }
        if (validFamilyResult(legacyResult) || !same(legacyResult, result)) {
          blockedReason = "v1/v2 migration changed calculated family economics";
          unavailable(blockedReason);
          return { ok: false, reason: blockedReason };
        }
      }
      const migrated = { ...pendingMigration, family: normalized };
      try {
        store.save(migrated);
        const reloaded = store.load({ account: targetAccount, periodStart, classifier });
        if (!reloaded.ok || !reloaded.state) {
          throw new Error(reloaded.reason || "v2 state did not reload");
        }
        state = clone(reloaded.state);
        pendingMigration = null;
        legacy = null;
      } catch (error) {
        blockedReason = `v1/v2 migration activation failed: ${error.message}`;
        unavailable(blockedReason);
        return { ok: false, reason: blockedReason };
      }
      return clone(normalized);
    }

    if (state.family?.observedAt === normalized.observedAt) {
      if (!same(state.family, normalized)) {
        return { ok: false, reason: "family economics changed at an identical source revision" };
      }
      return clone(state.family);
    }
    if (state.family?.observedAt && normalized.observedAt < iso(state.family.observedAt)) {
      return { ok: false, reason: "family source observations regressed behind persisted state" };
    }
    if (!persist({ ...state, family: normalized })) {
      return { ok: false, reason: blockedReason };
    }
    return clone(normalized);
  }

  function retire(reason = "family adapter retired") {
    generation += 1;
    cleanupListeners();
    clearPoll();
    connected = false;
    managed = false;
    historyReady = false;
    inFlight = false;
    activeApi = null;
    history.stop?.(reason);
    unavailable(reason);
  }

  return {
    attach,
    retire,
    pollNow,
    project,
    get connected() { return connected; },
    get managed() { return managed; },
    get requestInFlight() { return inFlight; },
    get blockedReason() { return blockedReason; },
    inspectState() {
      return {
        state: clone(state),
        legacy: clone(legacy),
        pendingMigration: clone(pendingMigration),
        historyReady,
        lastUnavailable,
      };
    },
  };
}

export const FAMILY_STATE_SCHEMA = STATE_SCHEMA;
export const FAMILY_LEGACY_STATE_SCHEMA = LEGACY_SCHEMA;
export const FAMILY_BASELINE_PERIOD_START = BASELINE_PERIOD_START;
