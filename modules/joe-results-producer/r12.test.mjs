import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createCapture } from './capture.mjs';
import { openProducer } from './producer.mjs';
import { hash, readJournal } from './journal.mjs';
import { roundTrips } from './fifo.mjs';
import { brokerDayTotals, brokerMismatches } from './broker-backstop.mjs';
import { decimalUnits, UNIT } from './contracts/decimal.mjs';
import { validateResults } from './results-validation.mjs';

const begin = '2026-10-15T22:00:00.000Z', end = '2026-10-20T22:00:00.000Z';
const instant = (day, hour) => `2026-10-${day}T${hour}:00:00.000Z`;
const health = { status: 'ok', halt: { active: false }, brakes: { newPerDay: 1, notionalEur: 1 }, gatewayReachable: true };
function directory() {
  const root = fileURLToPath(new URL('../../tests/.tmp/', import.meta.url));
  mkdirSync(root, { recursive: true });
  return mkdtempSync(path.join(root, 'joed20-r12-'));
}
function fill(key, side, at, { desk = 'j', instrument = hash('synthetic-acme'), quantity = '1', price = '10', fee = '0', currency = 'EUR', pnl = '0', reportCurrency = currency } = {}) {
  return { key: hash(key), desk, instrument, scope: 'stage0', symbol: 'ACME', side, at, quantity, price, currency,
    commission: { amount: fee, currency },
    brokerRealised: side === 'BUY' ? { unset: true, currency } : { amount: pnl, currency: reportCurrency },
    closeFx: { base: currency, quote: 'EUR', rate: currency === 'EUR' ? '1' : '0.86123457', source: currency === 'EUR' ? 'identity' : 'ib-fx-close', observedAt: currency === 'EUR' ? at : '2026-10-16T20:05:00.000Z' },
  };
}
function pair(key, day, options = {}) {
  return [fill(`${key}-open`, 'BUY', instant(day, '10'), options), fill(`${key}-close`, 'SELL', instant(day, '12'), options)];
}
function setup(t, fills, extra = {}) {
  const filename = path.join(directory(), 'results.jsonl');
  let producer = openProducer(filename, { now: () => end });
  const rows = [{ type: 'start', at: begin }, { type: 'cut', at: end, authoritative: true, fills,
    historyCoverage: { status: 'complete', target: { fromInclusive: begin, toExclusive: end }, gaps: [] }, ...extra }];
  producer.ingest(rows);
  t.after(() => producer.close());
  return { filename, rows, get producer() { return producer; },
    replay() { producer.close(); producer = openProducer(filename, { now: () => end }); return producer.snapshot(); } };
}
const coverage = (result, day) => result.days.find(row => row.date === `2026-10-${day}`).coverage ?? 'full';

test('USD-currency broker report retains PnL 12.34 × sampled 0.86123457 exactly at 10^-16', t => {
  const fills = pair('usd', '16', { currency: 'USD' });
  fills[1].price = '22.34'; fills[1].brokerRealised.amount = '12.34';
  const f = setup(t, fills, { fxSampler: { enabled: true, reason: null, days: {
    '2026-10-16': { samples: [{ rate: '0.86123457', sampleAt: '2026-10-16T20:05:00.000Z', kind: 'close' }] },
  } } });
  const result = f.producer.snapshot();
  assert.equal(coverage(result, '16'), 'full');
  assert.equal(result.trades[0].netEur.amount, '10.62763459');
  assert.equal(brokerDayTotals(fills, begin).get('2026-10-16:j').net, 106276345938000000n);
  assert.deepEqual(readJournal(f.filename).filter(row => row.type === 'broker-mismatch'), []);
  assert.deepEqual(f.replay().days, result.days);
});

for (const sign of [1, -1]) for (const [magnitude, expected] of [['0.01161123', 'full'], ['0.01161124', 'partial']]) {
  test(`USD broker tolerance ${sign < 0 ? '-' : '+'}${magnitude} USD is ${expected}`, t => {
    const fills = pair('tolerance', '16', { currency: 'USD', pnl: sign < 0 ? `-${magnitude}` : magnitude });
    const f = setup(t, fills), result = f.producer.snapshot();
    assert.equal(coverage(result, '16'), expected);
    const net16 = brokerDayTotals(fills, begin).get('2026-10-16:j').net;
    assert.equal((net16 < 0n ? -net16 : net16) > UNIT * UNIT / 100n, expected === 'partial');
    assert.deepEqual(brokerMismatches(result.days, fills, begin, end).map(row => row.kind), expected === 'partial' ? ['broker_realised_pnl_mismatch'] : []);
  });
}

test('multi-fill USD day sums exact broker products and preserves the EUR-report path', t => {
  const fills = ['12.34', '5.67', '-1.23'].flatMap((pnl, i) => {
    const rows = pair(`multi-${i}`, '16', { currency: 'USD', instrument: hash(`synthetic-${i}`), pnl });
    rows[1].price = ['22.34', '15.67', '8.77'][i];
    return rows;
  });
  const eurReport = pair('eur-report', '16', { currency: 'USD', reportCurrency: 'EUR', instrument: hash('synthetic-eur-report'), pnl: '1.72246914' });
  eurReport[1].price = '12'; fills.push(...eurReport);
  const f = setup(t, fills), result = f.producer.snapshot();
  assert.equal(coverage(result, '16'), 'full');
  assert.equal(result.trades.length, 4);
  const exact16 = ['12.34', '5.67', '-1.23'].reduce((sum, pnl) => sum + decimalUnits(pnl) * decimalUnits('0.86123457'), 0n)
    + decimalUnits('1.72246914') * UNIT;
  assert.equal(brokerDayTotals(fills, begin).get('2026-10-16:j').net, exact16);
  assert.deepEqual(brokerMismatches(result.days, fills, begin, end), []);
  assert.equal(validateResults(result).ok, true);
});

function sevenShareFills() {
  return [fill('seven-open', 'BUY', instant('16', '10'), { quantity: '7', fee: '3' }),
    fill('seven-close3', 'SELL', instant('16', '12'), { quantity: '3' }),
    fill('seven-close3-again', 'SELL', instant('17', '10'), { quantity: '3' }),
    fill('seven-close1', 'SELL', instant('17', '12'))];
}
test('7 shares / EUR 3 fee / closes 3 then 3+1 contain every inexact portion and preserve other output', t => {
  const fills = [...sevenShareFills(), ...pair('other-desk', '16', { desk: 'joe' }),
    ...pair('other-instrument', '18', { instrument: hash('synthetic-other') }),
    ...pair('later-other-desk', '18', { desk: 'joe' }),
    ...pair('later-affected', '19')];
  const f = setup(t, fills), result = f.producer.snapshot();
  assert.equal(coverage(result, '16'), 'partial'); assert.equal(coverage(result, '17'), 'partial');
  assert.equal(result.days[0].desks.joe.trades, 1);
  assert.equal(result.days[0].desks.joe.realisedNet.amount, '0');
  assert.deepEqual(brokerMismatches([{ ...result.days[0], desks: { joe: result.days[0].desks.joe } }], fills, begin, end), []);
  assert.equal(coverage(result, '18'), 'full');
  assert.equal(coverage(result, '19'), 'partial'); // zero-PnL later round trip, gap alone keeps it partial
  assert.equal(result.trades.length, 4);
  const records = () => readJournal(f.filename).filter(row => row.type === 'conversion-exclusion').map(row => row.record);
  assert.equal(records().length, 3); // each portion has a distinct value-free identity
  for (const record of records()) {
    assert.deepEqual(Object.keys(record).sort(), ['day', 'deskHash', 'kind', 'portionHash', 'instrumentHash', 'at'].sort());
    assert.equal(record.kind, 'source_not_authoritative');
    for (const field of ['deskHash', 'portionHash', 'instrumentHash']) assert.match(record[field], /^[a-f0-9]{64}$/);
  }
  assert.equal(f.producer.health(health).portionExclusions, 3);
  f.producer.snapshot(); assert.equal(records().length, 3);
  assert.deepEqual(f.replay().days, result.days);
  assert.equal(f.producer.health(health).portionExclusions, 3);
  assert.equal(validateResults(result).ok, true);
  // A clean fee correction does not erase the previously recorded gaps.
  f.rows.push({ ...f.rows[1], fills: [{ ...fills[0], commission: { amount: '0', currency: 'EUR' } }] });
  f.producer.ingest(f.rows);
  const corrected = f.producer.snapshot();
  assert.equal(coverage(corrected, '19'), 'partial');
  assert.equal(f.producer.health(health).portionExclusions, 3);
  assert.deepEqual(f.replay().days, corrected.days);
  // A post-gap flat proof restores only later days, not excluded history.
  f.rows.push({ type: 'cut', at: end, authoritative: true, fills: [],
    historyCoverage: f.rows[1].historyCoverage,
    positionProof: { at: instant('18', '08'), positions: [{ instrument: fills[0].instrument, quantity: '0' }], foreign: [] } });
  f.producer.ingest(f.rows);
  const proven = f.producer.snapshot();
  assert.equal(coverage(proven, '19'), 'full');
  assert.equal(coverage(proven, '16'), 'partial'); assert.equal(coverage(proven, '17'), 'partial');
  assert.deepEqual(f.replay().days, proven.days);
});

test('3+4 entries / single 7-share close excludes both unrepresentable closing-fee portions', t => {
  const fills = [fill('entry3', 'BUY', instant('16', '09'), { quantity: '3' }),
    fill('entry4', 'BUY', instant('16', '10'), { quantity: '4' }),
    fill('close7', 'SELL', instant('16', '12'), { quantity: '7', fee: '3', pnl: '-3' }),
    ...pair('fresh-after-consumed', '17')];
  const excluded = [], trades = roundTrips(fills, begin, [], () => {}, record => excluded.push(record));
  assert.equal(excluded.length, 2); assert.notEqual(excluded[0].portionHash, excluded[1].portionHash);
  assert.equal(trades.length, 1); assert.equal(trades[0].quantity, '1'); // no reuse of either failed lot
  const f = setup(t, fills), result = f.producer.snapshot();
  assert.equal(coverage(result, '16'), 'partial'); assert.equal(coverage(result, '17'), 'partial');
  assert.equal(f.producer.health(health).portionExclusions, 2);
  assert.deepEqual(f.replay().days, result.days);
});

test('a representable portion after an excluded portion in the same close still emits', () => {
  const fills = [fill('bad7', 'BUY', instant('16', '09'), { quantity: '7', fee: '3' }),
    fill('good1', 'BUY', instant('16', '10')), fill('partial-close', 'SELL', instant('16', '11'), { quantity: '3' }),
    fill('mixed-close', 'SELL', instant('16', '12'), { quantity: '5' })];
  const excluded = [], trades = roundTrips(fills, begin, [], () => {}, record => excluded.push(record));
  assert.equal(excluded.length, 2); assert.equal(trades.length, 1); assert.equal(trades[0].quantity, '1');
});

test('refused opening / zero-PnL later close stays partial until matching position proof; correction retains issue day', t => {
  const root = directory(), input = path.join(root, 'capture.jsonl'), account = 'synthetic-account';
  let now = begin;
  const config = { executorClientId: 705, foreignAlertSince: begin };
  const options = { account, attribute: () => ({ desk: 'j', method: 'admin' }), executionTime: Date.parse, now: () => now };
  let capture = createCapture(input, config, options);
  t.after(() => capture.close());
  capture({ ownershipComplete: true, executions: [] }); now = end;
  const raw = (id, time, side, price) => ({ contract: { conId: 1, symbol: 'ACME', currency: 'EUR' },
    execution: { execId: `synthetic-${id}.01`, acctNumber: account, clientId: 705, time, side, price, shares: '1' } });
  const opening = raw('refused', instant('16', '10'), 'BUY', 1e-7), closing = raw('zero-close', instant('18', '12'), 'SELL', '10');
  const state = { ownershipComplete: true, executions: [opening, closing],
    commissions: [opening, closing].map(row => ({ execId: row.execution.execId, commission: '0', currency: 'EUR', realizedPNL: row === opening ? Number.MAX_VALUE : '0' })),
    resultsHistoryCoverage: { status: 'complete', target: { fromInclusive: begin, toExclusive: end }, gaps: [] } };
  capture(state);
  const gap = { fromInclusive: opening.execution.time, toExclusive: new Date(Date.parse(opening.execution.time) + 1).toISOString() };
  assert.deepEqual(readJournal(input).at(-1).historyCoverage.gaps, [gap]);
  // This producer consumes the real capture journal, including its persistent issue.
  const captured = openProducer(path.join(root, 'results.jsonl'), { now: () => end });
  t.after(() => captured.close());
  const refresh = () => { capture(state); captured.ingest(readJournal(input)); return captured.snapshot(); };
  const first = refresh();
  assert.equal(coverage(first, '18'), 'partial'); assert.equal(first.trades.length, 0);
  assert.deepEqual(brokerMismatches(first.days.filter(day => day.date === '2026-10-18'), readJournal(input).flatMap(row => row.fills || []), begin, end), []);
  assert.equal(captured.health(health).captureRefusals, 1);
  capture.close(); capture = createCapture(input, config, options); capture(state);
  assert.deepEqual(readJournal(input).at(-1).historyCoverage.gaps, [gap]);
  // A proof must precede the apparent opening; a later matching short is insufficient.
  state.ownershipSnapshot = { account, ownershipComplete: true, observedAt: instant('19', '10'),
    positions: [{ conId: 1, symbol: 'ACME', currency: 'EUR', position: '-1' }] };
  assert.equal(coverage(refresh(), '18'), 'partial'); // proof after the fill cannot cover that day's close
  state.ownershipSnapshot.observedAt = instant('17', '10');
  state.ownershipSnapshot.positions[0].position = '0';
  assert.equal(coverage(refresh(), '18'), 'full');
  opening.execution.price = '10';
  const corrected = refresh();
  assert.equal(coverage(corrected, '16'), 'partial'); // capture issues intentionally never clear
  assert.equal(coverage(corrected, '18'), 'full'); assert.equal(corrected.trades.length, 1);
  assert.equal(captured.health(health).captureRefusals, 1);
  assert.equal(readFileSync(input, 'utf8').includes(account), false);
  assert.equal(validateResults(corrected).ok, true);
});
