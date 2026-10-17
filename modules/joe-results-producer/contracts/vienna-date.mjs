import { validInstant } from './schema-validator.mjs';

const formatter = new Intl.DateTimeFormat('en-CA', {
  timeZone: 'Europe/Vienna', year: 'numeric', month: '2-digit', day: '2-digit',
});

// Contract day keys need the explicit zone, never the market calendar.
export function viennaDay(instant) {
  if (!validInstant(instant)) throw new TypeError('Explicit UTC instant required');
  const parts = Object.fromEntries(formatter.formatToParts(new Date(instant)).map(p => [p.type, p.value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
}

// Diagnostics use the server's acceptance date, not the producer's clock or
// the host zone. A reported partial day is present and therefore covered.
export function missingResultsDays(value, receivedAt) {
  const today = viennaDay(receivedAt);
  const covered = new Set(value.days.map(day => day.date));
  const missing = new Set();
  for (const trade of value.trades) {
    const day = viennaDay(trade.closedAt);
    if (day < today && !covered.has(day)) missing.add(day);
  }
  return [...missing].sort();
}
