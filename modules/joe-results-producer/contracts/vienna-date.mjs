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
