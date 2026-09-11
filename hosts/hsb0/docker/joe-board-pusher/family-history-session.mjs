import { createHash } from "node:crypto";

import { createReconnectScheduler } from "./pusher-recovery.mjs";

const MAX_CAPTURE_RECORDS = 50_000;
const NEW_YORK = "America/New_York";

function clone(value) {
  return structuredClone(value);
}

function iso(value) {
  const epoch = new Date(value || "").getTime();
  return Number.isFinite(epoch) ? new Date(epoch).toISOString() : null;
}

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

function canonicalClassifier(familyClientIds, excludedSymbols) {
  const ids = [...new Set([...familyClientIds].map(Number))].sort((left, right) => left - right);
  const symbols = [...new Set([...excludedSymbols].map((value) => String(value).trim().toUpperCase()))].sort();
  if (!ids.length || ids.some((value) => !Number.isSafeInteger(value) || value < 0) || symbols.some((value) => !value)) {
    throw new TypeError("family history classifier is invalid");
  }
  return { familyClientIds: ids, excludedSymbols: symbols };
}

function formatter(timeZone) {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  });
}

const newYorkFormatter = formatter(NEW_YORK);

function zonedParts(date, dateFormatter) {
  const parts = {};
  for (const part of dateFormatter.formatToParts(date)) {
    if (part.type !== "literal") parts[part.type] = Number(part.value);
  }
  return [parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second];
}

function zonedInstant(parts, timeZone) {
  const naive = Date.UTC(parts[0], parts[1] - 1, parts[2], parts[3], parts[4], parts[5]);
  const dateFormatter = timeZone === NEW_YORK ? newYorkFormatter : formatter(timeZone);
  let candidate = naive;
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const actual = zonedParts(new Date(candidate), dateFormatter);
    const actualAsUtc = Date.UTC(actual[0], actual[1] - 1, actual[2], actual[3], actual[4], actual[5]);
    const adjustment = naive - actualAsUtc;
    if (adjustment === 0) break;
    candidate += adjustment;
  }
  const matches = [candidate - 3_600_000, candidate, candidate + 3_600_000]
    .filter((value) => zonedParts(new Date(value), dateFormatter).every((part, index) => part === parts[index]));
  if (matches.length !== 1) throw new Error("broker execution time is invalid or ambiguous");
  return new Date(matches[0]).toISOString();
}

function localDayWindow(value) {
  const normalized = iso(value);
  if (!normalized) throw new Error("capture time is invalid");
  const [year, month, day] = zonedParts(new Date(normalized), newYorkFormatter);
  const nextDate = new Date(Date.UTC(year, month - 1, day) + 86_400_000);
  const next = [nextDate.getUTCFullYear(), nextDate.getUTCMonth() + 1, nextDate.getUTCDate()];
  return {
    day: `${String(year).padStart(4, "0")}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`,
    fromInclusive: zonedInstant([year, month, day, 0, 0, 0], NEW_YORK),
    nextDayStart: zonedInstant([...next, 0, 0, 0], NEW_YORK),
  };
}

function filterTime(value) {
  return value.replace(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2}).*$/, "$1$2$3-$4:$5:$6");
}

function captureAddsFacts(state, executions, commissions) {
  if (!state) return true;
  const priorExecutions = new Map((state.executions || []).map((row) => [row?.execution?.execId, row]));
  const priorCommissions = new Map((state.commissions || []).map((row) => [row?.execId, row]));
  return executions.some((row) => {
    const prior = priorExecutions.get(row.execution.execId);
    return !prior || stable(prior) !== stable(row);
  }) || commissions.some((row) => {
    const prior = priorCommissions.get(row.execId);
    return !prior || stable(prior) !== stable(row);
  });
}

function historyIdentityReason(state, { targetAccount, classifier, historyStart, through }) {
  if (state?.account !== targetAccount) return "family history account does not match configured account";
  if (stable(state.classifier) !== stable(classifier)) {
    return "family history classifier does not match configured family";
  }
  const fromInclusive = iso(state?.target?.fromInclusive);
  const toExclusive = iso(state?.target?.toExclusive);
  if (fromInclusive !== historyStart || !toExclusive) {
    return "family history target does not match configured history start";
  }
  if (toExclusive > through) return "family history target extends beyond the current clock";
  return null;
}

function bootstrapCaptureReason(capture, { targetAccount, classifier, historyStart }) {
  if (capture?.account !== targetAccount) return "legacy family capture account does not match configured account";
  if (stable(capture.classifier) !== stable(classifier)) {
    return "legacy family capture classifier does not match configured family";
  }
  const fromInclusive = iso(capture?.window?.fromInclusive);
  const toExclusive = iso(capture?.window?.toExclusive);
  if (fromInclusive !== historyStart || !toExclusive || iso(capture?.capturedAt) !== toExclusive) {
    return "legacy family capture does not use its actual periodStart and coverageThrough";
  }
  if (capture.coverageStatus !== "known" || capture.completenessAssertion !== null) {
    return "legacy family capture makes an unsupported completeness claim";
  }
  return null;
}

function extendProjectionTarget(projection, state, through) {
  const priorThrough = iso(state?.target?.toExclusive);
  if (!priorThrough || through < priorThrough) {
    throw new Error("current clock regressed behind durable family history target");
  }
  const result = clone(projection);
  if (through === priorThrough) return result;
  result.status = "BEST_AVAILABLE";
  result.equity = null;
  result.coverage = clone(result.coverage);
  result.coverage.status = "known";
  result.coverage.target = {
    ...result.coverage.target,
    fromInclusive: iso(result.coverage.target.fromInclusive),
    toExclusive: through,
  };
  result.coverage.gaps = [
    ...result.coverage.gaps,
    {
      fromInclusive: priorThrough,
      toExclusive: through,
      reason: "runtime target extension has no capture receipt",
    },
  ];
  return result;
}

/**
 * Generation-scoped known-history capture over an API connection owned by the
 * pusher supervisor. It never connects, changes account state, or claims a
 * query is complete historical accounting.
 */
export function createFamilyHistorySessionAdapter({
  targetAccount,
  brokerClientId,
  familyClientIds,
  excludedSymbols = ["SXR8", "TSLA"],
  historyStart,
  captureSchema,
  captureSourceKind = "paper-api",
  normalizeExecutionRow,
  normalizeCommissionReport,
  reconcileCapture,
  projectHistory,
  eventNames,
  store,
  loadBootstrapCapture = null,
  executionRequestIdStart = 9601,
  pollIntervalMs = 30_000,
  requestTimeoutMs = 20_000,
  commissionDrainMs = 3_000,
  retryBaseMs = 5_000,
  retryMaxMs = 300_000,
  retryJitterRatio = 0.2,
  now = () => new Date().toISOString(),
  random = Math.random,
  setTimer = setTimeout,
  clearTimer = clearTimeout,
  requestManagedAccounts = true,
  hooks = {},
}) {
  if (!targetAccount || !Number.isSafeInteger(brokerClientId) || !iso(historyStart) || !captureSchema ||
      typeof normalizeExecutionRow !== "function" || typeof normalizeCommissionReport !== "function" ||
      typeof reconcileCapture !== "function" || typeof projectHistory !== "function" || !eventNames || !store) {
    throw new TypeError("family history session configuration is incomplete");
  }
  for (const [value, label] of [[pollIntervalMs, "pollIntervalMs"], [requestTimeoutMs, "requestTimeoutMs"],
    [commissionDrainMs, "commissionDrainMs"], [retryBaseMs, "retryBaseMs"], [retryMaxMs, "retryMaxMs"]]) {
    if (!Number.isFinite(value) || value <= 0) throw new TypeError(`${label} must be positive`);
  }
  if (retryMaxMs > 300_000) throw new TypeError("retryMaxMs cannot exceed five minutes");
  if (!Number.isSafeInteger(executionRequestIdStart) || executionRequestIdStart % 2 !== 1) {
    throw new TypeError("family history execution request IDs must start on an odd integer");
  }

  const classifier = canonicalClassifier(familyClientIds, excludedSymbols);
  const configuredHistoryStart = historyStart;
  const normalizedHistoryStart = iso(historyStart);
  let loaded;
  try {
    loaded = store.load();
  } catch (error) {
    loaded = { ok: false, reason: `family history state load failed: ${error?.message || error}` };
  }
  let state = loaded.ok ? (loaded.state ? clone(loaded.state) : null) : null;
  let blockedReason = loaded.ok ? null : loaded.reason;
  let startupReason = blockedReason;
  let retryReason = null;
  let activeApi = null;
  let generation = 0;
  let registrations = [];
  let connected = false;
  let managed = false;
  let activeCycle = null;
  let nextRequestId = executionRequestIdStart;
  let pollTimer = null;
  let deadlineTimer = null;
  let drainTimer = null;

  const retryScheduler = createReconnectScheduler({
    baseDelayMs: retryBaseMs,
    maxDelayMs: retryMaxMs,
    jitterRatio: retryJitterRatio,
    random,
    setTimer,
    clearTimer,
    onRetry: () => pollNow(),
  });

  function unavailable(reason) {
    hooks.onUnavailable?.(reason);
  }

  function initializeHistory() {
    const initializedAt = iso(now());
    if (!initializedAt) {
      blockedReason = "family history startup clock is unavailable";
      startupReason = blockedReason;
      return;
    }
    if (blockedReason) return;
    if (state) {
      blockedReason = historyIdentityReason(state, {
        targetAccount,
        classifier,
        historyStart: normalizedHistoryStart,
        through: initializedAt,
      });
      startupReason = blockedReason;
      if (blockedReason) state = null;
      return;
    }
    if (loadBootstrapCapture === null) return;
    if (typeof loadBootstrapCapture !== "function") {
      blockedReason = "family history bootstrap loader is invalid";
      startupReason = blockedReason;
      return;
    }
    let bootstrap;
    try {
      bootstrap = loadBootstrapCapture({
        targetAccount,
        classifier: clone(classifier),
        historyStart: configuredHistoryStart,
      });
    } catch (error) {
      blockedReason = `legacy family history bootstrap failed: ${error?.message || error}`;
      startupReason = blockedReason;
      return;
    }
    if (bootstrap?.ok !== true) {
      startupReason = bootstrap?.reason || "legacy family history source is unavailable";
      if (bootstrap?.freshInstall !== true) blockedReason = startupReason;
      return;
    }
    const capture = clone(bootstrap.capture);
    const captureReason = bootstrapCaptureReason(capture, {
      targetAccount,
      classifier,
      historyStart: normalizedHistoryStart,
    });
    if (captureReason) {
      blockedReason = captureReason;
      startupReason = captureReason;
      return;
    }
    let seeded;
    try {
      const next = reconcileCapture({
        prior: null,
        capture,
        target: { fromInclusive: normalizedHistoryStart, toExclusive: initializedAt },
      });
      const identityReason = historyIdentityReason(next, {
        targetAccount,
        classifier,
        historyStart: normalizedHistoryStart,
        through: initializedAt,
      });
      if (identityReason) throw new Error(identityReason);
      store.save(next);
      state = clone(next);
      seeded = {
        capturedAt: capture.capturedAt,
        executionCount: capture.executions.length,
        commissionCount: capture.commissions.length,
      };
    } catch (error) {
      blockedReason = `legacy family history bootstrap failed: ${error?.message || error}`;
      startupReason = blockedReason;
    }
    if (seeded) hooks.onSeeded?.(seeded);
  }

  initializeHistory();
  if (startupReason) unavailable(startupReason);

  function stopTimer(name) {
    const timer = name === "poll" ? pollTimer : name === "deadline" ? deadlineTimer : drainTimer;
    if (timer === null) return;
    clearTimer(timer);
    if (name === "poll") pollTimer = null;
    else if (name === "deadline") deadlineTimer = null;
    else drainTimer = null;
  }

  function stopCycleTimers() {
    stopTimer("deadline");
    stopTimer("drain");
  }

  function cleanupListeners() {
    for (const { api, name, handler } of registrations) api.off?.(name, handler);
    registrations = [];
  }

  function schedulePoll() {
    stopTimer("poll");
    if (!connected || !managed || blockedReason || retryReason || activeCycle) return false;
    pollTimer = setTimer(() => {
      pollTimer = null;
      pollNow();
    }, pollIntervalMs);
    return true;
  }

  function scheduleRetry(reason) {
    stopTimer("poll");
    retryReason = reason;
    unavailable(reason);
    if (!connected || !managed || blockedReason) return false;
    return retryScheduler.schedule(reason);
  }

  function retryCycle(reason) {
    stopCycleTimers();
    activeCycle = null;
    scheduleRetry(reason);
  }

  function block(reason) {
    stopCycleTimers();
    stopTimer("poll");
    activeCycle = null;
    retryReason = null;
    blockedReason = reason;
    retryScheduler.cancel();
    unavailable(reason);
  }

  function finishCycle() {
    if (!activeCycle?.ended) return false;
    stopCycleTimers();
    const cycle = activeCycle;
    activeCycle = null;
    const capturedAt = iso(now());
    if (!capturedAt || capturedAt <= cycle.window.fromInclusive) {
      retryCycle("history capture clock is unavailable or regressed");
      return false;
    }
    const executionIds = new Set(cycle.executions.keys());
    const commissions = [...cycle.commissions.values()].filter((row) => executionIds.has(row.execId));
    const executions = [...cycle.executions.values()];
    if (!captureAddsFacts(state, executions, commissions)) {
      retryReason = null;
      retryScheduler.reset();
      schedulePoll();
      return true;
    }
    const window = {
      fromInclusive: cycle.window.fromInclusive,
      toExclusive: capturedAt < cycle.window.nextDayStart ? capturedAt : cycle.window.nextDayStart,
    };
    const sourceFacts = {
      brokerClientId,
      requestId: cycle.requestId,
      retainedDay: cycle.window.day,
      requestedAt: cycle.requestedAt,
      capturedAt,
      executions,
      commissions,
    };
    const sha256 = digest(sourceFacts);
    const capture = {
      schema: captureSchema,
      account: targetAccount,
      classifier,
      source: {
        kind: captureSourceKind,
        id: `client-${brokerClientId}-request-${cycle.requestId}-${sha256}`,
        sha256,
        metadata: {
          brokerClientId,
          requestId: cycle.requestId,
          retainedDay: cycle.window.day,
          filterTime: cycle.filter.time,
        },
      },
      capturedAt,
      window,
      coverageStatus: "known",
      completenessAssertion: null,
      executions,
      commissions,
    };
    try {
      const next = reconcileCapture({
        prior: state,
        capture,
        target: { fromInclusive: normalizedHistoryStart, toExclusive: capturedAt },
      });
      const identityReason = historyIdentityReason(next, {
        targetAccount,
        classifier,
        historyStart: normalizedHistoryStart,
        through: capturedAt,
      });
      if (identityReason) throw new Error(identityReason);
      store.save(next);
      state = clone(next);
    } catch (error) {
      block(`family history reconciliation failed: ${error?.message || error}`);
      return false;
    }
    retryReason = null;
    retryScheduler.reset();
    hooks.onUpdated?.({
      capturedAt,
      executionCount: executions.length,
      commissionCount: commissions.length,
      missingCommissionCount: executions.length - commissions.length,
    });
    schedulePoll();
    return true;
  }

  function pollNow() {
    if (!connected || !managed || blockedReason || activeCycle || retryScheduler.pending) return false;
    let requestedAt;
    let window;
    try {
      requestedAt = iso(now());
      window = localDayWindow(requestedAt);
    } catch (error) {
      scheduleRetry(`history capture day is unavailable: ${error?.message || error}`);
      return false;
    }
    const fromInclusive = window.fromInclusive < normalizedHistoryStart ? normalizedHistoryStart : window.fromInclusive;
    if (requestedAt <= fromInclusive) {
      scheduleRetry("history capture window is not yet non-empty");
      return false;
    }
    const requestId = nextRequestId;
    nextRequestId += 2;
    const specificDate = Number(window.day.replaceAll("-", ""));
    const filter = {
      acctCode: targetAccount,
      time: filterTime(fromInclusive),
      specificDates: [specificDate],
    };
    activeCycle = {
      requestId,
      requestedAt,
      window: { ...window, fromInclusive },
      filter,
      executions: new Map(),
      commissions: new Map(),
      callbackCount: 0,
      ended: false,
    };
    deadlineTimer = setTimer(() => {
      deadlineTimer = null;
      if (activeCycle?.requestId === requestId) retryCycle("history execution request timed out before execDetailsEnd");
    }, requestTimeoutMs);
    try {
      activeApi.reqExecutions(requestId, filter);
    } catch (error) {
      retryCycle(`history execution request failed: ${error?.message || error}`);
      return false;
    }
    return true;
  }

  function attach(api) {
    cleanupListeners();
    stopTimer("poll");
    stopCycleTimers();
    retryScheduler.cancel();
    generation += 1;
    const attachedGeneration = generation;
    activeApi = api;
    connected = false;
    managed = false;
    activeCycle = null;

    const on = (name, callback) => {
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
      if (!connected) return;
      const available = String(accounts || "").split(",").map((value) => value.trim());
      if (!available.includes(targetAccount)) {
        block("configured family history account is not managed by this session");
        return;
      }
      managed = true;
      if (retryReason) retryScheduler.schedule(retryReason);
      else pollNow();
    });
    on(eventNames.execDetails, (requestId, contract, execution) => {
      if (!connected || !activeCycle || requestId !== activeCycle.requestId || execution?.acctNumber !== targetAccount) return;
      activeCycle.callbackCount += 1;
      if (activeCycle.callbackCount > MAX_CAPTURE_RECORDS * 2) {
        retryCycle("history callback limit exceeded");
        return;
      }
      try {
        const row = normalizeExecutionRow({ contract, execution });
        if (row?.execution?.acctNumber !== targetAccount) throw new Error("execution account mismatch");
        const prior = activeCycle.executions.get(row.execution.execId);
        if (prior && stable(prior) !== stable(row)) throw new Error(`conflicting execution ${row.execution.execId}`);
        activeCycle.executions.set(row.execution.execId, row);
        if (activeCycle.executions.size > MAX_CAPTURE_RECORDS) throw new Error("execution record limit exceeded");
      } catch (error) {
        retryCycle(`history execution callback rejected: ${error?.message || error}`);
      }
    });
    on(eventNames.execDetailsEnd, (requestId) => {
      if (!connected || !activeCycle || requestId !== activeCycle.requestId || activeCycle.ended) return;
      activeCycle.ended = true;
      stopTimer("deadline");
      drainTimer = setTimer(() => {
        drainTimer = null;
        finishCycle();
      }, commissionDrainMs);
    });
    on(eventNames.commissionReport, (report) => {
      if (!connected || !activeCycle) return;
      activeCycle.callbackCount += 1;
      if (activeCycle.callbackCount > MAX_CAPTURE_RECORDS * 2) {
        retryCycle("history callback limit exceeded");
        return;
      }
      let row;
      try {
        row = normalizeCommissionReport(report);
      } catch {
        return;
      }
      const prior = activeCycle.commissions.get(row.execId);
      if (prior && stable(prior) !== stable(row)) {
        retryCycle(`history commission callback conflicted for ${row.execId}`);
        return;
      }
      activeCycle.commissions.set(row.execId, row);
      if (activeCycle.commissions.size > MAX_CAPTURE_RECORDS) {
        retryCycle("history commission record limit exceeded");
      }
    });
    on(eventNames.disconnected, () => retire("broker disconnected; history capture paused"));
    return attachedGeneration;
  }

  function upstreamUnavailable(reason = "broker upstream unavailable; history capture paused") {
    if (!activeApi) return false;
    generation += 1;
    connected = false;
    managed = false;
    activeCycle = null;
    stopTimer("poll");
    stopCycleTimers();
    retryScheduler.cancel();
    unavailable(reason);
    return true;
  }

  function retire(reason = "family history session retired") {
    generation += 1;
    connected = false;
    managed = false;
    activeCycle = null;
    stopTimer("poll");
    stopCycleTimers();
    retryScheduler.cancel();
    cleanupListeners();
    activeApi = null;
    unavailable(reason);
  }

  function project() {
    if (blockedReason) return { ok: false, reason: blockedReason };
    if (!state) return { ok: false, reason: "no durable family history capture is available" };
    try {
      const through = iso(now());
      if (!through) throw new Error("current clock is unavailable");
      return extendProjectionTarget(projectHistory({ state: clone(state) }), state, through);
    } catch (error) {
      return { ok: false, reason: `family history projection failed: ${error?.message || error}` };
    }
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
    get startupReason() { return startupReason; },
    get retryReason() { return retryReason; },
    inspectState() { return state ? clone(state) : null; },
  };
}
