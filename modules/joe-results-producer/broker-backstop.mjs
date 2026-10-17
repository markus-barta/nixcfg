import { sdkDecimal } from './sdk-decimal.mjs';
import { decimalUnits, UNIT } from './contracts/decimal.mjs';
import { validInstant } from './contracts/schema-validator.mjs';
import { isSampleFx } from './fx.mjs';
import { hash } from './journal.mjs';
import { viennaDate } from './results-validation.mjs';

// commissionReport is retained by the executor; only its numeric projection
// crosses the shared SDK boundary. Older replays ignore additive provenance.
export function captureBrokerRealised(report) {
  if (!report || !/^[A-Z]{3}$/.test(report.currency)) return null;
  const value = sdkDecimal(report.realizedPNL);
  if (value.refused) return null;
  return { ...value, currency: report.currency };
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
      if (!fill.commission) throw new Error('missing');
      if (report?.unset === true && !closes && report.currency === fill.currency) continue;
      const pnl = report && !report.unset ? decimalUnits(report.amount) : null;
      if (pnl === null) throw new Error('missing');
      if (!closes && pnl === 0n) continue;
      total.count++;
      const fx = fill.closeFx;
      if (!fx || fx.base !== fill.currency || fx.quote !== 'EUR' || !validInstant(fx.observedAt)
        || Math.abs(Date.parse(fx.observedAt) - Date.parse(fill.at)) > 60_000 && !isSampleFx(fx, viennaDate(fill.at))) throw new Error('missing');
      const rate = report.currency === 'EUR' ? UNIT : report.currency === fill.currency ? decimalUnits(fx.rate) : 0n;
      if (rate <= 0n) throw new Error('missing');
      // IB realizedPNL is the broker's net result; do not subtract fees twice.
      // Keep the exact product in 10^-16 EUR, including USD fractional cents.
      total.net += pnl * rate;
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
        const difference = broker.net - decimalUnits(value.realisedNet.amount) * UNIT;
        if (difference > UNIT * UNIT / 100n || difference < -UNIT * UNIT / 100n) kinds.push('broker_realised_pnl_mismatch');
      }
      for (const kind of kinds) mismatches.push({ day: day.date, deskHash: hash(desk), kind });
    }
  }
  return mismatches;
}
