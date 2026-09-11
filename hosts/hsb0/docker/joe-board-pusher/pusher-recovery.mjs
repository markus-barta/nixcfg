function positiveNumber(value, name) {
  if (!Number.isFinite(value) || value <= 0) {
    throw new TypeError(`${name} must be a positive finite number`);
  }
  return value;
}

export function createReconnectScheduler({
  baseDelayMs,
  retryMs,
  maxDelayMs = baseDelayMs ?? retryMs,
  jitterRatio = 0,
  random = Math.random,
  onRetry,
  setTimer = setTimeout,
  clearTimer = clearTimeout,
}) {
  const base = positiveNumber(baseDelayMs ?? retryMs, "baseDelayMs");
  const maximum = positiveNumber(maxDelayMs, "maxDelayMs");
  if (maximum < base) throw new TypeError("maxDelayMs must be at least baseDelayMs");
  if (!Number.isFinite(jitterRatio) || jitterRatio < 0 || jitterRatio > 1) {
    throw new TypeError("jitterRatio must be between zero and one");
  }
  if (typeof random !== "function" || typeof onRetry !== "function") {
    throw new TypeError("random and onRetry must be functions");
  }

  let timer = null;
  let attempt = 0;
  let lastDelayMs = null;
  let stopped = false;

  function cancel() {
    if (timer === null) return false;
    clearTimer(timer);
    timer = null;
    return true;
  }

  return {
    schedule(reason = "connection unavailable") {
      if (stopped || timer !== null) return false;
      const exponent = Math.min(attempt, 52);
      const uncapped = base * (2 ** exponent);
      const capped = Math.min(maximum, Number.isFinite(uncapped) ? uncapped : maximum);
      const sample = Number(random());
      if (!Number.isFinite(sample) || sample < 0 || sample > 1) {
        throw new RangeError("random must return a number between zero and one");
      }
      const factor = 1 + ((sample * 2) - 1) * jitterRatio;
      const delay = Math.max(1, Math.min(maximum, Math.round(capped * factor)));
      const scheduledAttempt = attempt + 1;
      attempt = scheduledAttempt;
      lastDelayMs = delay;
      timer = setTimer(() => {
        timer = null;
        onRetry({ attempt: scheduledAttempt, delayMs: delay, reason });
      }, delay);
      return true;
    },

    cancel,

    reset() {
      cancel();
      attempt = 0;
      lastDelayMs = null;
    },

    stop() {
      stopped = true;
      cancel();
    },

    get pending() { return timer !== null; },
    get attempt() { return attempt; },
    get lastDelayMs() { return lastDelayMs; },
  };
}

/**
 * Owns the one active IB socket generation and the sole reconnect path.
 * TCP connect, complete-snapshot, health, and retry timers are injected for deterministic tests.
 */
export function createConnectionSupervisor({
  createApi,
  attachApi,
  requestHealth,
  onAttemptFailure = () => {},
  onRetryScheduled = () => {},
  baseDelayMs = 5_000,
  maxDelayMs = 300_000,
  jitterRatio = 0.2,
  connectTimeoutMs = 15_000,
  snapshotTimeoutMs = 60_000,
  healthIntervalMs = 60_000,
  healthTimeoutMs = 15_000,
  upstreamSilenceTimeoutMs = 300_000,
  random = Math.random,
  setTimer = setTimeout,
  clearTimer = clearTimeout,
}) {
  if (typeof createApi !== "function" || typeof attachApi !== "function" ||
      typeof requestHealth !== "function") {
    throw new TypeError("createApi, attachApi and requestHealth must be functions");
  }
  positiveNumber(connectTimeoutMs, "connectTimeoutMs");
  positiveNumber(snapshotTimeoutMs, "snapshotTimeoutMs");
  positiveNumber(healthIntervalMs, "healthIntervalMs");
  positiveNumber(healthTimeoutMs, "healthTimeoutMs");
  positiveNumber(upstreamSilenceTimeoutMs, "upstreamSilenceTimeoutMs");

  let activeApi = null;
  let connecting = false;
  let stopped = false;
  let connectTimer = null;
  let snapshotTimer = null;
  let healthTimer = null;
  let healthResponseTimer = null;
  let upstreamLost = false;

  function clearNamedTimer(name) {
    const value = name === "connect"
      ? connectTimer
      : name === "snapshot"
        ? snapshotTimer
        : name === "health"
          ? healthTimer
          : healthResponseTimer;
    if (value === null) return;
    clearTimer(value);
    if (name === "connect") connectTimer = null;
    else if (name === "snapshot") snapshotTimer = null;
    else if (name === "health") healthTimer = null;
    else healthResponseTimer = null;
  }

  function clearConnectionTimers() {
    clearNamedTimer("connect");
    clearNamedTimer("snapshot");
    clearNamedTimer("health");
    clearNamedTimer("healthResponse");
  }

  function disconnectQuietly(api) {
    try { api?.disconnect?.(); } catch {}
  }

  function scheduleSnapshotDeadline(api) {
    if (stopped || api !== activeApi || connecting || upstreamLost || snapshotTimer !== null) return false;
    const timer = setTimer(() => {
      if (snapshotTimer !== timer) return;
      snapshotTimer = null;
      if (stopped || api !== activeApi || connecting || upstreamLost) return;
      fail(api, "broker complete snapshot timed out");
    }, snapshotTimeoutMs);
    snapshotTimer = timer;
    return true;
  }

  function scheduleHealthProbe(api) {
    clearNamedTimer("health");
    clearNamedTimer("healthResponse");
    if (stopped || api !== activeApi || connecting) return;
    if (upstreamLost) {
      healthTimer = setTimer(() => {
        healthTimer = null;
        fail(api, "broker socket silent during upstream outage");
      }, upstreamSilenceTimeoutMs);
      return;
    }
    healthTimer = setTimer(() => {
      healthTimer = null;
      if (stopped || api !== activeApi || connecting) return;
      try {
        requestHealth(api);
      } catch (error) {
        fail(api, `health request failed: ${error?.message || error}`);
        return;
      }
      healthResponseTimer = setTimer(() => {
        healthResponseTimer = null;
        fail(api, "broker socket health callback timed out");
      }, healthTimeoutMs);
    }, healthIntervalMs);
  }

  const scheduler = createReconnectScheduler({
    baseDelayMs,
    maxDelayMs,
    jitterRatio,
    random,
    setTimer,
    clearTimer,
    onRetry: () => connectNow(),
  });

  function scheduleRetry(reason) {
    const scheduled = scheduler.schedule(reason);
    if (scheduled) {
      onRetryScheduled({
        reason,
        attempt: scheduler.attempt,
        delayMs: scheduler.lastDelayMs,
      });
    }
    return scheduled;
  }

  function fail(api, reason) {
    if (stopped || api !== activeApi) return false;
    activeApi = null;
    connecting = false;
    upstreamLost = false;
    clearConnectionTimers();
    onAttemptFailure(api, reason);
    disconnectQuietly(api);
    scheduleRetry(reason);
    return true;
  }

  function connectNow() {
    if (stopped || activeApi !== null) return false;
    let api;
    try {
      api = createApi();
      activeApi = api;
      connecting = true;
      upstreamLost = false;
      attachApi(api);
      connectTimer = setTimer(() => {
        connectTimer = null;
        fail(api, "broker socket connection attempt timed out");
      }, connectTimeoutMs);
      api.connect();
      return true;
    } catch (error) {
      const reason = `broker socket connection attempt failed: ${error?.message || error}`;
      if (api && activeApi === api) return fail(api, reason);
      connecting = false;
      onAttemptFailure(null, reason);
      scheduleRetry(reason);
      return false;
    }
  }

  return {
    start: connectNow,

    socketConnected(api) {
      if (stopped || api !== activeApi) return false;
      connecting = false;
      clearNamedTimer("connect");
      scheduleSnapshotDeadline(api);
      scheduleHealthProbe(api);
      return true;
    },

    socketActivity(api) {
      if (stopped || api !== activeApi || connecting) return false;
      scheduleHealthProbe(api);
      return true;
    },

    upstreamUnavailable(api) {
      if (stopped || api !== activeApi || connecting) return false;
      upstreamLost = true;
      clearNamedTimer("snapshot");
      scheduleHealthProbe(api);
      return true;
    },

    stable(api) {
      if (stopped || api !== activeApi || connecting) return false;
      clearNamedTimer("snapshot");
      scheduler.reset();
      scheduleHealthProbe(api);
      return true;
    },

    reconnect(api, reason = "broker socket unavailable") {
      if (stopped || api !== activeApi) return false;
      activeApi = null;
      connecting = false;
      upstreamLost = false;
      clearConnectionTimers();
      disconnectQuietly(api);
      scheduleRetry(reason);
      return true;
    },

    shutdown() {
      if (stopped) return;
      stopped = true;
      scheduler.stop();
      clearConnectionTimers();
      const api = activeApi;
      activeApi = null;
      connecting = false;
      upstreamLost = false;
      disconnectQuietly(api);
    },

    get activeApi() { return activeApi; },
    get connecting() { return connecting; },
    get retryPending() { return scheduler.pending; },
    get retryAttempt() { return scheduler.attempt; },
  };
}
