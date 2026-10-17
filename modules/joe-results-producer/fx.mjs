import { validInstant } from './contracts/schema-validator.mjs';
import { decimalUnits } from './contracts/decimal.mjs';

const ny = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit', weekday: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
function clock(at) {
  const p = Object.fromEntries(ny.formatToParts(new Date(at)).map(p => [p.type, p.value]));
  return { date: `${p.year}-${p.month}-${p.day}`, minute: Number(p.hour) * 60 + Number(p.minute), weekday: !['Sat', 'Sun'].includes(p.weekday) };
}
function samples(day, at) {
  return (day?.samples || []).filter(sample => {
    try {
      const c = clock(sample.sampleAt);
      return validInstant(sample.sampleAt) && sample.sampleAt <= at && decimalUnits(sample.rate) > 0n
        && (sample.kind === 'rth' && c.weekday && c.minute >= 570 && c.minute < 960 || sample.kind === 'close' && c.weekday && c.minute === 965);
    } catch { return false; }
  });
}
export function dayFx(day, date, at) {
  const available = samples(day, at).filter(sample => clock(sample.sampleAt).date === date);
  // A frozen close always wins. No later day's rate can fill historical holes.
  const sample = available.find(sample => sample.kind === 'close') || available.filter(sample =>
    clock(at).date === date && Date.parse(at) - Date.parse(sample.sampleAt) <= 30 * 60_000).at(-1);
  return sample ? { base: 'USD', quote: 'EUR', rate: sample.rate, source: sample.kind === 'close' ? 'ib-fx-close' : 'ib-fx-rth', observedAt: sample.sampleAt } : null;
}
export function fxDayPartial(day, date, status, at) {
  const available = samples(day, at).filter(sample => clock(sample.sampleAt).date === date);
  const c = clock(at);
  if (date === c.date && (!status?.enabled || status.reason)) return true;
  if (available.some(sample => sample.kind === 'close')) return false;
  if (date !== c.date) return true; // missed close, never backfilled
  if (!status?.enabled || status.reason) return true;
  const last = available.filter(sample => sample.kind === 'rth').at(-1);
  if (!last) return true;
  if (c.minute >= 965) return true; // fixed close was missed
  return c.weekday && c.minute >= 570 && c.minute < 960 && Date.parse(at) - Date.parse(last.sampleAt) > 30 * 60_000;
}

export function isSampleFx(fx, date) {
  if (!['ib-fx-close', 'ib-fx-rth'].includes(fx?.source)) return false;
  const sample = { rate: fx.rate, sampleAt: fx.observedAt, kind: fx.source === 'ib-fx-close' ? 'close' : 'rth' };
  return !!dayFx({ samples: [sample] }, date, fx.observedAt);
}
