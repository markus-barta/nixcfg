import { spawn as nodeSpawn } from "node:child_process";
import { randomUUID } from "node:crypto";

export const EXECUTION_QUERY_REQUEST_SCHEMA = "inspr.ib.execution-query.request.v1";
export const EXECUTION_QUERY_RESULT_SCHEMA = "inspr.ib.execution-query.result.v1";

const DEFAULT_MAX_LINE_BYTES = 16 * 1024 * 1024;
const DEFAULT_MAX_RECORDS = 50_000;
const DEFAULT_MAX_STDERR_BYTES = 64 * 1024;
const MAX_QUERY_DATES = 7;
const REQUIRED_SDK_VERSION = "10.45.1";
const STARTUP_TIMEOUT_MS = 15_000;
const PER_DATE_TIMEOUT_MS = 20_000;
const IPC_ALLOWANCE_MS = 2_000;

function failure(message) {
  throw new Error(message);
}

function plainObject(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    failure(`${label} is malformed`);
  }
  return value;
}

function text(value, label) {
  if (typeof value !== "string" || value.trim() !== value || !value) {
    failure(`${label} is invalid`);
  }
  return value;
}

function dateCode(value, label = "specific date") {
  const date = text(value, label);
  const match = date.match(/^(\d{4})(\d{2})(\d{2})$/);
  if (!match) failure(`${label} is invalid`);
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const parsed = new Date(Date.UTC(year, month - 1, day));
  if (
    parsed.getUTCFullYear() !== year ||
    parsed.getUTCMonth() !== month - 1 ||
    parsed.getUTCDate() !== day
  ) {
    failure(`${label} is invalid`);
  }
  return date;
}

function iso(value, label) {
  const raw = text(value, label);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$/.test(raw)) {
    failure(`${label} is not an explicit ISO timestamp`);
  }
  const epoch = Date.parse(raw);
  if (!Number.isFinite(epoch)) failure(`${label} is invalid`);
  return new Date(epoch).toISOString();
}

function finite(value, label) {
  if (
    typeof value !== "number" ||
    !Number.isFinite(value) ||
    Math.abs(value) === Number.MAX_VALUE
  ) {
    failure(`${label} is not a finite number`);
  }
  return value;
}

function positive(value, label) {
  const number = finite(value, label);
  if (number <= 0) failure(`${label} must be positive`);
  return number;
}

function integer(value, label, mustBePositive = false) {
  if (!Number.isSafeInteger(value) || (mustBePositive ? value <= 0 : value < 0)) {
    failure(`${label} is invalid`);
  }
  return value;
}

function currency(value, label) {
  const code = text(value, label).toUpperCase();
  if (!/^[A-Z]{3}$/.test(code)) failure(`${label} is invalid`);
  return code;
}

function stable(value) {
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${stable(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function uniqueRows(rows, identify, label) {
  const seen = new Map();
  for (const row of rows) {
    const id = identify(row);
    const encoded = stable(row);
    if (seen.has(id) && seen.get(id) !== encoded) failure(`conflicting ${label} identity`);
    if (seen.has(id)) failure(`duplicate ${label} identity`);
    seen.set(id, encoded);
  }
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
      failure("contract multiplier is invalid or too long");
    }
    return value;
  }
  return finite(value, "contract multiplier");
}

function normalizeContract(value) {
  const contract = plainObject(value, "execution contract");
  const secType = text(contract.secType, "contract secType").toUpperCase();
  return {
    conId: integer(contract.conId, "contract conId", true),
    symbol: text(contract.symbol, "contract symbol").toUpperCase(),
    secType,
    currency: currency(contract.currency, "contract currency"),
    multiplier: contractMultiplier(contract.multiplier, secType),
  };
}

function normalizeExecution(value, account, requestDate) {
  const execution = plainObject(value, "execution");
  if (text(execution.acctNumber, "execution account") !== account) {
    failure("execution account does not match query account");
  }
  const time = text(execution.time, "execution time");
  const match = time.match(
    /^(\d{8})\s+\d{2}:\d{2}:\d{2}\s+(?:US\/Eastern|America\/New_York)$/
  );
  if (!match || match[1] !== requestDate) {
    failure("execution time is outside its exact-date request");
  }
  const rawSide = text(execution.side, "execution side").toUpperCase();
  const side = { BOT: "BUY", BUY: "BUY", SLD: "SELL", SELL: "SELL" }[rawSide];
  if (!side) {
    failure("execution side is unsupported");
  }
  if (typeof execution.pendingPriceRevision !== "boolean") {
    failure("execution pendingPriceRevision is invalid");
  }
  return {
    execId: text(execution.execId, "execution execId"),
    time,
    acctNumber: account,
    clientId: integer(execution.clientId, "execution clientId"),
    side,
    shares: positive(execution.shares, "execution shares"),
    price: positive(execution.price, "execution price"),
    pendingPriceRevision: execution.pendingPriceRevision,
  };
}

function normalizeCommission(value) {
  const report = plainObject(value, "commission");
  return {
    execId: text(report.execId, "commission execId"),
    commission: finite(report.commission, "commission amount"),
    currency: currency(report.currency, "commission currency"),
  };
}

export function validateExecutionQueryRequest(value) {
  const request = plainObject(value, "execution query request");
  if (request.schema !== EXECUTION_QUERY_REQUEST_SCHEMA) {
    failure("execution query request schema mismatch");
  }
  const cycleId = text(request.cycleId, "execution query cycleId");
  const account = text(request.account, "execution query account");
  if (
    !Array.isArray(request.specificDates) ||
    !request.specificDates.length ||
    request.specificDates.length > MAX_QUERY_DATES
  ) {
    failure("execution query specificDates are invalid");
  }
  const specificDates = request.specificDates.map((date) => dateCode(date));
  if (new Set(specificDates).size !== specificDates.length) {
    failure("execution query dates are duplicated");
  }
  if (stable([...specificDates].sort()) !== stable(specificDates)) {
    failure("execution query dates are not canonical");
  }
  return { schema: EXECUTION_QUERY_REQUEST_SCHEMA, cycleId, account, specificDates };
}

export function validateExecutionQueryResult(value, expected, maxRecords = DEFAULT_MAX_RECORDS) {
  const result = plainObject(value, "execution query result");
  if (result.schema !== EXECUTION_QUERY_RESULT_SCHEMA) {
    failure("execution query result schema mismatch");
  }
  if (result.cycleId !== expected.cycleId) failure("execution query cycleId mismatch");
  if (result.account !== expected.account) failure("execution query account mismatch");
  if (!Array.isArray(result.errors) || result.errors.length !== 0) {
    failure("execution query returned errors or partial coverage");
  }
  if (!Array.isArray(result.requests) || result.requests.length !== expected.specificDates.length) {
    failure("execution query did not return every requested date");
  }
  if (stable(result.requests.map((request) => request?.date)) !== stable(expected.specificDates)) {
    failure("execution query dates were not completed oldest first");
  }

  const byDate = new Map();
  let recordCount = 0;
  for (const rawRequest of result.requests) {
    const request = plainObject(rawRequest, "execution date result");
    const date = dateCode(request.date, "execution result date");
    if (byDate.has(date) || !expected.specificDates.includes(date)) {
      failure("execution query returned duplicate or unrequested date");
    }
    const requestedAt = iso(request.requestedAt, "execution request requestedAt");
    const endedAt = iso(request.endedAt, "execution request endedAt");
    if (endedAt < requestedAt) failure("execution request timestamps regressed");
    if (!Array.isArray(request.errors) || request.errors.length !== 0) {
      failure("execution date request returned errors or partial coverage");
    }
    if (!Array.isArray(request.executions)) {
      failure("execution result executions are invalid");
    }
    recordCount += request.executions.length;
    if (recordCount > maxRecords) failure("execution query record limit exceeded");
    const executions = request.executions.map((row) => {
      const item = plainObject(row, "execution record");
      return {
        contract: normalizeContract(item.contract),
        execution: normalizeExecution(item.execution, expected.account, date),
      };
    });
    uniqueRows(executions, (row) => row.execution.execId, "execution");
    byDate.set(date, { date, requestedAt, endedAt, executions });
  }
  for (const date of expected.specificDates) {
    if (!byDate.has(date)) failure("execution query omitted a requested date");
  }
  const allExecutions = [...byDate.values()].flatMap((request) => request.executions);
  uniqueRows(allExecutions, (row) => row.execution.execId, "execution");

  if (!Array.isArray(result.commissions) || result.commissions.length > maxRecords) {
    failure("execution query commissions are invalid");
  }
  const commissions = result.commissions.map(normalizeCommission);
  uniqueRows(commissions, (row) => row.execId, "commission");
  const executionIds = new Set(allExecutions.map((row) => row.execution.execId));
  if (commissions.some((report) => !executionIds.has(report.execId))) {
    failure("execution query returned an unmatched commission");
  }
  const serverVersion = integer(result.serverVersion, "execution query serverVersion", true);
  if (serverVersion < 200) failure("execution query serverVersion lacks required capability");
  const sdkVersion = text(result.sdkVersion, "execution query sdkVersion");
  if (sdkVersion !== REQUIRED_SDK_VERSION) failure("execution query sdkVersion mismatch");
  const framing = text(result.framing, "execution query framing");
  const expectedFraming = serverVersion >= 201 ? "protobuf" : "legacy-extended";
  if (framing !== expectedFraming) failure("execution query framing mismatch");
  const finishedAt = iso(result.finishedAt, "execution query finishedAt");
  if (result.requests.some((request) => finishedAt < iso(request.endedAt, "execution request endedAt"))) {
    failure("execution query finishedAt precedes a request end");
  }

  return {
    schema: EXECUTION_QUERY_RESULT_SCHEMA,
    cycleId: expected.cycleId,
    account: expected.account,
    sdkVersion,
    serverVersion,
    framing,
    requests: expected.specificDates.map((date) => byDate.get(date)),
    commissions,
    errors: [],
    finishedAt,
  };
}

/** Long-lived, single-flight JSONL supervisor for the official ibapi helper. */
export function createExecutionHistorySupervisor({
  command = "/opt/ibapi/bin/python",
  args = [],
  spawnImpl = nodeSpawn,
  startupTimeoutMs = STARTUP_TIMEOUT_MS,
  perDateTimeoutMs = PER_DATE_TIMEOUT_MS,
  ipcAllowanceMs = IPC_ALLOWANCE_MS,
  maxLineBytes = DEFAULT_MAX_LINE_BYTES,
  maxRecords = DEFAULT_MAX_RECORDS,
  maxStderrBytes = DEFAULT_MAX_STDERR_BYTES,
  setTimer = setTimeout,
  clearTimer = clearTimeout,
  hooks = {},
} = {}) {
  if (typeof command !== "string" || !command || !Array.isArray(args)) {
    throw new TypeError("execution helper command and args are required");
  }
  if ([startupTimeoutMs, perDateTimeoutMs, ipcAllowanceMs].some((value) =>
    !Number.isSafeInteger(value) || value < 0) || perDateTimeoutMs === 0) {
    throw new TypeError("execution helper timeout configuration is invalid");
  }
  let child = null;
  let stdout = Buffer.alloc(0);
  let stderrBytes = 0;
  let pending = null;
  let helperSessionId = null;

  function settle(error, value) {
    const current = pending;
    if (!current) return;
    pending = null;
    clearTimer(current.timer);
    if (error) current.reject(error);
    else current.resolve(value);
  }

  function stopChild(signal = "SIGTERM") {
    const owned = child;
    child = null;
    helperSessionId = null;
    stdout = Buffer.alloc(0);
    stderrBytes = 0;
    if (owned && owned.exitCode === null && owned.signalCode === null) {
      owned.kill(signal);
    }
  }

  function protocolFailure(reason) {
    settle(new Error(reason));
    stopChild();
  }

  function handleLine(line) {
    if (!pending) {
      protocolFailure("execution helper emitted an unsolicited reply");
      return;
    }
    let decoded;
    try {
      decoded = JSON.parse(line);
    } catch {
      protocolFailure("execution helper emitted malformed JSONL");
      return;
    }
    try {
      const result = validateExecutionQueryResult(decoded, pending.request, maxRecords);
      settle(null, { ...result, helperSessionId });
    } catch (error) {
      protocolFailure(error.message);
    }
  }

  function bind(next) {
    child = next;
    helperSessionId = `helper-session-${randomUUID()}`;
    stdout = Buffer.alloc(0);
    stderrBytes = 0;

    next.stdout.on("data", (chunk) => {
      if (next !== child) return;
      stdout = Buffer.concat([stdout, Buffer.from(chunk)]);
      let newline;
      while ((newline = stdout.indexOf(0x0a)) !== -1) {
        if (newline > maxLineBytes) {
          protocolFailure("execution helper reply exceeded IPC limit");
          return;
        }
        const line = stdout.subarray(0, newline).toString("utf8");
        stdout = stdout.subarray(newline + 1);
        if (!line.trim()) {
          protocolFailure("execution helper emitted a blank protocol line");
          return;
        }
        handleLine(line);
      }
      if (stdout.length > maxLineBytes) {
        protocolFailure("execution helper reply exceeded IPC limit");
      }
    });

    next.stderr.on("data", (chunk) => {
      if (next !== child) return;
      const bytes = Buffer.byteLength(chunk);
      stderrBytes += bytes;
      hooks.onDiagnostic?.({ event: "execution_helper_stderr", bytes });
      if (stderrBytes > maxStderrBytes) {
        protocolFailure("execution helper diagnostics exceeded limit");
      }
    });

    next.stdin.on("error", () => {
      if (next !== child) return;
      protocolFailure("execution helper request write failed");
    });

    next.on("error", () => {
      if (next !== child) return;
      settle(new Error("execution helper failed to start"));
      stopChild();
    });

    next.on("exit", () => {
      if (next !== child) return;
      child = null;
      helperSessionId = null;
      stdout = Buffer.alloc(0);
      stderrBytes = 0;
      settle(new Error("execution helper exited before a complete reply"));
    });
  }

  function ensureChild() {
    if (child) return child;
    const next = spawnImpl(command, args, {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    if (!next?.stdin || !next?.stdout || !next?.stderr || typeof next.kill !== "function") {
      throw new Error("execution helper process is invalid");
    }
    bind(next);
    return next;
  }

  function query(rawRequest) {
    let request;
    try {
      request = validateExecutionQueryRequest(rawRequest);
    } catch (error) {
      return Promise.reject(error);
    }
    if (pending) {
      return Promise.reject(new Error("execution helper query already in flight"));
    }
    const timeoutMs = startupTimeoutMs + request.specificDates.length * perDateTimeoutMs + ipcAllowanceMs;
    if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0) {
      return Promise.reject(new Error("execution helper timeout configuration is invalid"));
    }
    return new Promise((resolve, reject) => {
      let active;
      try {
        active = ensureChild();
      } catch (error) {
        reject(error);
        return;
      }
      const timer = setTimer(() => {
        if (pending?.request.cycleId !== request.cycleId) return;
        settle(new Error("execution helper query timed out"));
        stopChild();
      }, timeoutMs);
      pending = { request, resolve, reject, timer };
      try {
        active.stdin.write(`${JSON.stringify(request)}\n`, (error) => {
          if (error && pending?.request.cycleId === request.cycleId) {
            protocolFailure("execution helper request write failed");
          }
        });
      } catch {
        if (pending?.request.cycleId === request.cycleId) {
          protocolFailure("execution helper request write failed");
        }
      }
    });
  }

  return {
    query,
    stop(reason = "execution helper stopped") {
      settle(new Error(reason));
      stopChild();
    },
    get running() { return Boolean(child); },
    get requestInFlight() { return Boolean(pending); },
    get sessionId() { return helperSessionId; },
  };
}
