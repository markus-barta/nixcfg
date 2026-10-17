import { PARTIAL_REASONS } from './results-validation.mjs';

// Producer-side equivalent of JoeDesk's pure reason selection and day-note
// rule at contracts.lock.json's rev-6 pin (results-model.js / results.js).
// Keep this offline: no consumer checkout, source evaluation or browser needed.
export const PARTIAL_REASON = "Part of this day's activity couldn't be confirmed, so its result may be incomplete.";
const labels = Object.freeze({
  capture_gap: 'Capture gap', history_gap: 'History gap',
  broker_trade_count_mismatch: 'Broker trade count mismatch',
  broker_realised_pnl_mismatch: 'Broker result mismatch',
  unattributed_activity: 'Unattributed activity', avg_cost_mismatch: 'Average-cost mismatch',
  fx_disabled: 'FX sampling off', fx_missing: 'FX missing',
  broker_evidence_missing: 'Broker evidence missing',
});

export function consumerPartialReasons(day) {
  const codes = new Set(day?.partialReasons ?? []);
  if (codes.has('fx_disabled')) codes.delete('fx_missing');
  return PARTIAL_REASONS.filter(code => codes.has(code)).map(code => ({ code, label: labels[code] }));
}

export function consumerDayNote(day, today, warning) {
  const partial = day?.coverage === 'partial';
  const reasons = partial ? consumerPartialReasons(day) : [];
  return reasons.length || day?.date === today ? '' : warning?.note ?? (partial ? PARTIAL_REASON : '');
}
