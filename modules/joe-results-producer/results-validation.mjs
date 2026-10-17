import { validateContract } from './contracts/index.mjs';
import { viennaDay } from './contracts/vienna-date.mjs';
import { validInstant } from './contracts/schema-validator.mjs';

export { viennaDay as viennaDate };
const clock = new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/Vienna', hourCycle: 'h23', hour: '2-digit', minute: '2-digit', second: '2-digit' });

// A half-open observation interval covers a day only from Vienna midnight
// through the following midnight. Local dates handle 23/25-hour DST days.
export function dayCoverage(date, from, through) {
  if (!validInstant(from) || !validInstant(through) || Date.parse(from) > Date.parse(through)) throw new Error('source_not_authoritative');
  const first = viennaDay(from), last = viennaDay(through);
  const startsAtMidnight = clock.format(new Date(from)) === '00:00:00' && Date.parse(from) % 1000 === 0;
  return (date > first || (date === first && startsAtMidnight)) && date < last ? 'full' : 'partial';
}

// The producer and ingress share revision 3's exact day/trade semantics.
// Coverage travels on each day; no private override can bypass the wire check.
export function validateResults(payload, { stage = 'ingress' } = {}) {
  return validateContract('results', payload, { stage });
}
