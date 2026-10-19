import data from './data.schema.json' with { type: 'json' };
import history from './history.schema.json' with { type: 'json' };
import results from './results.schema.json' with { type: 'json' };
import fleet from './fleet-config.schema.json' with { type: 'json' };
import healthz from './healthz.schema.json' with { type: 'json' };
import common from './common.schema.json' with { type: 'json' };
import reason from './reason.schema.json' with { type: 'json' };
import manifest from './manifest.json' with { type: 'json' };
import { checkSchema } from './schema-validator.mjs';
import { checkSemantics } from './semantics.mjs';

function freeze(value) {
  if (value && typeof value === 'object' && !Object.isFrozen(value)) {
    Object.values(value).forEach(freeze);
    Object.freeze(value);
  }
  return value;
}

export const CONTRACTS = freeze(manifest);
export const REASONS = freeze(reason.enum);
export const SCHEMAS = freeze({ data, history, results, 'fleet-config': fleet, healthz });
const files = {
  ...Object.fromEntries(Object.entries(SCHEMAS).map(([k, v]) => [`${k}.schema.json`, v])),
  'common.schema.json': common, 'reason.schema.json': reason,
};
export const SCHEMA_FILES = freeze({ ...files, ...Object.fromEntries(Object.values(files).map(s => [s.$id, s])) });

// Pure, offline, same entry point for browser, server and producer CI.
// Ingress forbids server-owned receipt/diagnostics; served requires a receipt.
// The trusted receivedAt option enables receipt-dependent ingress semantics;
// acceptSnapshot supplies it. Served semantics use the persisted receipt.
export function validateContract(kind, payload, { stage = 'served', receivedAt } = {}) {
  if (!Object.hasOwn(SCHEMAS, kind)) throw new TypeError('Unknown contract kind');
  if (!['served', 'ingress'].includes(stage)) throw new TypeError('Unknown contract stage');
  const errors = [];
  let size;
  try { size = new TextEncoder().encode(JSON.stringify(payload)).length; }
  catch { errors.push({ path: '$', rule: 'json' }); }
  if (size > CONTRACTS.limits[kind]) errors.push({ path: '$', rule: 'maxBytes' });
  if (payload?.schema !== CONTRACTS.contracts[kind]) {
    return { ok: false, status: 422, reason: 'schema_unsupported', errors: [{ path: '$.schema', rule: 'const' }] };
  }
  if (!errors.length) checkSchema(SCHEMAS[kind], payload, SCHEMA_FILES, errors);
  if (!errors.length) checkSemantics(kind, payload, stage, errors, receivedAt);
  return errors.length
    ? { ok: false, status: 422, reason: 'contract_invalid', errors }
    : { ok: true, status: 200, reason: null, errors: [] };
}

// Browser reads and server-controlled contracts use the same last-good rule.
export function validateAndRetain(kind, candidate, lastGood = null, options) {
  const result = validateContract(kind, candidate, options);
  return { ...result, value: result.ok ? candidate : lastGood };
}
