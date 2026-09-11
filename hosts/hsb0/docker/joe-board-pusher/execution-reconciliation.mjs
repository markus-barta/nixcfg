import { createHash } from "node:crypto";

export const EXECUTION_CAPTURE_SCHEMA = "inspr.ib.execution-capture.v1";
export const HISTORY_STATE_SCHEMA = "inspr.joe.best-available-history.v1";
export const HISTORY_RECEIPT_SCHEMA = "inspr.joe.history-capture-receipt.v1";

const MAX_RECORDS = 50_000;
const SHA256 = /^[0-9a-f]{64}$/;

function fail(message) {
  throw new Error(message);
}

function record(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail(`${label} is malformed`);
  return value;
}

function text(value, label) {
  if (typeof value !== "string" || !value.trim() || value.trim() !== value) fail(`${label} is invalid`);
  return value;
}

function instant(value, label) {
  const source = text(value, label);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$/.test(source)) {
    fail(`${label} must have an explicit timezone`);
  }
  const epoch = Date.parse(source);
  if (!Number.isFinite(epoch)) fail(`${label} is invalid`);
  return new Date(epoch).toISOString();
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

function deepFreeze(value) {
  if (value && typeof value === "object" && !Object.isFrozen(value)) {
    Object.freeze(value);
    for (const child of Object.values(value)) deepFreeze(child);
  }
  return value;
}

function finiteNumbers(value, label, seen = new Set()) {
  if (typeof value === "number") {
    if (!Number.isFinite(value) || Math.abs(value) === Number.MAX_VALUE) fail(`${label} contains a non-finite number`);
    return;
  }
  if (!value || typeof value !== "object") return;
  if (seen.has(value)) fail(`${label} contains a cycle`);
  seen.add(value);
  for (const child of Object.values(value)) finiteNumbers(child, label, seen);
  seen.delete(value);
}

function normalizedClassifier(value) {
  const source = record(value, "classifier");
  if (!Array.isArray(source.familyClientIds) || !source.familyClientIds.length) fail("classifier client IDs are invalid");
  if (!Array.isArray(source.excludedSymbols)) fail("classifier excluded symbols are invalid");
  const familyClientIds = [...new Set(source.familyClientIds.map(Number))].sort((a, b) => a - b);
  if (familyClientIds.some((id) => !Number.isSafeInteger(id) || id < 0)) fail("classifier client IDs are invalid");
  const excludedSymbols = [...new Set(source.excludedSymbols.map((symbol) => text(symbol, "excluded symbol").toUpperCase()))].sort();
  return { familyClientIds, excludedSymbols };
}

function interval(value, label) {
  const source = record(value, label);
  const fromInclusive = instant(source.fromInclusive, `${label}.fromInclusive`);
  const toExclusive = instant(source.toExclusive, `${label}.toExclusive`);
  if (fromInclusive >= toExclusive) fail(`${label} must be non-empty`);
  return { fromInclusive, toExclusive };
}

function executionId(row) {
  return text(row?.execution?.execId, "execution execId");
}

function commissionId(row) {
  return text(row?.execId, "commission execId");
}

function correctionIdentity(rowOrId) {
  const id = typeof rowOrId === "string" ? rowOrId : executionId(rowOrId);
  const match = id.match(/^(.*\.)(\d+)$/);
  if (!match || match[1] === ".") fail(`execution ${id} has no correction segment`);
  return { id, prefix: match[1], revision: BigInt(match[2]) };
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

function executionInstant(value) {
  const source = text(value, "execution time");
  if (/^\d{4}-\d{2}-\d{2}T/.test(source)) return instant(source, "execution time");
  const match = source.match(/^(\d{4})(\d{2})(\d{2})\s+(\d{2}):(\d{2}):(\d{2})\s+(?:US\/Eastern|America\/New_York)$/);
  if (!match) fail("execution time has no supported explicit timezone");
  const expected = match.slice(1).map(Number);
  const naive = Date.UTC(expected[0], expected[1] - 1, expected[2], expected[3], expected[4], expected[5]);
  const candidates = [];
  for (let offset = -14 * 60; offset <= 14 * 60; offset += 15) {
    const candidate = naive - offset * 60_000;
    const actual = {};
    for (const part of newYorkFormatter.formatToParts(new Date(candidate))) {
      if (part.type !== "literal") actual[part.type] = Number(part.value);
    }
    if ([actual.year, actual.month, actual.day, actual.hour, actual.minute, actual.second]
      .every((part, index) => part === expected[index])) candidates.push(candidate);
  }
  if (candidates.length !== 1) fail("execution time is invalid or ambiguous");
  return new Date(candidates[0]).toISOString();
}

function validateExecution(row, account) {
  record(row, "execution record");
  record(row.contract, "execution contract");
  const execution = record(row.execution, "execution");
  if (text(execution.acctNumber, "execution account") !== account) fail("execution account mismatch");
  if (!Number.isSafeInteger(execution.clientId) || execution.clientId < 0) fail("execution clientId is invalid");
  if (!Number.isFinite(execution.shares) || execution.shares <= 0) fail("execution shares are invalid");
  if (!Number.isFinite(execution.price) || execution.price <= 0) fail("execution price is invalid");
  if (!["BOT", "BUY", "SLD", "SELL"].includes(text(execution.side, "execution side").toUpperCase())) {
    fail("execution side is unsupported");
  }
  executionInstant(execution.time);
  text(row.contract.symbol, "contract symbol");
  text(row.contract.secType, "contract secType");
  if (!/^[A-Z]{3}$/.test(text(row.contract.currency, "contract currency").toUpperCase())) fail("contract currency is invalid");
  correctionIdentity(row);
  finiteNumbers(row, "execution record");
  return structuredClone(row);
}

function validateCommission(row) {
  record(row, "commission report");
  commissionId(row);
  if (!Number.isFinite(row.commission)) fail("commission amount is invalid");
  if (!/^[A-Z]{3}$/.test(text(row.currency, "commission currency").toUpperCase())) fail("commission currency is invalid");
  if (row.realizedPNL !== undefined && row.realizedPNL !== null && !Number.isFinite(row.realizedPNL)) {
    fail("commission realizedPNL is invalid");
  }
  finiteNumbers(row, "commission report");
  return structuredClone(row);
}

function mergeCommissions(existing, incoming) {
  const byId = new Map();
  for (const source of [...existing, ...incoming]) {
    const row = validateCommission(source);
    const id = commissionId(row);
    const prior = byId.get(id);
    if (!prior) {
      byId.set(id, row);
      continue;
    }
    if (prior.commission !== row.commission || prior.currency.toUpperCase() !== row.currency.toUpperCase()) {
      fail(`conflicting commission ${id}`);
    }
    if (prior.realizedPNL !== undefined && prior.realizedPNL !== null &&
        row.realizedPNL !== undefined && row.realizedPNL !== null &&
        prior.realizedPNL !== row.realizedPNL) fail(`conflicting commission realizedPNL ${id}`);
    if ((prior.realizedPNL === undefined || prior.realizedPNL === null) && row.realizedPNL !== undefined && row.realizedPNL !== null) {
      byId.set(id, row);
    }
  }
  if (byId.size > MAX_RECORDS) fail("commission record limit exceeded");
  return [...byId.values()].sort((left, right) => commissionId(left).localeCompare(commissionId(right)));
}

function mergeExact(existing, incoming, identify, label) {
  const rows = existing.map((row) => structuredClone(row));
  const seen = new Map(rows.map((row) => [identify(row), stable(row)]));
  for (const row of incoming) {
    const id = identify(row);
    const encoded = stable(row);
    if (seen.has(id) && seen.get(id) !== encoded) fail(`conflicting ${label} ${id}`);
    if (!seen.has(id)) {
      seen.set(id, encoded);
      rows.push(structuredClone(row));
    }
  }
  if (rows.length > MAX_RECORDS) fail(`${label} record limit exceeded`);
  return rows.sort((left, right) => identify(left).localeCompare(identify(right)));
}

function latestExecutions(rows) {
  const latest = new Map();
  for (const row of rows) {
    const identity = correctionIdentity(row);
    const prior = latest.get(identity.prefix);
    if (prior && identity.revision === prior.identity.revision && identity.id !== prior.identity.id) {
      fail("conflicting execution correction revision");
    }
    if (!prior || identity.revision > prior.identity.revision) latest.set(identity.prefix, { identity, row });
  }
  return [...latest.values()].sort((a, b) => a.identity.id.localeCompare(b.identity.id)).map(({ row }) => row);
}

function combineIntervals(entries) {
  const sorted = entries.map((entry) => ({
    fromInclusive: entry.fromInclusive,
    toExclusive: entry.toExclusive,
    receiptIds: [...new Set(entry.receiptIds)].sort(),
  })).sort((a, b) => a.fromInclusive.localeCompare(b.fromInclusive) || a.toExclusive.localeCompare(b.toExclusive));
  const result = [];
  for (const entry of sorted) {
    const prior = result.at(-1);
    if (!prior || entry.fromInclusive > prior.toExclusive) {
      result.push(entry);
      continue;
    }
    prior.toExclusive = prior.toExclusive > entry.toExclusive ? prior.toExclusive : entry.toExclusive;
    prior.receiptIds = [...new Set([...prior.receiptIds, ...entry.receiptIds])].sort();
  }
  return result;
}

function coverageFor(target, receipts) {
  const knownIntervals = combineIntervals(receipts.map((receipt) => ({ ...receipt.window, receiptIds: [receipt.receiptId] })));
  const completeIntervals = combineIntervals(receipts
    .filter((receipt) => receipt.coverageStatus === "complete")
    .map((receipt) => ({ ...receipt.window, receiptIds: [receipt.receiptId] })));
  const gaps = [];
  let cursor = target.fromInclusive;
  for (const complete of completeIntervals) {
    const begin = complete.fromInclusive < target.fromInclusive ? target.fromInclusive : complete.fromInclusive;
    const end = complete.toExclusive > target.toExclusive ? target.toExclusive : complete.toExclusive;
    if (end <= target.fromInclusive || begin >= target.toExclusive) continue;
    if (begin > cursor) gaps.push({ fromInclusive: cursor, toExclusive: begin, reason: "no authoritative completeness receipt" });
    if (end > cursor) cursor = end;
  }
  if (cursor < target.toExclusive) gaps.push({ fromInclusive: cursor, toExclusive: target.toExclusive, reason: "no authoritative completeness receipt" });
  return {
    status: gaps.length ? "known" : "complete",
    target,
    completeIntervals,
    knownIntervals,
    gaps,
  };
}

export function validateExecutionCapture(value) {
  const capture = record(value, "execution capture");
  if (capture.schema !== EXECUTION_CAPTURE_SCHEMA) fail("execution capture schema mismatch");
  const account = text(capture.account, "capture account");
  const classifier = normalizedClassifier(capture.classifier);
  const window = interval(capture.window, "capture window");
  const capturedAt = instant(capture.capturedAt, "capture capturedAt");
  if (capturedAt < window.fromInclusive) fail("capture predates its window");
  const source = record(capture.source, "capture source");
  const sourceId = text(source.id, "capture source id");
  const sourceDigest = text(source.sha256, "capture source digest");
  if (!SHA256.test(sourceDigest)) fail("capture source digest is invalid");
  if (source.kind !== "paper-api" && source.kind !== "persisted-ledger") fail("capture source kind is invalid");
  if (capture.coverageStatus !== "known" && capture.coverageStatus !== "complete") fail("capture coverageStatus is invalid");
  let completenessAssertion = null;
  if (capture.coverageStatus === "complete") {
    const assertion = record(capture.completenessAssertion, "completeness assertion");
    completenessAssertion = {
      provider: text(assertion.provider, "completeness provider"),
      assertionId: text(assertion.assertionId, "completeness assertionId"),
    };
  } else if (capture.completenessAssertion !== null && capture.completenessAssertion !== undefined) {
    fail("known-only capture cannot carry a completeness assertion");
  }
  if (!Array.isArray(capture.executions) || capture.executions.length > MAX_RECORDS) fail("capture executions are invalid");
  if (!Array.isArray(capture.commissions) || capture.commissions.length > MAX_RECORDS) fail("capture commissions are invalid");
  const executions = capture.executions.map((row) => validateExecution(row, account));
  const commissions = capture.commissions.map(validateCommission);
  if (executions.some((row) => {
    const occurredAt = executionInstant(row.execution.time);
    return occurredAt < window.fromInclusive || occurredAt >= window.toExclusive;
  })) fail("capture execution is outside its declared window");
  mergeExact([], executions, executionId, "execution");
  mergeExact([], commissions, commissionId, "commission");
  const metadata = source.metadata && typeof source.metadata === "object" && !Array.isArray(source.metadata)
    ? structuredClone(source.metadata)
    : {};
  finiteNumbers(metadata, "capture source metadata");
  return deepFreeze({
    schema: EXECUTION_CAPTURE_SCHEMA,
    account,
    classifier,
    source: { kind: source.kind, id: sourceId, sha256: sourceDigest, metadata },
    capturedAt,
    window,
    coverageStatus: capture.coverageStatus,
    completenessAssertion,
    executions,
    commissions,
  });
}

function receiptFor(capture) {
  const executionIds = capture.executions.map(executionId).sort();
  const commissionIds = capture.commissions.map(commissionId).sort();
  const facts = {
    source: capture.source,
    capturedAt: capture.capturedAt,
    window: capture.window,
    coverageStatus: capture.coverageStatus,
    completenessAssertion: capture.completenessAssertion,
    executionIdentityDigest: digest(executionIds),
    executionCount: executionIds.length,
    commissionIdentityDigest: digest(commissionIds),
    commissionCount: commissionIds.length,
    payloadDigest: digest({ executions: capture.executions, commissions: capture.commissions }),
  };
  return { schema: HISTORY_RECEIPT_SCHEMA, receiptId: digest(facts), ...facts, executionIds, commissionIds };
}

export function reconcileExecutionCapture({ prior = null, capture: rawCapture, target: rawTarget } = {}) {
  const capture = validateExecutionCapture(rawCapture);
  const requestedTarget = interval(rawTarget, "history target");
  if (capture.window.fromInclusive < requestedTarget.fromInclusive || capture.window.toExclusive > requestedTarget.toExclusive) {
    fail("capture window is outside the requested history target");
  }
  const receipt = receiptFor(capture);
  if (prior !== null) validateBestAvailableHistoryState(prior);
  if (prior && (prior.account !== capture.account || stable(prior.classifier) !== stable(capture.classifier))) {
    fail("history capture configuration mismatch");
  }
  const receipts = prior ? prior.receipts.map((item) => structuredClone(item)) : [];
  const existingReceipt = receipts.find((item) => item.receiptId === receipt.receiptId);
  const reusedSource = receipts.find((item) => item.source.id === receipt.source.id);
  if (reusedSource && reusedSource.receiptId !== receipt.receiptId) fail("capture source was previously bound to different facts");
  if (!existingReceipt) receipts.push(receipt);
  receipts.sort((a, b) => a.capturedAt.localeCompare(b.capturedAt) || a.receiptId.localeCompare(b.receiptId));
  const executions = mergeExact(prior?.executions || [], capture.executions, executionId, "execution");
  const commissions = mergeCommissions(prior?.commissions || [], capture.commissions);
  const target = prior ? {
    fromInclusive: prior.target.fromInclusive < requestedTarget.fromInclusive ? prior.target.fromInclusive : requestedTarget.fromInclusive,
    toExclusive: prior.target.toExclusive > requestedTarget.toExclusive ? prior.target.toExclusive : requestedTarget.toExclusive,
  } : requestedTarget;
  const state = {
    schema: HISTORY_STATE_SCHEMA,
    version: 1,
    account: capture.account,
    classifier: capture.classifier,
    target,
    createdAt: prior?.createdAt || capture.capturedAt,
    updatedAt: prior && existingReceipt
      ? prior.updatedAt
      : prior?.updatedAt > capture.capturedAt ? prior.updatedAt : capture.capturedAt,
    executions,
    commissions,
    receipts,
    coverage: coverageFor(target, receipts),
  };
  validateBestAvailableHistoryState(state);
  return deepFreeze(state);
}

export function validateBestAvailableHistoryState(value) {
  const state = record(value, "best-available history state");
  if (state.schema !== HISTORY_STATE_SCHEMA || state.version !== 1) fail("best-available history schema mismatch");
  text(state.account, "history account");
  if (stable(normalizedClassifier(state.classifier)) !== stable(state.classifier)) fail("history classifier is not canonical");
  const target = interval(state.target, "history target");
  instant(state.createdAt, "history createdAt");
  instant(state.updatedAt, "history updatedAt");
  if (!Array.isArray(state.executions) || !Array.isArray(state.commissions) || !Array.isArray(state.receipts)) {
    fail("history ledgers are invalid");
  }
  const executions = state.executions.map((row) => validateExecution(row, state.account));
  const commissions = state.commissions.map(validateCommission);
  if (stable(mergeExact([], executions, executionId, "execution")) !== stable(executions)) fail("history executions are not canonical");
  if (stable(mergeCommissions([], commissions)) !== stable(commissions)) fail("history commissions are not canonical");
  const receiptIds = new Set();
  for (const receipt of state.receipts) {
    if (receipt?.schema !== HISTORY_RECEIPT_SCHEMA || !SHA256.test(receipt.receiptId || "")) fail("history receipt is invalid");
    if (receiptIds.has(receipt.receiptId)) fail("history receipt is duplicated");
    receiptIds.add(receipt.receiptId);
    const receiptWindow = interval(receipt.window, "receipt window");
    if (receiptWindow.fromInclusive < target.fromInclusive || receiptWindow.toExclusive > target.toExclusive) {
      fail("history receipt is outside the target");
    }
    instant(receipt.capturedAt, "receipt capturedAt");
    if (!receipt.source || !["paper-api", "persisted-ledger"].includes(receipt.source.kind) ||
        !receipt.source.id || !SHA256.test(receipt.source.sha256 || "")) fail("history receipt source is invalid");
    if (!receipt.source.metadata || typeof receipt.source.metadata !== "object" || Array.isArray(receipt.source.metadata)) {
      fail("history receipt source metadata is invalid");
    }
    if (receipt.coverageStatus !== "known" && receipt.coverageStatus !== "complete") fail("history receipt coverage is invalid");
    if (receipt.coverageStatus === "complete") {
      if (!receipt.completenessAssertion?.provider || !receipt.completenessAssertion?.assertionId) {
        fail("complete history receipt lacks a completeness assertion");
      }
    } else if (receipt.completenessAssertion !== null) fail("known history receipt has a completeness assertion");
    if (![receipt.executionIdentityDigest, receipt.commissionIdentityDigest, receipt.payloadDigest]
      .every((value) => SHA256.test(value || ""))) fail("history receipt content digest is invalid");
    if (!Number.isSafeInteger(receipt.executionCount) || receipt.executionCount < 0 ||
        !Number.isSafeInteger(receipt.commissionCount) || receipt.commissionCount < 0) fail("history receipt count is invalid");
    for (const [ids, count, identityDigest, label] of [
      [receipt.executionIds, receipt.executionCount, receipt.executionIdentityDigest, "execution"],
      [receipt.commissionIds, receipt.commissionCount, receipt.commissionIdentityDigest, "commission"],
    ]) {
      if (ids !== undefined && (!Array.isArray(ids) || ids.length !== count ||
          ids.some((id) => typeof id !== "string" || !id) ||
          stable([...new Set(ids)].sort()) !== stable(ids) || digest(ids) !== identityDigest)) {
        fail(`history receipt ${label} identities are invalid`);
      }
    }
    if (receipt.receiptId !== digest({
      source: receipt.source,
      capturedAt: receipt.capturedAt,
      window: receipt.window,
      coverageStatus: receipt.coverageStatus,
      completenessAssertion: receipt.completenessAssertion,
      executionIdentityDigest: receipt.executionIdentityDigest,
      executionCount: receipt.executionCount,
      commissionIdentityDigest: receipt.commissionIdentityDigest,
      commissionCount: receipt.commissionCount,
      payloadDigest: receipt.payloadDigest,
    })) fail("history receipt digest mismatch");
  }
  const canonicalReceiptOrder = [...state.receipts]
    .sort((a, b) => a.capturedAt.localeCompare(b.capturedAt) || a.receiptId.localeCompare(b.receiptId));
  if (stable(canonicalReceiptOrder) !== stable(state.receipts)) fail("history receipts are not canonical");
  if (stable(state.coverage) !== stable(coverageFor(target, state.receipts))) fail("history coverage is not canonical");
  return true;
}

export function effectiveExecutionRecords(state) {
  validateBestAvailableHistoryState(state);
  return deepFreeze(latestExecutions(state.executions).map((row) => structuredClone(row)));
}

export function bestAvailableHistoryDigest(state) {
  validateBestAvailableHistoryState(state);
  return digest(state);
}
