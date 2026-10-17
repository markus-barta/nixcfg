import { decimalUnits, UNIT, unitsDecimal } from './contracts/decimal.mjs';
import { validInstant } from './contracts/schema-validator.mjs';
import { hash } from './journal.mjs';
import { viennaDate, dayCoverage } from './results-validation.mjs';
import { isSampleFx } from './fx.mjs';

export const DESKS = ['j', 'joe', 'joel'];
export const CLOSE_BASIS = 'execution-fifo-net-current-fx';
export const money = amount => ({ amount, currency: 'EUR' });
export { viennaDate };
const min = (a, b) => a < b ? a : b;
export const unavailable = () => new Error('source_not_authoritative');
const positive = s => { const n = decimalUnits(s); if (n <= 0n) throw unavailable(); return n; };

function fxFor(fill) {
  const fx = fill.closeFx;
  if (!fx || fx.base !== fill.currency || fx.quote !== 'EUR' || !validInstant(fx.observedAt) || !fx.source || fx.source.length > 80
    || fill.currency === 'USD' && !isSampleFx(fx, viennaDate(fill.at)) && Math.abs(Date.parse(fx.observedAt) - Date.parse(fill.at)) > 60_000) {
    throw Object.assign(unavailable(), { conversionReason: 'fx_missing' });
  }
  positive(fx.rate);
  return fx;
}

// Keep each portion rational through allocation AND FX. Opening and closing
// fees are combined before the one authorized rounding point per USD portion.
function feePortion(fill, quantity, fx) {
  if (!fill.commission || !['EUR', fill.currency].includes(fill.commission.currency)) throw unavailable();
  const fee = decimalUnits(fill.commission.amount);
  if (fee < 0n) throw unavailable();
  const rate = fill.commission.currency === 'EUR' ? UNIT : decimalUnits(fx.rate);
  const total = positive(fill.quantity);
  return { numerator: fee * quantity * rate, denominator: total * UNIT };
}

function feeSum(opening, closing) {
  const numerator = opening.numerator * closing.denominator + closing.numerator * opening.denominator;
  const denominator = opening.denominator * closing.denominator;
  return { numerator, denominator };
}

// Rational units -> integer 10^-8 EUR units, ties to even, including losses.
// All arithmetic is BigInt; allocation and FX have no intermediate rounding.
function halfEvenUnits(numerator, denominator) {
  const negative = numerator < 0n;
  const magnitude = negative ? -numerator : numerator;
  const quotient = magnitude / denominator, twiceRemainder = 2n * (magnitude % denominator);
  const rounded = quotient + (twiceRemainder > denominator || twiceRemainder === denominator && quotient % 2n === 1n ? 1n : 0n);
  return negative ? -rounded : rounded;
}

function exactUnits(numerator, denominator) {
  if (numerator % denominator) throw unavailable();
  return numerator / denominator;
}

// Amy's JOED-27 amendment: gross and combined fee each round once, here only.
function eurPortion(lot, fill, quantity, price) {
  const fx = fxFor(fill), rate = decimalUnits(fx.rate);
  const numerator = quantity * (price - lot.price) * lot.sign * rate;
  const convert = fill.currency === 'USD' ? halfEvenUnits : exactUnits;
  const gross = convert(numerator, UNIT * UNIT);
  const fee = feeSum(feePortion(lot.fill, quantity, fx), feePortion(fill, quantity, fx));
  const fees = convert(fee.numerator, fee.denominator);
  return { fx, gross, fees };
}

export function roundTrips(fills, trackingInstant, keepSymbols, onClose = () => {}, onExcluded = () => {}) {
  const lots = new Map(), trades = [];
  for (const fill of [...fills].sort((a, b) => (a.at || '').localeCompare(b.at || '') || (a.ordinal || 0) - (b.ordinal || 0) || a.key.localeCompare(b.key))) {
    if (!DESKS.includes(fill.desk) || fill.scope !== 'stage0') continue;
    if (keepSymbols.includes(fill.symbol)) continue;
    if (!validInstant(fill.at) || !/^[A-Z0-9][A-Z0-9._-]{0,15}$/.test(fill.symbol) || !['BUY', 'SELL'].includes(fill.side)) throw unavailable();
    const total = positive(fill.quantity), price = positive(fill.price);
    const sign = fill.side === 'BUY' ? 1n : -1n;
    const key = `${fill.desk}:${fill.instrument}:${fill.currency}`;
    const book = lots.get(key) || [];
    let remaining = total, used = 0n;
    while (remaining && book.length && book[0].sign !== sign) {
      const lot = book[0], quantity = min(remaining, lot.remaining);
      if (fill.at >= trackingInstant) {
        onClose({ instrument: fill.instrument, at: fill.at });
        try {
          const { fx, gross, fees } = eurPortion(lot, fill, quantity, price);
          trades.push({
            id: `rt-${hash([lot.fill.key, fill.key, unitsDecimal(lot.used), unitsDecimal(used)]).slice(0, 40)}`,
            desk: fill.desk, symbol: fill.symbol, side: lot.sign === 1n ? 'long' : 'short', quantity: unitsDecimal(quantity),
            openedAt: lot.fill.at, closedAt: fill.at,
            entryPrice: { amount: lot.fill.price, currency: fill.currency }, exitPrice: { amount: fill.price, currency: fill.currency },
            grossEur: money(unitsDecimal(gross)), feesEur: money(unitsDecimal(fees)), netEur: money(unitsDecimal(gross - fees)),
            fx: structuredClone(fx), method: CLOSE_BASIS,
          });
        } catch (error) {
          // Only absent/stale USD FX excludes a portion. Advance the quantity
          // book so later portions cannot reuse the excluded lot.
          if (fill.currency !== 'USD' || error.conversionReason !== 'fx_missing') throw error;
          onExcluded({ day: viennaDate(fill.at), deskHash: hash(fill.desk), kind: error.conversionReason });
        }
      }
      lot.remaining -= quantity; lot.used += quantity; remaining -= quantity; used += quantity;
      if (!lot.remaining) book.shift();
    }
    if (remaining) book.push({ fill, price, sign, remaining, used });
    lots.set(key, book);
  }
  return trades.sort((a, b) => a.closedAt.localeCompare(b.closedAt) || a.id.localeCompare(b.id));
}

export function dayCloses(fills, trades, trackingStart, { from, through, intervals, earlierGaps = new Set() } = {}) {
  const days = new Map();
  // Executor captures are the only daily source. No household equity/account
  // fragment is read; an active desk's unknown equity stays null.
  for (const fill of fills) {
    if (!validInstant(fill.at)) throw unavailable();
    if ((from && fill.at < from) || (through && fill.at > through)) continue;
    const date = viennaDate(fill.at);
    if (date < trackingStart) continue;
    const desks = days.get(date) || {};
    desks[fill.desk] = { equityClose: null };
    days.set(date, desks);
  }
  const totals = new Map(), coverage = {};
  for (const trade of trades) {
    const date = viennaDate(trade.closedAt), key = `${date}:${trade.desk}`;
    const total = totals.get(key) || { count: 0, net: 0n, fees: 0n };
    total.count++; total.net += decimalUnits(trade.netEur.amount); total.fees += decimalUnits(trade.feesEur.amount);
    totals.set(key, total);
    const desks = days.get(date) || {};
    desks[trade.desk] ||= { equityClose: null };
    days.set(date, desks);
  }
  const result = [...days].sort(([a], [b]) => a.localeCompare(b)).map(([date, desks]) => {
    for (const [desk, value] of Object.entries(desks)) {
      const total = totals.get(`${date}:${desk}`) || { count: 0, net: 0n, fees: 0n };
      Object.assign(value, { realisedNet: money(unitsDecimal(total.net)), fees: money(unitsDecimal(total.fees)), trades: total.count });
    }
    coverage[date] = earlierGaps.has(date) ? 'partial' : dayCoverage(date, from, through, intervals);
    const day = { date, desks };
    // Full is the documented default; only partial days need a wire marker.
    if (coverage[date] === 'partial') day.coverage = 'partial';
    return day;
  });
  return { days: result, coverage };
}
