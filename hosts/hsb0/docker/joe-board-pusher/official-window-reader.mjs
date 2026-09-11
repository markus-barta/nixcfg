/**
 * One-shot official-IB execution window reader.
 *
 * This module never shares or reconnects the production client-92 socket. Each
 * call owns one bounded client-94 subprocess and exposes only verified paper
 * account evidence.
 */
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const REQUEST_SCHEMA = "inspr.ib.official-window-request.v1";
const PAPER_PORT = 4002;
const READER_CLIENT_ID = 94;
const PAPER_ACCOUNT = "DUR970597";
const SDK_VERSION = "10.45.1";
const MIN_PROTOBUF_SERVER_VERSION = 201;
const MAX_DATES = 7;
const MAX_STDOUT_BYTES = 16 * 1024 * 1024;
const MAX_STDERR_BYTES = 64 * 1024;
const STARTUP_TIMEOUT_MS = 15_000;
const PER_DATE_TIMEOUT_MS = 20_000;
const COMMISSION_GRACE_MS = 1_000;
const IPC_ALLOWANCE_MS = 2_000;
const KILL_GRACE_MS = 1_000;
const WEEK_MS = 7 * 24 * 60 * 60 * 1_000;
const NEW_YORK = "America/New_York";
const DEFAULT_PYTHON = "/opt/ibapi/bin/python";
const DEFAULT_SCRIPT = fileURLToPath(new URL("./official-window-reader.py", import.meta.url));
const ACCOUNT_RE = /^[A-Z][A-Z0-9]{2,31}$/;
const HOST_RE = /^[^\s\u0000-\u0020]{1,253}$/;

const dateTimeFormatters = new Map();

function formatter(timeZone) {
  let value = dateTimeFormatters.get(timeZone);
  if (!value) {
    value = new Intl.DateTimeFormat("en-US", {
      timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hourCycle: "h23",
    });
    dateTimeFormatters.set(timeZone, value);
  }
  return value;
}

function zonedParts(date, timeZone) {
  const fields = {};
  for (const part of formatter(timeZone).formatToParts(date)) {
    if (part.type !== "literal") fields[part.type] = Number(part.value);
  }
  return fields;
}

function zonedDateTimeToUtc({ year, month, day, hour = 0, minute = 0, second = 0 }, timeZone) {
  const wallClock = Date.UTC(year, month - 1, day, hour, minute, second);
  let candidate = wallClock;
  for (let iteration = 0; iteration < 3; iteration += 1) {
    const parts = zonedParts(new Date(candidate), timeZone);
    const represented = Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second);
    const next = candidate + wallClock - represented;
    if (next === candidate) break;
    candidate = next;
  }
  const verified = zonedParts(new Date(candidate), timeZone);
  if (
    verified.year !== year || verified.month !== month || verified.day !== day ||
    verified.hour !== hour || verified.minute !== minute || verified.second !== second
  ) {
    throw new Error(`unsupported or ambiguous ${timeZone} timestamp`);
  }
  return candidate;
}

function dateCodeParts(code) {
  const text = String(code);
  if (!/^\d{8}$/.test(text)) throw new Error("New York date code is invalid");
  const year = Number(text.slice(0, 4));
  const month = Number(text.slice(4, 6));
  const day = Number(text.slice(6, 8));
  const check = new Date(Date.UTC(year, month - 1, day));
  if (check.getUTCFullYear() !== year || check.getUTCMonth() + 1 !== month || check.getUTCDate() !== day) {
    throw new Error("New York date code is not a calendar date");
  }
  return { year, month, day };
}

function newYorkDateCode(date) {
  const parts = zonedParts(date, NEW_YORK);
  return Number(`${parts.year}${String(parts.month).padStart(2, "0")}${String(parts.day).padStart(2, "0")}`);
}

function nextDateCode(code) {
  const { year, month, day } = dateCodeParts(code);
  const next = new Date(Date.UTC(year, month - 1, day + 1));
  return Number(
    `${next.getUTCFullYear()}${String(next.getUTCMonth() + 1).padStart(2, "0")}${String(next.getUTCDate()).padStart(2, "0")}`,
  );
}

function newYorkDayStart(code) {
  return zonedDateTimeToUtc(dateCodeParts(code), NEW_YORK);
}

function iso(value, label) {
  const date = value instanceof Date ? new Date(value.getTime()) : new Date(value);
  if (!Number.isFinite(date.getTime())) throw new TypeError(`${label} must be an ISO timestamp`);
  return date.toISOString();
}

function object(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function same(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function filterTime(isoTimestamp) {
  return isoTimestamp.slice(0, 19).replaceAll("-", "").replace("T", "-");
}

function actualWindows(fromInclusive, toExclusive) {
  const fromMs = Date.parse(fromInclusive);
  const toMs = Date.parse(toExclusive);
  const first = newYorkDateCode(new Date(fromMs));
  const last = newYorkDateCode(new Date(toMs - 1));
  const result = [];
  let code = first;
  while (true) {
    if (result.length >= MAX_DATES) throw new RangeError("execution window overlaps more than seven New York dates");
    const dayStart = newYorkDayStart(code);
    const nextCode = nextDateCode(code);
    const dayEnd = newYorkDayStart(nextCode);
    const windowFrom = Math.max(fromMs, dayStart);
    const windowTo = Math.min(toMs, dayEnd);
    if (windowFrom < windowTo) {
      const from = new Date(windowFrom).toISOString();
      result.push({
        requestId: 9300 + result.length,
        newYorkDate: code,
        fromInclusive: from,
        toExclusive: new Date(windowTo).toISOString(),
        filter: {
          acctCode: PAPER_ACCOUNT,
          time: filterTime(from),
          specificDates: [code],
        },
      });
    }
    if (code === last) break;
    code = nextCode;
  }
  return result;
}

function preparePlan(input, now) {
  if (!object(input)) throw new TypeError("official execution window options are required");
  const allowed = new Set(["fromInclusive", "toExclusive", "targetAccount", "host", "port", "clientId", "signal"]);
  for (const key of Object.keys(input)) {
    if (!allowed.has(key)) throw new TypeError(`unsupported official execution window option ${key}`);
  }
  const host = input.host ?? process.env.IB_GATEWAY_HOST;
  const port = input.port ?? PAPER_PORT;
  const clientId = input.clientId ?? READER_CLIENT_ID;
  const account = input.targetAccount;
  if (typeof host !== "string" || !HOST_RE.test(host)) throw new TypeError("host must be a bounded name or address");
  if (port !== PAPER_PORT) throw new RangeError("official execution reader permits paper Gateway port 4002 only");
  if (clientId !== READER_CLIENT_ID) throw new RangeError("official execution reader requires dedicated client ID 94");
  if (typeof account !== "string" || !ACCOUNT_RE.test(account) || account !== PAPER_ACCOUNT) {
    throw new RangeError("official execution reader requires the configured paper account");
  }
  if (input.signal !== undefined && !(input.signal instanceof AbortSignal)) {
    throw new TypeError("signal must be an AbortSignal");
  }
  if (input.signal?.aborted) throw input.signal.reason ?? new DOMException("The operation was aborted", "AbortError");

  const startedAt = iso(now(), "query start");
  const requestedFrom = iso(input.fromInclusive, "fromInclusive");
  const requestedTo = iso(input.toExclusive, "toExclusive");
  const startedMs = Date.parse(startedAt);
  const fromMs = Date.parse(requestedFrom);
  const toMs = Date.parse(requestedTo);
  if (fromMs >= toMs) throw new RangeError("execution window must be non-empty");
  if (fromMs % 1_000 !== 0) throw new RangeError("fromInclusive must have whole-second precision");
  if (fromMs < startedMs - WEEK_MS) throw new RangeError("execution window begins outside the supported past week");
  const effectiveTo = Math.min(toMs, startedMs);
  if (fromMs >= effectiveTo) throw new RangeError("execution window has no observable past interval");
  const requestedCoverage = {
    fromInclusive: requestedFrom,
    toExclusive: new Date(effectiveTo).toISOString(),
  };
  const windows = actualWindows(requestedCoverage.fromInclusive, requestedCoverage.toExclusive);
  return {
    plan: {
      schema: REQUEST_SCHEMA,
      schemaVersion: 1,
      endpoint: { host, port, clientId, account },
      startedAt,
      requestedCoverage,
      actualWindows: windows,
    },
    signal: input.signal,
  };
}

function executionInstant(value) {
  if (typeof value !== "string") throw new Error("execution.time must be a string");
  const match = /^(\d{4})(\d{2})(\d{2})[ -](\d{2}):(\d{2}):(\d{2})(?:\s+(.+))?$/.exec(value.trim());
  if (!match) throw new Error("execution.time has an unsupported format");
  const [, year, month, day, hour, minute, second, rawZone] = match;
  const timeZone = rawZone?.trim();
  if (!timeZone) throw new Error("execution.time lacks an explicit time zone");
  try {
    return zonedDateTimeToUtc({
      year: Number(year),
      month: Number(month),
      day: Number(day),
      hour: Number(hour),
      minute: Number(minute),
      second: Number(second),
    }, timeZone);
  } catch (error) {
    throw new Error(`execution.time zone is unsupported: ${error?.message || error}`);
  }
}

function validateTimestamp(value, label) {
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) throw new Error(`${label} is invalid`);
  return timestamp;
}

function validateResponse(value, plan, exitCode) {
  if (!object(value) || value.schemaVersion !== 1) throw new Error("official reader response schema is invalid");
  if (!same(value.endpoint, plan.endpoint)) throw new Error("official reader response endpoint identity changed");
  if (!same(value.sdk, { package: "ibapi", version: SDK_VERSION })) {
    throw new Error("official reader response SDK identity is invalid");
  }
  if (
    !object(value.negotiated) ||
    !Number.isInteger(value.negotiated.serverVersion) ||
    value.negotiated.serverVersion < MIN_PROTOBUF_SERVER_VERSION ||
    value.negotiated.executionRequestFraming !== "protobuf" ||
    value.negotiated.parameterizedExecutionFilters !== true
  ) {
    throw new Error("official reader did not prove protobuf parameterized execution support");
  }
  if (!Array.isArray(value.managedAccounts) || !value.managedAccounts.includes(plan.endpoint.account)) {
    throw new Error("official reader response does not include the configured managed account");
  }
  if (value.foreignAccountViolation !== false) throw new Error("official reader reported a foreign account violation");
  if (value.startedAt !== plan.startedAt) throw new Error("official reader response start identity changed");
  if (!same(value.requestedCoverage, plan.requestedCoverage) || !same(value.actualWindows, plan.actualWindows)) {
    throw new Error("official reader response coverage metadata changed");
  }
  const startedMs = validateTimestamp(value.startedAt, "official reader startedAt");
  const finishedMs = validateTimestamp(value.finishedAt, "official reader finishedAt");
  if (finishedMs < startedMs) throw new Error("official reader finished before it started");
  if (value.disconnected !== true || value.exitCode !== 0 || exitCode !== 0) {
    throw new Error("official reader did not disconnect cleanly");
  }
  if (!object(value.requests)) throw new Error("official reader requests are absent");
  const expectedIds = plan.actualWindows.map((item) => String(item.requestId));
  if (!same(Object.keys(value.requests).sort(), [...expectedIds].sort())) {
    throw new Error("official reader response request IDs are incomplete");
  }

  const coverageFrom = Date.parse(plan.requestedCoverage.fromInclusive);
  const coverageTo = Date.parse(plan.requestedCoverage.toExclusive);
  const executionsById = new Map();
  const includedIds = new Set();
  const requests = {};
  for (const window of plan.actualWindows) {
    const key = String(window.requestId);
    const request = value.requests[key];
    if (!object(request) || request.label !== "specific-date" || !same(request.filter, window.filter)) {
      throw new Error(`official reader request ${key} filter metadata is invalid`);
    }
    if (!same(request.actualWindow, {
      fromInclusive: window.fromInclusive,
      toExclusive: window.toExclusive,
    })) {
      throw new Error(`official reader request ${key} window metadata is invalid`);
    }
    if (request.timedOut !== false || !Array.isArray(request.errors) || request.errors.length !== 0) {
      throw new Error(`official reader request ${key} did not complete cleanly`);
    }
    const requestedAt = validateTimestamp(request.requestedAt, `official reader request ${key} requestedAt`);
    const endedAt = validateTimestamp(request.endedAt, `official reader request ${key} endedAt`);
    if (requestedAt < startedMs || endedAt < requestedAt || endedAt > finishedMs) {
      throw new Error(`official reader request ${key} timestamps are inconsistent`);
    }
    if (!Array.isArray(request.executions)) throw new Error(`official reader request ${key} executions are invalid`);
    const filtered = [];
    for (const row of request.executions) {
      const execution = row?.execution;
      // The pending correction signal is checked before any timestamp/account normalization.
      if (typeof execution?.pendingPriceRevision !== "boolean") {
        throw new Error("official execution pendingPriceRevision is missing or invalid");
      }
      if (execution.acctNumber !== plan.endpoint.account) throw new Error("official execution belongs to a foreign account");
      if (typeof execution.execId !== "string" || !execution.execId) throw new Error("official execution execId is invalid");
      const instant = executionInstant(execution.time);
      if (newYorkDateCode(new Date(instant)) !== window.newYorkDate) {
        throw new Error("official execution was returned under the wrong specific date");
      }
      const prior = executionsById.get(execution.execId);
      if (prior && !same(prior, row)) throw new Error("official execution has a conflicting duplicate execId");
      if (!prior) executionsById.set(execution.execId, row);
      if (instant < coverageFrom || instant >= coverageTo || prior) continue;
      includedIds.add(execution.execId);
      filtered.push(row);
    }
    requests[key] = { ...request, executions: filtered };
  }

  if (!object(value.commissionsByExecId)) throw new Error("official reader commissionsByExecId is invalid");
  const commissionsByExecId = {};
  for (const [key, report] of Object.entries(value.commissionsByExecId)) {
    if (!object(report) || report.execId !== key) throw new Error("official commission identity is invalid");
    if (includedIds.has(key)) commissionsByExecId[key] = report;
  }
  return { ...value, requests, commissionsByExecId };
}

function processError(message, stderr = "") {
  const detail = stderr.trim().slice(0, 512);
  return new Error(detail ? `${message}: ${detail}` : message);
}

export function createOfficialWindowReader({
  spawnImpl = spawn,
  now = () => new Date(),
  pythonPath = DEFAULT_PYTHON,
  scriptPath = DEFAULT_SCRIPT,
  maxStdoutBytes = MAX_STDOUT_BYTES,
  totalTimeoutMs = null,
  setTimer = setTimeout,
  clearTimer = clearTimeout,
} = {}) {
  if (typeof spawnImpl !== "function" || typeof now !== "function") throw new TypeError("reader dependencies are invalid");
  if (!Number.isSafeInteger(maxStdoutBytes) || maxStdoutBytes <= 0 || maxStdoutBytes > MAX_STDOUT_BYTES) {
    throw new RangeError("maxStdoutBytes is invalid");
  }
  return async function read(input) {
    const { plan, signal } = preparePlan(input, now);
    const hardTimeout = totalTimeoutMs ?? (
      STARTUP_TIMEOUT_MS + plan.actualWindows.length * (PER_DATE_TIMEOUT_MS + COMMISSION_GRACE_MS) + IPC_ALLOWANCE_MS
    );
    if (!Number.isSafeInteger(hardTimeout) || hardTimeout <= 0 || hardTimeout > 180_000) {
      throw new RangeError("total official reader timeout is invalid");
    }

    return await new Promise((resolve, reject) => {
      let child;
      try {
        child = spawnImpl(pythonPath, ["-I", scriptPath], { stdio: ["pipe", "pipe", "pipe"] });
      } catch (error) {
        reject(processError(`official reader subprocess failed to start: ${error?.message || error}`));
        return;
      }
      let stdoutBytes = 0;
      let stderrBytes = 0;
      const stdout = [];
      const stderr = [];
      let failure = null;
      let settled = false;
      let forceTimer = null;

      const settle = (callback, value) => {
        if (settled) return;
        settled = true;
        clearTimer(deadlineTimer);
        if (forceTimer !== null) clearTimer(forceTimer);
        signal?.removeEventListener("abort", abort);
        callback(value);
      };
      const stop = (error) => {
        if (failure) return;
        failure = error;
        child.kill("SIGTERM");
        forceTimer = setTimer(() => {
          child.kill("SIGKILL");
          settle(reject, failure);
        }, KILL_GRACE_MS);
      };
      const abort = () => stop(signal.reason ?? new DOMException("The operation was aborted", "AbortError"));
      const deadlineTimer = setTimer(() => stop(new Error("official reader subprocess timed out")), hardTimeout);
      signal?.addEventListener("abort", abort, { once: true });

      child.stdout.on("data", (chunk) => {
        const value = Buffer.from(chunk);
        stdoutBytes += value.length;
        if (stdoutBytes > maxStdoutBytes) {
          stop(new Error("official reader stdout exceeded its byte limit"));
          return;
        }
        stdout.push(value);
      });
      child.stderr.on("data", (chunk) => {
        if (stderrBytes >= MAX_STDERR_BYTES) return;
        const value = Buffer.from(chunk);
        const retained = value.subarray(0, MAX_STDERR_BYTES - stderrBytes);
        stderrBytes += retained.length;
        stderr.push(retained);
      });
      child.on("error", (error) => stop(processError(`official reader subprocess error: ${error?.message || error}`)));
      child.on("close", (code) => {
        if (failure) {
          settle(reject, failure);
          return;
        }
        const diagnostic = Buffer.concat(stderr).toString("utf8");
        if (code !== 0) {
          settle(reject, processError(`official reader subprocess exited ${code}`, diagnostic));
          return;
        }
        try {
          const raw = Buffer.concat(stdout).toString("utf8").trim();
          if (!raw) throw new Error("official reader returned no JSON");
          const value = JSON.parse(raw, (_key, item) => {
            if (typeof item === "number" && !Number.isFinite(item)) throw new Error("official reader returned a non-finite number");
            return item;
          });
          settle(resolve, validateResponse(value, plan, code));
        } catch (error) {
          settle(reject, processError(`official reader response rejected: ${error?.message || error}`, diagnostic));
        }
      });
      child.stdin.on("error", (error) => stop(processError(`official reader stdin failed: ${error?.message || error}`)));
      child.stdin.end(`${JSON.stringify(plan)}\n`);
    });
  };
}

const defaultReader = createOfficialWindowReader();

export async function readOfficialExecutionWindow(options) {
  return await defaultReader(options);
}

export const OFFICIAL_WINDOW_READER_LIMITS = Object.freeze({
  paperPort: PAPER_PORT,
  clientId: READER_CLIENT_ID,
  paperAccount: PAPER_ACCOUNT,
  maxDates: MAX_DATES,
  maxStdoutBytes: MAX_STDOUT_BYTES,
});
