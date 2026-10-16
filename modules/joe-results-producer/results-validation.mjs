import { validateContract } from './contracts/index.mjs';
import { decimalUnits } from './contracts/decimal.mjs';
import { validInstant } from './contracts/schema-validator.mjs';

// TODO(JOED-27): set to the approved day-level coverage field only after the
// merged manifest revision 3 closure and independent digest are supplied.
// The pinned 9550f81 schema forbids extensions; never alter vendored bytes.
export const PARTIAL_COVERAGE_FIELD = null;

const vienna = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Vienna', year: 'numeric', month: '2-digit', day: '2-digit' });
const clock = new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/Vienna', hourCycle: 'h23', hour: '2-digit', minute: '2-digit', second: '2-digit' });
export const viennaDate = instant => vienna.format(new Date(instant));

// A half-open observation interval covers a day only from Vienna midnight
// through the following midnight. Local dates handle 23/25-hour DST days.
export function dayCoverage(date, from, through) {
  if (!validInstant(from) || !validInstant(through) || Date.parse(from) > Date.parse(through)) throw new Error('source_not_authoritative');
  const first = viennaDate(from), last = viennaDate(through);
  const startsAtMidnight = clock.format(new Date(from)) === '00:00:00' && Date.parse(from) % 1000 === 0;
  return (date > first || (date === first && startsAtMidnight)) && date < last ? 'full' : 'partial';
}

// Producer-side strengthening while JOED-27 is pending. Full coverage means
// every traded desk on this DATE, including desks missing equity observations.
// Dates without a days[] row deliberately impose no close requirement.
export function validateResults(payload, { coverage = {}, stage = 'ingress' } = {}) {
  const checked = validateContract('results', payload, { stage });
  if (!checked.ok) return checked;
  const errors = [];
  const fail = (path, rule) => { if (errors.length < 20) errors.push({ path, rule }); };
  const grouped = new Map();
  for (const trade of payload.trades) {
    const date = viennaDate(trade.closedAt);
    if (!grouped.has(date)) grouped.set(date, new Map());
    const desks = grouped.get(date);
    const total = desks.get(trade.desk) || { trades: 0, net: 0n, fees: 0n };
    total.trades++;
    total.net += decimalUnits(trade.netEur.amount);
    total.fees += decimalUnits(trade.feesEur.amount);
    desks.set(trade.desk, total);
  }
  const seen = new Set();
  payload.days.forEach((day, index) => {
    const at = `$.days[${index}]`;
    if (seen.has(day.date)) fail(`${at}.date`, 'uniqueDay');
    seen.add(day.date);
    const partial = coverage[day.date] === 'partial' || (PARTIAL_COVERAGE_FIELD && day[PARTIAL_COVERAGE_FIELD] === 'partial');
    if (partial) return;
    const totals = grouped.get(day.date) || new Map();
    for (const desk of totals.keys()) if (!Object.hasOwn(day.desks, desk)) fail(`${at}.desks.${desk}`, 'missingTradedDesk');
    for (const [desk, value] of Object.entries(day.desks)) {
      const expected = totals.get(desk) || { trades: 0, net: 0n, fees: 0n };
      if (value.trades !== expected.trades) fail(`${at}.desks.${desk}.trades`, 'dayTradeCount');
      if (!value.realisedNet || decimalUnits(value.realisedNet.amount) !== expected.net) fail(`${at}.desks.${desk}.realisedNet`, 'dayRealisedNetSum');
      if (!value.fees || decimalUnits(value.fees.amount) !== expected.fees) fail(`${at}.desks.${desk}.fees`, 'dayFeesSum');
    }
  });
  return errors.length ? { ok: false, status: 422, reason: 'contract_invalid', errors } : checked;
}
