import { createHash, randomBytes } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

import * as reconciliationIdentity from "./execution-reconciliation.mjs";
import {
  RETENTION_CONTRACT,
  retentionWindowAt,
  transitionRetentionReadiness,
} from "./retention-windows.mjs";

export const RECONCILIATION_RECEIPT_JOURNAL_SCHEMA = "inspr.joe.reconciliation-receipt-journal.v1";
export const RECONCILIATION_RECEIPT_JOURNAL_TRUST_BOUNDARY = "OPERATOR_CONFIGURED_LOCAL_STATE";

const MAX_STATE_BYTES = 32 * 1024 * 1024;
const MAX_JOURNAL_RECORDS = 4_096;
const MAX_TEXT = 256;
const SHA256 = /^[0-9a-f]{64}$/;
const JOURNAL_KEYS = [
  "schema",
  "trustBoundary",
  "account",
  "configuredProviderId",
  "configuredGatewayTimeZone",
  "receiptSetDigest",
  "records",
  "readiness",
];
const RECORD_KEYS = ["receiptId", "conflict", "receipt"];
const READINESS_KEYS = ["receiptSetDigest", "recordCount", "receiptIds", "resultDigest", "result"];
const READINESS_RESULT_KEYS = [
  "schema",
  "status",
  "baselineRequired",
  "reason",
  "providerId",
  "gatewayTimeZone",
  "evaluatedAt",
  "observedThrough",
  "maxReplayAgeMs",
  "reconciledWindows",
  "unreconciledWindows",
  "unresolvedConflictWindows",
  "invalidatedReceiptIdsByWindow",
];
const WINDOW_KEYS = ["schema", "timeZone", "localDate", "begin", "end", "durationMs"];
const RECONCILED_WINDOW_KEYS = ["ok", "complete", "window", "providerId", "receiptIds"];
const INVALIDATED_WINDOW_KEYS = ["window", "receiptIds"];

export class ReconciliationReceiptJournalError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "ReconciliationReceiptJournalError";
    this.code = code;
  }
}

function fail(code, message) {
  throw new ReconciliationReceiptJournalError(code, message);
}

function record(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    fail("INVALID_STATE", `${label} must be an object`);
  }
  return value;
}

function exactKeys(value, keys, label) {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    fail("INVALID_STATE", `${label} fields are not canonical`);
  }
}

function text(value, label) {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > MAX_TEXT ||
    value.trim() !== value ||
    [...value].some((character) => character.codePointAt(0) < 32)
  ) fail("INVALID_STATE", `${label} is invalid`);
  return value;
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function canonicalJson(value, ancestors = new Set()) {
  if (value === null || typeof value === "boolean" || typeof value === "string") {
    return JSON.stringify(value);
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) fail("INVALID_STATE", "canonical state contains a non-finite number");
    return JSON.stringify(Object.is(value, -0) ? 0 : value);
  }
  if (typeof value !== "object") fail("INVALID_STATE", "canonical state contains a non-JSON value");
  if (ancestors.has(value)) fail("INVALID_STATE", "canonical state contains a cycle");
  ancestors.add(value);
  let encoded;
  if (Array.isArray(value)) {
    encoded = `[${value.map((item) => canonicalJson(item, ancestors)).join(",")}]`;
  } else {
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== Object.prototype && prototype !== null) {
      fail("INVALID_STATE", "canonical state contains a non-plain object");
    }
    encoded = `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${canonicalJson(value[key], ancestors)}`).join(",")}}`;
  }
  ancestors.delete(value);
  return encoded;
}

function digestCanonical(value) {
  return sha256(Buffer.from(canonicalJson(value), "utf8"));
}

function deepFreeze(value) {
  if (!value || typeof value !== "object" || Object.isFrozen(value)) return value;
  for (const nested of Object.values(value)) deepFreeze(nested);
  return Object.freeze(value);
}

function canonicalTimeZone(value) {
  const supplied = text(value, "configuredGatewayTimeZone");
  let canonical;
  try {
    canonical = new Intl.DateTimeFormat("en-US", { timeZone: supplied }).resolvedOptions().timeZone;
  } catch {
    fail("INVALID_CONFIG", "configuredGatewayTimeZone must be an explicit IANA time zone");
  }
  if (canonical !== supplied) fail("INVALID_CONFIG", "configuredGatewayTimeZone must use its canonical IANA name");
  return canonical;
}

function canonicalUtc(value, label) {
  const supplied = text(value, label);
  const parsed = Date.parse(supplied);
  if (!Number.isFinite(parsed) || new Date(parsed).toISOString() !== supplied) {
    fail("INVALID_STATE", `${label} must be a canonical UTC timestamp`);
  }
  return supplied;
}

function identityApi() {
  const required = [
    "normalizeReconciliationReceipt",
    "canonicalReconciliationReceiptId",
    "reconciliationJournalEntry",
  ];
  if (required.some((name) => typeof reconciliationIdentity[name] !== "function")) {
    fail("IDENTITY_API_UNAVAILABLE", "reconciliation receipt identity API is not integrated in this worktree");
  }
  return reconciliationIdentity;
}

function receiptComparable(receipt) {
  const { verifiedAt: _verifiedAt, ...facts } = receipt;
  return facts;
}

function normalizeStoredReceipt(value) {
  const api = identityApi();
  let normalized;
  try {
    normalized = api.normalizeReconciliationReceipt(value);
  } catch (error) {
    fail("INVALID_RECEIPT", `stored reconciliation receipt is invalid: ${error?.message || error}`);
  }
  if (canonicalJson(value) !== canonicalJson(normalized)) {
    fail("INVALID_RECEIPT", "stored reconciliation receipt content is not canonical");
  }
  return normalized;
}

function normalizeStoredRecord(value, account) {
  const supplied = record(value, "journal record");
  exactKeys(supplied, RECORD_KEYS, "journal record");
  if (typeof supplied.conflict !== "boolean") fail("INVALID_RECEIPT", "journal record conflict is invalid");
  if (typeof supplied.receiptId !== "string" || !SHA256.test(supplied.receiptId)) {
    fail("INVALID_RECEIPT", "journal record receiptId is invalid");
  }
  const receipt = normalizeStoredReceipt(supplied.receipt);
  if (receipt.account !== account) fail("BINDING_MISMATCH", "journal receipt account differs from configured account");
  let expectedId;
  try {
    expectedId = identityApi().canonicalReconciliationReceiptId(receipt);
  } catch (error) {
    fail("INVALID_RECEIPT", `journal receipt ID cannot be derived: ${error?.message || error}`);
  }
  if (expectedId !== supplied.receiptId) fail("RECEIPT_ID_CONFLICT", "journal receiptId does not match canonical receipt facts");
  return deepFreeze({ receiptId: expectedId, conflict: supplied.conflict, receipt });
}

function normalizeBrandedOutcome(value, account) {
  let entry;
  try {
    entry = identityApi().reconciliationJournalEntry(value);
  } catch (error) {
    fail("UNTRUSTED_OUTCOME", `journal ingress requires a branded reconciliation outcome: ${error?.message || error}`);
  }
  const supplied = record(entry, "reconciliation journal entry");
  exactKeys(supplied, RECORD_KEYS, "reconciliation journal entry");
  return normalizeStoredRecord(supplied, account);
}

function validateRecordSequence(values, account) {
  if (!Array.isArray(values) || values.length > MAX_JOURNAL_RECORDS) {
    fail("JOURNAL_LIMIT", "journal records exceed the explicit bound");
  }
  const records = values.map((value) => normalizeStoredRecord(value, account));
  const byId = new Map();
  const rawDigestToId = new Map();
  for (const entry of records) {
    const rawDigest = entry.receipt.rawArtifactSha256;
    const rawOwner = rawDigestToId.get(rawDigest);
    if (rawOwner && rawOwner !== entry.receiptId) {
      fail("RAW_DIGEST_REBOUND", "raw artifact digest is rebound to different receipt facts");
    }
    rawDigestToId.set(rawDigest, entry.receiptId);
    const prior = byId.get(entry.receiptId);
    if (!prior) {
      byId.set(entry.receiptId, entry);
      continue;
    }
    if (canonicalJson(prior.receipt) !== canonicalJson(entry.receipt)) {
      fail("RECEIPT_ID_CONFLICT", "one receiptId is bound to different stored content");
    }
    if (prior.conflict || !entry.conflict) {
      fail("INVALID_RECEIPT", "duplicate journal record is not a monotonic conflict promotion");
    }
    byId.set(entry.receiptId, deepFreeze({ ...prior, conflict: true }));
  }
  return deepFreeze(records);
}

function activeRecords(records, count = records.length) {
  const active = new Map();
  for (const entry of records.slice(0, count)) {
    const prior = active.get(entry.receiptId);
    active.set(entry.receiptId, prior
      ? deepFreeze({ ...prior, conflict: prior.conflict || entry.conflict })
      : entry);
  }
  return [...active.values()].sort((left, right) => left.receiptId.localeCompare(right.receiptId));
}

function recordSetDigest(records, count = records.length) {
  return digestCanonical(records.slice(0, count));
}

function receiptIds(records, count = records.length) {
  return activeRecords(records, count).map((entry) => entry.receiptId);
}

function normalizeReceiptReferences(value, label, knownReceiptIds) {
  if (!Array.isArray(value) || value.length === 0) {
    fail("INVALID_READINESS", `${label} must be a non-empty receipt ID array`);
  }
  const normalized = value.map((id) => {
    if (typeof id !== "string" || !SHA256.test(id) || !knownReceiptIds.has(id)) {
      fail("UNKNOWN_RECEIPT_REFERENCE", `${label} contains an unknown journal receipt`);
    }
    return id;
  });
  const canonical = [...new Set(normalized)].sort();
  if (canonicalJson(value) !== canonicalJson(canonical)) {
    fail("INVALID_READINESS", `${label} must contain sorted unique receipt IDs`);
  }
  return canonical;
}

function normalizePersistedWindow(value, config, label) {
  const supplied = record(value, label);
  exactKeys(supplied, WINDOW_KEYS, label);
  let derived;
  try {
    derived = retentionWindowAt({ instant: supplied.begin, timeZone: config.configuredGatewayTimeZone });
  } catch (error) {
    fail("INVALID_READINESS", `${label} is invalid: ${error?.message || error}`);
  }
  if (canonicalJson(supplied) !== canonicalJson(derived)) {
    fail("INVALID_READINESS", `${label} is not a canonical configured-calendar window`);
  }
  return derived;
}

function canonicalWindowOrder(values, label) {
  const begins = values.map((value) => value.window?.begin || value.begin);
  if (new Set(begins).size !== begins.length || canonicalJson(begins) !== canonicalJson([...begins].sort())) {
    fail("INVALID_READINESS", `${label} must contain sorted unique windows`);
  }
}

function normalizeReadinessResult(value, config, knownReceiptIds) {
  const result = record(value, "persisted readiness result");
  exactKeys(result, READINESS_RESULT_KEYS, "persisted readiness result");
  if (
    result.schema !== RETENTION_CONTRACT.stateSchema ||
    !["ready", "blocked"].includes(result.status) ||
    result.baselineRequired !== false
  ) fail("INVALID_READINESS", "persisted readiness result is not a reducer-owned ready/blocked state");
  if (result.providerId !== config.configuredProviderId) {
    fail("BINDING_MISMATCH", "persisted readiness provider differs from journal configuration");
  }
  if (result.gatewayTimeZone !== config.configuredGatewayTimeZone) {
    fail("BINDING_MISMATCH", "persisted readiness calendar differs from journal configuration");
  }
  canonicalUtc(result.evaluatedAt, "persisted readiness evaluatedAt");
  canonicalUtc(result.observedThrough, "persisted readiness observedThrough");
  if (result.status === "ready" ? result.reason !== null : typeof result.reason !== "string" || result.reason.length === 0) {
    fail("INVALID_READINESS", "persisted readiness reason is inconsistent with status");
  }
  if (result.status === "blocked") text(result.reason, "persisted readiness reason");
  if (result.maxReplayAgeMs !== null && (!Number.isSafeInteger(result.maxReplayAgeMs) || result.maxReplayAgeMs <= 0)) {
    fail("INVALID_READINESS", "persisted readiness maxReplayAgeMs is invalid");
  }
  for (const field of ["reconciledWindows", "unreconciledWindows", "unresolvedConflictWindows", "invalidatedReceiptIdsByWindow"]) {
    if (!Array.isArray(result[field])) fail("INVALID_READINESS", `persisted readiness ${field} is invalid`);
  }
  const reconciled = result.reconciledWindows.map((value, index) => {
    const item = record(value, `persisted reconciled window ${index}`);
    exactKeys(item, RECONCILED_WINDOW_KEYS, `persisted reconciled window ${index}`);
    if (item.ok !== true || item.complete !== true || item.providerId !== config.configuredProviderId) {
      fail("INVALID_READINESS", "persisted reconciliation is not a complete configured-provider result");
    }
    const window = normalizePersistedWindow(item.window, config, `persisted reconciled window ${index}.window`);
    normalizeReceiptReferences(item.receiptIds, `persisted reconciled window ${index}.receiptIds`, knownReceiptIds);
    return { window };
  });
  canonicalWindowOrder(reconciled, "persisted reconciled windows");
  const unreconciled = result.unreconciledWindows.map((window, index) => ({
    window: normalizePersistedWindow(window, config, `persisted unreconciled window ${index}`),
  }));
  canonicalWindowOrder(unreconciled, "persisted unreconciled windows");
  const unresolved = result.unresolvedConflictWindows.map((window, index) => ({
    window: normalizePersistedWindow(window, config, `persisted unresolved conflict window ${index}`),
  }));
  canonicalWindowOrder(unresolved, "persisted unresolved conflict windows");
  const invalidated = new Set();
  const invalidatedWindows = result.invalidatedReceiptIdsByWindow.map((value, index) => {
    const item = record(value, `persisted invalidated receipt window ${index}`);
    exactKeys(item, INVALIDATED_WINDOW_KEYS, `persisted invalidated receipt window ${index}`);
    const window = normalizePersistedWindow(item.window, config, `persisted invalidated receipt window ${index}.window`);
    const ids = normalizeReceiptReferences(
      item.receiptIds,
      `persisted invalidated receipt window ${index}.receiptIds`,
      knownReceiptIds,
    );
    for (const id of ids) {
      invalidated.add(id);
    }
    return { window };
  });
  canonicalWindowOrder(invalidatedWindows, "persisted invalidated receipt windows");
  const validation = transitionRetentionReadiness({
    prior: result,
    now: result.evaluatedAt,
    gatewayTimeZone: config.configuredGatewayTimeZone,
    finalEvidence: [],
    freshReplay: null,
    maxReplayAgeMs: result.maxReplayAgeMs || 1,
  });
  if (validation.status === "needs-baseline") {
    fail("INVALID_READINESS", `persisted readiness violates reducer invariants: ${validation.reason}`);
  }
  return { result: deepFreeze(result), invalidated };
}

function normalizeReadiness(value, records, config) {
  if (value === null) return { binding: null, current: false, reason: "readiness has not been cumulatively computed" };
  const supplied = record(value, "persisted readiness binding");
  exactKeys(supplied, READINESS_KEYS, "persisted readiness binding");
  if (!Number.isSafeInteger(supplied.recordCount) || supplied.recordCount < 0 || supplied.recordCount > records.length) {
    fail("INVALID_READINESS", "persisted readiness recordCount is invalid");
  }
  const expectedDigest = recordSetDigest(records, supplied.recordCount);
  if (supplied.receiptSetDigest !== expectedDigest) {
    fail("HEAD_MISMATCH", "persisted readiness receipt-set head changed");
  }
  const expectedIds = receiptIds(records, supplied.recordCount);
  if (!Array.isArray(supplied.receiptIds) || canonicalJson(supplied.receiptIds) !== canonicalJson(expectedIds)) {
    fail("UNKNOWN_RECEIPT_REFERENCE", "persisted readiness receipt references do not match its journal head");
  }
  const normalizedResult = normalizeReadinessResult(supplied.result, config, new Set(expectedIds));
  if (typeof supplied.resultDigest !== "string" || supplied.resultDigest !== digestCanonical(supplied.result)) {
    fail("INVALID_READINESS", "persisted readiness result digest is invalid");
  }
  const conflictIds = activeRecords(records, supplied.recordCount)
    .filter((entry) => entry.conflict)
    .map((entry) => entry.receiptId);
  if (conflictIds.some((id) => !normalizedResult.invalidated.has(id))) {
    fail("UNACKNOWLEDGED_CONFLICT", "persisted readiness omits a conflicting receipt");
  }
  const binding = deepFreeze({
    receiptSetDigest: expectedDigest,
    recordCount: supplied.recordCount,
    receiptIds: expectedIds,
    resultDigest: supplied.resultDigest,
    result: normalizedResult.result,
  });
  const current = supplied.recordCount === records.length && expectedDigest === recordSetDigest(records);
  return {
    binding,
    current,
    reason: current ? null : "journal head advanced after the persisted readiness calculation",
  };
}

function normalizeConfig({ account, configuredProviderId, configuredGatewayTimeZone } = {}) {
  return deepFreeze({
    account: text(account, "account"),
    configuredProviderId: text(configuredProviderId, "configuredProviderId"),
    configuredGatewayTimeZone: canonicalTimeZone(configuredGatewayTimeZone),
  });
}

function normalizeJournal(value, config) {
  const journal = record(value, "receipt journal");
  exactKeys(journal, JOURNAL_KEYS, "receipt journal");
  if (journal.schema !== RECONCILIATION_RECEIPT_JOURNAL_SCHEMA) fail("INVALID_STATE", "receipt journal schema is invalid");
  if (journal.trustBoundary !== RECONCILIATION_RECEIPT_JOURNAL_TRUST_BOUNDARY) {
    fail("INVALID_STATE", "receipt journal trust boundary is invalid");
  }
  if (
    journal.account !== config.account ||
    journal.configuredProviderId !== config.configuredProviderId ||
    journal.configuredGatewayTimeZone !== config.configuredGatewayTimeZone
  ) fail("BINDING_MISMATCH", "receipt journal account/provider/calendar binding changed");
  const records = validateRecordSequence(journal.records, config.account);
  const digest = recordSetDigest(records);
  if (journal.receiptSetDigest !== digest) fail("HEAD_MISMATCH", "receipt journal head digest is invalid");
  const readiness = normalizeReadiness(journal.readiness, records, config);
  return {
    journal: deepFreeze({
      schema: RECONCILIATION_RECEIPT_JOURNAL_SCHEMA,
      trustBoundary: RECONCILIATION_RECEIPT_JOURNAL_TRUST_BOUNDARY,
      ...config,
      receiptSetDigest: digest,
      records,
      readiness: readiness.binding,
    }),
    readinessCurrent: readiness.current,
    readinessReason: readiness.reason,
  };
}

function emptyJournal(config) {
  return deepFreeze({
    schema: RECONCILIATION_RECEIPT_JOURNAL_SCHEMA,
    trustBoundary: RECONCILIATION_RECEIPT_JOURNAL_TRUST_BOUNDARY,
    ...config,
    receiptSetDigest: recordSetDigest([]),
    records: [],
    readiness: null,
  });
}

function readStateFile(filePath, fsImpl) {
  let handle;
  try {
    handle = fsImpl.openSync(filePath, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    const stat = fsImpl.fstatSync(handle);
    if (!stat.isFile() || (stat.mode & 0o777) !== 0o600 || stat.size <= 0 || stat.size > MAX_STATE_BYTES) {
      return { ok: false, reason: "receipt journal file type, mode, or size is unsafe" };
    }
    const bytes = Buffer.alloc(stat.size + 1);
    let count = 0;
    while (count < bytes.length) {
      const amount = fsImpl.readSync(handle, bytes, count, bytes.length - count, null);
      if (amount === 0) break;
      count += amount;
    }
    if (count !== stat.size) return { ok: false, reason: "receipt journal changed size during read" };
    return { ok: true, source: bytes.subarray(0, count).toString("utf8") };
  } catch (error) {
    if (error?.code === "ENOENT") return { ok: true, source: null };
    return { ok: false, reason: `receipt journal read failed: ${error?.code || error}` };
  } finally {
    if (handle !== undefined) fsImpl.closeSync(handle);
  }
}

function writeStateFile(filePath, journal, config, fsImpl) {
  normalizeJournal(journal, config);
  const body = `${JSON.stringify(journal, null, 2)}\n`;
  if (Buffer.byteLength(body) > MAX_STATE_BYTES) fail("JOURNAL_LIMIT", "receipt journal exceeds its byte bound");
  const directory = path.dirname(filePath);
  const temporary = path.join(
    directory,
    `.${path.basename(filePath)}.${process.pid}.${randomBytes(8).toString("hex")}.tmp`,
  );
  let handle;
  try {
    handle = fsImpl.openSync(
      temporary,
      fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW,
      0o600,
    );
    fsImpl.writeFileSync(handle, body, "utf8");
    fsImpl.fsyncSync(handle);
    fsImpl.closeSync(handle);
    handle = undefined;
    fsImpl.renameSync(temporary, filePath);
    const directoryHandle = fsImpl.openSync(directory, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY);
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
}

function appendCanonicalEntries(journal, entries) {
  const records = [...journal.records];
  const active = new Map(activeRecords(records).map((entry) => [entry.receiptId, entry]));
  const rawOwners = new Map(activeRecords(records).map((entry) => [entry.receipt.rawArtifactSha256, entry.receiptId]));
  let changed = false;
  for (const entry of entries) {
    const rawOwner = rawOwners.get(entry.receipt.rawArtifactSha256);
    if (rawOwner && rawOwner !== entry.receiptId) {
      fail("RAW_DIGEST_REBOUND", "raw artifact digest is rebound to different receipt facts");
    }
    const prior = active.get(entry.receiptId);
    if (prior) {
      if (canonicalJson(receiptComparable(prior.receipt)) !== canonicalJson(receiptComparable(entry.receipt))) {
        fail("RECEIPT_ID_CONFLICT", "one receiptId is rebound to different canonical facts");
      }
      if (!prior.conflict && entry.conflict) {
        const promotion = deepFreeze({ receiptId: prior.receiptId, conflict: true, receipt: prior.receipt });
        records.push(promotion);
        active.set(prior.receiptId, promotion);
        changed = true;
      }
      continue;
    }
    if (records.length >= MAX_JOURNAL_RECORDS) fail("JOURNAL_LIMIT", "journal record bound is exhausted");
    records.push(entry);
    active.set(entry.receiptId, entry);
    rawOwners.set(entry.receipt.rawArtifactSha256, entry.receiptId);
    changed = true;
  }
  if (records.length > MAX_JOURNAL_RECORDS) fail("JOURNAL_LIMIT", "journal record bound is exhausted");
  return { records: deepFreeze(records), changed };
}

function cumulativeEvidence(journal, priorReadiness) {
  const invalidated = new Set();
  for (const item of priorReadiness?.invalidatedReceiptIdsByWindow || []) {
    for (const receiptId of item.receiptIds) invalidated.add(receiptId);
  }
  return deepFreeze(activeRecords(journal.records)
    .filter((entry) => !invalidated.has(entry.receiptId))
    .map((entry) => ({
      schema: RETENTION_CONTRACT.evidenceSchema,
      providerId: journal.configuredProviderId,
      calendarTimeZone: journal.configuredGatewayTimeZone,
      receiptId: entry.receiptId,
      finality: "validated-final",
      executionSetMatch: "exact",
      conflict: entry.conflict,
      begin: entry.receipt.coverage.fromInclusive,
      end: entry.receipt.coverage.toExclusive,
    })));
}

function buildReadinessBinding(journal, result, config) {
  const ids = receiptIds(journal.records);
  const normalized = normalizeReadinessResult(result, config, new Set(ids));
  const conflicts = activeRecords(journal.records).filter((entry) => entry.conflict);
  if (conflicts.some((entry) => !normalized.invalidated.has(entry.receiptId))) {
    fail("UNACKNOWLEDGED_CONFLICT", "reducer result did not retain every cumulative conflict");
  }
  return deepFreeze({
    receiptSetDigest: journal.receiptSetDigest,
    recordCount: journal.records.length,
    receiptIds: ids,
    resultDigest: digestCanonical(result),
    result,
  });
}

/**
 * Creates an explicitly configured, single-writer journal. The local hashes
 * detect accidental drift; they do not authenticate a malicious disk rewrite.
 * No provider, calendar, account, path, or trusted baseline is inferred.
 *
 * `load()` exposes saved state for diagnostics only and never authorizes use.
 * Only a successful `recomputeReadiness()` (or `transition()`, which invokes
 * it) can return `ready: true` after checking a caller-supplied current clock
 * and replay. Lock files intentionally survive abnormal process termination;
 * an operator must prove the prior writer is dead before removing a stale lock.
 * This module never guesses staleness or deletes a lock automatically.
 */
export function createFileReconciliationReceiptJournal(
  filePath,
  { account, configuredProviderId, configuredGatewayTimeZone, fsImpl = fs } = {},
) {
  if (typeof filePath !== "string" || !path.isAbsolute(filePath)) {
    throw new TypeError("reconciliation receipt journal path must be absolute");
  }
  const config = normalizeConfig({ account, configuredProviderId, configuredGatewayTimeZone });
  identityApi();
  const lockPath = `${filePath}.lock`;
  let lockHandle;
  let lockCreated = false;
  let closed = false;
  try {
    lockHandle = fsImpl.openSync(
      lockPath,
      fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW,
      0o600,
    );
    lockCreated = true;
    fsImpl.writeFileSync(lockHandle, "single-writer\n", "utf8");
    fsImpl.fsyncSync(lockHandle);
  } catch (error) {
    if (lockHandle !== undefined) {
      try { fsImpl.closeSync(lockHandle); } catch {}
    }
    if (lockCreated) {
      try { fsImpl.unlinkSync(lockPath); } catch {}
    }
    throw new ReconciliationReceiptJournalError(
      "SINGLE_WRITER_CONFLICT",
      `reconciliation receipt journal writer lock failed: ${error?.code || error}`,
    );
  }

  function assertOpen() {
    if (closed) fail("STORE_CLOSED", "reconciliation receipt journal store is closed");
  }

  function load() {
    assertOpen();
    const read = readStateFile(filePath, fsImpl);
    if (!read.ok) return read;
    if (read.source === null) {
      return {
        ok: true,
        journal: null,
        readyForUse: false,
        needsRecomputation: true,
        reason: "receipt journal does not exist",
      };
    }
    let parsed;
    try {
      parsed = JSON.parse(read.source);
    } catch {
      return { ok: false, reason: "receipt journal JSON is truncated or invalid" };
    }
    try {
      const normalized = normalizeJournal(parsed, config);
      const savedStatus = normalized.journal.readiness?.result.status || null;
      return {
        ok: true,
        journal: normalized.journal,
        readyForUse: false,
        needsRecomputation: true,
        reason: normalized.readinessCurrent
          ? `saved ${savedStatus} readiness is diagnostic only; fresh recomputation is required`
          : normalized.readinessReason,
      };
    } catch (error) {
      return { ok: false, reason: error?.message || String(error) };
    }
  }

  function requireLoaded() {
    const loaded = load();
    if (!loaded.ok) fail("LOAD_FAILED", loaded.reason);
    return loaded;
  }

  function appendOutcomes(outcomes) {
    assertOpen();
    if (!Array.isArray(outcomes) || outcomes.length > MAX_JOURNAL_RECORDS) {
      fail("INVALID_INPUT", "reconciliation outcomes must be an array within the explicit record bound");
    }
    const entries = outcomes.map((outcome) => normalizeBrandedOutcome(outcome, config.account));
    const loaded = requireLoaded();
    const journal = loaded.journal || emptyJournal(config);
    const appended = appendCanonicalEntries(journal, entries);
    if (!appended.changed) return { ...loaded, journal, changed: false };
    const next = deepFreeze({
      ...journal,
      records: appended.records,
      receiptSetDigest: recordSetDigest(appended.records),
    });
    writeStateFile(filePath, next, config, fsImpl);
    return { ...requireLoaded(), changed: true };
  }

  function recomputeReadiness({ operatorBaseline, now, freshReplay, maxReplayAgeMs } = {}) {
    assertOpen();
    const loaded = requireLoaded();
    const journal = loaded.journal || emptyJournal(config);
    if (journal.readiness && operatorBaseline !== undefined) {
      fail("BASELINE_RESET_FORBIDDEN", "operatorBaseline cannot replace persisted reducer readiness");
    }
    const prior = journal.readiness?.result || operatorBaseline;
    if (!prior) {
      return {
        ok: false,
        ready: false,
        persisted: false,
        reason: "an external trusted operator baseline is required for first computation",
        journal,
      };
    }
    const finalEvidence = cumulativeEvidence(journal, prior);
    const result = transitionRetentionReadiness({
      prior,
      now,
      gatewayTimeZone: config.configuredGatewayTimeZone,
      finalEvidence,
      freshReplay,
      maxReplayAgeMs,
    });
    if (result.status === "needs-baseline") {
      return {
        ok: false,
        ready: false,
        persisted: false,
        reason: result.reason,
        result,
        journal,
      };
    }
    let readiness;
    try {
      readiness = buildReadinessBinding(journal, result, config);
    } catch (error) {
      return {
        ok: true,
        ready: false,
        persisted: false,
        reason: result.reason || error?.message || String(error),
        persistenceReason: error?.message || String(error),
        result,
        journal,
      };
    }
    const next = deepFreeze({ ...journal, readiness });
    writeStateFile(filePath, next, config, fsImpl);
    const saved = requireLoaded();
    const savedAtHead = (
      saved.journal.readiness?.recordCount === saved.journal.records.length &&
      saved.journal.readiness?.receiptSetDigest === saved.journal.receiptSetDigest
    );
    return {
      ok: true,
      ready: savedAtHead && saved.journal.readiness.result.status === "ready",
      persisted: true,
      reason: result.reason,
      result,
      journal: saved.journal,
    };
  }

  function transition({ outcomes = [], operatorBaseline, now, freshReplay, maxReplayAgeMs } = {}) {
    appendOutcomes(outcomes);
    return recomputeReadiness({ operatorBaseline, now, freshReplay, maxReplayAgeMs });
  }

  function close() {
    if (closed) return;
    closed = true;
    try {
      fsImpl.closeSync(lockHandle);
    } finally {
      try { fsImpl.unlinkSync(lockPath); } finally {
        const directoryHandle = fsImpl.openSync(path.dirname(lockPath), fs.constants.O_RDONLY | fs.constants.O_DIRECTORY);
        try { fsImpl.fsyncSync(directoryHandle); } finally { fsImpl.closeSync(directoryHandle); }
      }
    }
  }

  return Object.freeze({ load, appendOutcomes, recomputeReadiness, transition, close });
}

export const RECONCILIATION_RECEIPT_JOURNAL_LIMITS = Object.freeze({
  maxStateBytes: MAX_STATE_BYTES,
  maxRecords: MAX_JOURNAL_RECORDS,
});
