import { validateContract } from './index.mjs';
import { validInstant } from './schema-validator.mjs';
import { missingResultsDays } from './vienna-date.mjs';

// Preserve the ADR's small producer skew while rejecting clocks that could
// poison durable generation progress. Receipt time remains server-owned.
export const MAX_CLOCK_AHEAD_MS = 5000;

// A transport-neutral acceptance boundary. P2 will connect this to atomic disk
// writes and HTTP. Rejection never replaces the last validated value.
export function acceptSnapshot(kind, candidate, previous = null, receivedAt) {
  if (!['data', 'history', 'results'].includes(kind)) throw new TypeError('Not a snapshot contract');
  if (!validInstant(receivedAt)) throw new TypeError('A server receive instant is required');
  const checked = validateContract(kind, candidate, { stage: 'ingress', receivedAt });
  const reject = (reason, errors = checked.errors) => ({
    ...previous, status: 422, reason, value: previous?.value ?? null,
    errors, rejectedAt: receivedAt,
  });
  if (!checked.ok) return reject(checked.reason);
  if (Date.parse(candidate.generatedAt) > Date.parse(receivedAt) + MAX_CLOCK_AHEAD_MS) {
    return reject('clock_ahead', [{ path: '$.generatedAt', rule: 'clockAhead' }]);
  }
  if (previous?.value) {
    if (candidate.seq <= previous.value.seq) return reject('sequence_replayed', [{ path: '$.seq', rule: 'sequenceReplayed' }]);
    if (Date.parse(candidate.generatedAt) < Date.parse(previous.value.generatedAt)) return reject('clock_regressed', [{ path: '$.generatedAt', rule: 'clockRegressed' }]);
    if (Date.parse(receivedAt) < Date.parse(previous.value.receivedAt)) return reject('clock_regressed', [{ path: '$.receivedAt', rule: 'clockRegressed' }]);
  }
  const advancing = candidate.generatedAt !== previous?.value?.generatedAt;
  const missingDays = kind === 'results' ? missingResultsDays(candidate, receivedAt) : [];
  return {
    status: 200, reason: null, errors: [],
    value: { ...structuredClone(candidate), receivedAt, ...(missingDays.length ? { missingDays } : {}) },
    generatedAdvancedAt: advancing ? receivedAt : previous.generatedAdvancedAt,
  };
}
