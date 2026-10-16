import { decimalUnits, UNIT, divRound, unitsDecimal } from './contracts/decimal.mjs';
import { validInstant } from './contracts/schema-validator.mjs';
import { hash } from './journal.mjs';

export const DESKS = ['j', 'joe', 'joel'];
export const money = amount => ({ amount, currency: 'EUR' });
export const viennaDate = instant => new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Vienna', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(instant));
const min = (a, b) => a < b ? a : b;
export const unavailable = () => new Error('source_not_authoritative');
const positive = s => { const n = decimalUnits(s); if (n <= 0n) throw unavailable(); return n; };

function fxFor(fill) {
  const fx = fill.closeFx;
  if (!fx || fx.base !== fill.currency || fx.quote !== 'EUR' || !validInstant(fx.observedAt) || !fx.source || fx.source.length > 80) throw unavailable();
  positive(fx.rate);
  return fx;
}

// A fee is a rational number of 10^-8 EUR units. Allocate from original
// quantities, then round only the final portion; the last portion receives
// any remainder, so the commission is conserved across partial closes.
function feePortion(fill, quantity, used, fx) {
  if (!fill.commission || !['EUR', fill.currency].includes(fill.commission.currency)) throw unavailable();
  const fee = decimalUnits(fill.commission.amount);
  if (fee < 0n) throw unavailable();
  const rate = fill.commission.currency === 'EUR' ? UNIT : decimalUnits(fx.rate);
  const total = positive(fill.quantity);
  const allocatedThrough = q => divRound(fee * q * rate, total * UNIT);
  return allocatedThrough(used + quantity) - allocatedThrough(used);
}

export function roundTrips(fills, trackingInstant, keepSymbols) {
  const lots = new Map(), trades = [];
  for (const fill of [...fills].sort((a, b) => (a.at || '').localeCompare(b.at || '') || (a.ordinal || 0) - (b.ordinal || 0) || a.key.localeCompare(b.key))) {
    if (!DESKS.includes(fill.desk) || fill.scope !== 'stage0') continue;
    if (keepSymbols.includes(fill.symbol)) throw unavailable(); // hold the WHOLE snapshot
    if (!validInstant(fill.at) || !/^[A-Z0-9][A-Z0-9._-]{0,15}$/.test(fill.symbol) || !['BUY', 'SELL'].includes(fill.side)) throw unavailable();
    const total = positive(fill.quantity), price = positive(fill.price);
    const sign = fill.side === 'BUY' ? 1n : -1n;
    const key = `${fill.desk}:${fill.instrument}:${fill.currency}`;
    const book = lots.get(key) || [];
    let remaining = total, used = 0n;
    while (remaining && book.length && book[0].sign !== sign) {
      const lot = book[0], quantity = min(remaining, lot.remaining);
      if (fill.at >= trackingInstant) {
        const fx = fxFor(fill), rate = decimalUnits(fx.rate);
        // Exact product, ONE conversion boundary. The contract has only eight
        // fractional digits: hold a nonrepresentable exact gross, never round it.
        const numerator = quantity * (price - lot.price) * lot.sign * rate;
        if (numerator % (UNIT * UNIT)) throw unavailable();
        const gross = numerator / (UNIT * UNIT);
        const fees = feePortion(lot.fill, quantity, lot.used, fx) + feePortion(fill, quantity, used, fx);
        trades.push({
          id: `rt-${hash([lot.fill.key, fill.key, unitsDecimal(lot.used), unitsDecimal(used)]).slice(0, 40)}`,
          desk: fill.desk, symbol: fill.symbol, side: lot.sign === 1n ? 'long' : 'short', quantity: unitsDecimal(quantity),
          openedAt: lot.fill.at, closedAt: fill.at,
          entryPrice: { amount: lot.fill.price, currency: fill.currency }, exitPrice: { amount: fill.price, currency: fill.currency },
          grossEur: money(unitsDecimal(gross)), feesEur: money(unitsDecimal(fees)), netEur: money(unitsDecimal(gross - fees)),
          fx: structuredClone(fx), method: 'execution-fifo-net-current-fx',
        });
      }
      lot.remaining -= quantity; lot.used += quantity; remaining -= quantity; used += quantity;
      if (!lot.remaining) book.shift();
    }
    if (remaining) book.push({ fill, price, sign, remaining, used });
    lots.set(key, book);
  }
  return trades.sort((a, b) => a.closedAt.localeCompare(b.closedAt) || a.id.localeCompare(b.id));
}

export function dayCloses(observations, trades, trackingStart) {
  const days = new Map(), bases = {};
  for (const observation of [...observations].sort((a, b) => a.at.localeCompare(b.at))) {
    if (!validInstant(observation.at)) throw unavailable();
    for (const desk of DESKS) {
      const close = observation.desks?.[desk];
      if (!close) continue; // sessionless desks/days are omitted
      const at = close.at || observation.at;
      if (!validInstant(at)) throw unavailable();
      const date = viennaDate(at);
      if (date < trackingStart) continue;
      const desks = days.get(date) || {};
      if (bases[`${date}:${desk}`]?.at > at) continue;
      if (typeof close.basisId !== 'string' || !close.basisId || close.equity.currency !== 'EUR') throw unavailable();
      decimalUnits(close.equity.amount);
      const closed = trades.filter(t => t.desk === desk && viennaDate(t.closedAt) === date && t.closedAt <= at);
      const sum = field => unitsDecimal(closed.reduce((n, t) => n + decimalUnits(t[field].amount), 0n));
      desks[desk] = { equityClose: money(close.equity.amount), realisedNet: money(sum('netEur')), fees: money(sum('feesEur')), trades: closed.length };
      // Results 9550f81 forbids a wire basis field. Preserve the exact evidence
      // internally until the owner approves a contract-set upgrade.
      bases[`${date}:${desk}`] = { basisId: close.basisId, at };
      days.set(date, desks);
    }
  }
  return { days: [...days].sort(([a], [b]) => a.localeCompare(b)).map(([date, desks]) => ({ date, desks })), bases };
}
