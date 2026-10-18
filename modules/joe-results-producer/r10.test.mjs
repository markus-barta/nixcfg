import test from 'node:test';
import assert from 'node:assert/strict';
import { cpSync, mkdtempSync, readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { roundTrips } from './fifo.mjs';
import { openProducer } from './producer.mjs';
import { readJournal } from './journal.mjs';
import { decimalUnits, unitsDecimal } from './contracts/decimal.mjs';
import { validateResults } from './results-validation.mjs';

const start = '2026-10-25T23:00:00.000Z', at = '2026-10-26T23:00:00.000Z';
const closeAt = '2026-10-26T14:35:00.000Z';
const sample = { rate: '0.5', sampleAt: '2026-10-26T20:05:00.000Z', kind: 'close' };
const directory = () => mkdtempSync(path.join(tmpdir(), 'joed20-r10-'));
function pair(key, { currency = 'USD', price = '11.00000001', fee = '0.00000003', rate = '0.5', net = '0.49999998' } = {}) {
  return ['BUY', 'SELL'].map((side, i) => ({ key: `${key}-${i}`, desk: 'j', scope: 'stage0', instrument: `synthetic-${key}`, symbol: 'ACME', currency, side,
    at: i ? closeAt : '2026-10-26T13:35:00.000Z', quantity: '1', price: i ? price : '10',
    commission: { amount: i ? '0' : fee, currency },
    brokerRealised: i ? { amount: net, currency: 'EUR' } : { unset: true, currency },
    closeFx: { base: currency, quote: 'EUR', rate: currency === 'EUR' ? '1' : rate, source: currency === 'EUR' ? 'identity' : 'synthetic', observedAt: closeAt },
  }));
}
function source(fills, fxSampler) {
  return [{ type: 'start', at: start }, { type: 'cut', at, authoritative: true, fills,
    historyCoverage: { status: 'complete', target: { fromInclusive: start, toExclusive: at }, gaps: [] },
    ...(fxSampler ? { fxSampler } : {}),
  }];
}

for (const [price, expected] of [['10.00000001', '0'], ['10.00000003', '0.00000002'], ['9.99999999', '0'], ['9.99999997', '-0.00000002']]) {
  test(`EUR gross half-even tie: USD close ${price} -> ${expected}`, () => {
    const [trade] = roundTrips(pair('tie', { price, fee: '0' }), start, []);
    assert.equal(trade.grossEur.amount, expected);
    assert.equal(trade.netEur.amount, expected);
  });
}
for (const [fee, expected] of [['0.00000001', '0'], ['0.00000003', '0.00000002']]) {
  test(`combined EUR fee half-even tie: USD fee ${fee} -> ${expected}`, () => {
    const [trade] = roundTrips(pair('fee-tie', { fee }), start, []);
    assert.equal(trade.feesEur.amount, expected);
    assert.equal(decimalUnits(trade.netEur.amount), decimalUnits(trade.grossEur.amount) - decimalUnits(expected));
  });
}
test('opening and closing fee halves combine before the only rounding point', () => {
  const fills = pair('combined', { fee: '0.00000001' });
  fills[1].commission.amount = '0.00000001';
  assert.equal(roundTrips(fills, start, [])[0].feesEur.amount, '0.00000001');
});

for (const [move, odd, rounded] of [['0.00000001', 1n, '0'], ['0.00000003', 3n, '0.00000002']]) {
  for (const sign of [1n, -1n]) test(`1,000 adversarial ties attain the n×0.5e-8 bound: ${sign} × ${move}`, () => {
    const count = 1000n, abs = x => x < 0n ? -x : x;
    const fills = Array.from({ length: Number(count) }, (_, i) => pair(`bound-${i}`, {
      price: unitsDecimal(decimalUnits('10') + sign * decimalUnits(move)), fee: move,
    })).flat();
    const trades = roundTrips(fills, start, []);
    assert.equal(trades.length, Number(count));
    assert.ok(trades.every(trade => decimalUnits(trade.grossEur.amount) === sign * decimalUnits(rounded) && trade.feesEur.amount === rounded));
    const gross = trades.reduce((sum, trade) => sum + decimalUnits(trade.grossEur.amount), 0n);
    const fees = trades.reduce((sum, trade) => sum + decimalUnits(trade.feesEur.amount), 0n);
    // Compare in half-units (0.5e-8 EUR), keeping the exact sum rational.
    // Every same-direction tie reaches, rather than merely approaches, the bound.
    for (const [roundedSum, exactTwiceSum] of [[gross, sign * count * odd], [fees, count * odd]]) {
      const errorInHalfUnits = abs(2n * roundedSum - exactTwiceSum);
      assert.ok(errorInHalfUnits <= count);
      assert.equal(errorInHalfUnits, count);
    }
  });
}

test('full day mixing rounded USD and exact EUR portions cross-checks with zero tolerance', t => {
  const producer = openProducer(path.join(directory(), 'mixed.jsonl'), { now: () => at });
  t.after(() => producer.close());
  producer.ingest(source([...pair('usd'), ...pair('eur', { currency: 'EUR', price: '12', fee: '0.1', net: '1.9' })]));
  const value = producer.snapshot();
  assert.equal(value.days[0].coverage ?? 'full', 'full');
  assert.equal(value.days[0].desks.j.realisedNet.amount, '2.39999998');
  assert.equal(value.days[0].desks.j.fees.amount, '0.10000002');
  assert.equal(validateResults(value).ok, true);
  const bad = structuredClone(value);
  bad.days[0].desks.j.realisedNet.amount = '2.39999999';
  assert.ok(validateResults(bad).errors.some(error => error.rule === 'dayNetSum'));
});

for (const mode of ['missing', 'stale-legacy', 'stale-rth', 'present-legacy', 'present-close']) {
  test(`${mode} FX: only missing/stale portions exclude with a value-free fx_missing record`, t => {
    const filename = path.join(directory(), 'results.jsonl');
    const fills = pair(mode);
    let sampler;
    if (mode === 'stale-legacy') fills[1].closeFx.observedAt = '2026-10-26T14:33:59.999Z';
    if (['missing', 'stale-rth', 'present-close'].includes(mode)) {
      fills.forEach(fill => { fill.closeFx = null; });
      sampler = { enabled: true, reason: null, days: mode === 'missing' ? {} : {
        '2026-10-26': { samples: [mode === 'stale-rth' ? { ...sample, sampleAt: '2026-10-26T14:00:00.000Z', kind: 'rth' } : sample] },
      } };
    }
    let producer = openProducer(filename, { now: () => at });
    t.after(() => producer.close());
    producer.ingest(source(fills, sampler));
    const value = producer.snapshot(), excluded = !mode.startsWith('present');
    assert.equal(value.days[0].coverage ?? 'full', excluded ? 'partial' : 'full');
    assert.equal(value.trades.length, excluded ? 0 : 1);
    const records = () => readJournal(filename).filter(row => row.type === 'conversion-exclusion');
    assert.equal(records().length, excluded ? 1 : 0);
    if (excluded) {
      assert.deepEqual(Object.keys(records()[0].record).sort(), ['day', 'deskHash', 'kind']);
      assert.equal(records()[0].record.kind, 'fx_missing');
      assert.match(records()[0].record.deskHash, /^[a-f0-9]{64}$/);
    }
    producer.close(); producer = openProducer(filename, { now: () => at });
    assert.deepEqual(producer.snapshot().trades, value.trades);
    assert.equal(records().length, excluded ? 1 : 0);
  });
}

test('frozen round-9b journal replays: old precision exclusions are history, healed days can become full', t => {
  const fixture = readFileSync(new URL('./fixtures/round9b-results.jsonl', import.meta.url));
  assert.equal(createHash('sha256').update(fixture).digest('hex'), '09e29c27e9c17b48e5cffd25412e3a4a6ad6f2055db9517127aeab714635342b');
  const filename = path.join(directory(), 'replay.jsonl');
  cpSync(new URL('./fixtures/round9b-results.jsonl', import.meta.url), filename);
  let producer = openProducer(filename, { now: () => at });
  t.after(() => producer.close());
  const value = producer.snapshot();
  assert.equal(value.seq, 2);
  assert.equal(value.trades[0].grossEur.amount, '2.04112593');
  assert.equal(value.days[0].coverage ?? 'full', 'full');
  assert.equal(validateResults(value).ok, true);
  assert.ok(readFileSync(filename).subarray(0, fixture.length).equals(fixture));
  assert.equal(readJournal(filename).filter(row => row.type === 'conversion-exclusion').length, 1);
  producer.close(); producer = openProducer(filename, { now: () => at });
  assert.deepEqual(producer.snapshot().trades, value.trades);
});
