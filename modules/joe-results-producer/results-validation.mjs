import { validateContract } from './contracts/index.mjs';
import { viennaDay } from './contracts/vienna-date.mjs';
import { validInstant } from './contracts/schema-validator.mjs';
import resultsSchema from './contracts/results.schema.json' with { type: 'json' };

export { viennaDay as viennaDate };
export const PARTIAL_REASONS = Object.freeze(resultsSchema.properties.days.items.properties.partialReasons.items.enum);
export function markPartial(day, reason) {
  // In particular, every broker backstop record must name an existing day.
  if (!day || typeof day !== 'object') throw new Error('partial_day_missing');
  if (!PARTIAL_REASONS.includes(reason) || reason === 'avg_cost_mismatch') throw new Error('invalid_partial_reason');
  day.coverage = 'partial';
  const reasons = new Set([...(day.partialReasons || []), reason]);
  day.partialReasons = PARTIAL_REASONS.filter(code => reasons.has(code));
}
const clock = new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/Vienna', hourCycle: 'h23', hour: '2-digit', minute: '2-digit', second: '2-digit' });
export const startsAtViennaMidnight = at => validInstant(at) && clock.format(new Date(at)) === '00:00:00' && Date.parse(at) % 1000 === 0;

// A half-open observation interval covers a day only from Vienna midnight
// through the following midnight. Local dates handle 23/25-hour DST days.
export function dayCoverage(date, from, through, intervals = [], includeOpen = false,
  provenEnd = intervals.reduce((latest, [, b]) => Math.max(latest, b), -Infinity)) {
  if (!validInstant(from) || !validInstant(through) || Date.parse(from) > Date.parse(through)) return 'partial';
  const first = viennaDay(from), last = viennaDay(through);
  if (!(date > first || (date === first && startsAtViennaMidnight(from))) || date > last || date === last && !includeOpen) return 'partial';
  // Locate Vienna midnights without assuming a 24-hour civil day.
  const noon = Date.parse(`${date}T12:00:00.000Z`);
  let begin = noon - 14 * 3600_000;
  while (viennaDay(new Date(begin).toISOString()) < date) begin += 3600_000;
  let end = begin + 22 * 3600_000;
  while (viennaDay(new Date(end).toISOString()) === date) end += 3600_000;
  if (includeOpen) {
    end = Math.min(end, Date.parse(through));
    // The open day is "so far": capture history normally lags the send clock.
    // Check to the largest authoritative history target, including trailing
    // explicit gaps; standalone interval callers use the largest interval end.
    if (date === last && provenEnd >= begin) end = Math.min(end, provenEnd);
  }
  return intervals.some(([a, b]) => a <= begin && b >= end) ? 'full' : 'partial';
}

// Offline ingress uses the same producer send clock as snapshot/transport.
// Served historical data retains the board's receipt-based read semantics.
export function validateResults(payload, { stage = 'ingress', requirePartialReasons = false, receivedAt = payload?.generatedAt } = {}) {
  const result = validateContract('results', payload, { stage, receivedAt: validInstant(receivedAt) ? receivedAt : undefined });
  if (!result.ok) return result;
  if (stage === 'ingress' && !validInstant(receivedAt)) return { ok: false, status: 422, reason: 'contract_invalid', errors: [{ path: '$.receivedAt', rule: 'required' }] };
  if (!requirePartialReasons) return result;
  const errors = [];
  payload.days.forEach((day, i) => {
    if (day.coverage === 'partial' && day.date !== viennaDay(receivedAt) && !day.partialReasons?.length) errors.push({ path: `$.days[${i}].partialReasons`, rule: 'partialReasonsRequired' });
    if (day.partialReasons?.includes('avg_cost_mismatch')) errors.push({ path: `$.days[${i}].partialReasons`, rule: 'reserved' });
  });
  return errors.length ? { ok: false, status: 422, reason: 'contract_invalid', errors } : result;
}

// History bounds are evidence, never inferred from a successful poll. Exclude
// explicit gaps and reject unknown, malformed or future bounds.
export function historyGaps(coverage, at) {
  const target = coverage?.target;
  if (!validInstant(at) || !['complete', 'known'].includes(coverage?.status) || !Array.isArray(coverage?.gaps)
    || !validInstant(target?.fromInclusive) || !validInstant(target?.toExclusive)) return null;
  const from = Date.parse(target.fromInclusive), to = Date.parse(target.toExclusive);
  if (from >= to || to > Date.parse(at) || (coverage.status === 'complete' && coverage.gaps.length)) return null;
  const gaps = [];
  for (const gap of coverage.gaps) {
    if (!validInstant(gap?.fromInclusive) || !validInstant(gap?.toExclusive)) return null;
    const a = Date.parse(gap.fromInclusive), b = Date.parse(gap.toExclusive);
    if (a >= b || a < from || b > to) return null;
    gaps.push([a, b]);
  }
  return gaps;
}

// Fill-level omissions have their own value-free provenance. They still revoke
// observation/position proof exactly like history gaps. Old cuts have no list.
export function withFillGaps(coverage, fillGaps = []) {
  if (!Array.isArray(coverage?.gaps) || !['complete', 'known'].includes(coverage.status)
    || coverage.status === 'complete' && coverage.gaps.length) return coverage;
  // Stored cuts already include these omissions. Preserve order/bounds for
  // round-14 authority hashes, without reapplying gaps at init/hash/replay.
  const seen = new Set(), gaps = [];
  for (const gap of [...coverage.gaps, ...fillGaps.map(({ fromInclusive, toExclusive }) => ({ fromInclusive, toExclusive }))]) {
    const key = JSON.stringify([gap.fromInclusive, gap.toExclusive]);
    if (!seen.has(key)) { seen.add(key); gaps.push(gap); }
  }
  return { ...coverage, status: fillGaps.length ? 'known' : coverage.status, gaps };
}

// New cuts keep the aggregate coverage field for conservative older readers,
// while recording the original history gaps independently of fill omissions.
export function reportedHistoryCoverage(cut) {
  return cut.historyGaps && cut.historyCoverage
    ? { ...cut.historyCoverage, gaps: cut.historyGaps } : cut.historyCoverage;
}

export function subtractIntervals(intervals, gaps) {
  const result = [];
  for (const [from, to] of intervals) {
    let cursor = from;
    for (const [a, b] of gaps) {
      if (b <= cursor || a >= to) continue;
      if (a > cursor) result.push([cursor, a]);
      cursor = Math.max(cursor, b);
    }
    if (cursor < to) result.push([cursor, to]);
  }
  return result;
}

export function historyIntervals(coverage, at) {
  const gaps = historyGaps(coverage, at);
  if (!gaps) return [];
  return subtractIntervals([[Date.parse(coverage.target.fromInclusive), Date.parse(coverage.target.toExclusive)]], gaps.sort(([a], [b]) => a - b));
}

// New explicit gaps revoke earlier proof too; replay must not union away a
// newly discovered unattributed fill. Later complete proof can heal the gap.
export function updateHistoryIntervals(intervals, coverage, at) {
  const gaps = historyGaps(coverage, at);
  if (!gaps) return intervals;
  return subtractIntervals(mergeIntervals([...intervals, [Date.parse(coverage.target.fromInclusive), Date.parse(coverage.target.toExclusive)]]), gaps.sort(([a], [b]) => a - b));
}

export function mergeIntervals(intervals) {
  const result = [];
  for (const [a, b] of [...intervals].sort(([a], [b]) => a - b)) {
    const previous = result.at(-1);
    if (previous && a <= previous[1]) previous[1] = Math.max(previous[1], b);
    else result.push([a, b]);
  }
  return result;
}
