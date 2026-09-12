import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";

const STATE_SCHEMA = "inspr.joe.day-baseline.v1";
const OUTPUT_METHOD = "sod-virtual-equity";
const OUTPUT_SCOPE = "virtual-desks";
const INPUT_SCOPE = "stage0-virtual-desks-keep-excluded";
const CURRENCY = "EUR";
const DESKS = ["j", "joe", "joel"];
const EQUITY_KEYS = [...DESKS, "total"];
const MAX_STATE_BYTES = 256 * 1024;
const MAX_MONEY = 1_000_000_000_000;
const SHA256 = /^[0-9a-f]{64}$/;

function clone(value) {
  return structuredClone(value);
}

function fail(message) {
  throw new Error(message);
}

function text(value, label, maxLength = 160) {
  if (typeof value !== "string" || !value.trim() || value.trim() !== value || value.length > maxLength) {
    fail(`${label} is invalid`);
  }
  return value;
}

function instant(value, label) {
  const source = text(value, label);
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,3})?(Z|([+-])(\d{2}):(\d{2}))$/.exec(source);
  if (!match) {
    fail(`${label} must have an explicit timezone`);
  }
  const [year, month, day, hour, minute, second] = match.slice(1, 7).map(Number);
  const leap = (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
  const monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (month < 1 || month > 12 || day < 1 || day > monthDays[month - 1] ||
      hour > 23 || minute > 59 || second > 59) fail(`${label} is invalid`);
  if (match[7] !== "Z") {
    const offsetHour = Number(match[9]);
    const offsetMinute = Number(match[10]);
    if (offsetHour > 14 || offsetMinute > 59 || (offsetHour === 14 && offsetMinute !== 0)) {
      fail(`${label} has an invalid timezone offset`);
    }
  }
  const epoch = Date.parse(source);
  if (!Number.isFinite(epoch)) fail(`${label} is invalid`);
  return new Date(epoch).toISOString();
}

function canonicalJson(value, label, depth = 0) {
  if (depth > 8) fail(`${label} is too deeply nested`);
  if (value === null || typeof value === "boolean") return value;
  if (typeof value === "string") return text(value, label, 512);
  if (typeof value === "number") {
    if (!Number.isFinite(value)) fail(`${label} contains a non-finite number`);
    return value;
  }
  if (Array.isArray(value)) {
    if (value.length > 128) fail(`${label} has too many entries`);
    return value.map((item, index) => canonicalJson(item, `${label}[${index}]`, depth + 1));
  }
  if (!value || typeof value !== "object") fail(`${label} is not JSON data`);
  const keys = Object.keys(value).sort();
  if (keys.length > 128) fail(`${label} has too many fields`);
  const entries = [];
  for (const key of keys) {
    text(key, `${label} field`, 128);
    entries.push([key, canonicalJson(value[key], `${label}.${key}`, depth + 1)]);
  }
  return Object.fromEntries(entries);
}

function stable(value) {
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stable(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function same(left, right) {
  return stable(left) === stable(right);
}

function normalizedSourceContract(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail("sourceContract is invalid");
  if (value.scope !== INPUT_SCOPE || value.keepExcluded !== true) {
    fail(`sourceContract must use ${INPUT_SCOPE}`);
  }
  const classifier = canonicalJson(value.classifier, "sourceContract.classifier");
  if (!classifier || typeof classifier !== "object" || Array.isArray(classifier) || !Object.keys(classifier).length) {
    fail("sourceContract.classifier is invalid");
  }
  return {
    method: text(value.method, "sourceContract.method"),
    classifier,
    historyRevisionMethod: text(value.historyRevisionMethod, "sourceContract.historyRevisionMethod"),
    scope: INPUT_SCOPE,
    keepExcluded: true,
  };
}

function money(value, label) {
  if (!Number.isFinite(value) || Math.abs(value) > MAX_MONEY) fail(`${label} is invalid`);
  const cents = Math.round(value * 100);
  const normalized = cents / 100;
  if (Math.abs(value - normalized) > 0.0000001) fail(`${label} has sub-cent precision`);
  return normalized;
}

function equityVector(value) {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      !same(Object.keys(value).sort(), [...EQUITY_KEYS].sort())) {
    fail("equity must contain exactly j, joe, joel and total");
  }
  const result = Object.fromEntries(EQUITY_KEYS.map((key) => [key, money(value[key], `equity.${key}`)]));
  const calculated = money(DESKS.reduce((sum, key) => sum + result[key], 0), "equity total");
  if (Math.abs(calculated - result.total) > 0.001) fail("equity.total does not equal the desk sum");
  return result;
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

function newYorkParts(value) {
  const epoch = new Date(value ?? "").getTime();
  if (!Number.isFinite(epoch)) fail("New York period source is invalid");
  const fields = {};
  for (const part of newYorkFormatter.formatToParts(new Date(epoch))) {
    if (part.type !== "literal") fields[part.type] = Number(part.value);
  }
  return fields;
}

/** Return the unique UTC instant for the America/New_York calendar-day start. */
export function newYorkPeriodStart(value) {
  const fields = newYorkParts(value);
  const expected = [fields.year, fields.month, fields.day, 0, 0, 0];
  const naive = Date.UTC(fields.year, fields.month - 1, fields.day);
  const matches = [];
  for (let offset = -14 * 60; offset <= 14 * 60; offset += 15) {
    const candidate = naive - offset * 60_000;
    const actual = newYorkParts(candidate);
    if ([actual.year, actual.month, actual.day, actual.hour, actual.minute, actual.second]
      .every((part, index) => part === expected[index])) matches.push(candidate);
  }
  if (matches.length !== 1) fail("New York day start is not unique");
  return new Date(matches[0]).toISOString();
}

function normalizedProofContract(value, expected) {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail("provenance is invalid");
  const actual = normalizedSourceContract(value);
  if (!same(actual, expected)) fail("source method or classifier does not match the configured contract");
  return actual;
}

function normalizedObservation(value, sourceContract) {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail("equity observation is invalid");
  const sourceObservedAt = instant(value.sourceObservedAt, "sourceObservedAt");
  const oldestSourceObservedAt = instant(value.oldestSourceObservedAt, "oldestSourceObservedAt");
  if (oldestSourceObservedAt > sourceObservedAt) fail("oldestSourceObservedAt is after sourceObservedAt");
  normalizedProofContract(value.provenance, sourceContract);
  const historyRevision = text(value.provenance.historyRevision, "provenance.historyRevision");
  if (!SHA256.test(historyRevision)) fail("provenance.historyRevision must be a lowercase SHA-256 digest");
  const coverage = value.provenance.executionCoverage;
  if (!coverage || coverage.status !== "complete") fail("execution coverage is incomplete");
  const throughInclusive = instant(coverage.throughInclusive, "executionCoverage.throughInclusive");
  if (throughInclusive > sourceObservedAt) fail("execution coverage ends after sourceObservedAt");
  if (oldestSourceObservedAt > throughInclusive) {
    fail("oldestSourceObservedAt does not include the execution coverage watermark");
  }
  return {
    equity: equityVector(value.equity),
    sourceObservedAt,
    oldestSourceObservedAt,
    provenance: {
      ...sourceContract,
      historyRevision,
      executionCoverage: { status: "complete", throughInclusive },
    },
  };
}

function normalizedBoundaryProof(value, sourceContract) {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail("boundary proof is invalid");
  normalizedProofContract(value.provenance, sourceContract);
  const periodStart = instant(value.periodStart, "boundary proof periodStart");
  if (newYorkPeriodStart(periodStart) !== periodStart) fail("boundary proof periodStart is not New York midnight");
  const proofObservedAt = instant(value.proofObservedAt, "boundary proof proofObservedAt");
  if (proofObservedAt < periodStart) fail("boundary proof predates its periodStart");
  const historyRevision = text(value.provenance.historyRevision, "boundary proof historyRevision");
  if (!SHA256.test(historyRevision)) fail("boundary proof historyRevision must be a lowercase SHA-256 digest");
  const coverage = value.provenance.executionCoverage;
  if (!coverage || coverage.status !== "complete") fail("boundary execution coverage is incomplete");
  const fromInclusive = instant(coverage.fromInclusive, "boundary coverage fromInclusive");
  const throughExclusive = instant(coverage.throughExclusive, "boundary coverage throughExclusive");
  if (fromInclusive > throughExclusive ||
      (fromInclusive === throughExclusive && fromInclusive !== periodStart)) {
    fail("boundary execution coverage is invalid");
  }
  if (throughExclusive < periodStart) fail("boundary execution coverage does not span periodStart");
  if (throughExclusive > proofObservedAt) fail("boundary execution coverage ends after proofObservedAt");
  return {
    periodStart,
    proofObservedAt,
    provenance: {
      ...sourceContract,
      historyRevision,
      // historyRevision is the effective economic-history digest at the
      // periodStart cutoff. The complete receipt may finish later.
      executionCoverage: { status: "complete", fromInclusive, throughExclusive },
    },
  };
}

function unavailable(reason) {
  const detail = String(reason).slice(0, 160);
  return {
    ok: false,
    reason: detail,
    values: { j: null, joe: null, joel: null, total: null },
    source: {
      status: "unavailable",
      method: null,
      currency: CURRENCY,
      scope: OUTPUT_SCOPE,
      observedAt: null,
      periodStart: null,
      detail,
    },
  };
}

function normalizedDeskProviderContract(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail("desk provider contract is invalid");
  const contract = {
    method: text(value.method, "desk provider method"),
    policyMethod: text(value.policyMethod, "desk provider policy method"),
    policyHash: text(value.policyHash, "desk provider policy hash"),
    scope: value.scope,
    keepExcluded: value.keepExcluded,
  };
  if (!SHA256.test(contract.policyHash)) fail("desk provider policy hash must be a lowercase SHA-256 digest");
  if (contract.scope !== INPUT_SCOPE || contract.keepExcluded !== true) {
    fail(`desk provider contract must use ${INPUT_SCOPE}`);
  }
  return contract;
}

function deskObservation(value, providerContract, sourceContract) {
  if (!value?.ok) fail(`all-desk equity is unavailable: ${value?.reason || "unknown reason"}`);
  if (value.historyRevisionMethod !== sourceContract.historyRevisionMethod) {
    fail("all-desk history revision method does not match the configured contract");
  }
  if (!same(value.sourceContract, providerContract)) {
    fail("all-desk source contract does not match the configured ownership policy");
  }
  if (value.ownershipEvidence?.status !== "complete" || value.ownershipEvidence.policyHash !== providerContract.policyHash ||
      value.ownershipEvidence.unclaimedExecutionCount !== 0) {
    fail("all-desk ownership evidence is incomplete");
  }
  return normalizedObservation({
    equity: value.equity,
    sourceObservedAt: value.sourceObservedAt,
    oldestSourceObservedAt: value.oldestSourceObservedAt,
    provenance: {
      ...sourceContract,
      historyRevision: value.historyRevision,
      executionCoverage: value.executionCoverage,
    },
  }, sourceContract);
}

function validObservation(value, sourceContract) {
  try {
    const normalized = normalizedObservation(value, sourceContract);
    return same(value, normalized) ? null : "persisted equity observation is not canonical";
  } catch (error) {
    return error.message;
  }
}

function validState(value, { account, sourceContract, boundaryFreshMs }) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return "day baseline state is not an object";
  if (value.schema !== STATE_SCHEMA || value.version !== 1) return "unsupported day baseline state schema";
  if (value.account !== account) return "day baseline state account mismatch";
  if (value.currency !== CURRENCY) return "day baseline state currency mismatch";
  if (!same(value.sourceContract, sourceContract)) return "day baseline source method or classifier mismatch";
  if (value.boundaryFreshMs !== boundaryFreshMs) return "day baseline freshness contract mismatch";
  try {
    if (instant(value.initializedAt, "state initializedAt") !== value.initializedAt ||
        instant(value.updatedAt, "state updatedAt") !== value.updatedAt) return "day baseline timestamps are not canonical";
    if (value.initializedAt > value.updatedAt) return "day baseline timestamps regress";
  } catch (error) {
    return error.message;
  }
  if (value.latest !== null) {
    const reason = validObservation(value.latest, sourceContract);
    if (reason) return reason;
  }
  const slots = [value.baseline, value.pending, value.missed].filter((item) => item !== null);
  if (slots.length > 1) return "day baseline state has conflicting boundary outcomes";
  try {
    if (value.baseline !== null) {
      if (newYorkPeriodStart(value.baseline.periodStart) !== value.baseline.periodStart) fail("baseline periodStart is invalid");
      if (validObservation(value.baseline.candidate, sourceContract)) fail("baseline candidate is invalid");
      normalizedBoundaryProof(value.baseline.proof, sourceContract);
      if (value.baseline.proof.periodStart !== value.baseline.periodStart) fail("baseline proof period mismatch");
      if (value.baseline.candidate.sourceObservedAt > value.baseline.periodStart) fail("baseline candidate is after periodStart");
      if (value.baseline.candidate.provenance.executionCoverage.throughInclusive > value.updatedAt) {
        fail("baseline candidate coverage is newer than persisted state");
      }
      if (value.baseline.proof.proofObservedAt > value.updatedAt) fail("baseline proof is newer than persisted state");
      if (value.baseline.proof.provenance.executionCoverage.fromInclusive >
          value.baseline.candidate.provenance.executionCoverage.throughInclusive) {
        fail("baseline execution proof does not cover the candidate execution watermark");
      }
      if (value.baseline.proof.provenance.historyRevision !== value.baseline.candidate.provenance.historyRevision) {
        fail("baseline history revision mismatch");
      }
      if (value.baseline.ageAtBoundaryMs !== Date.parse(value.baseline.periodStart) - Date.parse(value.baseline.candidate.oldestSourceObservedAt) ||
          value.baseline.ageAtBoundaryMs < 0 || value.baseline.ageAtBoundaryMs > boundaryFreshMs) {
        fail("baseline freshness proof is invalid");
      }
    }
    if (value.pending !== null) {
      if (newYorkPeriodStart(value.pending.periodStart) !== value.pending.periodStart) fail("pending periodStart is invalid");
      if (validObservation(value.pending.candidate, sourceContract)) fail("pending candidate is invalid");
      if (value.pending.candidate.sourceObservedAt > value.pending.periodStart) fail("pending candidate is after periodStart");
      if (value.pending.candidate.provenance.executionCoverage.throughInclusive > value.updatedAt) {
        fail("pending candidate coverage is newer than persisted state");
      }
      const pendingAge = Date.parse(value.pending.periodStart) - Date.parse(value.pending.candidate.oldestSourceObservedAt);
      if (pendingAge < 0 || pendingAge > boundaryFreshMs) fail("pending candidate freshness is invalid");
    }
    if (value.missed !== null) {
      if (newYorkPeriodStart(value.missed.periodStart) !== value.missed.periodStart) fail("missed periodStart is invalid");
      text(value.missed.reason, "missed reason");
    }
    if (value.latest !== null) {
      if (value.latest.sourceObservedAt > value.updatedAt) fail("latest observation is newer than persisted state");
      if (value.latest.provenance.executionCoverage.throughInclusive > value.updatedAt) {
        fail("latest execution coverage is newer than persisted state");
      }
      const currentPeriod = newYorkPeriodStart(value.latest.sourceObservedAt);
      const outcome = value.baseline || value.pending || value.missed;
      if (!outcome || outcome.periodStart !== currentPeriod) fail("state has no outcome for the latest New York day");
    }
  } catch (error) {
    return error.message;
  }
  return null;
}

function readBoundedFile(filePath, fsImpl) {
  let handle;
  try {
    handle = fsImpl.openSync(filePath, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    const stat = fsImpl.fstatSync(handle);
    if (!stat.isFile() || stat.size <= 0 || stat.size > MAX_STATE_BYTES) {
      return { ok: false, reason: "day baseline state has an invalid size" };
    }
    const bytes = Buffer.alloc(stat.size + 1);
    let count = 0;
    while (count < bytes.length) {
      const read = fsImpl.readSync(handle, bytes, count, bytes.length - count, null);
      if (read === 0) break;
      count += read;
    }
    if (count !== stat.size) return { ok: false, reason: "day baseline state changed size during read" };
    return { ok: true, source: bytes.subarray(0, count).toString("utf8") };
  } catch (error) {
    if (error?.code === "ENOENT") return { ok: true, source: null };
    return { ok: false, reason: `day baseline state read failed: ${error?.code || error}` };
  } finally {
    if (handle !== undefined) fsImpl.closeSync(handle);
  }
}

/** Bounded, no-follow, fsync+rename+directory-fsync persistence. */
export function createFileDayBaselineStore(filePath, fsImpl = fs) {
  if (typeof filePath !== "string" || !path.isAbsolute(filePath)) {
    throw new TypeError("day baseline state path must be absolute");
  }
  return {
    load(config) {
      const result = readBoundedFile(filePath, fsImpl);
      if (!result.ok || result.source === null) return result.source === null ? { ok: true, state: null } : result;
      try {
        const state = JSON.parse(result.source);
        const reason = validState(state, config);
        return reason ? { ok: false, reason } : { ok: true, state };
      } catch {
        return { ok: false, reason: "day baseline state is corrupt JSON" };
      }
    },

    save(state) {
      const reason = validState(state, {
        account: state?.account,
        sourceContract: state?.sourceContract,
        boundaryFreshMs: state?.boundaryFreshMs,
      });
      if (reason) throw new Error(reason);
      const body = `${JSON.stringify(state, null, 2)}\n`;
      if (Buffer.byteLength(body) > MAX_STATE_BYTES) throw new Error("day baseline state exceeds size limit");
      const directory = path.dirname(filePath);
      const temporary = path.join(directory, `.${path.basename(filePath)}.${process.pid}.${randomUUID()}.tmp`);
      let handle;
      try {
        handle = fsImpl.openSync(temporary, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, 0o600);
        fsImpl.writeFileSync(handle, body, "utf8");
        fsImpl.fsyncSync(handle);
        fsImpl.closeSync(handle);
        handle = undefined;
        fsImpl.renameSync(temporary, filePath);
        const directoryHandle = fsImpl.openSync(directory, "r");
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
    },
  };
}

/**
 * Persist full virtual-equity observations and establish one SOD baseline per
 * America/New_York day. A later boundary proof may confirm a retained
 * pre-midnight candidate, but no post-midnight observation can become SOD.
 */
export function createDayBaselineAdapter({
  account,
  sourceContract: sourceContractInput,
  store,
  boundaryFreshMs = 120_000,
  currentFreshMs = 300_000,
  now = () => new Date().toISOString(),
} = {}) {
  const targetAccount = text(account, "account");
  const sourceContract = normalizedSourceContract(sourceContractInput);
  if (!store || typeof store.load !== "function" || typeof store.save !== "function") {
    throw new TypeError("day baseline store is required");
  }
  if (!Number.isSafeInteger(boundaryFreshMs) || boundaryFreshMs <= 0 ||
      !Number.isSafeInteger(currentFreshMs) || currentFreshMs <= 0) {
    throw new TypeError("day baseline freshness limits must be positive integer milliseconds");
  }
  const config = { account: targetAccount, sourceContract, boundaryFreshMs };
  const loaded = store.load(config);
  let state = loaded.ok ? (loaded.state ? clone(loaded.state) : null) : null;
  let blockedReason = loaded.ok ? null : loaded.reason;

  function projection(at = now()) {
    if (blockedReason) return unavailable(blockedReason);
    if (!state?.latest) return unavailable("no complete virtual-equity observation has been persisted");
    const currentPeriod = newYorkPeriodStart(state.latest.sourceObservedAt);
    if (!state.baseline || state.baseline.periodStart !== currentPeriod) {
      return unavailable(state.missed?.reason || "exact New York SOD virtual-equity proof is pending");
    }
    let projectedAt;
    try {
      projectedAt = instant(at, "projection time");
    } catch (error) {
      return unavailable(error.message);
    }
    const currentAge = Date.parse(projectedAt) - Date.parse(state.latest.oldestSourceObservedAt);
    if (!Number.isFinite(currentAge) || currentAge < 0 || currentAge > currentFreshMs) {
      return unavailable("current virtual-equity observation is stale");
    }
    const values = {};
    for (const key of EQUITY_KEYS) {
      values[key] = money(state.latest.equity[key] - state.baseline.candidate.equity[key], `day P&L ${key}`);
    }
    const baseline = state.baseline;
    return {
      ok: true,
      values,
      source: {
        status: "available",
        method: OUTPUT_METHOD,
        currency: CURRENCY,
        scope: OUTPUT_SCOPE,
        observedAt: state.latest.sourceObservedAt,
        periodStart: baseline.periodStart,
        detail: "Current proven virtual equity minus durable New York SOD virtual equity; KEEP excluded.",
      },
      evidence: {
        sourceObservedAt: baseline.candidate.sourceObservedAt,
        oldestSourceObservedAt: baseline.candidate.oldestSourceObservedAt,
        proofObservedAt: baseline.proof.proofObservedAt,
        historyRevisionMethod: sourceContract.historyRevisionMethod,
        historyRevision: baseline.candidate.provenance.historyRevision,
        ageAtBoundaryMs: baseline.ageAtBoundaryMs,
        maxAgeMs: boundaryFreshMs,
      },
    };
  }

  function persist(next) {
    try {
      store.save(next);
      state = clone(next);
      return true;
    } catch (error) {
      blockedReason = `day baseline state save failed: ${error?.message || error}`;
      return false;
    }
  }

  function boundaryCandidate(observation, periodStart) {
    const candidates = [state?.latest, observation]
      .filter(Boolean)
      .filter((item) => item.sourceObservedAt <= periodStart)
      .sort((left, right) => right.sourceObservedAt.localeCompare(left.sourceObservedAt));
    return candidates[0] || null;
  }

  function applyBoundaryProof(next, proofInput, ingestAt) {
    if (!proofInput || !next.pending) return { next, reason: null };
    let proof;
    try {
      proof = normalizedBoundaryProof(proofInput, sourceContract);
    } catch (error) {
      return { next, reason: error.message };
    }
    const pending = next.pending;
    if (proof.proofObservedAt > ingestAt) return { next, reason: "boundary proof is observed in the future" };
    if (proof.periodStart !== pending.periodStart) return { next, reason: "boundary proof period does not match the pending day" };
    if (proof.provenance.executionCoverage.fromInclusive >
        pending.candidate.provenance.executionCoverage.throughInclusive) {
      return { next, reason: "boundary execution proof does not cover the candidate execution watermark to midnight" };
    }
    if (proof.provenance.historyRevision !== pending.candidate.provenance.historyRevision) {
      next.pending = null;
      next.missed = {
        periodStart: pending.periodStart,
        reason: "SOD candidate history revision differs from the exact boundary revision",
      };
      return { next, reason: next.missed.reason };
    }
    const ageAtBoundaryMs = Date.parse(pending.periodStart) - Date.parse(pending.candidate.oldestSourceObservedAt);
    if (ageAtBoundaryMs < 0 || ageAtBoundaryMs > boundaryFreshMs) {
      next.pending = null;
      next.missed = {
        periodStart: pending.periodStart,
        reason: "latest pre-boundary virtual-equity observation is too stale for SOD",
      };
      return { next, reason: next.missed.reason };
    }
    next.baseline = {
      periodStart: pending.periodStart,
      candidate: clone(pending.candidate),
      proof,
      ageAtBoundaryMs,
    };
    next.pending = null;
    next.missed = null;
    return { next, reason: null };
  }

  function observe(observationInput, { boundaryProof = null } = {}) {
    if (blockedReason) return projection();
    let observation;
    let ingestAt;
    try {
      observation = normalizedObservation(observationInput, sourceContract);
      ingestAt = instant(now(), "ingest time");
      if (observation.sourceObservedAt > ingestAt) fail("equity observation is observed in the future");
      if (observation.provenance.executionCoverage.throughInclusive > ingestAt) {
        fail("execution coverage is observed in the future");
      }
    } catch (error) {
      return unavailable(error.message);
    }
    if (state?.latest) {
      if (observation.sourceObservedAt < state.latest.sourceObservedAt) {
        return unavailable("virtual-equity observation regressed behind persisted state");
      }
      if (observation.sourceObservedAt === state.latest.sourceObservedAt && !same(observation, state.latest)) {
        return unavailable("virtual-equity observation changed at an identical source revision");
      }
    }

    const periodStart = newYorkPeriodStart(observation.sourceObservedAt);
    let next;
    const priorPeriod = state?.latest ? newYorkPeriodStart(state.latest.sourceObservedAt) : null;
    if (!state) {
      next = {
        schema: STATE_SCHEMA,
        version: 1,
        account: targetAccount,
        currency: CURRENCY,
        sourceContract: clone(sourceContract),
        boundaryFreshMs,
        initializedAt: ingestAt,
        updatedAt: ingestAt,
        latest: clone(observation),
        baseline: null,
        pending: null,
        missed: null,
      };
      if (observation.sourceObservedAt === periodStart) {
        next.pending = { periodStart, candidate: clone(observation) };
      } else {
        next.missed = { periodStart, reason: "first observation arrived after the New York SOD boundary" };
      }
    } else {
      next = clone(state);
      next.updatedAt = ingestAt;
      next.latest = clone(observation);
      if (priorPeriod !== periodStart) {
        next.baseline = null;
        next.pending = null;
        next.missed = null;
        const candidate = boundaryCandidate(observation, periodStart);
        const ageAtBoundaryMs = candidate
          ? Date.parse(periodStart) - Date.parse(candidate.oldestSourceObservedAt)
          : Number.POSITIVE_INFINITY;
        if (!candidate) {
          next.missed = { periodStart, reason: "no observation exists at or before the New York SOD boundary" };
        } else if (ageAtBoundaryMs < 0 || ageAtBoundaryMs > boundaryFreshMs) {
          next.missed = { periodStart, reason: "latest pre-boundary virtual-equity observation is too stale for SOD" };
        } else {
          next.pending = { periodStart, candidate: clone(candidate) };
        }
      }
    }

    const applied = applyBoundaryProof(next, boundaryProof, ingestAt);
    next = applied.next;
    if (!persist(next)) return projection(ingestAt);
    return applied.reason ? unavailable(applied.reason) : projection(ingestAt);
  }

  return {
    observe,
    project: projection,
    inspectState() { return state ? clone(state) : null; },
    get blockedReason() { return blockedReason; },
  };
}

/**
 * Bind the baseline state machine to the independently verified all-desk
 * calculator. The producer preserves the calculator's timestamps and digest,
 * and asks the authoritative-history helper to prove a retained candidate only
 * after the New York boundary has passed.
 */
export function createDeskDayPnlProducer({
  account,
  policy,
  providerContract: providerContractInput,
  historyRevisionMethod,
  store,
  buildBoundaryEvidence,
  getVerifiedHistoryState,
  boundaryFreshMs = 300_000,
  currentFreshMs = 300_000,
  now = () => new Date().toISOString(),
} = {}) {
  const targetAccount = text(account, "account");
  const providerContract = normalizedDeskProviderContract(providerContractInput);
  const revisionMethod = text(historyRevisionMethod, "historyRevisionMethod");
  if (typeof buildBoundaryEvidence !== "function") throw new TypeError("all-desk boundary evidence builder is required");
  if (typeof getVerifiedHistoryState !== "function") throw new TypeError("verified history state reader is required");
  const sourceContract = {
    method: providerContract.method,
    classifier: {
      method: providerContract.policyMethod,
      policyHash: providerContract.policyHash,
    },
    historyRevisionMethod: revisionMethod,
    scope: INPUT_SCOPE,
    keepExcluded: true,
  };
  const adapter = createDayBaselineAdapter({
    account: targetAccount,
    sourceContract,
    store,
    boundaryFreshMs,
    currentFreshMs,
    now,
  });

  function observe(value) {
    let observation;
    try {
      observation = deskObservation(value, providerContract, sourceContract);
    } catch (error) {
      return unavailable(error.message);
    }
    let result = adapter.observe(observation);
    const pending = adapter.inspectState()?.pending;
    if (!pending) return result;

    let verifiedHistoryState;
    let boundary;
    const proofObservedAt = now();
    try {
      verifiedHistoryState = getVerifiedHistoryState();
      boundary = buildBoundaryEvidence({
        verifiedHistoryState,
        account: targetAccount,
        policy,
        candidateSourceObservedAt: pending.candidate.sourceObservedAt,
        candidateHistoryRevision: pending.candidate.provenance.historyRevision,
        periodStart: pending.periodStart,
        proofObservedAt,
      });
    } catch (error) {
      return unavailable(`SOD boundary proof failed: ${error?.message || error}`);
    }
    if (!boundary?.ok) return unavailable(`SOD boundary proof unavailable: ${boundary?.reason || "unknown reason"}`);
    if (boundary.historyRevisionMethod !== revisionMethod || boundary.policyHash !== providerContract.policyHash) {
      return unavailable("SOD boundary proof contract does not match the configured ownership policy");
    }
    result = adapter.observe(observation, {
      boundaryProof: {
        periodStart: boundary.periodStart,
        proofObservedAt: boundary.proofObservedAt,
        provenance: {
          ...sourceContract,
          historyRevision: boundary.boundaryHistoryRevision,
          executionCoverage: boundary.executionCoverage,
        },
      },
    });
    return result;
  }

  return {
    observe,
    project: () => adapter.project(),
    inspectState: () => adapter.inspectState(),
    get blockedReason() { return adapter.blockedReason; },
  };
}

export const DAY_BASELINE_STATE_SCHEMA = STATE_SCHEMA;
export const DAY_PNL_METHOD = OUTPUT_METHOD;
export const DAY_BASELINE_INPUT_SCOPE = INPUT_SCOPE;
