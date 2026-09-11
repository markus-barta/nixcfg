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

function terminalNeedsBaseline(reason) {
  return deepFreeze({
    schema: STATE_SCHEMA,
    status: "needs-baseline",
    baselineRequired: true,
    reason,
    providerId: null,
    gatewayTimeZone: null,
    evaluatedAt: null,
    observedThrough: null,
    maxReplayAgeMs: null,
    reconciledWindows: [],
    unreconciledWindows: [],
    unresolvedConflictWindows: [],
    invalidatedReceiptIdsByWindow: [],
  });
}

function uniqueReceiptIds(value, label) {
  if (!Array.isArray(value) || value.length === 0) fail(`${label} must be a non-empty array`);
  const ids = value.map((id) => requireNonEmptyString(id, `${label} entry`));
  if (new Set(ids).size !== ids.length) fail(`${label} must contain unique receipt IDs`);
  return ids.sort();
}

function canonicalPrior(prior) {
  const state = requireRecord(prior, "prior");
  if (state.schema !== STATE_SCHEMA) fail("prior schema is invalid");
  if (state.status === "needs-baseline" || state.baselineRequired === true) {
    fail("prior requires trusted baseline creation");
  }
  if (state.status !== "ready" && state.status !== "blocked") fail("prior status is invalid");
  if (state.baselineRequired !== undefined && state.baselineRequired !== false) {
    fail("prior baselineRequired flag is invalid");
  }
  const providerId = requireNonEmptyString(state.providerId, "prior.providerId");
  const zone = canonicalTimeZone(state.gatewayTimeZone);
  const evaluatedAtEpoch = parseInstant(state.evaluatedAt, "prior.evaluatedAt");
  const observedEpoch = parseInstant(state.observedThrough, "prior.observedThrough");
  if (observedEpoch > evaluatedAtEpoch) fail("prior observedThrough cannot follow prior evaluatedAt");
  const priorReplayAgeMs = state.maxReplayAgeMs ?? null;
  if (priorReplayAgeMs !== null && (!Number.isSafeInteger(priorReplayAgeMs) || priorReplayAgeMs <= 0)) {
    fail("prior maxReplayAgeMs is invalid");
  }
  if (!Array.isArray(state.reconciledWindows)) fail("prior.reconciledWindows must be an array");
  const reconciledBegins = new Set();
  const reconciledWindows = state.reconciledWindows.map((entry) => {
    const record = requireRecord(entry, "prior reconciled window");
    if (record.ok !== true || record.complete !== true) fail("prior reconciled window is not complete");
    const window = canonicalWindow(record.window, "prior reconciled window.window");
    if (window.timeZone !== zone) fail("prior reconciled window uses a different calendar");
    if (Date.parse(window.end) > evaluatedAtEpoch) fail("prior reconciled window is not closed at prior evaluatedAt");
    if (reconciledBegins.has(window.begin)) fail("prior reconciled windows must be unique");
    reconciledBegins.add(window.begin);
    if (record.providerId !== providerId) fail("prior reconciled window provider is invalid");
    const receiptIds = uniqueReceiptIds(record.receiptIds, "prior reconciled window receiptIds");
    return { ok: true, complete: true, window, providerId, receiptIds };
  });
  if (!Array.isArray(state.unreconciledWindows)) fail("prior.unreconciledWindows must be an array");
  const unreconciledBegins = new Set();
  const unreconciledWindows = state.unreconciledWindows.map((value) => {
    const window = canonicalWindow(value, "prior unreconciled window");
    if (window.timeZone !== zone) fail("prior unreconciled window uses a different calendar");
    if (Date.parse(window.end) > evaluatedAtEpoch) fail("prior unreconciled window is not closed at prior evaluatedAt");
    if (unreconciledBegins.has(window.begin)) fail("prior unreconciled windows must be unique");
    if (reconciledBegins.has(window.begin)) fail("prior reconciled and unreconciled windows must be disjoint");
    unreconciledBegins.add(window.begin);
    return window;
  });
  if (state.status === "ready" && unreconciledWindows.length > 0) {
    fail("ready prior cannot contain unreconciled windows");
  }
  const invalidatedReceiptRecords = state.invalidatedReceiptIdsByWindow ?? [];
  if (!Array.isArray(invalidatedReceiptRecords)) {
    fail("prior.invalidatedReceiptIdsByWindow must be an array");
  }
  const invalidatedBegins = new Set();
  const invalidatedReceiptIdsByWindow = invalidatedReceiptRecords.map((entry) => {
    const record = requireRecord(entry, "prior invalidated receipt record");
    const window = canonicalWindow(record.window, "prior invalidated receipt record.window");
    if (window.timeZone !== zone) fail("prior invalidated receipt record uses a different calendar");
    if (invalidatedBegins.has(window.begin)) fail("prior invalidated receipt window records must be unique");
    invalidatedBegins.add(window.begin);
    const receiptIds = uniqueReceiptIds(record.receiptIds, "prior invalidated receipt record receiptIds");
    const reconciled = reconciledWindows.find((candidate) => candidate.window.begin === window.begin);
    if (reconciled?.receiptIds.some((receiptId) => receiptIds.includes(receiptId))) {
      fail("prior reconciled window reuses an invalidated receipt ID");
    }
    return { window, receiptIds };
  });
  const unresolvedConflictRecords = state.unresolvedConflictWindows ?? [];
  if (!Array.isArray(unresolvedConflictRecords)) fail("prior.unresolvedConflictWindows must be an array");
  const unresolvedConflictBegins = new Set();
  const unresolvedConflictWindows = unresolvedConflictRecords.map((value) => {
    const window = canonicalWindow(value, "prior unresolved conflict window");
    if (window.timeZone !== zone) fail("prior unresolved conflict window uses a different calendar");
    if (unresolvedConflictBegins.has(window.begin)) fail("prior unresolved conflict windows must be unique");
    if (reconciledBegins.has(window.begin)) fail("prior reconciled and unresolved conflict windows must be disjoint");
    if (!invalidatedBegins.has(window.begin)) fail("prior unresolved conflict window lacks invalidated receipt IDs");
    unresolvedConflictBegins.add(window.begin);
    return window;
  });
  if (state.status === "ready" && unresolvedConflictWindows.length > 0) {
    fail("ready prior cannot contain unresolved conflict windows");
  }
  return {
    providerId,
    zone,
    evaluatedAtEpoch,
    observedEpoch,
    maxReplayAgeMs: priorReplayAgeMs,
    reconciledWindows,
    unreconciledWindows,
    unresolvedConflictWindows,
    invalidatedReceiptIdsByWindow,
  };
}

function blockedFromPrior({
  prior,
  reason,
  evaluatedAtEpoch,
  reconciledWindows,
  unreconciledWindows,
  unresolvedConflictWindows,
  invalidatedReceiptIdsByWindow,
  maxReplayAgeMs,
}) {
  return deepFreeze({
    schema: STATE_SCHEMA,
    status: "blocked",
    baselineRequired: false,
    reason,
    providerId: prior.providerId,
    gatewayTimeZone: prior.zone,
    evaluatedAt: new Date(evaluatedAtEpoch ?? prior.evaluatedAtEpoch).toISOString(),
    observedThrough: new Date(prior.observedEpoch).toISOString(),
    maxReplayAgeMs: maxReplayAgeMs ?? prior.maxReplayAgeMs,
    reconciledWindows: reconciledWindows ?? prior.reconciledWindows,
    unreconciledWindows: unreconciledWindows ?? prior.unreconciledWindows,
    unresolvedConflictWindows: unresolvedConflictWindows ?? prior.unresolvedConflictWindows,
    invalidatedReceiptIdsByWindow: invalidatedReceiptIdsByWindow ?? prior.invalidatedReceiptIdsByWindow,
  });
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

function canonicalFinalEvidence(evidenceIntervals, providerId, timeZone) {
  if (!Array.isArray(evidenceIntervals)) fail("finalEvidence must be an array of validated receipt intervals");
  return evidenceIntervals.map((entry) => canonicalEvidenceInterval(entry, providerId, timeZone));
}

function overlapsWindow(interval, window) {
  return interval.beginEpoch < Date.parse(window.end) && interval.endEpoch > Date.parse(window.begin);
}

function invalidatedReceiptMap(records) {
  return new Map(records.map((record) => [
    record.window.begin,
    { window: record.window, receiptIds: new Set(record.receiptIds) },
  ]));
}

function sortedInvalidatedRecords(records) {
  return [...records.values()]
    .map((record) => ({ window: record.window, receiptIds: [...record.receiptIds].sort() }))
    .sort((a, b) => a.window.begin.localeCompare(b.window.begin));
}

function addInvalidatedReceipts(records, window, receiptIds) {
  let record = records.get(window.begin);
  if (!record) {
    record = { window, receiptIds: new Set() };
    records.set(window.begin, record);
  }
  for (const receiptId of receiptIds) record.receiptIds.add(receiptId);
}

function conflictWindows(interval, priorWindowBegin, nowEpoch, timeZone, knownWindows) {
  const byBegin = new Map();
  for (const window of knownWindows) {
    if (overlapsWindow(interval, window)) byBegin.set(window.begin, window);
  }

  const rangeBegin = Math.max(interval.beginEpoch, priorWindowBegin);
  const rangeEnd = Math.min(interval.endEpoch, nowEpoch);
  if (rangeBegin < rangeEnd) {
    let window = retentionWindowAt({ instant: new Date(rangeBegin).toISOString(), timeZone });
    for (let count = 0; Date.parse(window.begin) < rangeEnd; count += 1) {
      if (count >= MAX_WINDOW_SCAN) fail("conflicting evidence window scan exceeds its safety bound");
      byBegin.set(window.begin, window);
      if (Date.parse(window.end) >= rangeEnd) break;
      window = retentionWindowAt({ instant: window.end, timeZone });
    }
  }
  return [...byBegin.values()];
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
  let canonical = null;
  let retainedReconciliations = [];
  let unreconciledWindows = [];
  let unresolvedConflictWindows = [];
  let invalidatedReceiptIdsByWindow = [];
  let replayAgeLimit = null;
  let acceptedNowEpoch = null;
  try {
    canonical = canonicalPrior(prior);
    retainedReconciliations = canonical.reconciledWindows;
    unreconciledWindows = canonical.unreconciledWindows;
    unresolvedConflictWindows = canonical.unresolvedConflictWindows;
    invalidatedReceiptIdsByWindow = canonical.invalidatedReceiptIdsByWindow;
    const nowEpoch = parseInstant(now, "now");
    if (nowEpoch < canonical.evaluatedAtEpoch || nowEpoch < canonical.observedEpoch) {
      fail("readiness clock moved backward");
    }
    const requestedZone = canonicalTimeZone(gatewayTimeZone);
    if (requestedZone !== canonical.zone) fail("Gateway calendar changed without a new trusted baseline");
    acceptedNowEpoch = nowEpoch;
    const currentWindow = retentionWindowAt({ instant: now, timeZone: canonical.zone });
    replayAgeLimit = canonicalMaxReplayAge(maxReplayAgeMs, currentWindow);

    const intervals = canonicalFinalEvidence(finalEvidence, canonical.providerId, canonical.zone);
    const invalidatedByBegin = invalidatedReceiptMap(invalidatedReceiptIdsByWindow);
    for (const interval of intervals) {
      for (const record of invalidatedByBegin.values()) {
        if (record.receiptIds.has(interval.receiptId) && overlapsWindow(interval, record.window)) {
          fail(`receipt ${interval.receiptId} was invalidated for this retention window`);
        }
      }
    }

    const conflictIntervals = intervals.filter((interval) => interval.conflict);
    if (conflictIntervals.length > 0) {
      const knownWindows = [
        ...retainedReconciliations.map((record) => record.window),
        ...unreconciledWindows,
        ...unresolvedConflictWindows,
      ];
      const priorWindowBegin = Date.parse(retentionWindowAt({
        instant: prior.observedThrough,
        timeZone: canonical.zone,
      }).begin);
      const affectedByBegin = new Map();
      for (const interval of conflictIntervals) {
        for (const window of conflictWindows(interval, priorWindowBegin, nowEpoch, canonical.zone, knownWindows)) {
          let affected = affectedByBegin.get(window.begin);
          if (!affected) {
            affected = { window, receiptIds: new Set() };
            affectedByBegin.set(window.begin, affected);
          }
          affected.receiptIds.add(interval.receiptId);
        }
      }
      if (affectedByBegin.size > 0) {
        const pendingByBegin = new Map(unreconciledWindows.map((window) => [window.begin, window]));
        const retained = [];
        for (const record of retainedReconciliations) {
          const affected = affectedByBegin.get(record.window.begin);
          if (!affected) {
            retained.push(record);
            continue;
          }
          for (const receiptId of record.receiptIds) affected.receiptIds.add(receiptId);
          pendingByBegin.set(record.window.begin, record.window);
        }
        retainedReconciliations = retained;
        for (const affected of affectedByBegin.values()) {
          addInvalidatedReceipts(invalidatedByBegin, affected.window, affected.receiptIds);
          if (Date.parse(affected.window.end) <= nowEpoch) {
            pendingByBegin.set(affected.window.begin, affected.window);
          }
        }
        unreconciledWindows = [...pendingByBegin.values()].sort((a, b) => a.begin.localeCompare(b.begin));
        const unresolvedByBegin = new Map(unresolvedConflictWindows.map((window) => [window.begin, window]));
        for (const affected of affectedByBegin.values()) unresolvedByBegin.set(affected.window.begin, affected.window);
        unresolvedConflictWindows = [...unresolvedByBegin.values()].sort((a, b) => a.begin.localeCompare(b.begin));
        invalidatedReceiptIdsByWindow = sortedInvalidatedRecords(invalidatedByBegin);
        fail("conflicting receipt invalidated retention coverage");
      }
    }

    const replacementReconciliations = new Map();
    if (unresolvedConflictWindows.length > 0) {
      for (const window of unresolvedConflictWindows) {
        const replacement = reconcileWindowCoverage({
          window,
          evidenceIntervals: finalEvidence,
          providerId: canonical.providerId,
        });
        if (!replacement.ok) fail(`unresolved conflict requires replacement coverage: ${replacement.reason}`);
        if (Date.parse(window.end) <= nowEpoch) replacementReconciliations.set(window.begin, replacement);
      }
      const resolvedBegins = new Set(unresolvedConflictWindows.map((window) => window.begin));
      unreconciledWindows = unreconciledWindows.filter((window) => !resolvedBegins.has(window.begin));
      unresolvedConflictWindows = [];
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
    for (const [begin, replacement] of replacementReconciliations) byBegin.set(begin, replacement);
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
      baselineRequired: false,
      reason: null,
      providerId: canonical.providerId,
      gatewayTimeZone: canonical.zone,
      evaluatedAt: new Date(nowEpoch).toISOString(),
      observedThrough: new Date(observedEpoch).toISOString(),
      maxReplayAgeMs: replayAgeLimit,
      reconciledWindows: [...byBegin.values()].sort((a, b) => a.window.begin.localeCompare(b.window.begin)),
      unreconciledWindows: [],
      unresolvedConflictWindows: [],
      invalidatedReceiptIdsByWindow,
    });
  } catch (error) {
    if (!(error instanceof RetentionContractError)) throw error;
    if (!canonical) return terminalNeedsBaseline(error.message);
    return blockedFromPrior({
      prior: canonical,
      reason: error.message,
      evaluatedAtEpoch: acceptedNowEpoch,
      reconciledWindows: retainedReconciliations,
      unreconciledWindows,
      unresolvedConflictWindows,
      invalidatedReceiptIdsByWindow,
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
