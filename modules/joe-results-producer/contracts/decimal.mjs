// Eight fractional digits, represented exactly. No Number arithmetic on money.
export function decimalUnits(value) {
  if (typeof value !== 'string' || value.length > 32 || !/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]{1,8})?$/.test(value)) {
    throw new TypeError('Invalid decimal');
  }
  const [whole, fraction = ''] = value.replace(/^-/, '').split('.');
  return (BigInt(whole) * 100000000n + BigInt(fraction.padEnd(8, '0'))) * (value.startsWith('-') ? -1n : 1n);
}

// One unit is 10⁻⁸; a decimal string is exact in units and back.
export const UNIT = 100000000n;
const SCALE = [1n, 10n, 100n, 1000n, 10000n, 100000n, 1000000n, 10000000n, UNIT];

// Integer division rounded half away from zero: a half cent is a whole cent
// in its own direction, never towards zero and never by binary floating point.
export function divRound(numerator, denominator) {
  if (typeof numerator !== 'bigint' || typeof denominator !== 'bigint' || denominator === 0n) throw new TypeError('BigInt numerator and non-zero denominator required');
  const negative = (numerator < 0n) !== (denominator < 0n);
  const n = numerator < 0n ? -numerator : numerator, d = denominator < 0n ? -denominator : denominator;
  const q = n / d + (2n * (n % d) >= d ? 1n : 0n);
  return negative ? -q : q;
}

// Units rounded to `digits` fraction digits (0–8), still in units.
export function roundUnits(units, digits = 2) {
  if (!Number.isInteger(digits) || digits < 0 || digits > 8) throw new TypeError('0 to 8 digits');
  const step = SCALE[8 - digits];
  return divRound(units, step) * step;
}

// Exact product of two unit values, rounded half away from zero to units.
export const mulUnits = (a, b) => divRound(a * b, UNIT);
// Exact quotient of two unit values, as units of the ratio (1 = UNIT).
export const divUnits = (a, b) => divRound(a * UNIT, b);

export function unitsDecimal(units) {
  if (typeof units !== 'bigint') throw new TypeError('BigInt units required');
  const sign = units < 0n ? '-' : '', abs = units < 0n ? -units : units;
  const whole = abs / UNIT, fraction = String(abs % UNIT).padStart(8, '0').replace(/0+$/, '');
  return `${sign}${whole}${fraction ? `.${fraction}` : ''}`;
}

// The display value: rounded once, at the end, to `digits`; the Number then
// carries exactly those digits for formatting.
export const unitsNumber = (units, digits = 2) => Number(unitsDecimal(roundUnits(units, digits)));
