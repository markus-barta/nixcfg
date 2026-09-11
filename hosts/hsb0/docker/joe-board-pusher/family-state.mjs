import fs from "node:fs";
import path from "node:path";
import { createReconnectScheduler } from "./pusher-recovery.mjs";
import { validateBestAvailableHistoryState } from "./execution-reconciliation.mjs";
import { normalizeEconomicCommission, normalizeEconomicExecution } from "./execution-history.mjs";

const STATE_SCHEMA = "inspr.joe.family-execution-ledger.v1";
const MAX_STATE_BYTES = 16 * 1024 * 1024;
const MAX_RECORDS = 50_000;
const BASELINE_PERIOD_START = "2026-09-10T04:00:00Z";
const BASELINE_NEW_YORK_DAY = "2026-09-10";

function iso(value) {
  const date = new Date(value || "");
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

function finitePositive(value) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : null;
}

function stable(value) {
  if (Array.isArray(value)) {
    return `[${Array.from(value, (item) => stable(item) ?? "null").join(",")}]`;
  }
  if (value && typeof value === "object") {
    const fields = [];
    for (const key of Object.keys(value).sort()) {
      const encoded = stable(value[key]);
      // JSON persistence omits undefined/function/symbol-valued object keys.
      if (encoded !== undefined) fields.push(`${JSON.stringify(key)}:${encoded}`);
    }
    return `{${fields.join(",")}}`;
  }
  return JSON.stringify(value);
}

function sameRecord(left, right) {
  return stable(left) === stable(right);
}

function executionId(row) {
  const value = row?.execution?.execId;
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function commissionId(row) {
  const value = row?.execId;
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function assertFiniteJsonNumbers(value, label, seen = new Set()) {
  if (typeof value === "number") {
    if (!Number.isFinite(value) || Math.abs(value) === Number.MAX_VALUE) {
      throw new Error(`${label} contains a non-finite broker number`);
    }
    return;
  }
  if (!value || typeof value !== "object") return;
  if (seen.has(value)) throw new Error(`${label} contains a circular value`);
  seen.add(value);
  for (const child of Object.values(value)) assertFiniteJsonNumbers(child, label, seen);
  seen.delete(value);
}

function validateReplayRecord(row, label) {
  assertFiniteJsonNumbers(row, label);
  if (label === "execution") {
    if (!row?.contract || typeof row.contract !== "object" || !row.execution || typeof row.execution !== "object") {
      throw new Error("execution is malformed");
    }
    if (!Number.isInteger(row.execution.clientId) ||
        !Number.isFinite(row.execution.shares) || !Number.isFinite(row.execution.price)) {
      throw new Error("execution has invalid numeric fields");
    }
  } else if (label === "commission" && !Number.isFinite(row?.commission)) {
    throw new Error("commission has invalid numeric fields");
  }
}

function correctionIdentity(rowOrId) {
  const id = typeof rowOrId === "string" ? rowOrId : executionId(rowOrId);
  const match = id?.match(/^(.*\.)(\d+)$/);
  if (!match || match[1] === ".") throw new Error(`execution ${id || "ID"} has no correction segment`);
  return { id, prefix: match[1], revision: BigInt(match[2]) };
}

function latestExecutionIdentities(rows) {
  const latest = new Map();
  for (const row of rows) {
    const identity = correctionIdentity(row);
    const prior = latest.get(identity.prefix);
    if (!prior || identity.revision > prior.revision) latest.set(identity.prefix, identity);
  }
  return [...latest.values()]
    .sort((left, right) => left.id.localeCompare(right.id))
    .map(({ id }) => id);
}

function missingPriorQueryIdentities(priorIds, currentIds) {
  const current = new Map(currentIds.map((id) => {
    const identity = correctionIdentity(id);
    return [identity.prefix, identity];
  }));
  return priorIds.filter((id) => {
    const prior = correctionIdentity(id);
    const next = current.get(prior.prefix);
    return !next || next.revision < prior.revision;
  });
}

function mergeExact(existing, incoming, identify, label) {
  for (const row of [...existing, ...incoming]) validateReplayRecord(row, label);
  const merged = [...existing];
  const byId = new Map(existing.map((row, index) => [identify(row), { row, index }]));
  let changed = false;
  for (const row of incoming) {
    const id = identify(row);
    if (!id) throw new Error(`${label} is missing execId`);
    const prior = byId.get(id);
    if (prior) {
      if (!sameRecord(prior.row, row)) throw new Error(`conflicting replay for ${label} ${id}`);
      continue;
    }
    byId.set(id, { row, index: merged.length });
    merged.push(row);
    changed = true;
  }
  return { rows: merged, changed };
}

function mergeHistoryExecutions(existing, incoming) {
  const merged = [...existing];
  const byId = new Map(existing.map((row) => [executionId(row), row]));
  let changed = false;
  for (const row of incoming) {
    const id = executionId(row);
    const prior = byId.get(id);
    if (prior) {
      if (!sameRecord(normalizeEconomicExecution(prior), normalizeEconomicExecution(row))) {
        throw new Error(`conflicting official history execution ${id}`);
      }
      continue;
    }
    const normalized = normalizeEconomicExecution(row);
    merged.push(normalized);
    byId.set(id, normalized);
    changed = true;
  }
  return { rows: merged, changed };
}

function mergeHistoryCommissions(existing, incoming) {
  const merged = [...existing];
  const byId = new Map(existing.map((row, index) => [commissionId(row), { row, index }]));
  let changed = false;
  for (const row of incoming) {
    const normalized = normalizeEconomicCommission(row);
    const id = commissionId(normalized);
    const prior = byId.get(id);
    if (!prior) {
      byId.set(id, { row: normalized, index: merged.length });
      merged.push(normalized);
      changed = true;
      continue;
    }
    const priorNormalized = normalizeEconomicCommission(prior.row);
    if (priorNormalized.commission !== normalized.commission || priorNormalized.currency !== normalized.currency ||
        (priorNormalized.realizedPNL !== null && priorNormalized.realizedPNL !== undefined &&
         normalized.realizedPNL !== null && normalized.realizedPNL !== undefined &&
         priorNormalized.realizedPNL !== normalized.realizedPNL)) {
      throw new Error(`conflicting official history commission ${id}`);
    }
    if ((priorNormalized.realizedPNL === null || priorNormalized.realizedPNL === undefined) &&
        normalized.realizedPNL !== null && normalized.realizedPNL !== undefined) {
      merged[prior.index] = normalized;
      byId.set(id, { row: normalized, index: prior.index });
      changed = true;
    }
  }
  return { rows: merged, changed };
}

function clone(value) {
  return structuredClone(value);
}

function normalizedClassifier(familyClientIds, excludedSymbols) {
  const ids = [...familyClientIds].map(Number);
  if (!ids.length || ids.some((value) => !Number.isInteger(value) || value < 0)) {
    throw new TypeError("family classifier has invalid client IDs");
  }
  const symbols = [...excludedSymbols].map((value) => String(value).trim().toUpperCase());
  if (symbols.some((value) => !value)) throw new TypeError("family classifier has invalid excluded symbols");
  return {
    familyClientIds: [...new Set(ids)].sort((left, right) => left - right),
    excludedSymbols: [...new Set(symbols)].sort(),
  };
}

function validState(value, account, periodStart, classifier) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return "state is not an object";
  if (value.schema !== STATE_SCHEMA || value.version !== 1) return "unsupported state schema";
  if (typeof value.account !== "string" || !value.account.trim()) return "state account is invalid";
  if (!iso(value.periodStart) || !iso(value.initializedAt)) return "state baseline metadata is invalid";
  if (value.account !== account) return "state account does not match configured account";
  if (value.periodStart !== periodStart) return "state periodStart does not match configured baseline";
  let persistedClassifier;
  try {
    persistedClassifier = normalizedClassifier(
      value.classifier?.familyClientIds || [],
      value.classifier?.excludedSymbols || []
    );
  } catch {
    return "state classifier is invalid";
  }
  if (!sameRecord(value.classifier, persistedClassifier)) return "state classifier is not canonical";
  if (!sameRecord(persistedClassifier, classifier)) return "state classifier does not match configured family";
  if (!Array.isArray(value.executions) || value.executions.length > MAX_RECORDS) return "invalid execution ledger";
  if (!Array.isArray(value.commissions) || value.commissions.length > MAX_RECORDS) return "invalid commission ledger";
  if (!Array.isArray(value.queryExecutionIdentities) || value.queryExecutionIdentities.length > MAX_RECORDS) {
    return "invalid execution query coverage";
  }
  if (!iso(value.ledgerObservedAt)) return "invalid ledger observation time";
  if (!iso(value.coverageThrough) || newYorkDay(value.coverageThrough) !== value.coverageTradingDay) {
    return "invalid execution coverage metadata";
  }
  if (value.requiresVerifiedHistory !== undefined && value.requiresVerifiedHistory !== true) {
    return "invalid verified-history requirement";
  }
  if (value.unverifiedSince !== undefined && !iso(value.unverifiedSince)) return "invalid unverified coverage boundary";
  const seenExecutions = new Map();
  for (const row of value.executions) {
    const id = executionId(row);
    if (!row?.contract || typeof row.contract !== "object" || !row.execution || typeof row.execution !== "object" || !id) {
      return "execution ledger row is malformed";
    }
    if (row.execution.acctNumber !== value.account) return "execution ledger account mismatch";
    try { validateReplayRecord(row, "execution"); } catch (error) { return error.message; }
    if (seenExecutions.has(id) && !sameRecord(seenExecutions.get(id), row)) return `conflicting persisted execution ${id}`;
    seenExecutions.set(id, row);
  }
  const seenCommissions = new Map();
  for (const row of value.commissions) {
    const id = commissionId(row);
    if (!id) return "commission ledger row is missing execId";
    try { validateReplayRecord(row, "commission"); } catch (error) { return error.message; }
    if (seenCommissions.has(id) && !sameRecord(seenCommissions.get(id), row)) return `conflicting persisted commission ${id}`;
    seenCommissions.set(id, row);
  }
  try {
    const canonicalQuery = latestExecutionIdentities(value.queryExecutionIdentities);
    if (!sameRecord(value.queryExecutionIdentities, canonicalQuery)) {
      return "execution query coverage is not canonical";
    }
    const ledgerIdentities = latestExecutionIdentities(value.executions);
    if (missingPriorQueryIdentities(canonicalQuery, ledgerIdentities).length) {
      return "execution query coverage is absent from persisted ledger";
    }
  } catch (error) {
    return error.message;
  }
  if (value.family !== null && value.family !== undefined) {
    const invalid = validateFamilyResult(value.family);
    if (invalid || value.family.positions.length > MAX_RECORDS) return "invalid persisted family projection";
  }
  return null;
}

export function createFileFamilyStateStore(filePath, fsImpl = fs) {
  if (typeof filePath !== "string" || !path.isAbsolute(filePath)) {
    throw new TypeError("family state path must be absolute");
  }
  return {
    load({ account, periodStart, classifier }) {
      let source;
      let handle;
      try {
        handle = fsImpl.openSync(filePath, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
        const stat = fsImpl.fstatSync(handle);
        if (!stat.isFile() || stat.size <= 0 || stat.size > MAX_STATE_BYTES) {
          return { ok: false, reason: "family ledger state has an invalid size" };
        }
        // Read the same opened inode we validated; a pathname replacement must
        // not change the ledger selected by this load. Bound concurrent growth.
        const bytes = Buffer.alloc(stat.size + 1);
        let count = 0;
        while (count < bytes.length) {
          const read = fsImpl.readSync(handle, bytes, count, bytes.length - count, null);
          if (read === 0) break;
          count += read;
        }
        if (count !== stat.size) return { ok: false, reason: "family ledger state changed size during read" };
        source = bytes.subarray(0, count).toString("utf8");
      } catch (error) {
        if (error?.code === "ENOENT") return { ok: true, state: null };
        return { ok: false, reason: `family ledger state read failed: ${error?.code || error}` };
      } finally {
        if (handle !== undefined) fsImpl.closeSync(handle);
      }
      try {
        const state = JSON.parse(source);
        const reason = validState(state, account, periodStart, classifier);
        return reason ? { ok: false, reason } : { ok: true, state };
      } catch {
        return { ok: false, reason: "family ledger state is corrupt JSON" };
      }
    },

    save(state) {
      const reason = validState(state, state?.account, state?.periodStart, state?.classifier);
      if (reason) throw new Error(reason);
      const body = `${JSON.stringify(state, null, 2)}\n`;
      if (Buffer.byteLength(body) > MAX_STATE_BYTES) throw new Error("family ledger state exceeds size limit");
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
    },
  };
}

function newYorkDay(value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return null;
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/New_York",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);
  const fields = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${fields.year}-${fields.month}-${fields.day}`;
}

function nyDateForIso(value) {
  const day = newYorkDay(value);
  return day ? day.replaceAll("-", "") : null;
}

function newYorkDayStart(value) {
  const day = newYorkDay(value);
  if (!day) return null;
  const expected = [...day.split("-").map(Number), 0, 0, 0];
  const naive = Date.UTC(expected[0], expected[1] - 1, expected[2]);
  const formatter = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/New_York",
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
  });
  const matches = [];
  for (let offset = -14 * 60; offset <= 14 * 60; offset += 15) {
    const candidate = naive - offset * 60_000;
    const actual = {};
    for (const part of formatter.formatToParts(new Date(candidate))) {
      if (part.type !== "literal") actual[part.type] = Number(part.value);
    }
    if ([actual.year, actual.month, actual.day, actual.hour, actual.minute, actual.second]
      .every((part, index) => part === expected[index])) matches.push(candidate);
  }
  return matches.length === 1 ? new Date(matches[0]).toISOString() : null;
}

function contractIdentity(contract) {
  const conId = Number(contract?.conId);
  if (Number.isInteger(conId) && conId > 0) return `conId:${conId}`;
  const symbol = typeof contract?.symbol === "string" ? contract.symbol.trim().toUpperCase() : "";
  const secType = typeof contract?.secType === "string" ? contract.secType.trim().toUpperCase() : "";
  const currency = typeof contract?.currency === "string" ? contract.currency.trim().toUpperCase() : "";
  return symbol && secType && currency ? `${symbol}:${secType}:${currency}` : null;
}

function maxIso(values) {
  let latest = null;
  for (const value of values) {
    const normalized = iso(value);
    if (normalized && (!latest || normalized > latest)) latest = normalized;
  }
  return latest;
}

function baseCurrencyProven(book, targetAccount) {
  const nlv = book?.summary?.NetLiquidation;
  return nlv?.account === targetAccount && String(nlv.currency || "").toUpperCase() === "EUR";
}

function validateFamilyResult(result) {
  if (!result || result.ok !== true || !iso(result.observedAt)) return "calculator did not return a complete family result";
  for (const field of ["equity", "totalPnl", "realizedPnl", "unrealizedPnl"]) {
    if (!Number.isFinite(result[field])) return `calculator returned invalid ${field}`;
  }
  if (!Array.isArray(result.positions)) return "calculator returned invalid positions";
  return null;
}

/**
 * Generation-scoped, read-only execution/commission/FX collector.
 * It owns no network connection and publishes nothing; the existing pusher remains
 * the sole inbox writer.
 */
export function createFamilySessionAdapter({
  targetAccount,
  familyClientIds,
  excludedSymbols = ["SXR8", "TSLA"],
  periodStart = BASELINE_PERIOD_START,
  calculateFamily,
  eventNames,
  store,
  executionRequestIdStart = 9600,
  accountUpdateRequestIdStart = 9701,
  pollIntervalMs = 30_000,
  requestTimeoutMs = 20_000,
  retryBaseMs = 5_000,
  retryMaxMs = 60_000,
  retryJitterRatio = 0.2,
  fxFreshMs = 300_000,
  fxRefreshIntervalMs = 240_000,
  now = () => new Date().toISOString(),
  random = Math.random,
  setTimer = setTimeout,
  clearTimer = clearTimeout,
  requestManagedAccounts = true,
  hooks = {},
  getVerifiedHistoryState = null,
}) {
  if (!targetAccount || typeof calculateFamily !== "function" || !eventNames || !store) {
    throw new TypeError("targetAccount, calculateFamily, eventNames and store are required");
  }
  const classifier = normalizedClassifier(familyClientIds, excludedSymbols);
  const familyIds = new Set(classifier.familyClientIds);
  const excluded = new Set(classifier.excludedSymbols);
  let activeApi = null;
  let generation = 0;
  let registrations = [];
  let connected = false;
  let managed = false;
  let executionReady = false;
  let activeCycle = null;
  let nextRequestId = executionRequestIdStart;
  let nextAccountUpdateRequestId = accountUpdateRequestIdStart;
  let activeAccountUpdateRequestId = null;
  let pollTimer = null;
  let timeoutTimer = null;
  let fxRefreshTimer = null;
  let blockedReason = null;
  let retryReason = null;
  let state = null;
  let fxRates = new Map();
  let commissionBuffer = new Map();

  const loaded = store.load({ account: targetAccount, periodStart, classifier });
  if (!loaded.ok) blockedReason = loaded.reason;
  else state = loaded.state ? clone(loaded.state) : null;

  function trustedOfficialReceipt(receipt) {
    return receipt.coverageStatus === "complete" &&
      receipt.completenessAssertion?.provider === "ibkr-official-sdk-execution-window-v1" &&
      receipt.source?.kind === "paper-api" &&
      receipt.source?.metadata?.adapterId === "official-window-json" &&
      receipt.source?.metadata?.adapterVersion === "1" &&
      receipt.source?.metadata?.sdkPackage === "ibapi" &&
      receipt.source?.metadata?.sdkVersion === "10.45.1" &&
      Number.isSafeInteger(receipt.source?.metadata?.serverVersion) &&
      receipt.source.metadata.serverVersion >= 223 &&
      receipt.source?.metadata?.executionRequestFraming === "protobuf" &&
      receipt.source?.metadata?.parameterizedExecutionFilters === true &&
      receipt.source?.metadata?.responseEndedCleanly === true &&
      receipt.source?.metadata?.completenessClaimed === true &&
      receipt.executionCount === receipt.commissionCount &&
      Array.isArray(receipt.executionIds) && Array.isArray(receipt.commissionIds);
  }

  function verifiedContinuity() {
    if (!state?.requiresVerifiedHistory) return { reason: null, history: null, receipts: [] };
    if (typeof getVerifiedHistoryState !== "function") {
      return { reason: "authoritative execution coverage across midnight is unavailable", history: null, receipts: [] };
    }
    let history;
    try {
      history = getVerifiedHistoryState();
      validateBestAvailableHistoryState(history);
    } catch (error) {
      return { reason: `authoritative history is invalid: ${error?.message || error}`, history: null, receipts: [] };
    }
    if (history.account !== targetAccount || !sameRecord(history.classifier, classifier)) {
      return { reason: "authoritative history account or classifier does not match", history, receipts: [] };
    }
    const requiredThrough = newYorkDayStart(state.coverageThrough);
    let cursor = iso(periodStart);
    const receipts = history.receipts.filter(trustedOfficialReceipt);
    const intervals = receipts
      .map((receipt) => receipt.window)
      .sort((left, right) => left.fromInclusive.localeCompare(right.fromInclusive));
    for (const interval of intervals) {
      if (interval.fromInclusive > cursor) break;
      if (interval.toExclusive > cursor) cursor = interval.toExclusive;
    }
    if (!requiredThrough || cursor < requiredThrough) {
      return { reason: "authoritative execution coverage across midnight is incomplete", history, receipts };
    }
    const historyExecutionIds = new Set(history.executions.map((row) => executionId(row)));
    const currentDay = state.coverageTradingDay.replaceAll("-", "");
    const missingRetainedIdentity = state.executions.some((row) => {
      const time = String(row?.execution?.time || "");
      const date = /^\d{8}/.test(time) ? time.slice(0, 8) : nyDateForIso(time);
      return date && date < currentDay && !historyExecutionIds.has(executionId(row));
    });
    return {
      reason: missingRetainedIdentity ? "authoritative history omits a retained execution identity" : null,
      history,
      receipts,
    };
  }

  function mergeVerifiedHistory({ history, receipts }) {
    if (!history || !receipts.length) return null;
    const executionById = new Map(history.executions.map((row) => [executionId(row), row]));
    const commissionById = new Map(history.commissions.map((row) => [commissionId(row), row]));
    const executionIds = new Set(receipts.flatMap((receipt) => receipt.executionIds));
    const commissionIds = new Set(receipts.flatMap((receipt) => receipt.commissionIds));
    const executions = [...executionIds].sort().map((id) => executionById.get(id));
    const commissions = [...commissionIds].sort().map((id) => commissionById.get(id));
    if (executions.some((row) => !row) || commissions.some((row) => !row)) {
      throw new Error("official history receipt identities are absent from the durable sidecar");
    }
    const executionMerge = mergeHistoryExecutions(state.executions, executions);
    const commissionMerge = mergeHistoryCommissions(state.commissions, commissions);
    if (!executionMerge.changed && !commissionMerge.changed) return null;
    return {
      ...state,
      ledgerObservedAt: maxIso([state.ledgerObservedAt, history.updatedAt]),
      executions: executionMerge.rows,
      commissions: commissionMerge.rows,
    };
  }

  const retryScheduler = createReconnectScheduler({
    baseDelayMs: retryBaseMs,
    maxDelayMs: retryMaxMs,
    jitterRatio: retryJitterRatio,
    random,
    setTimer,
    clearTimer,
    onRetry: () => pollNow(),
  });

  function emitAvailability(reason) {
    hooks.onUnavailable?.(reason);
  }

  function stopTimer(which) {
    if (which === "poll" && pollTimer !== null) {
      clearTimer(pollTimer);
      pollTimer = null;
    }
    if (which === "timeout" && timeoutTimer !== null) {
      clearTimer(timeoutTimer);
      timeoutTimer = null;
    }
    if (which === "fx" && fxRefreshTimer !== null) {
      clearTimer(fxRefreshTimer);
      fxRefreshTimer = null;
    }
  }

  function cleanupListeners() {
    for (const { api, name, handler } of registrations) api.off?.(name, handler);
    registrations = [];
  }

  function schedulePoll(delay = pollIntervalMs) {
    stopTimer("poll");
    if (!connected || !managed || blockedReason || retryReason) return;
    pollTimer = setTimer(() => {
      pollTimer = null;
      pollNow();
    }, delay);
  }

  function scheduleRetry() {
    stopTimer("poll");
    if (!connected || !managed || blockedReason || !retryReason) return false;
    return retryScheduler.schedule(retryReason);
  }

  function scheduleFxRefresh() {
    stopTimer("fx");
    if (!connected || !managed || blockedReason) return;
    fxRefreshTimer = setTimer(() => {
      fxRefreshTimer = null;
      refreshFx();
    }, fxRefreshIntervalMs);
  }

  function refreshFx() {
    if (!connected || !managed || blockedReason) return false;
    if (activeAccountUpdateRequestId !== null) {
      try { activeApi.cancelAccountUpdatesMulti(activeAccountUpdateRequestId); } catch {}
    }
    const requestId = nextAccountUpdateRequestId;
    nextAccountUpdateRequestId += 2;
    activeAccountUpdateRequestId = requestId;
    try {
      activeApi.reqAccountUpdatesMulti(requestId, targetAccount, "", true);
    } catch (error) {
      activeAccountUpdateRequestId = null;
      emitAvailability(`FX refresh request failed: ${error?.message || error}`);
      scheduleFxRefresh();
      return false;
    }
    scheduleFxRefresh();
    return true;
  }

  function persist(next) {
    try {
      store.save(next);
      state = clone(next);
      return true;
    } catch (error) {
      blockedReason = `family ledger state write failed: ${error?.message || error}`;
      retryReason = null;
      retryScheduler.cancel();
      emitAvailability(blockedReason);
      return false;
    }
  }

  function bootstrapAllowed(at) {
    return periodStart === BASELINE_PERIOD_START && newYorkDay(at) === BASELINE_NEW_YORK_DAY;
  }

  function isFamilyExecution(row) {
    const symbol = String(row?.contract?.symbol || "").trim().toUpperCase();
    return familyIds.has(Number(row?.execution?.clientId)) && !excluded.has(symbol);
  }

  function missingFamilyCommissions(cycle) {
    return cycle.executions
      .filter(isFamilyExecution)
      .map(executionId)
      .filter((id) => id && !commissionBuffer.has(id));
  }

  function finishCycle() {
    if (!activeCycle?.ended || missingFamilyCommissions(activeCycle).length) return false;
    stopTimer("timeout");
    const cycle = activeCycle;
    activeCycle = null;
    const observedAt = iso(now());
    if (!observedAt) {
      terminalCycle("invalid execution observation time");
      return false;
    }
    const coverageTradingDay = newYorkDay(observedAt);
    if (cycle.startedTradingDay !== coverageTradingDay) {
      terminalCycle("unproved execution retrieval gap across America/New_York midnight; backfill required");
      return false;
    }
    if (state && observedAt < state.coverageThrough) {
      terminalCycle("execution coverage timestamp regressed; backfill required");
      return false;
    }
    if (!state && !bootstrapAllowed(observedAt)) {
      terminalCycle("family ledger state is missing after the authorized baseline day; backfill required");
      return false;
    }
    try {
      const queryExecutionIdentities = latestExecutionIdentities(cycle.executions);
      const crossedTradingDay = Boolean(state && state.coverageTradingDay !== coverageTradingDay);
      if (state && !crossedTradingDay) {
        const missing = missingPriorQueryIdentities(
          state.queryExecutionIdentities,
          queryExecutionIdentities
        );
        if (missing.length) {
          retryCycle(`execution replay temporarily omitted ${missing.length} previously covered identities`);
          return false;
        }
      }
      const prior = state || {
        schema: STATE_SCHEMA,
        version: 1,
        account: targetAccount,
        periodStart,
        classifier,
        initializedAt: observedAt,
        ledgerObservedAt: observedAt,
        coverageThrough: observedAt,
        coverageTradingDay,
        queryExecutionIdentities,
        executions: [],
        commissions: [],
        family: null,
      };
      const executionMerge = mergeExact(prior.executions, cycle.executions, executionId, "execution");
      const relevantIds = new Set(cycle.executions.map(executionId));
      const reports = [...commissionBuffer.values()].filter((report) => relevantIds.has(commissionId(report)));
      const commissionMerge = mergeExact(prior.commissions, reports, commissionId, "commission");
      const changed = !state || executionMerge.changed || commissionMerge.changed;
      const next = {
        ...prior,
        ledgerObservedAt: changed ? observedAt : prior.ledgerObservedAt,
        coverageThrough: observedAt,
        coverageTradingDay,
        queryExecutionIdentities,
        executions: executionMerge.rows,
        commissions: commissionMerge.rows,
        ...(prior.requiresVerifiedHistory === true || crossedTradingDay ? {
          requiresVerifiedHistory: true,
          unverifiedSince: prior.unverifiedSince || prior.coverageThrough,
        } : {}),
      };
      if (!persist(next)) return false;
      retryReason = null;
      retryScheduler.reset();
      executionReady = true;
      hooks.onLedgerUpdated?.({ changed, observedAt: next.ledgerObservedAt });
      schedulePoll();
      return true;
    } catch (error) {
      terminalCycle(`family execution replay rejected: ${error?.message || error}`);
      return false;
    }
  }

  function retryCycle(reason) {
    stopTimer("timeout");
    activeCycle = null;
    executionReady = false;
    retryReason = reason;
    emitAvailability(reason);
    scheduleRetry();
  }

  function terminalCycle(reason) {
    stopTimer("timeout");
    activeCycle = null;
    executionReady = false;
    retryReason = null;
    blockedReason = reason;
    retryScheduler.cancel();
    emitAvailability(reason);
  }

  function pollNow() {
    if (!connected || !managed || blockedReason || activeCycle || retryScheduler.pending) return false;
    const requestedAt = iso(now());
    const startedTradingDay = requestedAt && newYorkDay(requestedAt);
    if (!requestedAt || !startedTradingDay) {
      terminalCycle("execution request time is unavailable");
      return false;
    }
    const requestId = nextRequestId;
    nextRequestId += 2;
    executionReady = false;
    activeCycle = { requestId, executions: [], ended: false, startedTradingDay };
    timeoutTimer = setTimer(() => {
      timeoutTimer = null;
      const suffix = activeCycle?.ended
        ? `; missing commissions for ${missingFamilyCommissions(activeCycle).length} family fills`
        : " before execDetailsEnd";
      retryCycle(`execution request timed out${suffix}`);
    }, requestTimeoutMs);
    try {
      activeApi.reqExecutions(requestId, { acctCode: targetAccount });
    } catch (error) {
      retryCycle(`execution request failed: ${error?.message || error}`);
      return false;
    }
    return true;
  }

  function attach(api) {
    try {
      if (activeApi && activeAccountUpdateRequestId !== null) {
        activeApi.cancelAccountUpdatesMulti?.(activeAccountUpdateRequestId);
      }
    } catch {}
    cleanupListeners();
    stopTimer("poll");
    stopTimer("timeout");
    stopTimer("fx");
    retryScheduler.cancel();
    generation += 1;
    const attachedGeneration = generation;
    activeApi = api;
    connected = false;
    managed = false;
    executionReady = false;
    activeCycle = null;
    activeAccountUpdateRequestId = null;
    fxRates = new Map();
    commissionBuffer = new Map();

    const on = (name, fn) => {
      const handler = (...args) => {
        if (activeApi === api && generation === attachedGeneration) fn(...args);
      };
      api.on(name, handler);
      registrations.push({ api, name, handler });
    };

    on(eventNames.connected, () => {
      connected = true;
      if (requestManagedAccounts) api.reqManagedAccts();
    });
    on(eventNames.managedAccounts, (accounts) => {
      if (!connected) return;
      if (!String(accounts || "").split(",").map((value) => value.trim()).includes(targetAccount)) {
        terminalCycle("configured family account is not managed by this session");
        return;
      }
      managed = true;
      const fxRequested = refreshFx();
      if (retryReason) scheduleRetry();
      else if (fxRequested) pollNow();
    });
    on(eventNames.accountUpdateMulti, (requestId, account, _model, key, value, currency) => {
      if (!connected) return;
      if (requestId !== activeAccountUpdateRequestId || account !== targetAccount || key !== "ExchangeRate") return;
      const code = String(currency || "").trim().toUpperCase();
      const rate = finitePositive(value);
      const observedAt = iso(now());
      if (!/^[A-Z]{3}$/.test(code) || rate === null || !observedAt) return;
      fxRates.set(code, { rate, observedAt });
    });
    on(eventNames.execDetails, (requestId, contract, execution) => {
      if (!connected) return;
      if (!activeCycle || requestId !== activeCycle.requestId || execution?.acctNumber !== targetAccount) return;
      try {
        const merged = mergeExact(activeCycle.executions, [{ contract, execution }], executionId, "execution");
        activeCycle.executions = merged.rows;
      } catch (error) {
        blockedReason = `family execution callback rejected: ${error?.message || error}`;
        terminalCycle(blockedReason);
      }
    });
    on(eventNames.execDetailsEnd, (requestId) => {
      if (!connected) return;
      if (!activeCycle || requestId !== activeCycle.requestId) return;
      activeCycle.ended = true;
      finishCycle();
    });
    on(eventNames.commissionReport, (report) => {
      if (!connected) return;
      const id = commissionId(report);
      if (!id) return;
      const prior = commissionBuffer.get(id);
      if (prior && !sameRecord(prior, report)) {
        blockedReason = `conflicting commission replay ${id}`;
        terminalCycle(blockedReason);
        return;
      }
      commissionBuffer.set(id, report);
      finishCycle();
    });
    on(eventNames.disconnected, () => {
      generation += 1;
      activeApi = null;
      connected = false;
      managed = false;
      executionReady = false;
      activeCycle = null;
      fxRates = new Map();
      stopTimer("poll");
      stopTimer("timeout");
      stopTimer("fx");
      retryScheduler.cancel();
      activeAccountUpdateRequestId = null;
      cleanupListeners();
      emitAvailability("broker disconnected; fresh executions and FX required");
    });
    return attachedGeneration;
  }

  function upstreamUnavailable(reason = "broker upstream unavailable; fresh executions and FX required") {
    if (!activeApi) return false;
    connected = false;
    managed = false;
    executionReady = false;
    activeCycle = null;
    fxRates = new Map();
    commissionBuffer = new Map();
    stopTimer("poll");
    stopTimer("timeout");
    stopTimer("fx");
    retryScheduler.cancel();
    try {
      if (activeAccountUpdateRequestId !== null) {
        activeApi.cancelAccountUpdatesMulti?.(activeAccountUpdateRequestId);
      }
    } catch {}
    activeAccountUpdateRequestId = null;
    emitAvailability(reason);
    return true;
  }

  function requiredCurrencies() {
    const currencies = new Set(["EUR"]);
    if (!state) return currencies;
    const familyExecutionIds = new Set();
    for (const row of state.executions) {
      if (!isFamilyExecution(row)) continue;
      familyExecutionIds.add(executionId(row));
      const code = String(row?.contract?.currency || "").trim().toUpperCase();
      if (/^[A-Z]{3}$/.test(code)) currencies.add(code);
    }
    for (const report of state.commissions) {
      if (!familyExecutionIds.has(commissionId(report))) continue;
      const code = String(report?.currency || "").trim().toUpperCase();
      if (/^[A-Z]{3}$/.test(code)) currencies.add(code);
    }
    return currencies;
  }

  function project(book) {
    if (blockedReason) return { ok: false, reason: blockedReason };
    if (retryReason) return { ok: false, reason: retryReason };
    if (!state) return { ok: false, reason: "family ledger has not completed its baseline execution cycle" };
    if (!connected || !executionReady) return { ok: false, reason: "fresh complete execution cycle unavailable" };
    if (state.coverageTradingDay !== newYorkDay(now())) {
      return { ok: false, reason: "fresh current-day execution cycle unavailable" };
    }
    const continuity = verifiedContinuity();
    if (!continuity.reason) {
      try {
        const next = mergeVerifiedHistory(continuity);
        if (next && !persist(next)) return { ok: false, reason: blockedReason };
      } catch (error) {
        blockedReason = `official family history merge failed: ${error?.message || error}`;
        retryReason = null;
        retryScheduler.cancel();
        emitAvailability(blockedReason);
        return { ok: false, reason: blockedReason };
      }
    }
    if (!baseCurrencyProven(book, targetAccount)) return { ok: false, reason: "target account base currency is not proven EUR" };
    if (book?.positionsCoverage?.status !== "complete") return { ok: false, reason: "current broker positions are incomplete" };

    const at = new Date(now()).getTime();
    if (!Number.isFinite(at)) return { ok: false, reason: "current time is unavailable for FX freshness" };
    const rates = {};
    const rateTimes = [];
    for (const currency of requiredCurrencies()) {
      const item = fxRates.get(currency);
      const age = item ? at - new Date(item.observedAt).getTime() : Number.POSITIVE_INFINITY;
      if (!item || !Number.isFinite(age) || age < 0 || age > fxFreshMs) {
        return { ok: false, reason: `fresh explicit ${currency}→EUR FX rate unavailable` };
      }
      rates[currency] = item.rate;
      rateTimes.push(item.observedAt);
    }

    const affected = new Set(state.executions.filter(isFamilyExecution).map((row) => contractIdentity(row.contract)).filter(Boolean));
    const marketTimes = (book.portfolio || [])
      .filter((row) => affected.has(contractIdentity(row.contract)))
      .flatMap((row) => [row.markObservedAt, row.observedAt]);
    const observedAt = maxIso([state.ledgerObservedAt, ...rateTimes, ...marketTimes]);
    if (!observedAt) return { ok: false, reason: "family economic observation timestamp unavailable" };
    if (state.family?.observedAt && observedAt < iso(state.family.observedAt)) {
      return { ok: false, reason: "family source observations regressed behind persisted state" };
    }

    let result;
    try {
      result = calculateFamily({
        executions: clone(state.executions),
        commissions: clone(state.commissions),
        portfolio: clone(book.portfolio || []),
        positions: clone(book.positionsCoverage.rows || []),
        fx: { baseCurrency: "EUR", rates, observedAt: maxIso(rateTimes) },
        account: targetAccount,
        familyClientIds: [...familyIds],
        excludedSymbols: [...excluded],
        periodStart,
        virtualEquity: 5000,
        observedAt,
      });
    } catch (error) {
      return { ok: false, reason: `family calculator failed: ${error?.message || error}` };
    }
    const invalid = validateFamilyResult(result);
    if (invalid) return { ok: false, reason: invalid };
    const normalized = { ...clone(result), observedAt: iso(result.observedAt) };
    const continuityReason = continuity.reason;
    if (continuityReason) {
      const history = continuity.history;
      const gaps = Array.isArray(history?.coverage?.gaps) && history.coverage.gaps.length
        ? clone(history.coverage.gaps)
        : [{
          fromInclusive: state.unverifiedSince || state.periodStart,
          toExclusive: newYorkDayStart(state.coverageThrough),
          reason: "no authoritative completeness receipt",
        }];
      return {
        ok: false,
        reason: continuityReason,
        partialAccounting: {
          status: "CAPTURED_ESTIMATE",
          currency: "EUR",
          equity: null,
          capturedTotalPnl: normalized.totalPnl,
          capturedRealizedPnl: normalized.realizedPnl,
          estimatedOpenPnl: normalized.unrealizedPnl,
          dayPnl: null,
          positions: normalized.positions.map((row) => ({ ...row, accountingScope: "captured-estimate" })),
          accounting: {
            ...normalized.accounting,
            completeness: "partial",
            fxBasis: "current-observed",
            detail: "Captured J-family FIFO, net of fees, with current marks and observed FX; historical coverage remains incomplete.",
          },
          coverage: { status: "partial", gaps },
          observedAt: normalized.observedAt,
          executionCount: normalized.executionCount,
        },
      };
    }
    if (state.family?.observedAt === normalized.observedAt) {
      if (!sameRecord(state.family, normalized)) return { ok: false, reason: "family replay changed at an identical source revision" };
      return clone(state.family);
    }
    if (!persist({ ...state, family: normalized })) return { ok: false, reason: blockedReason };
    return clone(normalized);
  }

  function retire(reason = "family session retired") {
    generation += 1;
    connected = false;
    managed = false;
    executionReady = false;
    activeCycle = null;
    fxRates = new Map();
    stopTimer("poll");
    stopTimer("timeout");
    stopTimer("fx");
    retryScheduler.cancel();
    try {
      if (activeAccountUpdateRequestId !== null) {
        activeApi?.cancelAccountUpdatesMulti?.(activeAccountUpdateRequestId);
      }
    } catch {}
    activeAccountUpdateRequestId = null;
    cleanupListeners();
    activeApi = null;
    emitAvailability(reason);
  }

  return {
    attach,
    retire,
    upstreamUnavailable,
    pollNow,
    project,
    get connected() { return connected; },
    get requestInFlight() { return Boolean(activeCycle); },
    get blockedReason() { return blockedReason; },
    get retryReason() { return retryReason; },
    inspectState() { return state ? clone(state) : null; },
  };
}

export const FAMILY_STATE_SCHEMA = STATE_SCHEMA;
export const FAMILY_BASELINE_PERIOD_START = BASELINE_PERIOD_START;
