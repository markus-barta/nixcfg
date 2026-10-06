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

import { ACCOUNT, newYorkDay, validateKey } from "./policy.mjs";
import { confinedPath } from "./security.mjs";

export const RETENTION_MS = 14 * 24 * 60 * 60_000;
const MAX_INTENTS = 5000;
const MAX_STATE_BYTES = 16 * 1024 * 1024;
const MAX_AUDIT_BYTES = 1024 * 1024;

function dictionary(value, kind) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`invalid ${kind} dictionary`);
  const result = Object.create(null);
  for (const [key, row] of Object.entries(value)) result[validateKey(key, kind)] = row;
  return result;
}

function firstOrderDictionary(value) {
  const result = dictionary(value, "desk");
  for (const desk of Object.keys(result)) result[desk] = dictionary(result[desk], "symbol");
  return result;
}

// First-order dates survive placement retention; they contain no fill quantities.
export function rememberFirstOrders(state) {
  if (!state.firstOrders) {
    state.firstOrders = Object.create(null);
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
    const dates = state.firstOrders[desk] ||= Object.create(null);
    if (!dates[symbol] || day < dates[symbol]) dates[symbol] = day;
  }
}

export function pruneState(state, now = Date.now()) {
  state.intents = dictionary(state.intents, "intentId");
  rememberFirstOrders(state);
  for (const [id, row] of Object.entries(state.intents)) {
    if (!["claimed", "uncertain"].includes(row.status) && now - Date.parse(row.finishedAt || row.claimedAt) > RETENTION_MS) delete state.intents[id];
  }
  state.placements = state.placements.filter((row) => ["reserved", "uncertain", "partial"].includes(row.status) || now - Date.parse(row.reservedAt || `${row.day}T00:00:00Z`) <= RETENTION_MS);
}

export function admitIntent(state) {
  pruneState(state);
  if (Object.keys(state.intents).length >= MAX_INTENTS || state.executions.length >= 50000 || Buffer.byteLength(JSON.stringify(state)) > MAX_STATE_BYTES - 262144) throw new Error("ledger capacity reached; new intents refused while evidence is retained");
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

export function openLedger(root) {
  const resolvedRoot = path.resolve(root);
  const statePath = confinedPath(resolvedRoot, path.join(resolvedRoot, "ledger.json"), "state path");
  const auditPath = confinedPath(resolvedRoot, path.join(resolvedRoot, "audit.jsonl"), "audit path");
  const haltPath = confinedPath(resolvedRoot, path.join(resolvedRoot, "HALT"), "local HALT path");

  function initialState() {
    return {
      schema: STATE_SCHEMA,
      account: ACCOUNT,
      initializedAt: new Date().toISOString(),
      firstOrders: Object.create(null),
      intents: Object.create(null),
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
    pruneState(state);
    const body = `${JSON.stringify(state)}\n`;
    if (Buffer.byteLength(body) > MAX_STATE_BYTES) throw new Error("ledger size limit reached; evidence retained");
    writeAtomic(statePath, body);
  }

  function load() {
    let handle;
    try {
      handle = openSync(statePath, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
      const initial = initialState();
      try {
        writeAtomic(statePath, `${JSON.stringify(initial)}\n`, { exclusive: true });
        audit({ event: "ledger_initialized", initializedAt: initial.initializedAt });
      } catch (error) {
        if (error.code !== "EEXIST") throw error;
      }
      handle = openSync(statePath, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    }
    let value;
    try {
      const info = fstatSync(handle);
      if (!info.isFile() || info.size > MAX_STATE_BYTES) throw new Error("executor ledger exceeds size limit or is not a regular file");
      value = JSON.parse(readFileSync(handle, "utf8"));
    } finally { closeSync(handle); }
    if (value?.schema !== STATE_SCHEMA || value?.account !== ACCOUNT
        || !Number.isFinite(Date.parse(value.initializedAt)) || !value.intents
        || Array.isArray(value.intents) || !Array.isArray(value.placements)
        || !Array.isArray(value.executions)) {
      throw new Error("executor state is invalid");
    }
    value.intents = dictionary(value.intents, "intentId");
    rememberFirstOrders(value);
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

  return { root: resolvedRoot, statePath, auditPath, haltPath, load, save, audit, haltBody, setHalt };
}
