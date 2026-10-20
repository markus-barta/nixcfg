import {
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
import { createHash, randomUUID } from "node:crypto";

import { ACCOUNT, digest, newYorkDay, validateKey } from "./policy.mjs";
import { confinedPath } from "./security.mjs";
import { planReattribution, pruneForeignAlerts } from "./attribution.mjs";

export const RETENTION_MS = 14 * 24 * 60 * 60_000;
export const RECON_RETENTION_MS = 48 * 60 * 60_000;
const MAX_INTENTS = 5000;
export const MAX_STATE_BYTES = 16 * 1024 * 1024;
export const CAPTURE_DEGRADED_ADMISSION_BYTES = Math.floor(MAX_STATE_BYTES * 0.9);
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

// Only fixed classes cross the diagnostic boundary; exception messages and
// arbitrary error codes can contain broker evidence or filesystem paths.
const CAPTURE_ERROR_CODES = new Set(["ENOSPC", "EIO", "EDQUOT", "EACCES", "EPERM", "EROFS", "ENOENT", "EMFILE", "ENFILE", "EFBIG"]);

function captureFailure(state, error, now = Date.now()) {
  const at = new Date(now).toISOString();
  const code = CAPTURE_ERROR_CODES.has(error?.code) ? error.code : "unavailable";
  const previous = state.resultsCapture;
  state.resultsCapture = {
    ok: false, since: previous?.ok === false ? previous.since : at,
    lastErrorAt: at, code, count: (previous?.count || 0) + 1,
    ...(previous?.lastRecoveredAt ? { lastRecoveredAt: previous.lastRecoveredAt } : {}),
  };
  const retentionDays = Number(process.env.PAPER_DESK_FOREIGN_ALERT_RETENTION_DAYS || 14);
  const alerts = (state.resultsCaptureAlerts || []).filter(row => !row.resolvedAt || now - Date.parse(row.lastSeenAt || row.at) <= retentionDays * 86400000);
  let receipt = alerts.find(row => row.code === code && !row.resolvedAt);
  const transition = !receipt || !!receipt.resolvedAt;
  if (!receipt) {
    receipt = { key: `results_capture:${code}`, outageId: randomUUID(), event: "results_capture_failed", ticket: "JOED-43", at, code, count: 0 };
    alerts.push(receipt);
  }
  receipt.lastSeenAt = at;
  delete receipt.resolvedAt;
  receipt.count++;
  // One receipt per allowlisted class, independently of evidence retention.
  // Keep all unresolved classes plus a bounded history of resolved outages.
  state.resultsCaptureAlerts = [...alerts.filter(row => !row.resolvedAt), ...alerts.filter(row => row.resolvedAt).slice(-128)];
  if (transition) {
    try { console.error(JSON.stringify({ event: "results_capture_failed", code })); }
    catch { /* Diagnostics must also fail open. */ }
  }
}

function captureBeforePrune(state, beforePrune, now = Date.now()) {
  if (!beforePrune) return true;
  try { beforePrune(state); }
  catch (error) { captureFailure(state, error, now); return false; }
  return true;
}

function captureRecovered(state, now = Date.now()) {
  if (state.resultsCapture?.ok !== false) return;
  const at = new Date(now).toISOString();
  state.resultsCapture = { ...state.resultsCapture, ok: true, lastRecoveredAt: at };
  if (state.resultsCaptureAlerts) state.resultsCaptureAlerts = state.resultsCaptureAlerts
    .map(receipt => receipt.resolvedAt ? receipt : { ...receipt, resolvedAt: at })
    .sort((a, b) => Date.parse(a.resolvedAt) - Date.parse(b.resolvedAt)).slice(-128);
}

function pruneRetainedState(state, now, reconRetentionMs) {
  if (state.resultsCaptureAlerts) {
    const retentionDays = Number(process.env.PAPER_DESK_FOREIGN_ALERT_RETENTION_DAYS || 14);
    state.resultsCaptureAlerts = state.resultsCaptureAlerts.filter(row => !row.resolvedAt || now - Date.parse(row.lastSeenAt || row.at) <= retentionDays * 86400000);
  }
  pruneForeignAlerts(state, undefined, now);
  state.intents = dictionary(state.intents, "intentId");
  rememberFirstOrders(state);
  for (const [id, row] of state.intents) {
    const recon = row.action === "recon";
    if ((recon || !["claimed", "uncertain"].includes(row.status)) && now - Date.parse(row.finishedAt || row.claimedAt) > (recon ? reconRetentionMs : RETENTION_MS)) state.intents.delete(id);
  }
  state.placements = state.placements.filter((row) => ["reserved", "uncertain", "partial"].includes(row.status) || row.stopHistory?.some((change) => ["reserved", "uncertain"].includes(change.status)) || now - Date.parse(row.reservedAt || `${row.day}T00:00:00Z`) <= RETENTION_MS);
}

export function pruneState(state, now = Date.now(), { reconRetentionMs = reconRetention(), beforePrune } = {}) {
  if (!beforePrune) return pruneRetainedState(state, now, reconRetentionMs);
  if (!captureBeforePrune(state, beforePrune, now)) return;
  // Admission does retention only. Recovery waits for save's full compaction,
  // catch-up prune and durable publication, even if this capture succeeds.
  try {
    const next = { ...state };
    pruneRetainedState(next, now, reconRetentionMs);
    Object.assign(state, next);
  } catch (error) { captureFailure(state, error, now); }
}

export function admitIntent(state, action, options) {
  pruneState(state, Date.now(), options);
  // A failed capture skips retention, but admission still accepts the same
  // plain dictionaries as the normal pruning path without dropping any rows.
  if (!(state.intents instanceof Map)) state.intents = dictionary(state.intents, "intentId");
  if (options?.beforePrune && state.resultsCapture?.ok === false
      && Buffer.byteLength(serializeState(state)) + 1 >= CAPTURE_DEGRADED_ADMISSION_BYTES
      && !["recon", "cancel", "flatten", "modify-stop"].includes(action)) {
    throw Object.assign(new Error("results_capture_degraded_ledger_cap"), {
      publicCode: "results_capture_degraded_ledger_cap", statusCode: 422,
    });
  }
  // A full recon receipt budget must not consume the state-changing claim
  // budget. Both remain bounded; only another recon is refused at its cap.
  const claims = [...state.intents.values()].filter((row) => (row.action === "recon") === (action === "recon")).length;
  if (claims >= MAX_INTENTS || state.executions.length >= 50000 || Buffer.byteLength(serializeState(state)) > MAX_STATE_BYTES - 262144) throw new Error("ledger capacity reached; new intents refused while evidence is retained");
}

const STATE_SCHEMA = "barta.paper-desk-executor-state.v1";

// Every caller gets the same publication contract. A pre-publication error
// throws with published=false; visible bytes always return an
// outcome, even if their crash durability could not be confirmed afterward.
function writeAtomic(filePath, body, { exclusive = false } = {}) {
  const temporary = `${filePath}.${randomUUID()}.new`;
  let publishedAt, error, created = false, published = false;
  try {
    const handle = openSync(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    created = true;
    try {
      writeFileSync(handle, body);
      fsyncSync(handle);
      publishedAt = new Date(fstatSync(handle).mtimeMs).toISOString();
    } finally { closeSync(handle); }
    // The exclusive link never replaces a concurrently published winner.
    if (exclusive) linkSync(temporary, filePath);
    else renameSync(temporary, filePath);
    published = true;
  } catch (caught) { error = caught; }
  if (created) {
    try { unlinkSync(temporary); }
    catch (caught) { if (caught.code !== "ENOENT") error ??= caught; }
  }
  if (published && !error) {
    try {
      const directory = openSync(path.dirname(filePath), constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
      try { fsyncSync(directory); } finally { closeSync(directory); }
    } catch (caught) { error = caught; }
  }
  const errorClass = error ? (CAPTURE_ERROR_CODES.has(error.code) || error.code === "EEXIST" ? error.code : "unavailable") : undefined;
  if (!published) {
    throw Object.assign(error, { published: false, errorClass });
  }
  const outcome = { published: true, durability: error ? "uncertain" : "ok", errorClass, publishedAt };
  if (error) Object.assign(error, { published: true, durability: "uncertain", errorClass });
  return { ...outcome, error };
}

export function openLedger(root, { reconRetentionMs = reconRetention(), beforePrune } = {}) {
  reconRetentionMs = reconRetention(reconRetentionMs);
  const resolvedRoot = path.resolve(root);
  const statePath = confinedPath(resolvedRoot, path.join(resolvedRoot, "ledger.json"), "state path");
  const auditPath = confinedPath(resolvedRoot, path.join(resolvedRoot, "audit.jsonl"), "audit path");
  const haltPath = confinedPath(resolvedRoot, path.join(resolvedRoot, "HALT"), "local HALT path");
  const reconEvidencePath = confinedPath(resolvedRoot, path.join(resolvedRoot, "recon-evidence.jsonl"), "recon evidence path");
  const backupPath = confinedPath(resolvedRoot, path.join(resolvedRoot, "ledger.pre-ops331.json"), "ledger backup path");
  let headroomWarning = false;
  // Only diagnostics may outlive a failed publication in memory. Claims and
  // evidence must still come from disk on the next load.
  let pendingCaptureFailure, pendingCaptureAnchor;
  let captureRevision = 0, durableCaptureAnchor, durableCaptureAt, durableCaptureStatus, durabilityWarning;
  let durableCaptureOutages = new Set();
  let durableCaptureAlerts = [];
  const publishedLedgerErrors = new WeakSet();
  let durabilityRevision = 0;

  function publish(file, body, options) {
    const outcome = writeAtomic(file, body, options);
    if (outcome.durability === "uncertain") {
      durabilityWarning = { durability: "uncertain", durabilityCode: outcome.errorClass };
      durabilityRevision++;
    }
    return outcome;
  }

  function rememberDurableCapture(body, state, at) {
    if (!beforePrune) return;
    // Publication time distinguishes a healthy rewrite of identical bytes
    // while remaining stable across restarts of an unchanged full volume.
    durableCaptureAnchor = createHash("sha256").update(`${at}\n`).update(body).digest("hex");
    durableCaptureAt = at;
    durableCaptureOutages = new Set((state.resultsCaptureAlerts ?? []).map(row => row.outageId));
    // Never alias the mutable pending delivery bookkeeping into this snapshot.
    durableCaptureAlerts = structuredClone(state.resultsCaptureAlerts ?? []);
    durableCaptureStatus = structuredClone(state.resultsCapture);
  }

  function adoptPublishedCapture(state, { adoptDelivery = false } = {}) {
    const alerts = state.resultsCaptureAlerts ?? [];
    for (const receipt of alerts) {
      const published = durableCaptureAlerts.find(row => row.outageId && row.outageId === receipt.outageId)
        ?? (!receipt.resolvedAt && durableCaptureAlerts.find(row => !row.resolvedAt && row.code === receipt.code));
      if (!published) continue;
      if (adoptDelivery) Object.assign(receipt, structuredClone(published));
      // An outage's published resolution always wins over an old overlay.
      if (published.resolvedAt) receipt.resolvedAt = published.resolvedAt;
      else delete receipt.resolvedAt;
      // An older pending overlay must not replace the receipt other readers
      // see. Same-generation memory may hold a newer unsaved delivery result.
      if (adoptDelivery || receipt.outageId !== published.outageId || receipt.at !== published.at) {
        receipt.outageId = published.outageId;
        receipt.at = published.at;
        delete receipt.delivery;
        if (published.delivery) receipt.delivery = structuredClone(published.delivery);
      }
    }
    if (state.resultsCaptureAlerts) state.resultsCaptureAlerts = [...alerts,
      ...durableCaptureAlerts.filter(row => !alerts.some(receipt => receipt.outageId === row.outageId)).map(row => structuredClone(row))];
    if (durableCaptureStatus?.ok === true && state.resultsCaptureAlerts?.every(row => row.resolvedAt)) {
      state.resultsCapture = structuredClone(durableCaptureStatus);
    }
  }

  function retainCaptureFailure(state) {
    // A never-persisted outage must reconstruct the same delivery identity
    // after a full-disk restart. The last durable ledger anchors both key and
    // message timestamp; no evidence values enter the diagnostic. Previously
    // persisted outage IDs, bodies and delivery budgets remain authoritative.
    adoptPublishedCapture(state);
    for (const receipt of state.resultsCaptureAlerts ?? []) {
      if (receipt.resolvedAt || durableCaptureOutages.has(receipt.outageId)) continue;
      receipt.outageId = digest({ event: "unpersisted_capture_failure", code: receipt.code,
        anchor: durableCaptureAnchor ?? resolvedRoot });
      receipt.at = durableCaptureAt ?? state.initializedAt;
    }
    pendingCaptureFailure = { resultsCapture: state.resultsCapture, resultsCaptureAlerts: state.resultsCaptureAlerts };
    pendingCaptureAnchor = durableCaptureAnchor;
    captureRevision++;
  }

  function captureDiagnostics() {
    return { revision: captureRevision, persisted: !pendingCaptureFailure, ...durabilityWarning };
  }

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
        publish(`${reconEvidencePath}.1`, current);
        current = "";
        bytes = 0;
      }
      current += line;
      bytes += size;
    }
    publish(reconEvidencePath, current);
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
    // The archive (or migration backup) is published before replacing results.
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
      ...pendingCaptureFailure,
    };
  }

  function audit(event) {
    // Reads the whole file and atomically rewrites up to 1 MiB, plus fsync per row.
    // Safe only with synchronous callers in this single executor Node process:
    // no second process (CLI or tool) may write audit.jsonl. Near a full volume,
    // the rewrite needs about 1 MiB free where an append needed only one row.
    let row = `${JSON.stringify({ at: new Date().toISOString(), ...event })}\n`;
    if (Buffer.byteLength(row) > 65536) row = `${JSON.stringify({ at: new Date().toISOString(), event: event.event, intentId: event.intentId, status: event.status, resultOmitted: "large result retained in ledger" })}\n`;
    let current = "";
    try { current = readBounded(auditPath, MAX_AUDIT_BYTES); }
    catch (error) { if (error.code !== "ENOENT") throw error; }
    if (Buffer.byteLength(current) + Buffer.byteLength(row) > MAX_AUDIT_BYTES) {
      publish(`${auditPath}.1`, current);
      current = "";
    }
    publish(auditPath, current + row);
  }

  function save(state) {
    const warningSince = durabilityRevision;
    // Preserve capture-off's exact serialization and retention path.
    if (!beforePrune) {
      compactRecons(state);
      pruneState(state, Date.now(), { reconRetentionMs });
      persist(state, { warningSince });
      return;
    }
    if (!captureBeforePrune(state, beforePrune)) { persist(state, { retainOnFailure: true, warningSince }); return; }
    let next;
    try {
      // Keep live placement/stop-change identity across catch-up: the
      // executor updates those objects after broker acknowledgement.
      next = { ...state };
      compactRecons(next);
      pruneState(next, Date.now(), { reconRetentionMs });
      captureRecovered(next);
    } catch (error) {
      captureFailure(state, error);
      persist(state, { retainOnFailure: true, warningSince });
      return;
    }
    persist(next, { target: state, retainOnFailure: state.resultsCapture?.ok === false, warningSince });
  }

  function persist(state, { target = state, exclusive = false, retainOnFailure = false, warningSince = durabilityRevision } = {}) {
    let published = false;
    try {
      const body = `${serializeState(state)}\n`;
      if (Buffer.byteLength(body) > MAX_STATE_BYTES) throw new Error("ledger size limit reached; evidence retained");
      const outcome = publish(statePath, body, { exclusive });
      published = outcome.published;
      // Adopt visible bytes before propagating a ledger durability warning.
      // In particular, a claim stays visible but cannot reach the broker.
      Object.assign(target, state);
      rememberDurableCapture(body, state, outcome.publishedAt);
      pendingCaptureFailure = pendingCaptureAnchor = undefined;
      if (durabilityRevision === warningSince) durabilityWarning = undefined;
      captureRevision++;
      if (outcome.durability === "uncertain") {
        throw outcome.error;
      }
      headroom(Buffer.byteLength(body));
    } catch (error) {
      if (published) throw publishedLedgerError(error);
      if (!published && retainOnFailure) retainCaptureFailure(target);
      // Claims still fail closed on any I/O error. Only pre-publication
      // failures may retain diagnostics over the ledger other readers open.
      throw error;
    }
  }

  function publishedLedgerError(error) {
    // The receipt covers all bookkeeping after this generation became visible,
    // including diagnostics that throw after an otherwise durable write.
    if (!error || (typeof error !== "object" && typeof error !== "function")) error = new Error("ledger post-publication failure");
    error.published = true;
    publishedLedgerErrors.add(error);
    return error;
  }

  function noteCaptureFailure(error) {
    // Startup catches ledger I/O too. A visible ledger with uncertain fsync
    // must never become a fresh capture failure in that outer handler.
    if (error?.published === true || publishedLedgerErrors.has(error)) return;
    // Startup's caller holds the exclusive queue. Never publish a possibly
    // stale snapshot while storage itself is unavailable.
    const state = load({ initialize: false, readOnly: true, migrate: false });
    captureFailure(state, error);
    retainCaptureFailure(state);
  }

  function updateCaptureDelivery(outageId, event, update) {
    // Called only by the background sender under the server's exclusive queue.
    // Publish diagnostics without invoking capture, retention or recovery.
    const state = load({ initialize: false, readOnly: true });
    const receipt = state.resultsCaptureAlerts?.find(row => (row.outageId ?? `${row.code}:${row.at}`) === outageId);
    if (!receipt) return;
    receipt.delivery ??= {};
    receipt.delivery[event] = update(receipt.delivery[event], receipt);
    try { persist(state, { retainOnFailure: true }); }
    catch {
      // The sender is best effort even if the shared volume cannot publish
      // its attempt marker. Keep the same finite per-receipt retry budget.
    }
    return receipt.delivery[event];
  }

  function rearmCaptureDelivery() {
    // The HTTP admin caller holds the same exclusive queue as intent saves.
    // No capture, retention, recovery or evidence mutation occurs here.
    const state = load({ initialize: false, readOnly: true, migrate: false });
    let rearmed = 0;
    state.resultsCaptureAlerts = (state.resultsCaptureAlerts ?? []).map(receipt => {
      if (receipt.resolvedAt || receipt.delivery?.failure?.status !== "failed") return receipt;
      rearmed++;
      return { ...receipt, delivery: { ...receipt.delivery,
        failure: { ...receipt.delivery.failure, attempts: 0, status: "pending", nextAttemptAt: 0 } } };
    });
    if (rearmed) persist(state);
    return { status: "ok", rearmed };
  }

  function load({ initialize = true, readOnly = false, migrate = true } = {}) {
    let handle;
    try {
      handle = openSync(statePath, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
      if (!initialize || readOnly) return initialState();
      const initial = initialState();
      let initialized = false;
      try {
        persist(initial, { exclusive: true });
        initialized = true;
        audit({ event: "ledger_initialized", initializedAt: initial.initializedAt });
      } catch (error) {
        if (initialized) throw publishedLedgerError(error);
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
      rememberDurableCapture(original, value, new Date(info.mtimeMs).toISOString());
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
    if (pendingCaptureFailure) {
      Object.assign(value, pendingCaptureFailure);
      adoptPublishedCapture(value, { adoptDelivery: pendingCaptureAnchor !== durableCaptureAnchor });
      pendingCaptureFailure = { resultsCapture: value.resultsCapture, resultsCaptureAlerts: value.resultsCaptureAlerts };
      pendingCaptureAnchor = durableCaptureAnchor;
      if (JSON.stringify(pendingCaptureFailure) === JSON.stringify({ resultsCapture: durableCaptureStatus, resultsCaptureAlerts: durableCaptureAlerts })) {
        pendingCaptureFailure = pendingCaptureAnchor = undefined;
      }
    }
    const legacyRecons = [...value.intents.values()].some((row) => row.action === "recon" && row.result && row.result.resultCompacted !== true);
    if (!readOnly && migrate && (value.reconStorageVersion !== 1 || legacyRecons)) {
      const warningSince = durabilityRevision;
      if (!captureBeforePrune(value, beforePrune)) {
        // A reader never publishes a failed migration snapshot. Leave complete
        // evidence on disk; only the exclusive save publishes the diagnostic.
        return value;
      }
      try { publish(backupPath, original, { exclusive: true }); }
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
      persist(value, { warningSince });
    } else if (!readOnly) {
      try { headroom(loadedBytes); }
      catch (error) { throw publishedLedgerError(error); }
    }
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
    publish(haltPath, body);
    try { audit({ event: "halt_set", reason: text }); }
    catch (error) {
      // HALT is already visible. An audit failure cannot undo or retry it.
      durabilityWarning = { durability: "uncertain", durabilityCode: CAPTURE_ERROR_CODES.has(error?.code) ? error.code : "unavailable" };
      durabilityRevision++;
    }
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

  return { root: resolvedRoot, statePath, auditPath, haltPath, reconEvidencePath, backupPath, reconRetentionMs, beforePrune, load, save, usage, audit, haltBody, setHalt, reattribute, updateCaptureDelivery, noteCaptureFailure, captureDiagnostics, rearmCaptureDelivery };
}
