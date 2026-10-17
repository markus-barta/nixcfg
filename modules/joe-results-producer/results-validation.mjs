import { validateContract } from './contracts/index.mjs';
import { viennaDay } from './contracts/vienna-date.mjs';
import { validInstant } from './contracts/schema-validator.mjs';

export { viennaDay as viennaDate };
const clock = new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/Vienna', hourCycle: 'h23', hour: '2-digit', minute: '2-digit', second: '2-digit' });

// A half-open observation interval covers a day only from Vienna midnight
// through the following midnight. Local dates handle 23/25-hour DST days.
export function dayCoverage(date, from, through, intervals = []) {
  if (!validInstant(from) || !validInstant(through) || Date.parse(from) > Date.parse(through)) return 'partial';
  const first = viennaDay(from), last = viennaDay(through);
  const startsAtMidnight = clock.format(new Date(from)) === '00:00:00' && Date.parse(from) % 1000 === 0;
  if (!(date > first || (date === first && startsAtMidnight)) || date >= last) return 'partial';
  // Locate Vienna midnights without assuming a 24-hour civil day.
  const noon = Date.parse(`${date}T12:00:00.000Z`);
  let begin = noon - 14 * 3600_000;
  while (viennaDay(new Date(begin).toISOString()) < date) begin += 3600_000;
  let end = begin + 22 * 3600_000;
  while (viennaDay(new Date(end).toISOString()) === date) end += 3600_000;
  return intervals.some(([a, b]) => a <= begin && b >= end) ? 'full' : 'partial';
}

// The producer and ingress share revision 3's exact day/trade semantics.
// Coverage travels on each day; no private override can bypass the wire check.
export function validateResults(payload, { stage = 'ingress' } = {}) {
  return validateContract('results', payload, { stage });
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

function subtractIntervals(intervals, gaps) {
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
