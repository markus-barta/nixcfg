import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { roundTrips } from './fifo.mjs';
import { openProducer } from './producer.mjs';
import { createCapture } from './capture.mjs';
import { readJournal } from './journal.mjs';
import { decimalUnits } from './contracts/decimal.mjs';
import { validateContract } from './contracts/index.mjs';
import { validateResults, PARTIAL_REASONS, markPartial } from './results-validation.mjs';

const start = '2026-10-15T22:00:00.000Z', at = '2026-10-18T22:00:00.000Z';
const instant = (day, minute = 0) => new Date(Date.parse(`2026-10-${day}T10:00:00.000Z`) + minute * 60_000).toISOString();
function directory(t) {
  const root = fileURLToPath(new URL('../../tests/.tmp/', import.meta.url));
  mkdirSync(root, { recursive: true });
  const dir = mkdtempSync(path.join(root, 'joed20-r13-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}
function fill(key, side, quantity, fee = '0', { currency = 'EUR', rate = '1', day = '16', minute = 0, instrument = 'synthetic-acme' } = {}) {
  const time = instant(day, minute);
  return { key, desk: 'j', instrument, symbol: 'ACME', scope: 'stage0', side, at: time, currency, quantity, price: '10',
    commission: { amount: fee, currency }, brokerRealised: side === 'BUY' ? { unset: true, currency } : { amount: `-${fee}`, currency },
    closeFx: { base: currency, quote: 'EUR', rate, observedAt: time, source: currency === 'EUR' ? 'identity' : 'synthetic' } };
}
function setup(t, fills, extra = {}, from = start, through = at) {
  const filename = path.join(directory(t), 'results.jsonl');
  let producer = openProducer(filename, { now: () => through });
  const rows = [{ type: 'start', at: from }, { type: 'cut', at: through, authoritative: true, fills,
    historyCoverage: { status: 'complete', target: { fromInclusive: from, toExclusive: through }, gaps: [] }, ...extra }];
  producer.ingest(rows);
  t.after(() => producer.close());
  return { rows, get producer() { return producer; }, snapshot() { return producer.snapshot(); },
    replay() { producer.close(); producer = openProducer(filename, { now: () => through }); return producer.snapshot(); } };
}
const sumFees = trades => trades.reduce((sum, trade) => sum + decimalUnits(trade.feesEur.amount), 0n);
const run = fills => {
  const excluded = [], trades = roundTrips(fills, start, [], () => {}, record => excluded.push(record));
  assert.deepEqual(excluded, []);
  return trades;
};

for (const currency of ['EUR', 'USD']) {
  test(`${currency} 7 / 3 fee vector: close 3 then 4 yields the approved EUR portions`, t => {
    const options = { currency };
    const fills = [fill('open', 'BUY', '7', '3', options), fill('close3', 'SELL', '3', '0', { ...options, minute: 1 }),
      fill('close4', 'SELL', '4', '0', { ...options, minute: 2 })];
    fills[1].brokerRealised.amount = '-1.28571429'; fills[2].brokerRealised.amount = '-1.71428571';
    const trades = run(fills);
    assert.deepEqual(trades.map(t => t.feesEur.amount), ['1.28571429', '1.71428571']);
    assert.equal(sumFees(trades), decimalUnits('3.00000000'));
    const f = setup(t, fills), result = f.snapshot();
    assert.equal(result.days[0].coverage ?? 'full', 'full');
    assert.equal(result.days[0].desks.j.fees.amount, '3');
    assert.deepEqual(f.replay().days, result.days);
    assert.deepEqual(f.replay().trades, result.trades);
    assert.equal(f.producer.health({}).portionExclusions, 0);
  });
  test(`${currency} 3+4 entries / single 7-share close conserves the closing fee`, () => {
    const options = { currency };
    const trades = run([fill('entry3', 'BUY', '3', '0', options), fill('entry4', 'BUY', '4', '0', { ...options, minute: 1 }),
      fill('close7', 'SELL', '7', '3', { ...options, minute: 2 })]);
    assert.deepEqual(trades.map(t => t.feesEur.amount), ['1.28571429', '1.71428571']);
    assert.equal(sumFees(trades), decimalUnits('3'));
  });
  for (const count of currency === 'EUR' ? [7, 1001] : []) test(`${currency} ${count} portions round each share once and conserve the lot fee`, () => {
    const options = { currency };
    const fills = [fill('open', 'BUY', String(count), '3', options), ...Array.from({ length: count }, (_, i) =>
      fill(`close-${i}`, 'SELL', '1', '0', { ...options, minute: i + 1 }))];
    const trades = run(fills), rounded = count === 7 ? decimalUnits('0.42857143') : decimalUnits('0.002997');
    assert.equal(trades.length, count);
    assert.ok(trades.slice(0, -1).every(t => decimalUnits(t.feesEur.amount) === rounded));
    assert.equal(decimalUnits(trades.at(-1).feesEur.amount), decimalUnits('3') - BigInt(count - 1) * rounded);
    assert.equal(sumFees(trades), decimalUnits('3'));
  });
  for (const [fee, expected] of currency === 'EUR' ? [['0.00000001', ['0', '0.00000001']], ['0.00000003', ['0.00000002', '0.00000001']]] : []) {
    test(`${currency} source allocation half-even tie ${fee}; last share is the remainder`, () => {
      const options = { currency };
      const trades = run([fill('open', 'BUY', '2', fee, options), fill('close1', 'SELL', '1', '0', { ...options, minute: 1 }),
        fill('close2', 'SELL', '1', '0', { ...options, minute: 2 })]);
      assert.deepEqual(trades.map(t => t.feesEur.amount), expected);
      assert.equal(sumFees(trades), decimalUnits(fee));
    });
  }
}

test('USD allocated shares convert at each close FX; combined converted fees round once', () => {
  const options = { currency: 'USD', rate: '0.5' };
  const trades = run([fill('open', 'BUY', '7', '3', options), fill('close3', 'SELL', '3', '0', { ...options, minute: 1 }),
    fill('close4', 'SELL', '4', '0', { ...options, minute: 2 })]);
  assert.deepEqual(trades.map(t => t.feesEur.amount), ['0.64285714', '0.85714286']);
  assert.equal(sumFees(trades), decimalUnits('1.5'));
  const both = run([fill('open', 'BUY', '1', '0.00000001', options), fill('close', 'SELL', '1', '0.00000001', { ...options, minute: 1 })]);
  assert.equal(both[0].feesEur.amount, '0.00000001');
});

test('reversing execution carries its already allocated fee into the remaining opening lot', () => {
  const trades = run([fill('open3', 'BUY', '3'), fill('reverse7', 'SELL', '7', '3', { minute: 1 }),
    fill('close4', 'BUY', '4', '0', { minute: 2 })]);
  assert.deepEqual(trades.map(t => t.feesEur.amount), ['1.28571429', '1.71428571']);
  assert.equal(sumFees(trades), decimalUnits('3'));
});

test('failed FX portion consumes its allocation and quantity; later portions keep their own shares', t => {
  const fills = [fill('open7', 'BUY', '7', '3', { currency: 'USD' }), fill('missing3', 'SELL', '3', '0', { currency: 'USD', minute: 1 }),
    fill('good4', 'SELL', '4', '0', { currency: 'USD', minute: 2 })];
  fills[1].closeFx = null;
  const excluded = [], trades = roundTrips(fills, start, [], () => {}, record => excluded.push(record));
  assert.equal(excluded.length, 1); assert.equal(excluded[0].kind, 'fx_missing');
  assert.equal(trades[0].feesEur.amount, '1.71428571'); assert.equal(trades[0].quantity, '4');
  const f = setup(t, fills), result = f.snapshot();
  assert.ok(result.days[0].partialReasons.includes('fx_missing'));
  assert.equal(validateResults(result, { requirePartialReasons: true }).ok, true);
});

test('unexpected portion failure is guarded, counted and scoped across replay', t => {
  const fills = [fill('bad-open', 'BUY', '7', '3'), fill('bad-close', 'SELL', '7', '0', { minute: 1 }),
    fill('good-open', 'BUY', '1', '0', { instrument: 'synthetic-other', day: '17' }),
    fill('good-close', 'SELL', '1', '0', { instrument: 'synthetic-other', day: '17', minute: 1 })];
  fills[0].commission.currency = 'GBP';
  const f = setup(t, fills), result = f.snapshot();
  assert.equal(result.trades.length, 1); assert.equal(f.producer.health({}).portionExclusions, 1);
  assert.ok(result.days[0].partialReasons.includes('history_gap'));
  assert.equal(result.days[1].coverage ?? 'full', 'full');
  assert.deepEqual(f.replay().days, result.days); assert.equal(f.producer.health({}).portionExclusions, 1);
});

test('a non-Error thrown by a portion cannot escape the containment guard', () => {
  const bad = fill('throws-null', 'SELL', '1', '0', { minute: 1 });
  Object.defineProperty(bad, 'closeFx', { get() { throw null; } });
  const excluded = [];
  const trades = roundTrips([fill('open', 'BUY', '1'), bad,
    fill('next-open', 'BUY', '1', '0', { minute: 2 }), fill('next-close', 'SELL', '1', '0', { minute: 3 })],
  start, [], () => {}, record => excluded.push(record));
  assert.equal(excluded.length, 1); assert.equal(excluded[0].kind, 'source_not_authoritative');
  assert.equal(trades.length, 1); assert.equal(trades[0].quantity, '1');
});

const pair = () => [fill('open', 'BUY', '1'), fill('close', 'SELL', '1', '0', { minute: 1 })];
const gap = { fromInclusive: instant('16', 2), toExclusive: new Date(Date.parse(instant('16', 2)) + 1).toISOString() };
const reasonCases = [
  ['capture_gap', () => ({ from: instant('16') })],
  ['history_gap', () => ({ extra: { historyCoverage: { status: 'known', target: { fromInclusive: start, toExclusive: at }, gaps: [gap] } } })],
  ['broker_trade_count_mismatch', () => ({ fills: [fill('open3', 'BUY', '3'), fill('open4', 'BUY', '4', '0', { minute: 1 }), fill('close7', 'SELL', '7', '0', { minute: 2 })] })],
  ['broker_realised_pnl_mismatch', () => { const fills = pair(); fills[1].brokerRealised.amount = '1'; return { fills }; }],
  ['unattributed_activity', () => ({ extra: { unattributedActivity: { '2026-10-16': 2 } } })],
  ['fx_disabled', () => ({ fills: pair().map(f => ({ ...f, currency: 'USD', closeFx: null })), extra: { fxSampler: { enabled: false, days: {} } } })],
  ['fx_missing', () => ({ fills: pair().map(f => ({ ...f, currency: 'USD', closeFx: null })), extra: { fxSampler: { enabled: true, days: {} } } })],
  ['broker_evidence_missing', () => { const fills = pair(); fills[0].commission = null; return { fills }; }],
];
for (const [reason, scenario] of reasonCases) test(`partial cause ${reason} is emitted in canonical order with valid count rules`, t => {
  const { fills = pair(), extra, from } = scenario(), f = setup(t, fills, extra, from);
  const result = f.snapshot(), day = result.days[0];
  assert.equal(day.coverage, 'partial'); assert.ok(day.partialReasons.includes(reason));
  assert.deepEqual(day.partialReasons, PARTIAL_REASONS.filter(code => day.partialReasons.includes(code)));
  assert.equal(day.partialReasons.includes('avg_cost_mismatch'), false);
  assert.equal(day.unattributedCount, reason === 'unattributed_activity' ? 2 : undefined);
  assert.equal(validateResults(result, { requirePartialReasons: true }).ok, true);
  assert.deepEqual(f.replay().days, result.days);
});

test('capture counts distinct unattributed logical fills, excludes KEEP and heals on attribution', t => {
  const dir = directory(t), filename = path.join(dir, 'capture.jsonl');
  let now = start;
  const raw = (id, symbol = 'ACME') => ({ attributed: false, contract: { conId: 1, symbol, currency: 'EUR' },
    execution: { execId: `synthetic-${id}.01`, acctNumber: 'synthetic-account', clientId: 705, time: instant('16'), side: 'BUY', shares: '1', price: '10' } });
  const capture = createCapture(filename, { executorClientId: 705, foreignAlertSince: start }, {
    account: 'synthetic-account', now: () => now, executionTime: Date.parse,
    attribute: row => row.attributed ? { desk: 'j', method: 'admin' } : { needsAttribution: true },
  });
  t.after(() => capture.close());
  capture({ executions: [], ownershipComplete: true }); now = at;
  const a = raw('one'), b = raw('two'), state = { executions: [a, a, b, raw('keep', 'TSLA')], ownershipComplete: true,
    commissions: [a, b].map(row => ({ execId: row.execution.execId, commission: '0', currency: 'EUR', realizedPNL: Number.MAX_VALUE })),
    resultsHistoryCoverage: { status: 'complete', target: { fromInclusive: start, toExclusive: at }, gaps: [] } };
  capture(state);
  // Consume real capture evidence, not a synthetic count projection.
  const output = openProducer(path.join(dir, 'results.jsonl'), { now: () => at }); t.after(() => output.close());
  output.ingest(readJournal(filename));
  const first = output.snapshot();
  assert.deepEqual(first.days[0].partialReasons, ['unattributed_activity']);
  assert.equal(first.days[0].unattributedCount, 2);
  a.attributed = true; b.attributed = true; capture(state);
  output.ingest(readJournal(filename));
  const healed = output.snapshot();
  assert.equal(healed.days[0].coverage ?? 'full', 'full');
  assert.equal(Object.hasOwn(healed.days[0], 'partialReasons'), false);
  assert.equal(Object.hasOwn(healed.days[0], 'unattributedCount'), false);
});

test('many simultaneous partial causes deduplicate in canonical order, with no full-day metadata', t => {
  const result = setup(t, pair()).snapshot(), day = result.days[0];
  assert.equal(Object.hasOwn(day, 'partialReasons'), false);
  assert.equal(Object.hasOwn(day, 'unattributedCount'), false);
  for (const reason of [...PARTIAL_REASONS].reverse().filter(code => code !== 'avg_cost_mismatch')) {
    markPartial(day, reason); markPartial(day, reason);
  }
  assert.deepEqual(day.partialReasons, PARTIAL_REASONS.filter(code => code !== 'avg_cost_mismatch'));
  assert.equal(validateResults(result, { requirePartialReasons: true }).ok, true);
});

test('rev-6 local validator matches every board refusal; strict producer mode requires reasons', t => {
  const result = setup(t, pair()).snapshot();
  const invalid = [
    ['partialCoverageRequired', day => { day.partialReasons = ['history_gap']; }],
    ['partialCoverageRequired', day => { day.coverage = 'full'; day.partialReasons = ['history_gap']; }],
    ['canonicalOrder', day => { day.coverage = 'partial'; day.partialReasons = ['fx_missing', 'capture_gap']; }],
    ['uniqueItems', day => { day.coverage = 'partial'; day.partialReasons = ['history_gap', 'history_gap']; }],
    ['minItems', day => { day.coverage = 'partial'; day.partialReasons = []; }],
    ['enum', day => { day.coverage = 'partial'; day.partialReasons = ['fx_pending']; }],
    ['unattributedReasonRequired', day => { day.coverage = 'partial'; day.unattributedCount = 1; }],
    ['minimum', day => { day.coverage = 'partial'; day.partialReasons = ['unattributed_activity']; day.unattributedCount = 0; }],
    ['type', day => { day.coverage = 'partial'; day.partialReasons = ['unattributed_activity']; day.unattributedCount = 1.5; }],
  ];
  for (const [rule, mutate] of invalid) {
    const bad = structuredClone(result); mutate(bad.days[0]);
    const local = validateResults(bad), board = validateContract('results', bad, { stage: 'ingress', receivedAt: bad.generatedAt });
    assert.deepEqual(local, board); assert.equal(local.status, 422);
    assert.ok(local.errors.some(error => error.rule === rule), JSON.stringify(local));
  }
  const legacy = structuredClone(result); legacy.days[0].coverage = 'partial';
  assert.equal(validateResults(legacy).status, 422);
  assert.equal(validateResults(legacy, { requirePartialReasons: true }).status, 422);
  markPartial(legacy.days[0], 'history_gap');
  assert.equal(validateResults(legacy, { requirePartialReasons: true }).ok, true);
  legacy.days[0].partialReasons = ['avg_cost_mismatch'];
  assert.equal(validateResults(legacy).ok, true);
  assert.equal(validateResults(legacy, { requirePartialReasons: true }).status, 422);
  assert.throws(() => markPartial({}, 'avg_cost_mismatch'), /invalid_partial_reason/);
});
