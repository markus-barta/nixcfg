const WINDOW_SCHEMA = "inspr.retention-window.v1";
const EVIDENCE_SCHEMA = "inspr.retention-evidence-interval.v1";
const REPLAY_SCHEMA = "inspr.gateway-replay.v1";
const STATE_SCHEMA = "inspr.retention-readiness.v1";
const MAX_WINDOW_SCAN = 366;

export class RetentionContractError extends Error {
  constructor(message) {
    super(message);
    this.name = "RetentionContractError";
  }
}

function fail(message) {
  throw new RetentionContractError(message);
}

function deepFreeze(value) {
  if (value && typeof value === "object" && !Object.isFrozen(value)) {
    Object.freeze(value);
    for (const child of Object.values(value)) deepFreeze(child);
  }
  return value;
}

function requireRecord(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    fail(`${label} must be an object`);
  }
  return value;
}

function requireNonEmptyString(value, label) {
  if (typeof value !== "string" || value.trim() !== value || value.length === 0) {
    fail(`${label} must be a non-empty string`);
  }
  return value;
}

function parseInstant(value, label) {
  requireNonEmptyString(value, label);
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?(Z|([+-])(\d{2}):(\d{2}))$/.exec(value);
  if (!match) {
    fail(`${label} must be an ISO timestamp with an explicit offset`);
  }
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = Number(match[6]);
  const leapYear = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const daysInMonth = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (
    month < 1 || month > 12 ||
    day < 1 || day > daysInMonth[month - 1] ||
    hour > 23 || minute > 59 || second > 59
  ) fail(`${label} has an invalid calendar or clock component`);
  if (match[8] !== "Z") {
    const offsetHour = Number(match[10]);
    const offsetMinute = Number(match[11]);
    if (offsetHour > 14 || offsetMinute > 59 || (offsetHour === 14 && offsetMinute !== 0)) {
      fail(`${label} has an invalid UTC offset`);
    }
  }
  const epoch = Date.parse(value);
  if (!Number.isFinite(epoch)) fail(`${label} is invalid`);
  return epoch;
}

function canonicalTimeZone(value) {
  requireNonEmptyString(value, "timeZone");
  let formatter;
  try {
    formatter = new Intl.DateTimeFormat("en-US", { timeZone: value });
  } catch {
    fail("timeZone must be a valid explicit IANA time zone");
  }
  const canonical = formatter.resolvedOptions().timeZone;
  if (canonical !== value) {
    fail("timeZone must use its canonical IANA name");
  }
  return canonical;
}

const formatterCache = new Map();

function partsFormatter(timeZone) {
  let formatter = formatterCache.get(timeZone);
  if (!formatter) {
    formatter = new Intl.DateTimeFormat("en-CA", {
      timeZone,
      calendar: "iso8601",
      numberingSystem: "latn",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hourCycle: "h23",
    });
    formatterCache.set(timeZone, formatter);
  }
  return formatter;
}

function localParts(epoch, timeZone) {
  const values = {};
  for (const part of partsFormatter(timeZone).formatToParts(new Date(epoch))) {
    if (part.type !== "literal") values[part.type] = Number(part.value);
  }
  return {
    year: values.year,
    month: values.month,
    day: values.day,
    hour: values.hour,
    minute: values.minute,
    second: values.second,
  };
}

function localDateString(parts) {
  return `${String(parts.year).padStart(4, "0")}-${String(parts.month).padStart(2, "0")}-${String(parts.day).padStart(2, "0")}`;
}

function parseLocalDate(value) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) fail("local date is invalid");
  const parts = { year: Number(match[1]), month: Number(match[2]), day: Number(match[3]) };
  const check = new Date(Date.UTC(parts.year, parts.month - 1, parts.day));
  if (
    check.getUTCFullYear() !== parts.year ||
    check.getUTCMonth() + 1 !== parts.month ||
    check.getUTCDate() !== parts.day
  ) fail("local date is invalid");
  return parts;
}

function addLocalDays(localDate, days) {
  const parts = parseLocalDate(localDate);
  const date = new Date(Date.UTC(parts.year, parts.month - 1, parts.day + days));
  return localDateString({
    year: date.getUTCFullYear(),
    month: date.getUTCMonth() + 1,
    day: date.getUTCDate(),
  });
}

function localMidnightEpoch(localDate, timeZone) {
  const target = parseLocalDate(localDate);
  const naive = Date.UTC(target.year, target.month - 1, target.day);
  const offsets = new Set();

  // Sampling both sides of the target date discovers each offset involved in a
  // midnight transition without assuming that a civil day lasts 24 hours.
  for (let hours = -36; hours <= 36; hours += 6) {
    const probe = naive + hours * 60 * 60 * 1000;
    const local = localParts(probe, timeZone);
    const representedAsUtc = Date.UTC(
      local.year,
      local.month - 1,
      local.day,
      local.hour,
      local.minute,
      local.second,
    );
    offsets.add(representedAsUtc - probe);
  }

  const candidates = [];
  for (const offset of offsets) {
    const candidate = naive - offset;
    const local = localParts(candidate, timeZone);
    if (
      local.year === target.year &&
      local.month === target.month &&
      local.day === target.day &&
      local.hour === 0 &&
      local.minute === 0 &&
      local.second === 0
    ) candidates.push(candidate);
  }

  const unique = [...new Set(candidates)].sort((a, b) => a - b);
  if (unique.length !== 1) {
    fail(`local midnight ${localDate} is missing or ambiguous in ${timeZone}`);
  }
  return unique[0];
}

/**
 * Returns the explicit Gateway-calendar window containing `instant`.
 * Windows are UTC [begin, end) instants derived from local calendar midnights.
 */
export function retentionWindowAt({ instant, timeZone } = {}) {
  const epoch = parseInstant(instant, "instant");
  const zone = canonicalTimeZone(timeZone);
  const localDate = localDateString(localParts(epoch, zone));
  const beginEpoch = localMidnightEpoch(localDate, zone);
  const endEpoch = localMidnightEpoch(addLocalDays(localDate, 1), zone);
  if (!(beginEpoch <= epoch && epoch < endEpoch)) fail("instant is outside its derived retention window");
  return deepFreeze({
    schema: WINDOW_SCHEMA,
    timeZone: zone,
    localDate,
    begin: new Date(beginEpoch).toISOString(),
    end: new Date(endEpoch).toISOString(),
    durationMs: endEpoch - beginEpoch,
  });
}

function canonicalWindow(value, label = "window") {
  const supplied = requireRecord(value, label);
  if (supplied.schema !== WINDOW_SCHEMA) fail(`${label}.schema is invalid`);
  const derived = retentionWindowAt({ instant: supplied.begin, timeZone: supplied.timeZone });
  if (
    supplied.localDate !== derived.localDate ||
    supplied.begin !== derived.begin ||
    supplied.end !== derived.end ||
    supplied.durationMs !== derived.durationMs
  ) fail(`${label} is not a canonical retention window`);
  return derived;
}

/** Returns complete Gateway-calendar windows crossed after `observedThrough`. */
export function uncoveredRetentionWindows({ observedThrough, now, timeZone } = {}) {
  const observedEpoch = parseInstant(observedThrough, "observedThrough");
  const nowEpoch = parseInstant(now, "now");
  if (nowEpoch < observedEpoch) fail("now cannot precede observedThrough");
  const zone = canonicalTimeZone(timeZone);
  const windows = [];
  let window = retentionWindowAt({ instant: observedThrough, timeZone: zone });

  while (Date.parse(window.end) <= nowEpoch) {
    windows.push(window);
    if (windows.length > MAX_WINDOW_SCAN) fail("retention window scan exceeds its safety bound");
    window = retentionWindowAt({ instant: window.end, timeZone: zone });
  }
  return deepFreeze(windows);
}

function canonicalEvidenceInterval(value, providerId, timeZone) {
  const interval = requireRecord(value, "evidence interval");
  if (interval.schema !== EVIDENCE_SCHEMA) fail("evidence interval schema is invalid");
  if (interval.providerId !== providerId) fail("evidence interval provider does not match configured provider");
  if (interval.calendarTimeZone !== timeZone) fail("evidence interval calendar does not match Gateway calendar");
  requireNonEmptyString(interval.receiptId, "evidence interval receiptId");
  if (interval.finality !== "validated-final") fail("evidence interval is not validated FINAL evidence");
  if (interval.executionSetMatch !== "exact") fail("evidence interval lacks an exact execution-set match");
  if (typeof interval.conflict !== "boolean") fail("evidence interval conflict must be explicit");
  const beginEpoch = parseInstant(interval.begin, "evidence interval begin");
  const endEpoch = parseInstant(interval.end, "evidence interval end");
  if (endEpoch <= beginEpoch) fail("evidence interval must have positive duration");
  return {
    schema: EVIDENCE_SCHEMA,
    providerId,
    calendarTimeZone: timeZone,
    receiptId: interval.receiptId,
    finality: "validated-final",
    executionSetMatch: "exact",
    conflict: interval.conflict,
    begin: new Date(beginEpoch).toISOString(),
    end: new Date(endEpoch).toISOString(),
    beginEpoch,
    endEpoch,
  };
}

/**
 * Reduces already-validated receipt intervals. It does not parse a report or
 * establish finality, ownership, fees, or economics.
 */
export function reconcileWindowCoverage({ window, evidenceIntervals, providerId } = {}) {
  try {
    const target = canonicalWindow(window);
    const provider = requireNonEmptyString(providerId, "providerId");
    if (!Array.isArray(evidenceIntervals) || evidenceIntervals.length === 0) {
      fail("validated FINAL evidence intervals are required");
    }
    const intervals = evidenceIntervals.map((entry) => canonicalEvidenceInterval(entry, provider, target.timeZone));
    const targetBegin = Date.parse(target.begin);
    const targetEnd = Date.parse(target.end);
    const relevant = intervals.filter((entry) => entry.beginEpoch < targetEnd && entry.endEpoch > targetBegin);
    if (relevant.some((entry) => entry.conflict)) fail("a receipt conflicts with the reconciled execution set");

    const spans = relevant
      .map((entry) => ({ begin: Math.max(entry.beginEpoch, targetBegin), end: Math.min(entry.endEpoch, targetEnd) }))
      .sort((a, b) => a.begin - b.begin || a.end - b.end);
    let cursor = targetBegin;
    for (const span of spans) {
      if (span.begin > cursor) fail("validated FINAL evidence has a coverage gap");
      cursor = Math.max(cursor, span.end);
      if (cursor >= targetEnd) break;
    }
    if (cursor < targetEnd) fail("validated FINAL evidence does not cover the closed window");

    return deepFreeze({
      ok: true,
      complete: true,
      window: target,
      providerId: provider,
      receiptIds: [...new Set(relevant.map((entry) => entry.receiptId))].sort(),
    });
  } catch (error) {
    if (!(error instanceof RetentionContractError)) throw error;
    return deepFreeze({ ok: false, complete: false, reason: error.message });
  }
}

function blockedState({ prior, now, gatewayTimeZone, reason, reconciledWindows, unreconciledWindows, maxReplayAgeMs }) {
  return deepFreeze({
    schema: STATE_SCHEMA,
    status: "blocked",
    reason,
    providerId: typeof prior?.providerId === "string" ? prior.providerId : null,
    gatewayTimeZone: typeof gatewayTimeZone === "string" ? gatewayTimeZone : null,
    evaluatedAt: typeof now === "string" ? now : null,
    observedThrough: typeof prior?.observedThrough === "string" ? prior.observedThrough : null,
    maxReplayAgeMs,
    reconciledWindows: reconciledWindows ?? [],
    unreconciledWindows: unreconciledWindows ?? [],
  });
}

function canonicalPrior(prior, gatewayTimeZone) {
  const state = requireRecord(prior, "prior");
  if (state.schema !== STATE_SCHEMA) fail("prior schema is invalid");
  const providerId = requireNonEmptyString(state.providerId, "prior.providerId");
  const zone = canonicalTimeZone(gatewayTimeZone);
  if (state.gatewayTimeZone !== zone) fail("Gateway calendar changed without a new readiness baseline");
  const evaluatedAtEpoch = parseInstant(state.evaluatedAt, "prior.evaluatedAt");
  const observedEpoch = parseInstant(state.observedThrough, "prior.observedThrough");
  if (observedEpoch > evaluatedAtEpoch) fail("prior observedThrough cannot follow prior evaluatedAt");
  if (!Array.isArray(state.reconciledWindows)) fail("prior.reconciledWindows must be an array");
  const reconciledWindows = state.reconciledWindows.map((entry) => {
    const record = requireRecord(entry, "prior reconciled window");
    const window = canonicalWindow(record.window, "prior reconciled window.window");
    if (record.providerId !== providerId) fail("prior reconciled window provider is invalid");
    if (!Array.isArray(record.receiptIds) || record.receiptIds.some((id) => typeof id !== "string" || id.length === 0)) {
      fail("prior reconciled window receipt IDs are invalid");
    }
    return { ok: true, complete: true, window, providerId, receiptIds: [...new Set(record.receiptIds)].sort() };
  });
  if (!Array.isArray(state.unreconciledWindows)) fail("prior.unreconciledWindows must be an array");
  const unreconciledWindows = state.unreconciledWindows.map((window) => canonicalWindow(window, "prior unreconciled window"));
  return { providerId, zone, evaluatedAtEpoch, observedEpoch, reconciledWindows, unreconciledWindows };
}

function canonicalMaxReplayAge(value, currentWindow) {
  if (!Number.isSafeInteger(value) || value <= 0 || value > currentWindow.durationMs) {
    fail("maxReplayAgeMs must be a positive safe integer no greater than the current retention window");
  }
  return value;
}

function canonicalReplay(value, nowEpoch, currentWindow, priorObservedEpoch, maxReplayAgeMs) {
  const replay = requireRecord(value, "freshReplay");
  if (replay.schema !== REPLAY_SCHEMA) fail("freshReplay schema is invalid");
  if (replay.source !== "raw-socket-ledger") fail("freshReplay must come from the raw socket ledger");
  if (replay.calendarTimeZone !== currentWindow.timeZone) fail("freshReplay calendar is invalid");
  if (replay.windowBegin !== currentWindow.begin) fail("freshReplay does not cover the current retention window");
  if (replay.completeness !== "validated-current-window") fail("freshReplay completeness is not validated");
  if (replay.knownExecutionSet !== "retained") fail("freshReplay does not retain the known execution set");
  if (typeof replay.conflict !== "boolean" || replay.conflict) fail("freshReplay has an invalid or conflicting execution set");
  if (!Number.isSafeInteger(replay.executionCount) || replay.executionCount < 0) fail("freshReplay executionCount is invalid");
  const observedEpoch = parseInstant(replay.observedThrough, "freshReplay.observedThrough");
  const completedEpoch = parseInstant(replay.completedAt, "freshReplay.completedAt");
  if (observedEpoch < Date.parse(currentWindow.begin) || observedEpoch >= Date.parse(currentWindow.end)) {
    fail("freshReplay watermark is outside the current retention window");
  }
  if (observedEpoch < priorObservedEpoch) fail("freshReplay watermark moved backward");
  if (completedEpoch < observedEpoch || completedEpoch > nowEpoch) fail("freshReplay completion clock is invalid");
  if (nowEpoch - completedEpoch > maxReplayAgeMs) fail("freshReplay completion is older than maxReplayAgeMs");
  if (nowEpoch - observedEpoch > maxReplayAgeMs) fail("freshReplay watermark is older than maxReplayAgeMs");
  return observedEpoch;
}

function evidenceConflictsWithReconciled(evidenceIntervals, providerId, timeZone, reconciledWindows) {
  if (!Array.isArray(evidenceIntervals)) fail("finalEvidence must be an array of validated receipt intervals");
  const intervals = evidenceIntervals.map((entry) => canonicalEvidenceInterval(entry, providerId, timeZone));
  const conflicted = new Set();
  for (const interval of intervals) {
    if (!interval.conflict) continue;
    for (const record of reconciledWindows) {
      if (interval.beginEpoch < Date.parse(record.window.end) && interval.endEpoch > Date.parse(record.window.begin)) {
        conflicted.add(record.window.begin);
      }
    }
  }
  return conflicted;
}

/**
 * Pure readiness transition. `finalEvidence` must contain receipt intervals
 * validated elsewhere; `freshReplay` carries no independent economics.
 * The caller must choose `maxReplayAgeMs`; this reducer has no runtime TTL
 * default and only bounds that choice to the current calendar window.
 */
export function transitionRetentionReadiness({
  prior,
  now,
  gatewayTimeZone,
  finalEvidence,
  freshReplay,
  maxReplayAgeMs,
} = {}) {
  let retainedReconciliations = [];
  let unreconciledWindows = [];
  let replayAgeLimit = null;
  try {
    const canonical = canonicalPrior(prior, gatewayTimeZone);
    retainedReconciliations = canonical.reconciledWindows;
    unreconciledWindows = canonical.unreconciledWindows;
    const nowEpoch = parseInstant(now, "now");
    if (nowEpoch < canonical.evaluatedAtEpoch || nowEpoch < canonical.observedEpoch) {
      fail("readiness clock moved backward");
    }
    const currentWindow = retentionWindowAt({ instant: now, timeZone: canonical.zone });
    replayAgeLimit = canonicalMaxReplayAge(maxReplayAgeMs, currentWindow);

    const conflicted = evidenceConflictsWithReconciled(
      finalEvidence,
      canonical.providerId,
      canonical.zone,
      retainedReconciliations,
    );
    if (conflicted.size > 0) {
      const invalidated = retainedReconciliations
        .filter((entry) => conflicted.has(entry.window.begin))
        .map((entry) => entry.window);
      retainedReconciliations = retainedReconciliations.filter((entry) => !conflicted.has(entry.window.begin));
      const pendingByBegin = new Map(unreconciledWindows.map((window) => [window.begin, window]));
      for (const window of invalidated) pendingByBegin.set(window.begin, window);
      unreconciledWindows = [...pendingByBegin.values()].sort((a, b) => a.begin.localeCompare(b.begin));
      fail("a corrected receipt invalidated reconciled retention coverage");
    }

    const required = uncoveredRetentionWindows({
      observedThrough: prior.observedThrough,
      now,
      timeZone: canonical.zone,
    });
    const requiredByBegin = new Map(unreconciledWindows.map((window) => [window.begin, window]));
    for (const window of required) requiredByBegin.set(window.begin, window);
    unreconciledWindows = [...requiredByBegin.values()].sort((a, b) => a.begin.localeCompare(b.begin));
    const byBegin = new Map(retainedReconciliations.map((entry) => [entry.window.begin, entry]));
    for (const window of unreconciledWindows) {
      if (byBegin.has(window.begin)) continue;
      const reconciliation = reconcileWindowCoverage({
        window,
        evidenceIntervals: finalEvidence,
        providerId: canonical.providerId,
      });
      if (!reconciliation.ok) fail(reconciliation.reason);
      byBegin.set(window.begin, reconciliation);
    }

    const observedEpoch = canonicalReplay(
      freshReplay,
      nowEpoch,
      currentWindow,
      canonical.observedEpoch,
      replayAgeLimit,
    );
    return deepFreeze({
      schema: STATE_SCHEMA,
      status: "ready",
      reason: null,
      providerId: canonical.providerId,
      gatewayTimeZone: canonical.zone,
      evaluatedAt: new Date(nowEpoch).toISOString(),
      observedThrough: new Date(observedEpoch).toISOString(),
      maxReplayAgeMs: replayAgeLimit,
      reconciledWindows: [...byBegin.values()].sort((a, b) => a.window.begin.localeCompare(b.window.begin)),
      unreconciledWindows: [],
    });
  } catch (error) {
    if (!(error instanceof RetentionContractError)) throw error;
    return blockedState({
      prior,
      now,
      gatewayTimeZone,
      reason: error.message,
      reconciledWindows: retainedReconciliations,
      unreconciledWindows,
      maxReplayAgeMs: replayAgeLimit,
    });
  }
}

export const RETENTION_CONTRACT = deepFreeze({
  windowSchema: WINDOW_SCHEMA,
  evidenceSchema: EVIDENCE_SCHEMA,
  replaySchema: REPLAY_SCHEMA,
  stateSchema: STATE_SCHEMA,
});
