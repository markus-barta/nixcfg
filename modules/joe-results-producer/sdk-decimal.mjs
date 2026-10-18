import { decimalUnits } from './contracts/decimal.mjs';

// One SDK boundary policy. Replay and financial arithmetic still use strings.
export function sdkDecimal(value) {
  // IB sentinels must be recognised before String/precision validation.
  if (value == null || value === Number.MAX_VALUE || value === String(Number.MAX_VALUE)
    || value === 2147483647 || value === '2147483647') return { unset: true };
  let amount = value, src;
  if (typeof value === 'number') {
    amount = String(Object.is(value, -0) ? 0 : value);
    const significant = amount.replace(/^-/, '').replace('.', '').replace(/^0+/, '');
    if (!Number.isFinite(value) || /e/i.test(amount) || significant.length > 15) return { refused: true };
    src = 'sdk_number_roundtrip';
  }
  try { decimalUnits(amount); }
  catch { return { refused: true }; }
  return { amount, ...(src ? { src } : {}) };
}
