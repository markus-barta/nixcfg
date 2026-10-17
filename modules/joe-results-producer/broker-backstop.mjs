import { decimalUnits, UNIT } from './contracts/decimal.mjs';
import { validInstant } from './contracts/schema-validator.mjs';
import { isSampleFx } from './fx.mjs';
import { hash } from './journal.mjs';
import { viennaDate } from './results-validation.mjs';

// commissionReport is already retained by the executor. Never manufacture
// decimal precision from fractional JS Numbers or IB's unset-double sentinel.
export function captureBrokerRealised(report) {
  try {
    let amount = report?.realizedPNL;
    if (Number.isSafeInteger(amount)) amount = String(amount);
    decimalUnits(amount);
    if (!/^[A-Z]{3}$/.test(report.currency)) return null;
    return { amount, currency: report.currency };
  } catch { return null; }
}

// This quantity-only book counts closing EXECUTIONS, independently of FIFO's
// price lots/portions. One execution closing two FIFO lots therefore fails the
// count comparison conservatively. A broker-reported nonzero close also counts
// when a missed opening makes the local quantity book appear to open a lot.
export function brokerDayTotals(fills, trackingInstant) {
  const positions = new Map(), totals = new Map();
  for (const fill of [...fills].sort((a, b) => a.at.localeCompare(b.at) || (a.ordinal || 0) - (b.ordinal || 0) || a.key.localeCompare(b.key))) {
    const key = `${fill.desk}:${fill.instrument}:${fill.currency}`;
    const previous = positions.get(key) || 0n;
    const quantity = decimalUnits(fill.quantity) * (fill.side === 'BUY' ? 1n : -1n);
    const closes = previous !== 0n && (previous > 0n) !== (quantity > 0n);
    positions.set(key, previous + quantity);
    if (fill.at < trackingInstant) continue;
    const dayKey = `${viennaDate(fill.at)}:${fill.desk}`;
    const total = totals.get(dayKey) || { count: 0, net: 0n, complete: true };
    totals.set(dayKey, total);
    try {
      const report = fill.brokerRealised;
      const pnl = report ? decimalUnits(report.amount) : null;
      if (pnl === null || !fill.commission) throw new Error('missing');
      if (!closes && pnl === 0n) continue;
      total.count++;
      const fx = fill.closeFx;
      if (!fx || fx.base !== fill.currency || fx.quote !== 'EUR' || !validInstant(fx.observedAt)
        || Math.abs(Date.parse(fx.observedAt) - Date.parse(fill.at)) > 60_000 && !isSampleFx(fx, viennaDate(fill.at))) throw new Error('missing');
      const rate = report.currency === 'EUR' ? UNIT : report.currency === fill.currency ? decimalUnits(fx.rate) : 0n;
      if (rate <= 0n || pnl * rate % UNIT) throw new Error('missing');
      // IB realizedPNL is the broker's net result; do not subtract fees twice.
      total.net += pnl * rate / UNIT;
    } catch { total.complete = false; }
  }
  return totals;
}

export function brokerMismatches(days, fills, trackingInstant, at) {
  const totals = brokerDayTotals(fills, trackingInstant), mismatches = [];
  for (const day of days) {
    if (day.date >= viennaDate(at)) continue; // closed Vienna days only
    for (const [desk, value] of Object.entries(day.desks)) {
      const broker = totals.get(`${day.date}:${desk}`);
      const kinds = [];
      if (!broker?.complete) kinds.push('broker_evidence_missing');
      else {
        if (broker.count !== value.trades) kinds.push('broker_trade_count_mismatch');
        const difference = broker.net - decimalUnits(value.realisedNet.amount);
        if (difference > UNIT / 100n || difference < -UNIT / 100n) kinds.push('broker_realised_pnl_mismatch');
      }
      for (const kind of kinds) mismatches.push({ day: day.date, deskHash: hash(desk), kind });
    }
  }
  return mismatches;
}
