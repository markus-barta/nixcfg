import {
  appendFileSync,
  closeSync,
  existsSync,
  fsyncSync,
  openSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";

import { ACCOUNT } from "./policy.mjs";
import { confinedPath } from "./security.mjs";

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
      intents: {},
      placements: [],
      executions: [],
    };
  }

  function audit(event) {
    const row = `${JSON.stringify({ at: new Date().toISOString(), ...event })}\n`;
    const handle = openSync(auditPath, "a", 0o600);
    try {
      appendFileSync(handle, row);
      fsyncSync(handle);
    } finally {
      closeSync(handle);
    }
  }

  function save(state) {
    writeAtomic(statePath, `${JSON.stringify(state, null, 2)}\n`);
  }

  function load() {
    if (!existsSync(statePath)) {
      const state = initialState();
      save(state);
      audit({ event: "ledger_initialized", initializedAt: state.initializedAt });
      return state;
    }
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
