import {
  appendFileSync,
  closeSync,
  constants,
  fstatSync,
  fsyncSync,
  linkSync,
  openSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";

import { ACCOUNT, digest, newYorkDay, validateKey } from "./policy.mjs";
import { confinedPath } from "./security.mjs";
import { planReattribution, pruneForeignAlerts } from "./attribution.mjs";

export const RETENTION_MS = 14 * 24 * 60 * 60_000;
export const RECON_RETENTION_MS = 48 * 60 * 60_000;
const MAX_INTENTS = 5000;
export const MAX_STATE_BYTES = 16 * 1024 * 1024;
export const MAX_RECON_EVIDENCE_BYTES = 8 * 1024 * 1024;
const MAX_AUDIT_BYTES = 1024 * 1024;

function reconRetention(value) {
  if (value === undefined) {
    const hours = Number(process.env.PAPER_DESK_RECON_RETENTION_HOURS ?? 48);
    if (!Number.isFinite(hours) || hours < 16 / 60 || hours > 336) throw new Error("PAPER_DESK_RECON_RETENTION_HOURS must be finite and between 16/60 and 336 hours (16 minutes to 14 days)");
    value = Math.round(hours * 3_600_000);
  }
  // Intent validity is 15 minutes with up to 60 seconds of future clock skew.
  // Keep the receipt for the entire accepted replay window.
  if (!Number.isSafeInteger(value) || value < 16 * 60_000 || value > RETENTION_MS) throw new Error("recon retention must be between 16 minutes and 14 days");
  return value;
}

const RECON_COUNTED_FIELDS = ["positions", "deskPositions", "openOrders", "executions", "pnlPerDesk", "errors", "resolutions", "marks", "foreignPositions", "foreignExecutions"];

function reconReceipt(result) {
  const receipt = { resultCompacted: true, snapshot: "omitted", resultSha256: digest(result), omittedCounts: {} };
  for (const [key, limit] of [["status", 32], ["intentId", 64], ["desk", 8], ["action", 16], ["observedAt", 64], ["account", 32], ["code", 80], ["reason", 500]]) {
    if (typeof result[key] === "string") receipt[key] = result[key].slice(0, limit);
  }
  for (const key of ["gateway", "ownershipComplete"]) if (typeof result[key] === "boolean") receipt[key] = result[key];
  if (typeof result.paperPort === "number") receipt.paperPort = result.paperPort;
  if (result.ownershipHistory) receipt.ownershipHistory = Object.fromEntries(["status", "reason"].filter((key) => typeof result.ownershipHistory[key] === "string").map((key) => [key, result.ownershipHistory[key].slice(0, key === "reason" ? 500 : 32)]));
  // Counted fields are a fixed list (CodeQL: no property names taken from the result).
  for (const key of RECON_COUNTED_FIELDS) {
    const value = result[key];
    if (Array.isArray(value)) receipt.omittedCounts[key] = value.length;
    else if (value && typeof value === "object") receipt.omittedCounts[key] = Object.keys(value).length;
  }
  return receipt;
}

function dictionary(value, kind) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`invalid ${kind} dictionary`);
  const result = new Map();
  for (const [key, row] of value instanceof Map ? value : Object.entries(value)) result.set(validateKey(key, kind), row);
  return result;
}

function firstOrderDictionary(value) {
  const result = dictionary(value, "desk");
  for (const [desk, dates] of result) result.set(desk, dictionary(dates, "symbol"));
  return result;
}

// Maps stay in memory; the ledger keeps its existing plain JSON dictionaries.
function serializeState(state) {
  const { attributionConfig: _runtimeConfig, ...persisted } = state;
  return JSON.stringify({
    ...persisted,
    intents: Object.fromEntries(dictionary(state.intents, "intentId")),
    firstOrders: Object.fromEntries([...firstOrderDictionary(state.firstOrders)].map(([desk, dates]) => [desk, Object.fromEntries(dates)])),
  });
}

// First-order dates survive placement retention; they contain no fill quantities.
export function rememberFirstOrders(state) {
  if (!state.firstOrders) {
    state.firstOrders = new Map();
    // Older ledgers may already have pruned their earliest placements.
    state.ownershipHistoryFrom = state.initializedAt;
  }
  state.firstOrders = firstOrderDictionary(state.firstOrders);
  for (const row of state.placements) {
    if (row.desk === undefined && row.symbol === undefined) continue;
    const desk = validateKey(row.desk, "desk");
    const symbol = validateKey(row.symbol, "symbol");
    if (row.intentId !== undefined) validateKey(row.intentId, "intentId");
    if (row.orderRef !== undefined) validateKey(row.orderRef, "orderRef");
    const timestamp = Date.parse(row.reservedAt);
    const day = Number.isFinite(timestamp) ? newYorkDay(timestamp) : row.day;
    if (!day) throw new Error("first-order ownership date is missing");
    let dates = state.firstOrders.get(desk);
    if (!dates) { dates = new Map(); state.firstOrders.set(desk, dates); }
    if (!dates.get(symbol) || day < dates.get(symbol)) dates.set(symbol, day);
  }
}

export function pruneState(state, now = Date.now(), { reconRetentionMs = reconRetention(), beforePrune = () => {} } = {}) {
  beforePrune(state);
  pruneForeignAlerts(state, undefined, now);
  state.intents = dictionary(state.intents, "intentId");
  rememberFirstOrders(state);
  for (const [id, row] of state.intents) {
    const recon = row.action === "recon";
    if ((recon || !["claimed", "uncertain"].includes(row.status)) && now - Date.parse(row.finishedAt || row.claimedAt) > (recon ? reconRetentionMs : RETENTION_MS)) state.intents.delete(id);
  }
  state.placements = state.placements.filter((row) => ["reserved", "uncertain", "partial"].includes(row.status) || row.stopHistory?.some((change) => ["reserved", "uncertain"].includes(change.status)) || now - Date.parse(row.reservedAt || `${row.day}T00:00:00Z`) <= RETENTION_MS);
}

export function admitIntent(state, action, options) {
  pruneState(state, Date.now(), options);
  // A full recon receipt budget must not consume the state-changing claim
  // budget. Both remain bounded; only another recon is refused at its cap.
  const claims = [...state.intents.values()].filter((row) => (row.action === "recon") === (action === "recon")).length;
  if (claims >= MAX_INTENTS || state.executions.length >= 50000 || Buffer.byteLength(serializeState(state)) > MAX_STATE_BYTES - 262144) throw new Error("ledger capacity reached; new intents refused while evidence is retained");
}

const STATE_SCHEMA = "barta.paper-desk-executor-state.v1";

function writeAtomic(filePath, body, { exclusive = false } = {}) {
  const temporary = `${filePath}.${randomUUID()}.new`;
  const handle = openSync(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try {
    try {
      writeFileSync(handle, body);
      fsyncSync(handle);
    } finally {
      closeSync(handle);
    }
    // A hard link publishes a fully written initial ledger without replacing
    // a ledger concurrently created by another process.
    if (exclusive) linkSync(temporary, filePath);
    else renameSync(temporary, filePath);
  } finally {
    try { unlinkSync(temporary); } catch (error) { if (error.code !== "ENOENT") throw error; }
  }
  const directory = openSync(path.dirname(filePath), constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
  try { fsyncSync(directory); } finally { closeSync(directory); }
}

export function openLedger(root, { reconRetentionMs = reconRetention(), beforePrune = () => {} } = {}) {
  reconRetentionMs = reconRetention(reconRetentionMs);
  const resolvedRoot = path.resolve(root);
  const statePath = confinedPath(resolvedRoot, path.join(resolvedRoot, "ledger.json"), "state path");
  const auditPath = confinedPath(resolvedRoot, path.join(resolvedRoot, "audit.jsonl"), "audit path");
  const haltPath = confinedPath(resolvedRoot, path.join(resolvedRoot, "HALT"), "local HALT path");
  const reconEvidencePath = confinedPath(resolvedRoot, path.join(resolvedRoot, "recon-evidence.jsonl"), "recon evidence path");
  const backupPath = confinedPath(resolvedRoot, path.join(resolvedRoot, "ledger.pre-ops331.json"), "ledger backup path");
  let headroomWarning = false;

  function headroom(bytes) {
    const ledgerPercent = bytes / MAX_STATE_BYTES * 100;
    if (ledgerPercent >= 75 && !headroomWarning) console.warn(JSON.stringify({ event: "ledger_headroom_warning", ledgerBytes: bytes, ledgerPercent, ledgerMaxBytes: MAX_STATE_BYTES }));
    headroomWarning = ledgerPercent >= 75;
    return { ledgerBytes: bytes, ledgerPercent, ledgerMaxBytes: MAX_STATE_BYTES };
  }

  function readBounded(file, limit) {
    const handle = openSync(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
      const info = fstatSync(handle);
      if (!info.isFile() || info.size > limit) throw new Error("executor evidence exceeds size limit or is not a regular file");
      return readFileSync(handle, "utf8");
    } finally { closeSync(handle); }
  }

  function appendReconEvidence(lines) {
    let current = "";
    try { current = readBounded(reconEvidencePath, MAX_RECON_EVIDENCE_BYTES); }
    catch (error) { if (error.code !== "ENOENT") throw error; }
    let bytes = Buffer.byteLength(current);
    for (const line of lines) {
      const size = Buffer.byteLength(line);
      if (size > MAX_RECON_EVIDENCE_BYTES) throw new Error("recon evidence row exceeds size limit");
      if (bytes + size > MAX_RECON_EVIDENCE_BYTES) {
        // Publish the previous complete generation first. A crash between the
        // two atomic writes can duplicate evidence, never truncate a JSON line.
        writeAtomic(`${reconEvidencePath}.1`, current);
        current = "";
        bytes = 0;
      }
      current += line;
      bytes += size;
    }
    writeAtomic(reconEvidencePath, current);
  }

  function compactRecons(state, { backedUp = false } = {}) {
    state.intents = dictionary(state.intents, "intentId");
    const changes = [];
    function* evidenceLines() {
      for (const [intentId, record] of state.intents) {
        if (record.action !== "recon" || !record.result || record.result.resultCompacted === true) continue;
        // Keep just one normalized result alive; archive strings are bounded
        // to one generation, rather than cloning the entire legacy ledger.
        let result = JSON.parse(JSON.stringify(record.result));
        const receipt = reconReceipt(result);
        changes.push([intentId, { ...record, result: receipt }]);
        const line = `${JSON.stringify({ intentId, desk: record.desk, observedAt: result.observedAt || record.finishedAt || record.claimedAt, resultSha256: receipt.resultSha256, result })}\n`;
        result = null;
        yield line;
      }
    }
    const pending = [...state.intents.values()].some((row) => row.action === "recon" && row.result && row.result.resultCompacted !== true);
    if (!pending) return;
    try { appendReconEvidence(evidenceLines()); }
    catch (error) {
      if (!backedUp) throw error;
      // Only migration has a durable, complete source before archiving. It
      // must still unblock admission if the bounded archive is unavailable.
      console.error(JSON.stringify({ event: "recon_migration_archive_failed", backup: path.basename(backupPath), migrationBackupAvailable: true, code: error.code || "archive_error", reason: error.message }));
      changes.length = 0;
      for (const [intentId, record] of state.intents) {
        if (record.action === "recon" && record.result && record.result.resultCompacted !== true) changes.push([intentId, { ...record, result: reconReceipt(JSON.parse(JSON.stringify(record.result))) }]);
      }
    }
    // The archive (or migration backup) is durable before replacing results.
    for (const [intentId, record] of changes) state.intents.set(intentId, record);
  }

  function usage() {
    const handle = openSync(statePath, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
      const info = fstatSync(handle);
      if (!info.isFile()) throw new Error("executor ledger is not a regular file");
      return headroom(info.size);
    } finally { closeSync(handle); }
  }

  function initialState() {
    return {
      schema: STATE_SCHEMA,
      account: ACCOUNT,
      initializedAt: new Date().toISOString(),
      reconStorageVersion: 1,
      firstOrders: new Map(),
      intents: new Map(),
      placements: [],
      executions: [],
    };
  }

  function audit(event) {
    let row = `${JSON.stringify({ at: new Date().toISOString(), ...event })}\n`;
    if (Buffer.byteLength(row) > 65536) row = `${JSON.stringify({ at: new Date().toISOString(), event: event.event, intentId: event.intentId, status: event.status, resultOmitted: "large result retained in ledger" })}\n`;
    function openAudit() {
      const handle = openSync(auditPath, constants.O_WRONLY | constants.O_APPEND | constants.O_CREAT | constants.O_NOFOLLOW | constants.O_NONBLOCK, 0o600);
      if (!fstatSync(handle).isFile()) {
        closeSync(handle);
        throw new Error("executor audit is not a regular file");
      }
      return handle;
    }
    let handle = openAudit();
    try {
      const info = fstatSync(handle);
      if (info.size + Buffer.byteLength(row) > MAX_AUDIT_BYTES) {
        renameSync(auditPath, `${auditPath}.1`);
        closeSync(handle);
        handle = undefined;
        handle = openAudit();
      }
      appendFileSync(handle, row);
      fsyncSync(handle);
    } finally {
      if (handle !== undefined) closeSync(handle);
    }
  }

  function save(state) {
    // Capture once, before compaction; pruneState below uses its no-op hook.
    beforePrune(state);
    compactRecons(state);
    pruneState(state, Date.now(), { reconRetentionMs });
    persist(state);
  }

  function persist(state) {
    const body = `${serializeState(state)}\n`;
    if (Buffer.byteLength(body) > MAX_STATE_BYTES) throw new Error("ledger size limit reached; evidence retained");
    writeAtomic(statePath, body);
    headroom(Buffer.byteLength(body));
  }

  function load({ initialize = true, readOnly = false } = {}) {
    let handle;
    try {
      handle = openSync(statePath, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
      if (!initialize || readOnly) return initialState();
      const initial = initialState();
      try {
        writeAtomic(statePath, `${serializeState(initial)}\n`, { exclusive: true });
        audit({ event: "ledger_initialized", initializedAt: initial.initializedAt });
      } catch (error) {
        if (error.code !== "EEXIST") throw error;
      }
      handle = openSync(statePath, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    }
    let value, original, loadedBytes;
    try {
      const info = fstatSync(handle);
      if (!info.isFile() || info.size > MAX_STATE_BYTES) throw new Error("executor ledger exceeds size limit or is not a regular file");
      loadedBytes = info.size;
      original = readFileSync(handle, "utf8");
      value = JSON.parse(original);
    } finally { closeSync(handle); }
    if (value?.schema !== STATE_SCHEMA || value?.account !== ACCOUNT
        || !Number.isFinite(Date.parse(value.initializedAt)) || !value.intents
        || Array.isArray(value.intents) || !Array.isArray(value.placements)
        || !Array.isArray(value.executions)) {
      throw new Error("executor state is invalid");
    }
    if (value.reconStorageVersion !== undefined && value.reconStorageVersion !== 1) throw new Error(`unsupported reconStorageVersion: ${value.reconStorageVersion}; refusing to migrate or downgrade`);
    value.intents = dictionary(value.intents, "intentId");
    delete value.attributionConfig;
    rememberFirstOrders(value);
    const legacyRecons = [...value.intents.values()].some((row) => row.action === "recon" && row.result && row.result.resultCompacted !== true);
    if (!readOnly && (value.reconStorageVersion !== 1 || legacyRecons)) {
      beforePrune(value);
      try { writeAtomic(backupPath, original, { exclusive: true }); }
      catch (error) {
        if (error.code !== "EEXIST") throw error;
        // An existing regular backup is immutable; a symlink/directory is not
        // a backup and must fail closed before publishing a migrated ledger.
        const backup = openSync(backupPath, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
        try {
          if (!fstatSync(backup).isFile()) throw new Error("executor backup is not a regular file");
        } finally { closeSync(backup); }
      }
      original = null;
      compactRecons(value, { backedUp: true });
      value.reconStorageVersion = 1;
      // Migration preserves every non-recon row, even if already expired.
      // Normal admission/save retention happens only after publication.
      persist(value);
    } else if (!readOnly) headroom(loadedBytes);
    return value;
  }

  function haltBody() {
    try {
      const handle = openSync(haltPath, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
      try {
        if (!fstatSync(handle).isFile()) throw new Error("local HALT is not a regular file");
        return readFileSync(handle, "utf8");
      } finally { closeSync(handle); }
    } catch (error) {
      if (error?.code === "ENOENT") return "";
      throw error;
    }
  }

  function setHalt(reason) {
    const text = String(reason || "halt").trim() || "halt";
    if (text.length > 240) throw new Error("halt reason is too long");
    const body = `${JSON.stringify({ at: new Date().toISOString(), reason: text })}\n`;
    writeAtomic(haltPath, body);
    audit({ event: "halt_set", reason: text });
    return body;
  }

  function reattribute(request, options) {
    const planned = planReattribution(load({ initialize: false }), request, options);
    if (!planned.result.dryRun) {
      // The journal and assignment publish together in the atomic ledger save.
      save(planned.state);
      audit(planned.journal);
    }
    return planned.result;
  }

  return { root: resolvedRoot, statePath, auditPath, haltPath, reconEvidencePath, backupPath, reconRetentionMs, beforePrune, load, save, usage, audit, haltBody, setHalt, reattribute };
}
