/** Lightweight contract checks for inspr.joe.household.v1 (paper only). */

const DESK_IDS = ["j", "joe", "joel"];
const STATES = new Set(["working", "sit-out", "stuck"]);
const LEARNING = new Set(["learning", "iterating", "steady", "blocked"]);
const GW = new Set(["ok", "degraded", "down"]);

function isObj(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

function moneyOk(m, path, errors) {
  if (!isObj(m)) {
    errors.push(`${path} must be object`);
    return;
  }
  for (const k of ["equity", "dayPnl", "totalPnl"]) {
    const v = m[k];
    if (!(v === null || (typeof v === "number" && Number.isFinite(v)))) {
      errors.push(`${path}.${k} must be number or null`);
    }
  }
  for (const k of Object.keys(m)) {
    if (!["equity", "dayPnl", "totalPnl"].includes(k)) errors.push(`${path} unknown key ${k}`);
  }
}

export function validateHouseholdSnapshot(raw) {
  const errors = [];
  if (!isObj(raw)) return { ok: false, errors: ["body must be a JSON object"] };

  if (raw.schema !== "inspr.joe.household.v1") errors.push("schema must be inspr.joe.household.v1");
  if (raw.mode !== "PAPER") errors.push("mode must be PAPER");
  if (raw.currency !== "EUR") errors.push("currency must be EUR");
  if (typeof raw.generatedAt !== "string" || !raw.generatedAt) errors.push("generatedAt required");

  if (!isObj(raw.source) || typeof raw.source.label !== "string" || !raw.source.label) {
    errors.push("source.label required");
  }

  if (!isObj(raw.safety)) {
    errors.push("safety required");
  } else {
    if (typeof raw.safety.halt !== "boolean") errors.push("safety.halt boolean");
    if (!(raw.safety.haltReason === null || typeof raw.safety.haltReason === "string")) {
      errors.push("safety.haltReason string|null");
    }
    if (!Number.isInteger(raw.safety.staleAfterSeconds) || raw.safety.staleAfterSeconds < 1) {
      errors.push("safety.staleAfterSeconds >= 1");
    }
    const gw = raw.safety.gateway;
    if (!isObj(gw) || !GW.has(gw.status)) errors.push("safety.gateway.status invalid");
  }

  if (!Array.isArray(raw.desks) || raw.desks.length !== 3) {
    errors.push("desks must have length 3");
  } else {
    const seen = new Set();
    for (let i = 0; i < raw.desks.length; i++) {
      const d = raw.desks[i];
      const p = `desks[${i}]`;
      if (!isObj(d)) {
        errors.push(`${p} must be object`);
        continue;
      }
      if (!DESK_IDS.includes(d.id)) errors.push(`${p}.id invalid`);
      if (seen.has(d.id)) errors.push(`${p}.id duplicate`);
      seen.add(d.id);
      if (typeof d.label !== "string" || !d.label) errors.push(`${p}.label`);
      if (!STATES.has(d.state)) errors.push(`${p}.state`);
      if (!(d.stateSince === null || typeof d.stateSince === "string")) errors.push(`${p}.stateSince`);
      if (typeof d.action !== "string" || !d.action) errors.push(`${p}.action`);
      if (!isObj(d.learning) || !LEARNING.has(d.learning.status)) errors.push(`${p}.learning`);
      moneyOk(d.money, `${p}.money`, errors);
      if (!Array.isArray(d.issues)) errors.push(`${p}.issues array`);
    }
    for (const id of DESK_IDS) {
      if (!seen.has(id)) errors.push(`missing desk ${id}`);
    }
  }

  moneyOk(raw.totals, "totals", errors);

  // Soft consistency: when all money fields are numbers, totals should match sums.
  if (Array.isArray(raw.desks) && raw.desks.length === 3 && isObj(raw.totals)) {
    for (const field of ["equity", "dayPnl", "totalPnl"]) {
      const parts = raw.desks.map((d) => d?.money?.[field]);
      if (parts.every((v) => typeof v === "number") && typeof raw.totals[field] === "number") {
        const sum = parts.reduce((a, b) => a + b, 0);
        if (Math.abs(sum - raw.totals[field]) >= 0.01) {
          errors.push(`totals.${field} must equal sum of desk money.${field}`);
        }
      }
    }
  }

  // Reject obvious secret-ish keys anywhere at top level
  for (const k of Object.keys(raw)) {
    if (/password|passwd|secret|token|credential|api[_-]?key/i.test(k)) {
      errors.push(`forbidden key ${k}`);
    }
  }

  return { ok: errors.length === 0, errors };
}
