import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

import { EXECUTION_CAPTURE_SCHEMA } from "./execution-reconciliation.mjs";

const MAX_ARTIFACT_BYTES = 32 * 1024 * 1024;
const MAX_RECORDS = 50_000;

export const J_FAMILY_CLASSIFIER = Object.freeze({
  familyClientIds: Object.freeze([27, 28, 29, 50, 51, 52, 53, 54, 55, 56]),
  excludedSymbols: Object.freeze(["SXR8", "TSLA"]),
});

function fail(message) {
  throw new Error(message);
}

function text(value, label) {
  if (typeof value !== "string" || !value.trim()) fail(`${label} is invalid`);
  return value.trim();
}

function number(value, label, { positive = false } = {}) {
  let result;
  if (typeof value === "number") {
    result = value;
  } else if (typeof value === "string" && value.trim() === value &&
    /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(value)) {
    result = Number(value);
  } else {
    fail(`${label} is invalid`);
  }
  if (!Number.isFinite(result) || Math.abs(result) === Number.MAX_VALUE || (positive && result <= 0)) {
    fail(`${label} is invalid`);
  }
  return result;
}

function integer(value, label, { positive = false } = {}) {
  const result = number(value, label, { positive });
  if (!Number.isSafeInteger(result) || (!positive && result < 0)) fail(`${label} is invalid`);
  return result;
}

function explicitIso(value, label) {
  const source = text(value, label);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$/.test(source)) {
    fail(`${label} must have an explicit timezone`);
  }
  const epoch = Date.parse(source);
  if (!Number.isFinite(epoch)) fail(`${label} is invalid`);
  return new Date(epoch).toISOString();
}

const formatterCache = new Map();

function formatter(timeZone) {
  let value = formatterCache.get(timeZone);
  if (!value) {
    try {
      value = new Intl.DateTimeFormat("en-CA", {
        timeZone,
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
        hourCycle: "h23",
      });
    } catch {
      fail("execution time zone is unsupported");
    }
    formatterCache.set(timeZone, value);
  }
  return value;
}

function executionTime(value) {
  const source = text(value, "execution time");
  if (/^\d{4}-\d{2}-\d{2}T/.test(source)) return explicitIso(source, "execution time");
  const match = source.match(/^(\d{4})(\d{2})(\d{2})\s+(\d{2}):(\d{2}):(\d{2})\s+(.+)$/);
  if (!match) fail("execution time is unsupported");
  const expected = match.slice(1, 7).map(Number);
  const zone = text(match[7], "execution time zone");
  const format = formatter(zone);
  const naive = Date.UTC(expected[0], expected[1] - 1, expected[2], expected[3], expected[4], expected[5]);
  const candidates = [];
  for (let offset = -14 * 60; offset <= 14 * 60; offset += 15) {
    const candidate = naive - offset * 60_000;
    const actual = {};
    for (const part of format.formatToParts(new Date(candidate))) {
      if (part.type !== "literal") actual[part.type] = Number(part.value);
    }
    if ([actual.year, actual.month, actual.day, actual.hour, actual.minute, actual.second]
      .every((part, index) => part === expected[index])) candidates.push(candidate);
  }
  if (candidates.length !== 1) fail("execution time is invalid or ambiguous");
  return new Date(candidates[0]).toISOString();
}

function readArtifact(filePath, fsImpl = fs) {
  if (typeof filePath !== "string" || !path.isAbsolute(filePath)) fail("source path must be absolute");
  let handle;
  try {
    handle = fsImpl.openSync(filePath, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    const stat = fsImpl.fstatSync(handle);
    if (!stat.isFile() || stat.size <= 0 || stat.size > MAX_ARTIFACT_BYTES) fail("source artifact size is invalid");
    const bytes = Buffer.alloc(stat.size + 1);
    let count = 0;
    while (count < bytes.length) {
      const read = fsImpl.readSync(handle, bytes, count, bytes.length - count, null);
      if (read === 0) break;
      count += read;
    }
    if (count !== stat.size) fail("source artifact changed size during read");
    const body = bytes.subarray(0, count);
    return {
      value: JSON.parse(body.toString("utf8")),
      sha256: createHash("sha256").update(body).digest("hex"),
    };
  } catch (error) {
    if (error instanceof SyntaxError) fail("source artifact is invalid JSON");
    throw error;
  } finally {
    if (handle !== undefined) fsImpl.closeSync(handle);
  }
}

function multiplier(value, secType) {
  if (secType === "STK") {
    if (value === undefined || value === null || value === "") return 1;
    const parsed = number(value, "contract multiplier");
    if (parsed === 0 || parsed === 1) return 1;
    if (parsed <= 0) fail("contract multiplier is invalid");
    return parsed;
  }
  return number(value, "contract multiplier", { positive: true });
}

export function normalizeEconomicExecution(row) {
  if (!row?.contract || !row?.execution) fail("execution record is malformed");
  const contract = row.contract;
  const execution = row.execution;
  const secType = text(contract.secType, "contract secType").toUpperCase();
  const side = { BOT: "BUY", BUY: "BUY", SLD: "SELL", SELL: "SELL" }[text(execution.side, "execution side").toUpperCase()];
  if (!side) fail("execution side is unsupported");
  const currency = text(contract.currency, "contract currency").toUpperCase();
  if (!/^[A-Z]{3}$/.test(currency)) fail("contract currency is invalid");
  return {
    contract: {
      conId: integer(contract.conId, "contract conId", { positive: true }),
      symbol: text(contract.symbol, "contract symbol").toUpperCase(),
      secType,
      currency,
      multiplier: multiplier(contract.multiplier, secType),
    },
    execution: {
      execId: text(execution.execId, "execution execId"),
      time: executionTime(execution.time),
      acctNumber: text(execution.acctNumber, "execution account"),
      clientId: integer(execution.clientId, "execution clientId"),
      side,
      shares: number(execution.shares, "execution shares", { positive: true }),
      price: number(execution.price, "execution price", { positive: true }),
    },
  };
}

export function normalizeEconomicCommission(row) {
  if (!row || typeof row !== "object") fail("commission report is malformed");
  const currency = text(row.currency, "commission currency").toUpperCase();
  if (!/^[A-Z]{3}$/.test(currency)) fail("commission currency is invalid");
  const rawAmount = row.commissionAndFees ?? row.commission;
  const realized = row.realizedPNL;
  const unavailableRealized = realized === undefined || realized === null ||
    realized === Number.MAX_VALUE ||
    (typeof realized === "string" && realized.trim() === realized &&
      /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(realized) &&
      Number(realized) === Number.MAX_VALUE);
  return {
    execId: text(row.execId, "commission execId"),
    commission: number(rawAmount, "commission amount"),
    currency,
    realizedPNL: unavailableRealized
      ? null
      : number(realized, "commission realizedPNL"),
  };
}

function canonicalClassifier(value = J_FAMILY_CLASSIFIER) {
  if (!Array.isArray(value?.familyClientIds) || !value.familyClientIds.length || !Array.isArray(value.excludedSymbols)) {
    fail("classifier is invalid");
  }
  const familyClientIds = [...new Set(value.familyClientIds.map((item) => integer(item, "classifier client ID")))].sort((a, b) => a - b);
  const excludedSymbols = [...new Set(value.excludedSymbols.map((item) => text(item, "classifier excluded symbol").toUpperCase()))].sort();
  return { familyClientIds, excludedSymbols };
}

function captureFromRows({ rows, commissions, account, source, capturedAt, window, classifier, metadata }) {
  if (rows.length > MAX_RECORDS || commissions.length > MAX_RECORDS) fail("source artifact record limit exceeded");
  const executions = rows.map(normalizeEconomicExecution);
  if (!executions.length) fail("source capture has no executions");
  const accounts = new Set(executions.map((row) => row.execution.acctNumber));
  if (accounts.size !== 1 || !accounts.has(account)) fail("source capture account is inconsistent");
  const reports = commissions.map(normalizeEconomicCommission);
  return {
    schema: EXECUTION_CAPTURE_SCHEMA,
    account,
    classifier: canonicalClassifier(classifier),
    source: { ...source, metadata },
    capturedAt: explicitIso(capturedAt, "capture timestamp"),
    window,
    coverageStatus: "known",
    completenessAssertion: null,
    executions,
    commissions: reports,
  };
}

export function captureFromFamilyLedgerFile({ filePath, window, classifier = J_FAMILY_CLASSIFIER, fsImpl = fs } = {}) {
  const artifact = readArtifact(filePath, fsImpl);
  const ledger = artifact.value;
  if (!Array.isArray(ledger.executions) || !Array.isArray(ledger.commissions)) fail("family ledger artifact is malformed");
  const account = text(ledger.account, "family ledger account");
  return captureFromRows({
    rows: ledger.executions,
    commissions: ledger.commissions,
    account,
    source: {
      kind: "persisted-ledger",
      id: `${path.resolve(filePath)}#sha256:${artifact.sha256}`,
      sha256: artifact.sha256,
    },
    capturedAt: ledger.coverageThrough || ledger.ledgerObservedAt,
    window,
    classifier,
    metadata: { adapterId: "family-ledger-json", adapterVersion: "1", sourcePath: path.resolve(filePath) },
  });
}

export function captureFromOfficialProbeFile({ filePath, requestId, window, classifier = J_FAMILY_CLASSIFIER, fsImpl = fs } = {}) {
  const artifact = readArtifact(filePath, fsImpl);
  const evidence = artifact.value;
  const key = String(requestId ?? "");
  const request = evidence?.requests?.[key];
  if (!request || !Array.isArray(request.executions)) fail("official probe request is absent");
  if (request.timedOut !== false || !Array.isArray(request.errors) || request.errors.length !== 0 || !request.endedAt) {
    fail("official probe request did not end cleanly");
  }
  const rows = request.executions;
  if (!rows.length) fail("official probe request has no executions");
  const account = text(rows[0]?.execution?.acctNumber, "official probe account");
  const ids = new Set(rows.map((row) => text(row?.execution?.execId, "execution execId")));
  const reports = Object.values(evidence.commissionsByExecId || {}).filter((row) => ids.has(row?.execId));
  if (reports.length !== ids.size) fail("official probe lacks a commission callback for an execution");
  return captureFromRows({
    rows,
    commissions: reports,
    account,
    source: {
      kind: "paper-api",
      id: `${path.resolve(filePath)}#sha256:${artifact.sha256}#request:${key}`,
      sha256: artifact.sha256,
    },
    capturedAt: request.endedAt,
    window,
    classifier,
    metadata: {
      adapterId: "official-probe-json",
      adapterVersion: "1",
      sourcePath: path.resolve(filePath),
      requestId: key,
      requestLabel: String(request.label || ""),
      sdkPackage: String(evidence.sdk?.package || ""),
      sdkVersion: String(evidence.sdk?.version || ""),
      serverVersion: Number(evidence.negotiated?.serverVersion),
      executionRequestFraming: String(evidence.negotiated?.executionRequestFraming || ""),
      responseEndedCleanly: true,
      completenessClaimed: false,
    },
  });
}
