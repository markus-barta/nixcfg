import { createHash } from "node:crypto";

export const RECONCILIATION_EVIDENCE_SCHEMA = "inspr.joe.execution-reconciliation.v1";
export const RECONCILIATION_RECEIPT_SCHEMA = "inspr.joe.execution-reconciliation-receipt.v1";

const ALL_ACCOUNT = "ALL_ACCOUNT";
const FINAL = "FINAL";
const CORRECTION_SEMANTICS = new Set(["ALL_REVISIONS", "LATEST_EFFECTIVE"]);
const MAX_ARTIFACT_BYTES = 16 * 1024 * 1024;
const MAX_NORMALIZED_BYTES = 16 * 1024 * 1024;
const MAX_RECORDS = 50_000;
const MAX_RECEIPTS = 1_024;
const MAX_ALLOWED_ADAPTERS = 128;
const MAX_TEXT = 256;
const SHA256 = /^[0-9a-f]{64}$/;
const VALIDATED_EVIDENCE = new WeakSet();
const JOURNALABLE_SUCCESSES = new WeakMap();
const JOURNALABLE_OVERLAP_ERRORS = new WeakMap();

export class ReconciliationError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "ReconciliationError";
    this.code = code;
  }
}

function fail(code, message) {
  throw new ReconciliationError(code, message);
}

function plainObject(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    fail("INVALID_INPUT", `${label} must be an object`);
  }
  return value;
}

function exactKeys(value, keys, label) {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    fail("INVALID_INPUT", `${label} fields are not canonical`);
  }
}

function allowedKeys(value, required, optional, label) {
  const keys = Object.keys(value);
  if (required.some((key) => !keys.includes(key))) {
    fail("INVALID_INPUT", `${label} is missing required fields`);
  }
  const allowed = new Set([...required, ...optional]);
  if (keys.some((key) => !allowed.has(key))) {
    fail("INVALID_INPUT", `${label} contains unsupported fields`);
  }
}

function text(value, label, max = MAX_TEXT) {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > max ||
    value.trim() !== value ||
    [...value].some((character) => character.codePointAt(0) < 32)
  ) {
    fail("INVALID_INPUT", `${label} is invalid`);
  }
  return value;
}

function utc(value, label) {
  const raw = text(value, label);
  const match = raw.match(
    /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?Z$/
  );
  if (!match) fail("INVALID_TIME", `${label} must be an explicit UTC timestamp`);
  const fraction = (match[7] || "").padEnd(3, "0");
  const canonical = `${match[1]}-${match[2]}-${match[3]}T${match[4]}:${match[5]}:${match[6]}.${fraction}Z`;
  const epoch = Date.parse(canonical);
  if (!Number.isFinite(epoch) || new Date(epoch).toISOString() !== canonical) {
    fail("INVALID_TIME", `${label} is not a real UTC instant`);
  }
  return canonical;
}

function finite(value, label, { positive = false } = {}) {
  if (
    typeof value !== "number" ||
    !Number.isFinite(value) ||
    Math.abs(value) === Number.MAX_VALUE ||
    (positive && value <= 0)
  ) {
    fail("INVALID_INPUT", `${label} is invalid`);
  }
  return Object.is(value, -0) ? 0 : value;
}

function nonnegativeInteger(value, label) {
  if (!Number.isSafeInteger(value) || value < 0) {
    fail("INVALID_INPUT", `${label} is invalid`);
  }
  return value;
}

function currency(value, label) {
  const code = text(value, label);
  if (!/^[A-Z]{3}$/.test(code)) fail("INVALID_INPUT", `${label} is invalid`);
  return code;
}

function side(value, label) {
  const normalized = text(value, label).toUpperCase();
  const result = { BOT: "BUY", BUY: "BUY", SLD: "SELL", SELL: "SELL" }[normalized];
  if (!result) fail("INVALID_INPUT", `${label} is invalid`);
  return result;
}

function canonicalJson(value, ancestors = new Set()) {
  if (value === null || typeof value === "boolean" || typeof value === "string") {
    return JSON.stringify(value);
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) fail("INVALID_INPUT", "canonical content contains a non-finite number");
    return JSON.stringify(Object.is(value, -0) ? 0 : value);
  }
  if (typeof value !== "object") {
    fail("INVALID_INPUT", "canonical content contains a non-JSON value");
  }
  if (ancestors.has(value)) fail("INVALID_INPUT", "canonical content contains a cycle");
  ancestors.add(value);
  let encoded;
  if (Array.isArray(value)) {
    encoded = `[${value.map((item) => canonicalJson(item, ancestors)).join(",")}]`;
  } else {
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== Object.prototype && prototype !== null) {
      fail("INVALID_INPUT", "canonical content contains a non-plain object");
    }
    encoded = `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${canonicalJson(value[key], ancestors)}`).join(",")}}`;
  }
  ancestors.delete(value);
  return encoded;
}

function sha256Bytes(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function sha256Canonical(value) {
  return sha256Bytes(Buffer.from(canonicalJson(value), "utf8"));
}

function deepFreeze(value) {
  if (!value || typeof value !== "object" || Object.isFrozen(value)) return value;
  for (const nested of Object.values(value)) deepFreeze(nested);
  return Object.freeze(value);
}

function correctionIdentity(execId) {
  const id = text(execId, "execution execId");
  const match = id.match(/^(.*\.)(\d+)$/);
  if (!match || match[1] === ".") {
    fail("INVALID_CORRECTION_CHAIN", "execution execId has no correction revision");
  }
  return { execId: id, prefix: match[1], revision: BigInt(match[2]) };
}

function normalizeEconomics(value) {
  const economics = plainObject(value, "execution economics");
  const fields = ["side", "shares", "price", "currency", "commission", "commissionCurrency"];
  allowedKeys(economics, [], fields, "execution economics");
  if (Object.keys(economics).length === 0) {
    fail("INVALID_INPUT", "execution economics must contain an observed field");
  }
  const normalized = {};
  if ("side" in economics) normalized.side = side(economics.side, "execution economics side");
  if ("shares" in economics) {
    normalized.shares = finite(economics.shares, "execution economics shares", { positive: true });
  }
  if ("price" in economics) {
    normalized.price = finite(economics.price, "execution economics price", { positive: true });
  }
  if ("currency" in economics) {
    normalized.currency = currency(economics.currency, "execution economics currency");
  }
  if ("commission" in economics) {
    normalized.commission = finite(economics.commission, "execution economics commission");
  }
  if ("commissionCurrency" in economics) {
    normalized.commissionCurrency = currency(
      economics.commissionCurrency,
      "execution economics commissionCurrency"
    );
  }
  return normalized;
}

function normalizeEvidenceExecution(value, account, fromEpoch, toEpoch) {
  const row = plainObject(value, "evidence execution");
  if ("clientId" in row) {
    fail("REPORT_ATTRIBUTION_FORBIDDEN", "report evidence must not contain clientId attribution");
  }
  allowedKeys(row, ["execId", "occurredAt", "account"], ["economics"], "evidence execution");
  const execId = correctionIdentity(row.execId).execId;
  const occurredAt = utc(row.occurredAt, "evidence execution occurredAt");
  const executionAccount = text(row.account, "evidence execution account");
  if (executionAccount !== account) {
    fail("ACCOUNT_MISMATCH", "evidence execution account differs from evidence account");
  }
  const epoch = Date.parse(occurredAt);
  if (epoch < fromEpoch || epoch >= toEpoch) {
    fail("COVERAGE_MISMATCH", "evidence execution falls outside the declared UTC interval");
  }
  return {
    execId,
    occurredAt,
    account: executionAccount,
    ...(row.economics === undefined ? {} : { economics: normalizeEconomics(row.economics) }),
  };
}

function validateCorrectionChains(rows, semantics, label) {
  const ids = new Set();
  const groups = new Map();
  for (const row of rows) {
    const identity = correctionIdentity(row.execId);
    if (ids.has(identity.execId)) fail("INVALID_CORRECTION_CHAIN", `${label} repeats an execId`);
    ids.add(identity.execId);
    const group = groups.get(identity.prefix) || [];
    if (group.some((item) => item.revision === identity.revision)) {
      fail("INVALID_CORRECTION_CHAIN", `${label} has conflicting correction revisions`);
    }
    group.push({ ...identity, row });
    groups.set(identity.prefix, group);
  }
  for (const group of groups.values()) {
    group.sort((left, right) => left.revision < right.revision ? -1 : left.revision > right.revision ? 1 : 0);
    if (semantics === "LATEST_EFFECTIVE" && group.length !== 1) {
      fail("INVALID_CORRECTION_CHAIN", "LATEST_EFFECTIVE evidence contains multiple revisions");
    }
  }
  return groups;
}

function normalizeAllowedAdapters(allowedAdapters) {
  if (!Array.isArray(allowedAdapters) || allowedAdapters.length === 0) {
    fail("UNTRUSTED_ADAPTER", "allowed adapter configuration must not be empty");
  }
  if (allowedAdapters.length > MAX_ALLOWED_ADAPTERS) {
    fail("INPUT_LIMIT", "allowed adapter configuration exceeds the supported bound");
  }
  const result = new Set();
  for (const value of allowedAdapters) {
    const adapter = plainObject(value, "allowed adapter");
    exactKeys(adapter, ["adapterId", "adapterVersion"], "allowed adapter");
    const key = `${text(adapter.adapterId, "allowed adapterId")}\u0000${text(
      adapter.adapterVersion,
      "allowed adapterVersion"
    )}`;
    if (result.has(key)) fail("UNTRUSTED_ADAPTER", "allowed adapter configuration is duplicated");
    result.add(key);
  }
  return result;
}

/**
 * Validate provider-neutral normalized evidence against caller-supplied trust
 * configuration and the exact raw artifact bytes. FINAL is source-declared;
 * this function does not establish provider truth and no runtime adapter exists.
 *
 * @param {object} input Normalized evidence; the object is read but never mutated.
 * @param {{rawArtifactBytes: Uint8Array, allowedAdapters: Array<object>}} options
 * @returns {object} A deeply frozen canonical evidence value accepted by the reducer.
 * @throws {ReconciliationError} When any trust, finality, coverage, or size gate fails.
 */
export function validateReconciliationEvidence(
  input,
  { rawArtifactBytes, allowedAdapters } = {}
) {
  const evidence = plainObject(input, "reconciliation evidence");
  exactKeys(evidence, [
    "schema",
    "account",
    "scope",
    "fromInclusive",
    "toExclusive",
    "completeThrough",
    "finality",
    "generatedAt",
    "retrievedAt",
    "correctionSemantics",
    "rawArtifactSha256",
    "adapterId",
    "adapterVersion",
    "executions",
  ], "reconciliation evidence");
  if (evidence.schema !== RECONCILIATION_EVIDENCE_SCHEMA) {
    fail("INVALID_SCHEMA", "reconciliation evidence schema mismatch");
  }
  if (!(rawArtifactBytes instanceof Uint8Array)) {
    fail("RAW_ARTIFACT_MISMATCH", "raw artifact must be supplied as bytes");
  }
  if (rawArtifactBytes.byteLength === 0 || rawArtifactBytes.byteLength > MAX_ARTIFACT_BYTES) {
    fail("INPUT_LIMIT", "raw artifact size is outside the supported bound");
  }
  const adapters = normalizeAllowedAdapters(allowedAdapters);
  const adapterId = text(evidence.adapterId, "evidence adapterId");
  const adapterVersion = text(evidence.adapterVersion, "evidence adapterVersion");
  if (!adapters.has(`${adapterId}\u0000${adapterVersion}`)) {
    fail("UNTRUSTED_ADAPTER", "evidence adapter is not explicitly allowed");
  }
  const rawArtifactSha256 = text(evidence.rawArtifactSha256, "raw artifact SHA-256");
  if (!SHA256.test(rawArtifactSha256) || sha256Bytes(rawArtifactBytes) !== rawArtifactSha256) {
    fail("RAW_ARTIFACT_MISMATCH", "raw artifact SHA-256 does not match supplied bytes");
  }

  const account = text(evidence.account, "evidence account");
  if (evidence.scope !== ALL_ACCOUNT) {
    fail("PARTIAL_SCOPE", "reconciliation evidence must cover ALL_ACCOUNT");
  }
  const fromInclusive = utc(evidence.fromInclusive, "evidence fromInclusive");
  const toExclusive = utc(evidence.toExclusive, "evidence toExclusive");
  const completeThrough = utc(evidence.completeThrough, "evidence completeThrough");
  const fromEpoch = Date.parse(fromInclusive);
  const toEpoch = Date.parse(toExclusive);
  if (fromEpoch >= toEpoch || Date.parse(completeThrough) < toEpoch) {
    fail("COVERAGE_MISMATCH", "evidence does not declare a complete non-empty UTC interval");
  }

  const finality = plainObject(evidence.finality, "evidence finality");
  exactKeys(
    finality,
    ["status", "scope", "fromInclusive", "toExclusive", "assertionId"],
    "evidence finality"
  );
  if (finality.status !== FINAL) {
    fail("PROVISIONAL_EVIDENCE", "evidence lacks an authoritative FINAL assertion");
  }
  if (finality.scope !== ALL_ACCOUNT) {
    fail("PARTIAL_SCOPE", "evidence finality assertion is not ALL_ACCOUNT");
  }
  const finalFrom = utc(finality.fromInclusive, "finality fromInclusive");
  const finalTo = utc(finality.toExclusive, "finality toExclusive");
  if (finalFrom !== fromInclusive || finalTo !== toExclusive) {
    fail("COVERAGE_MISMATCH", "finality assertion does not bind the evidence interval");
  }
  const assertionId = text(finality.assertionId, "finality assertionId");
  const generatedAt = utc(evidence.generatedAt, "evidence generatedAt");
  const retrievedAt = utc(evidence.retrievedAt, "evidence retrievedAt");
  if (Date.parse(generatedAt) < toEpoch || Date.parse(retrievedAt) < Date.parse(generatedAt)) {
    fail("INVALID_TIME", "evidence generation or retrieval timestamps are inconsistent");
  }

  const correctionSemantics = text(evidence.correctionSemantics, "correction semantics");
  if (!CORRECTION_SEMANTICS.has(correctionSemantics)) {
    fail("INVALID_CORRECTION_CHAIN", "evidence correction semantics are unsupported");
  }
  if (!Array.isArray(evidence.executions) || evidence.executions.length > MAX_RECORDS) {
    fail("INPUT_LIMIT", "evidence executions exceed the supported bound");
  }
  const executions = evidence.executions.map((row) =>
    normalizeEvidenceExecution(row, account, fromEpoch, toEpoch));
  const sortedIds = executions.map((row) => row.execId).sort();
  if (executions.some((row, index) => row.execId !== sortedIds[index])) {
    fail("INVALID_INPUT", "evidence executions are not sorted by execId");
  }
  validateCorrectionChains(executions, correctionSemantics, "evidence");

  const normalized = {
    schema: RECONCILIATION_EVIDENCE_SCHEMA,
    account,
    scope: ALL_ACCOUNT,
    fromInclusive,
    toExclusive,
    completeThrough,
    finality: {
      status: FINAL,
      scope: ALL_ACCOUNT,
      fromInclusive: finalFrom,
      toExclusive: finalTo,
      assertionId,
    },
    generatedAt,
    retrievedAt,
    correctionSemantics,
    rawArtifactSha256,
    adapterId,
    adapterVersion,
    executions,
  };
  if (Buffer.byteLength(canonicalJson(normalized), "utf8") > MAX_NORMALIZED_BYTES) {
    fail("INPUT_LIMIT", "normalized evidence exceeds the supported bound");
  }
  const frozen = deepFreeze(normalized);
  VALIDATED_EVIDENCE.add(frozen);
  return frozen;
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

function socketOccurredAt(value) {
  const raw = text(value, "socket execution time");
  if (/^\d{4}-\d{2}-\d{2}T/.test(raw)) return utc(raw, "socket execution time");
  const match = raw.match(
    /^(\d{4})(\d{2})(\d{2})\s+(\d{2}):(\d{2}):(\d{2})\s+(?:US\/Eastern|America\/New_York)$/
  );
  if (!match) fail("INVALID_TIME", "socket execution time has no supported explicit timezone");
  const parts = match.slice(1).map(Number);
  const naive = Date.UTC(parts[0], parts[1] - 1, parts[2], parts[3], parts[4], parts[5]);
  const matches = [];
  for (let offsetMinutes = -14 * 60; offsetMinutes <= 14 * 60; offsetMinutes += 15) {
    const candidate = naive - offsetMinutes * 60_000;
    if (newYorkParts(candidate).every((part, index) => part === parts[index])) matches.push(candidate);
  }
  if (matches.length !== 1) {
    fail("INVALID_TIME", "socket execution time is invalid or ambiguous");
  }
  return new Date(matches[0]).toISOString();
}

function normalizeWindow(value) {
  const window = plainObject(value, "reconciliation window");
  exactKeys(window, ["fromInclusive", "toExclusive"], "reconciliation window");
  const fromInclusive = utc(window.fromInclusive, "window fromInclusive");
  const toExclusive = utc(window.toExclusive, "window toExclusive");
  if (Date.parse(fromInclusive) >= Date.parse(toExclusive)) {
    fail("COVERAGE_MISMATCH", "reconciliation window must be non-empty");
  }
  return { fromInclusive, toExclusive };
}

function normalizeSocketExecution(row, account, window) {
  const record = plainObject(row, "socket execution record");
  const execution = plainObject(record.execution, "socket execution");
  const contract = plainObject(record.contract, "socket contract");
  const execId = correctionIdentity(execution.execId).execId;
  if (text(execution.acctNumber, "socket execution account") !== account) {
    fail("ACCOUNT_MISMATCH", "socket execution account differs from reconciliation account");
  }
  const occurredAt = socketOccurredAt(execution.time);
  const epoch = Date.parse(occurredAt);
  if (epoch < Date.parse(window.fromInclusive) || epoch >= Date.parse(window.toExclusive)) {
    fail("COVERAGE_MISMATCH", "socket execution falls outside the reconciliation window");
  }
  return {
    row,
    execId,
    occurredAt,
    clientId: nonnegativeInteger(execution.clientId, "socket execution clientId"),
    side: side(execution.side, "socket execution side"),
    shares: finite(execution.shares, "socket execution shares", { positive: true }),
    price: finite(execution.price, "socket execution price", { positive: true }),
    currency: currency(contract.currency, "socket contract currency"),
  };
}

function normalizeSocketCommission(row, executionIds) {
  const report = plainObject(row, "socket commission");
  const execId = correctionIdentity(report.execId).execId;
  if (!executionIds.has(execId)) {
    fail("IDENTITY_MISMATCH", "socket commission has no execution in the requested window");
  }
  return {
    row,
    execId,
    commission: finite(report.commission, "socket commission amount"),
    currency: currency(report.currency, "socket commission currency"),
  };
}

function sortedSet(values) {
  return [...new Set(values)].sort();
}

function sameArray(left, right) {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

function effectiveRows(groups) {
  return [...groups.values()]
    .map((group) => group[group.length - 1])
    .sort((left, right) => left.execId < right.execId ? -1 : left.execId > right.execId ? 1 : 0);
}

function assertEconomicsMatch(evidenceRow, socketRow, commissionById) {
  if (evidenceRow.occurredAt !== socketRow.occurredAt) {
    fail("ECONOMICS_MISMATCH", "common execution timestamps differ");
  }
  const economics = evidenceRow.economics;
  if (!economics) return;
  for (const field of ["side", "shares", "price", "currency"]) {
    if (field in economics && economics[field] !== socketRow[field]) {
      fail("ECONOMICS_MISMATCH", `common execution ${field} differs`);
    }
  }
  if ("commission" in economics || "commissionCurrency" in economics) {
    const report = commissionById.get(evidenceRow.execId);
    if (!report) fail("MISSING_SOCKET_FEE", "report economics cannot create a missing socket fee");
    if ("commission" in economics && economics.commission !== report.commission) {
      fail("ECONOMICS_MISMATCH", "common execution commission differs");
    }
    if ("commissionCurrency" in economics && economics.commissionCurrency !== report.currency) {
      fail("ECONOMICS_MISMATCH", "common execution commission currency differs");
    }
  }
}

const RECEIPT_KEYS = [
  "schema",
  "account",
  "scope",
  "adapterId",
  "adapterVersion",
  "rawArtifactSha256",
  "evidenceContentSha256",
  "correctionSemantics",
  "canonicalIdentityDigest",
  "identityCount",
  "coverage",
  "matchedSocketLedgerDigest",
  "verifiedAt",
];

function normalizeReceipt(value) {
  const receipt = plainObject(value, "prior reconciliation receipt");
  exactKeys(receipt, RECEIPT_KEYS, "prior reconciliation receipt");
  if (receipt.schema !== RECONCILIATION_RECEIPT_SCHEMA || receipt.scope !== ALL_ACCOUNT) {
    fail("RECEIPT_CONFLICT", "prior reconciliation receipt schema or scope is invalid");
  }
  for (const field of [
    "rawArtifactSha256",
    "evidenceContentSha256",
    "canonicalIdentityDigest",
    "matchedSocketLedgerDigest",
  ]) {
    if (typeof receipt[field] !== "string" || !SHA256.test(receipt[field])) {
      fail("RECEIPT_CONFLICT", `prior reconciliation receipt ${field} is invalid`);
    }
  }
  const coverage = plainObject(receipt.coverage, "prior receipt coverage");
  exactKeys(coverage, ["fromInclusive", "toExclusive", "completeThrough", "asOf"], "prior receipt coverage");
  const normalized = {
    schema: RECONCILIATION_RECEIPT_SCHEMA,
    account: text(receipt.account, "prior receipt account"),
    scope: ALL_ACCOUNT,
    adapterId: text(receipt.adapterId, "prior receipt adapterId"),
    adapterVersion: text(receipt.adapterVersion, "prior receipt adapterVersion"),
    rawArtifactSha256: receipt.rawArtifactSha256,
    evidenceContentSha256: receipt.evidenceContentSha256,
    correctionSemantics: text(receipt.correctionSemantics, "prior receipt correctionSemantics"),
    canonicalIdentityDigest: receipt.canonicalIdentityDigest,
    identityCount: nonnegativeInteger(receipt.identityCount, "prior receipt identityCount"),
    coverage: {
      fromInclusive: utc(coverage.fromInclusive, "prior receipt fromInclusive"),
      toExclusive: utc(coverage.toExclusive, "prior receipt toExclusive"),
      completeThrough: utc(coverage.completeThrough, "prior receipt completeThrough"),
      asOf: utc(coverage.asOf, "prior receipt asOf"),
    },
    matchedSocketLedgerDigest: receipt.matchedSocketLedgerDigest,
    verifiedAt: utc(receipt.verifiedAt, "prior receipt verifiedAt"),
  };
  if (!CORRECTION_SEMANTICS.has(normalized.correctionSemantics)) {
    fail("RECEIPT_CONFLICT", "prior reconciliation receipt correction semantics are invalid");
  }
  if (
    Date.parse(normalized.coverage.fromInclusive) >= Date.parse(normalized.coverage.toExclusive) ||
    Date.parse(normalized.coverage.completeThrough) < Date.parse(normalized.coverage.toExclusive) ||
    normalized.coverage.asOf !== normalized.coverage.completeThrough
  ) {
    fail("RECEIPT_CONFLICT", "prior reconciliation receipt coverage is invalid");
  }
  return deepFreeze(normalized);
}

function receiptComparable(receipt) {
  const { verifiedAt: _verifiedAt, ...comparable } = receipt;
  return comparable;
}

/**
 * Canonicalize a persisted receipt structurally. This does not prove its
 * producer, adapter authority, or reconciliation provenance.
 */
export function normalizeReconciliationReceipt(receipt) {
  return normalizeReceipt(receipt);
}

/** Return the stable SHA-256 identity of canonical receipt facts, excluding verifiedAt. */
export function canonicalReconciliationReceiptId(receipt) {
  return sha256Canonical(receiptComparable(normalizeReceipt(receipt)));
}

function journalEntryForReceipt(receipt, conflict) {
  const normalized = normalizeReceipt(receipt);
  return deepFreeze({
    receiptId: sha256Canonical(receiptComparable(normalized)),
    conflict,
    receipt: normalized,
  });
}

/**
 * Convert only a live, module-produced reconciliation success or valid
 * candidate-overlap error into a persistence-safe journal entry.
 */
export function reconciliationJournalEntry(value) {
  if (value && typeof value === "object") {
    const successReceipt = JOURNALABLE_SUCCESSES.get(value);
    if (successReceipt) return journalEntryForReceipt(successReceipt, false);
    const conflictReceipt = JOURNALABLE_OVERLAP_ERRORS.get(value);
    if (conflictReceipt) return journalEntryForReceipt(conflictReceipt, true);
  }
  fail("UNTRUSTED_JOURNAL_VALUE", "journal entry requires a live reconciliation result or overlap error");
}

function intervalsOverlap(left, right) {
  return (
    Date.parse(left.fromInclusive) < Date.parse(right.toExclusive) &&
    Date.parse(right.fromInclusive) < Date.parse(left.toExclusive)
  );
}

function sameInterval(left, right) {
  return left.fromInclusive === right.fromInclusive && left.toExclusive === right.toExclusive;
}

function sameVerifiedFacts(left, right) {
  return (
    left.correctionSemantics === right.correctionSemantics &&
    left.canonicalIdentityDigest === right.canonicalIdentityDigest &&
    left.identityCount === right.identityCount &&
    left.matchedSocketLedgerDigest === right.matchedSocketLedgerDigest
  );
}

function receiptsConflict(left, right) {
  return (
    left.account === right.account &&
    intervalsOverlap(left.coverage, right.coverage) &&
    (!sameInterval(left.coverage, right.coverage) || !sameVerifiedFacts(left, right))
  );
}

function rejectConflictsWithinPriorReceipts(priorReceipts) {
  for (let leftIndex = 0; leftIndex < priorReceipts.length; leftIndex += 1) {
    for (let rightIndex = leftIndex + 1; rightIndex < priorReceipts.length; rightIndex += 1) {
      if (receiptsConflict(priorReceipts[leftIndex], priorReceipts[rightIndex])) {
        fail(
          "RECEIPT_OVERLAP_CONFLICT",
          "overlapping finalized receipts require explicit future correction reconciliation"
        );
      }
    }
  }
}

function rejectCandidateReceiptOverlap(receipt, priorReceipts) {
  if (!priorReceipts.some((prior) => receiptsConflict(prior, receipt))) return;
  const error = new ReconciliationError(
    "RECEIPT_OVERLAP_CONFLICT",
    "overlapping finalized receipts require explicit future correction reconciliation"
  );
  JOURNALABLE_OVERLAP_ERRORS.set(error, receipt);
  throw error;
}

/**
 * Match already-validated FINAL/ALL_ACCOUNT evidence to the raw socket ledger.
 * Socket rows are returned by reference and never merged with report data.
 * `verifiedAt` is a caller clock value, not a completeness signal. The result
 * is a receipt proposal only and deliberately never authorizes activation.
 *
 * @param {object} input Validated evidence, socket ledger, UTC window, and prior receipts.
 * @returns {object} A frozen match result and append-only receipt proposal.
 * @throws {ReconciliationError} When identity, correction, economics, or receipt gates fail.
 */
export function reconcileExecutionWindow({
  evidence,
  socketExecutions,
  socketCommissions,
  account,
  window,
  priorReceipts = [],
  verifiedAt,
} = {}) {
  if (!evidence || typeof evidence !== "object" || !VALIDATED_EVIDENCE.has(evidence)) {
    fail("UNTRUSTED_EVIDENCE", "evidence must come from validateReconciliationEvidence");
  }
  const reconciliationAccount = text(account, "reconciliation account");
  const normalizedWindow = normalizeWindow(window);
  if (
    evidence.account !== reconciliationAccount ||
    evidence.fromInclusive !== normalizedWindow.fromInclusive ||
    evidence.toExclusive !== normalizedWindow.toExclusive
  ) {
    fail("COVERAGE_MISMATCH", "evidence account or interval differs from the requested window");
  }
  const verified = utc(verifiedAt, "reconciliation verifiedAt");
  if (Date.parse(verified) < Date.parse(evidence.retrievedAt)) {
    fail("INVALID_TIME", "reconciliation verifiedAt predates evidence retrieval");
  }
  if (!Array.isArray(socketExecutions) || socketExecutions.length > MAX_RECORDS) {
    fail("INPUT_LIMIT", "socket executions exceed the supported bound");
  }
  if (!Array.isArray(socketCommissions) || socketCommissions.length > MAX_RECORDS) {
    fail("INPUT_LIMIT", "socket commissions exceed the supported bound");
  }
  if (!Array.isArray(priorReceipts) || priorReceipts.length > MAX_RECEIPTS) {
    fail("INPUT_LIMIT", "prior reconciliation receipts exceed the supported bound");
  }

  const socketRows = socketExecutions.map((row) =>
    normalizeSocketExecution(row, reconciliationAccount, normalizedWindow));
  const socketIds = new Set();
  for (const row of socketRows) {
    if (socketIds.has(row.execId)) fail("IDENTITY_MISMATCH", "socket ledger repeats an execId");
    socketIds.add(row.execId);
  }
  const commissionRows = socketCommissions.map((row) => normalizeSocketCommission(row, socketIds));
  const commissionById = new Map();
  for (const report of commissionRows) {
    if (commissionById.has(report.execId)) {
      fail("ECONOMICS_MISMATCH", "socket ledger repeats a commission report");
    }
    commissionById.set(report.execId, report);
  }

  const evidenceGroups = validateCorrectionChains(
    evidence.executions,
    evidence.correctionSemantics,
    "evidence"
  );
  const socketGroups = validateCorrectionChains(socketRows, "ALL_REVISIONS", "socket ledger");
  const evidenceEffective = effectiveRows(evidenceGroups);
  const socketEffective = effectiveRows(socketGroups);
  const evidenceEffectiveIds = evidenceEffective.map((row) => row.execId);
  const socketEffectiveIds = socketEffective.map((row) => row.execId);
  if (!sameArray(evidenceEffectiveIds, socketEffectiveIds)) {
    fail("IDENTITY_MISMATCH", "all-account effective execution identity sets differ");
  }
  if (
    evidence.correctionSemantics === "ALL_REVISIONS" &&
    !sameArray(sortedSet(evidence.executions.map((row) => row.execId)), sortedSet(socketRows.map((row) => row.execId)))
  ) {
    fail("IDENTITY_MISMATCH", "ALL_REVISIONS correction chains differ from the socket ledger");
  }

  const socketById = new Map(socketRows.map((row) => [row.execId, row]));
  for (const reportRow of evidence.executions) {
    const socketRow = socketById.get(reportRow.execId);
    if (!socketRow) fail("IDENTITY_MISMATCH", "report evidence contains an execution absent from the socket ledger");
    assertEconomicsMatch(reportRow, socketRow, commissionById);
  }
  for (const effective of socketEffective) {
    const identity = correctionIdentity(effective.execId);
    if (identity.revision > 1n && !commissionById.has(identity.execId)) {
      fail("MISSING_SOCKET_FEE", "a higher socket correction has no captured socket fee");
    }
  }

  const canonicalIdentities = evidenceEffective.map((row) => ({
    execId: row.execId,
    occurredAt: row.row.occurredAt,
  }));
  const canonicalIdentityDigest = sha256Canonical(canonicalIdentities);
  const evidenceContentSha256 = sha256Canonical(evidence);
  const matchedSocketLedgerDigest = sha256Canonical({
    executions: [...socketRows]
      .sort((left, right) => left.execId < right.execId ? -1 : left.execId > right.execId ? 1 : 0)
      .map((row) => row.row),
    commissions: [...commissionRows]
      .sort((left, right) => left.execId < right.execId ? -1 : left.execId > right.execId ? 1 : 0)
      .map((row) => row.row),
  });
  const receipt = deepFreeze({
    schema: RECONCILIATION_RECEIPT_SCHEMA,
    account: reconciliationAccount,
    scope: ALL_ACCOUNT,
    adapterId: evidence.adapterId,
    adapterVersion: evidence.adapterVersion,
    rawArtifactSha256: evidence.rawArtifactSha256,
    evidenceContentSha256,
    correctionSemantics: evidence.correctionSemantics,
    canonicalIdentityDigest,
    identityCount: evidenceEffective.length,
    coverage: {
      fromInclusive: normalizedWindow.fromInclusive,
      toExclusive: normalizedWindow.toExclusive,
      completeThrough: evidence.completeThrough,
      asOf: evidence.completeThrough,
    },
    matchedSocketLedgerDigest,
    verifiedAt: verified,
  });

  const normalizedPrior = priorReceipts.map(normalizeReceipt);
  const reused = normalizedPrior
    .map((value, index) => ({ value, original: priorReceipts[index] }))
    .filter(({ value }) => value.rawArtifactSha256 === receipt.rawArtifactSha256);
  if (reused.length > 1) {
    fail("RECEIPT_CONFLICT", "raw artifact digest appears in multiple prior receipts");
  }
  if (
    reused.length === 1 &&
    canonicalJson(receiptComparable(reused[0].value)) !== canonicalJson(receiptComparable(receipt))
  ) {
    fail("RECEIPT_CONFLICT", "raw artifact digest was previously bound to different content");
  }
  rejectConflictsWithinPriorReceipts(normalizedPrior);
  rejectCandidateReceiptOverlap(receipt, normalizedPrior);

  let acceptedReceipt = receipt;
  let journalReceipt = receipt;
  let receipts;
  let idempotent = false;
  if (reused.length === 1) {
    acceptedReceipt = reused[0].original;
    journalReceipt = reused[0].value;
    receipts = Object.freeze([...priorReceipts]);
    idempotent = true;
  } else {
    receipts = Object.freeze([...priorReceipts, receipt]);
  }

  const result = Object.freeze({
    ok: true,
    status: "MATCHED",
    trustBoundary: "CALLER_VERIFIED_ADAPTER",
    activationAuthorized: false,
    idempotent,
    evidence,
    socketExecutions,
    socketCommissions,
    receipt: acceptedReceipt,
    receipts,
  });
  JOURNALABLE_SUCCESSES.set(result, journalReceipt);
  return result;
}
