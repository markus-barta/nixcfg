import {
  appendFileSync,
  closeSync,
  existsSync,
  fsyncSync,
  statSync,
  openSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";

import { ACCOUNT, DESKS, newYorkDay } from "./policy.mjs";
import { confinedPath } from "./security.mjs";

export const RETENTION_MS = 14 * 24 * 60 * 60_000;
const MAX_INTENTS = 5000;
const MAX_STATE_BYTES = 16 * 1024 * 1024;
const MAX_AUDIT_BYTES = 1024 * 1024;

// First-order dates survive placement retention; they contain no fill quantities.
export function rememberFirstOrders(state) {
  if (!state.firstOrders) {
    state.firstOrders = {};
    // Older ledgers may already have pruned their earliest placements.
    state.ownershipHistoryFrom = state.initializedAt;
  }
  for (const row of state.placements) {
    if (!DESKS.includes(row.desk) || !/^[A-Z][A-Z0-9.]{0,9}$/.test(row.symbol || "")) continue;
    const timestamp = Date.parse(row.reservedAt);
    const day = Number.isFinite(timestamp) ? newYorkDay(timestamp) : row.day;
    if (!day) throw new Error("first-order ownership date is missing");
    const dates = state.firstOrders[row.desk] ||= {};
    if (!dates[row.symbol] || day < dates[row.symbol]) dates[row.symbol] = day;
  }
}

export function pruneState(state, now = Date.now()) {
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

function writeAtomic(filePath, body) {
  const temporary = `${filePath}.new`;
  const handle = openSync(temporary, "w", 0o600);
  try {
    writeFileSync(handle, body);
    fsyncSync(handle);
  } finally {
    closeSync(handle);
  }
  renameSync(temporary, filePath);
  const directory = openSync(path.dirname(filePath), "r");
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
      firstOrders: {},
      intents: {},
      placements: [],
      executions: [],
    };
  }

  function audit(event) {
    let row = `${JSON.stringify({ at: new Date().toISOString(), ...event })}\n`;
    if (Buffer.byteLength(row) > 65536) row = `${JSON.stringify({ at: new Date().toISOString(), event: event.event, intentId: event.intentId, status: event.status, resultOmitted: "large result retained in ledger" })}\n`;
    if (existsSync(auditPath) && statSync(auditPath).size + Buffer.byteLength(row) > MAX_AUDIT_BYTES) renameSync(auditPath, `${auditPath}.1`);
    const handle = openSync(auditPath, "a", 0o600);
    try {
      appendFileSync(handle, row);
      fsyncSync(handle);
    } finally {
      closeSync(handle);
    }
  }

  function save(state) {
    pruneState(state);
    const body = `${JSON.stringify(state)}\n`;
    if (Buffer.byteLength(body) > MAX_STATE_BYTES) throw new Error("ledger size limit reached; evidence retained");
    writeAtomic(statePath, body);
  }

  function load() {
    if (!existsSync(statePath)) {
      const state = initialState();
      save(state);
      audit({ event: "ledger_initialized", initializedAt: state.initializedAt });
      return state;
    }
    if (statSync(statePath).size > MAX_STATE_BYTES) throw new Error("executor ledger exceeds size limit");
    const value = JSON.parse(readFileSync(statePath, "utf8"));
    if (value?.schema !== STATE_SCHEMA || value?.account !== ACCOUNT
        || !Number.isFinite(Date.parse(value.initializedAt)) || !value.intents
        || Array.isArray(value.intents) || !Array.isArray(value.placements)
        || !Array.isArray(value.executions)) {
      throw new Error("executor state is invalid");
    }
    return value;
  }

  function haltBody() {
    try { return readFileSync(haltPath, "utf8"); } catch (error) {
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
