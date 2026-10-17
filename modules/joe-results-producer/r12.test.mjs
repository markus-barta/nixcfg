import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createCapture } from './capture.mjs';
import { openProducer, createRunner } from './producer.mjs';
import { hash, readJournal } from './journal.mjs';
import { roundTrips } from './fifo.mjs';
import { brokerDayTotals, brokerMismatches } from './broker-backstop.mjs';
import { decimalUnits, UNIT } from './contracts/decimal.mjs';
import { validateResults } from './results-validation.mjs';

const begin = '2026-10-15T22:00:00.000Z', end = '2026-10-20T22:00:00.000Z';
const instant = (day, hour) => `2026-10-${day}T${hour}:00:00.000Z`;
const health = { status: 'ok', halt: { active: false }, brakes: { newPerDay: 1, notionalEur: 1 }, gatewayReachable: true };
function directory(t) {
  const root = fileURLToPath(new URL('../../tests/.tmp/', import.meta.url));
  mkdirSync(root, { recursive: true });
  const directory = mkdtempSync(path.join(root, 'joed20-r12-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  return directory;
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
  const filename = path.join(directory(t), 'results.jsonl');
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

function guardedSevenShareFills() {
  const opening = fill('seven-open', 'BUY', instant('16', '10'), { quantity: '7', fee: '3' });
  opening.commission.currency = 'GBP'; // unexpected source defect, not a fee split
  return [opening,
    fill('seven-close3', 'SELL', instant('16', '12'), { quantity: '3' }),
    fill('seven-close3-again', 'SELL', instant('17', '10'), { quantity: '3' }),
    fill('seven-close1', 'SELL', instant('17', '12'))];
}
test('third-currency opening fee contains every failed portion and preserves other output', t => {
  const fills = [...guardedSevenShareFills(), ...pair('other-desk', '16', { desk: 'joe' }),
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

test('3+4 entries / single close with third-currency fee contains both failed portions', t => {
  const fills = [fill('entry3', 'BUY', instant('16', '09'), { quantity: '3' }),
    fill('entry4', 'BUY', instant('16', '10'), { quantity: '4' }),
    fill('close7', 'SELL', instant('16', '12'), { quantity: '7', fee: '3', pnl: '-3' }),
    ...pair('fresh-after-consumed', '17')];
  fills[2].commission.currency = 'GBP';
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
  fills[0].commission.currency = 'GBP';
  const excluded = [], trades = roundTrips(fills, begin, [], () => {}, record => excluded.push(record));
  assert.equal(excluded.length, 2); assert.equal(trades.length, 1); assert.equal(trades[0].quantity, '1');
});

test('refused opening / zero-PnL later close stays partial until matching position proof; correction retains issue day', t => {
  const root = directory(t), input = path.join(root, 'capture.jsonl'), account = 'synthetic-account';
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
  assert.deepEqual(readJournal(input).at(-1).fillGaps, [{ ...gap, kind: 'capture_gap' }]);
  // This producer consumes the real capture journal, including its persistent issue.
  const captured = openProducer(path.join(root, 'results.jsonl'), { now: () => end });
  t.after(() => captured.close());
  const refresh = () => { capture(state); captured.ingest(readJournal(input)); return captured.snapshot(); };
  const first = refresh();
  assert.equal(coverage(first, '18'), 'partial'); assert.equal(first.trades.length, 0);
  assert.deepEqual(brokerMismatches(first.days.filter(day => day.date === '2026-10-18'), readJournal(input).flatMap(row => row.fills || []).filter(fill => fill.scope === 'stage0'), begin, end), []);
  assert.equal(captured.health(health).captureRefusals, 1);
  capture.close(); capture = createCapture(input, config, options); capture(state);
  assert.deepEqual(readJournal(input).at(-1).fillGaps, [{ ...gap, kind: 'capture_gap' }]);
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

function captureFixture(t) {
  const root = directory(t), input = path.join(root, 'capture.jsonl'), account = 'synthetic-account';
  let now = begin;
  const options = {
    account, attribute: row => ({ desk: row.testDesk || 'j', method: 'admin' }), executionTime: Date.parse, now: () => now,
  };
  const config = { executorClientId: 705, foreignAlertSince: begin };
  let capture = createCapture(input, config, options);
  capture({ ownershipComplete: true, executions: [] }); now = end;
  const filename = path.join(root, 'results.jsonl');
  let producer = openProducer(filename, { now: () => now });
  const state = { ownershipComplete: true, executions: [], commissions: [],
    resultsHistoryCoverage: { status: 'complete', target: { fromInclusive: begin, toExclusive: end }, gaps: [] } };
  t.after(() => { capture.close(); producer.close(); });
  const raw = (id, day, side, desk = 'j') => ({ testDesk: desk,
    contract: { conId: 1, symbol: 'ACME', currency: 'EUR' },
    execution: { execId: `synthetic-${id}.01`, acctNumber: account, clientId: 999, // admin attribution bypasses client ownership
      time: instant(day, side === 'BUY' ? '10' : '12'), side, shares: '1', price: '10' } });
  const addPair = (id, day, desk) => {
    const rows = [raw(`${id}-open`, day, 'BUY', desk), raw(`${id}-close`, day, 'SELL', desk)];
    state.executions.push(...rows);
    state.commissions.push(...rows.map((row, i) => ({ execId: row.execution.execId, commission: '0', currency: 'EUR', realizedPNL: i ? '0' : Number.MAX_VALUE })));
    return rows;
  };
  return { input, filename, state, raw, addPair, get capture() { return capture; }, get producer() { return producer; },
    setCaptureTime(at) { now = at; },
    restartCapture() { capture.close(); capture = createCapture(input, config, options); },
    refresh() { capture(state); producer.ingest(readJournal(input)); return producer.snapshot(); },
    replay() { producer.close(); producer = openProducer(filename, { now: () => now }); return producer.snapshot(); } };
}

for (const action of ['flatten', 'modify-stop']) for (const missingSide of ['opening', 'closing']) {
  test(`${action} save shape with missing ${missingSide} commission recovers without durable guard or gap`, t => {
    const f = captureFixture(t), rows = f.addPair(action, '16');
    f.addPair('later-same-book', '18');
    // Both executor action branches save their new executions before the next
    // recon merges commission reports. Exercise that state at capture's input.
    const missingId = rows[missingSide === 'opening' ? 0 : 1].execution.execId;
    const report = f.state.commissions.find(row => row.execId === missingId);
    f.state.commissions = f.state.commissions.filter(row => row.execId !== missingId);
    const first = f.refresh();
    assert.equal(coverage(first, '16'), 'partial');
    assert.ok(first.days.find(day => day.date === '2026-10-16').partialReasons.includes('broker_evidence_missing'));
    assert.equal(coverage(first, '18'), 'full'); // no scoped gap into later days
    assert.equal(first.trades.length, 1);
    assert.equal(f.producer.health(health).portionExclusions, 0);
    const records = () => readJournal(f.filename).filter(row => row.type === 'conversion-exclusion').map(row => row.record);
    assert.deepEqual(records(), [{ day: '2026-10-16', deskHash: hash('j'), kind: 'broker_evidence_missing' }]);
    assert.deepEqual(readJournal(f.input).at(-1).historyCoverage.gaps, []);
    assert.deepEqual(f.replay().days, first.days);
    assert.equal(f.producer.health(health).portionExclusions, 0);
    f.state.commissions.push(report);
    const corrected = f.refresh();
    assert.equal(coverage(corrected, '16'), 'full');
    assert.equal(coverage(corrected, '18'), 'full');
    assert.equal(corrected.trades.length, 2);
    assert.equal(f.producer.health(health).portionExclusions, 0);
    assert.equal(records().length, 1); // historical diagnostic only, never a guard
    assert.deepEqual(f.replay().days, corrected.days);
    assert.equal(validateResults(corrected).ok, true);
  });
}

for (const defect of ['third-currency fee', 'invalid rate']) test(`${defect} remains durable across correction and replay`, t => {
  const fills = [...pair('durable', '16'), ...pair('later', '18')];
  if (defect === 'third-currency fee') fills[1].commission.currency = 'GBP';
  else fills[1].closeFx.rate = '0';
  const f = setup(t, fills), first = f.producer.snapshot();
  assert.equal(coverage(first, '16'), 'partial'); assert.equal(coverage(first, '18'), 'partial');
  assert.equal(first.trades.length, 1); assert.equal(f.producer.health(health).portionExclusions, 1);
  const records = readJournal(f.filename).filter(row => row.type === 'conversion-exclusion').map(row => row.record);
  assert.equal(records[0].kind, 'source_not_authoritative'); assert.ok(records[0].portionHash); assert.ok(records[0].at);
  f.rows.push({ ...f.rows[1], fills: [{ ...fills[1], commission: { amount: '0', currency: 'EUR' }, closeFx: { ...fills[1].closeFx, rate: '1' } }] });
  f.producer.ingest(f.rows);
  const corrected = f.producer.snapshot();
  assert.equal(corrected.trades.length, 2);
  assert.equal(coverage(corrected, '16'), 'partial'); assert.equal(coverage(corrected, '18'), 'partial');
  assert.equal(f.producer.health(health).portionExclusions, 1);
  assert.deepEqual(f.replay().days, corrected.days);
});

const defects = [
  ['symbol', row => { row.contract.symbol = 'ACME A'; }],
  ['price', row => { row.execution.price = '0'; }],
  ['quantity', row => { row.execution.shares = '-1'; }],
  ['side', row => { row.execution.side = 'UNKNOWN'; }],
  ['at', row => { row.execution.time = 'invalid-instant'; }],
];
for (const [field, mutate] of defects) test(`admin capture refuses invalid ${field} with issue, tombstone and 1 ms gap; other Results continue`, t => {
  const f = captureFixture(t), bad = f.raw('bad', '17', 'BUY');
  f.addPair('good-before', '16', 'joe'); f.addPair('good-shared-day', '17', 'joe');
  f.state.executions.push(bad); mutate(bad);
  const affectedDay = field === 'at' ? '20' : '17';
  const result = f.refresh();
  assert.equal(coverage(result, affectedDay), 'partial'); assert.equal(coverage(result, '16'), 'full');
  assert.equal(result.trades.length, 2);
  assert.equal(result.days.find(day => day.date === '2026-10-17').desks.joe.trades, 1);
  assert.equal(result.days.find(day => day.date === '2026-10-17').desks.joe.realisedNet.amount, '0');
  assert.ok(result.days.find(day => day.date === `2026-10-${affectedDay}`).partialReasons.includes('capture_gap'));
  const cut = readJournal(f.input).at(-1), issue = cut.captureIssues[0];
  assert.deepEqual(Object.keys(issue).sort(), ['id', 'day', 'deskHash', 'kind', 'field', 'refused'].sort());
  assert.equal(issue.field, field); assert.equal(issue.refused, true); assert.equal(issue.kind, 'capture_gap');
  assert.equal(issue.deskHash, hash('j')); assert.equal(issue.day, `2026-10-${affectedDay}`);
  assert.ok(cut.fills.some(fill => fill.scope === 'excluded' && fill.desk === null));
  assert.equal(cut.fillGaps.length, 1);
  assert.equal(Date.parse(cut.fillGaps[0].toExclusive) - Date.parse(cut.fillGaps[0].fromInclusive), 1);
  assert.equal(f.producer.health(health).captureRefusals, 1);
  assert.equal(f.producer.health(health).portionExclusions, 0);
  assert.deepEqual(f.replay().days, result.days);
  f.capture(f.state); // same refused fill neither grows the journal nor loses its gap
  assert.equal(readJournal(f.input).length, 3);
  if (field === 'at') {
    f.setCaptureTime('2026-10-21T22:00:00.000Z');
    f.capture(f.state); f.restartCapture(); f.capture(f.state);
    assert.equal(readJournal(f.input).length, 3); // invalid instants keep their first refusal anchor across polls/restart
  }
  assert.equal(validateResults(result).ok, true);
});

for (const [field, value] of [['symbol', 'ACME A'], ['side', 'UNKNOWN'], ['at', 'invalid'], ['quantity', 'bad'], ['price', '0']]) {
  test(`old-journal invalid ${field} is contained per fill and downstream projections keep producing`, t => {
    const bad = { ...fill('bad-old', 'BUY', instant('17', '10')), [field]: value };
    const fills = [bad, ...pair('good', '18', { desk: 'joe' })], excluded = [];
    assert.equal(roundTrips(fills, begin, [], () => {}, record => excluded.push(record)).length, 1);
    assert.equal(excluded.length, 1); assert.equal(excluded[0].kind, 'source_not_authoritative');
    const f = setup(t, fills), result = f.producer.snapshot();
    assert.equal(result.trades.length, 1); assert.equal(coverage(result, '18'), 'full');
    assert.equal(result.days.find(day => day.date === excluded[0].day).coverage, 'partial');
    assert.equal(f.producer.health(health).portionExclusions, 1);
    assert.deepEqual(f.replay().days, result.days);
    assert.equal(validateResults(result).ok, true);
  });
}

test('runner health counts portion exclusions from the snapshot sent in that same tick', async t => {
  const f = setup(t, guardedSevenShareFills()), sent = [];
  const runner = createRunner({ producer: f.producer, readSource: () => f.rows, readHealth: () => health,
    now: () => Date.parse(end), transport: { send: result => sent.push(result) } });
  assert.equal(await runner.tick(), true);
  assert.equal(sent.length, 1); assert.equal(f.producer.latestHealth.portionExclusions, 3);
  const rows = readJournal(f.filename);
  assert.ok(rows.findIndex(row => row.type === 'health') > rows.findLastIndex(row => row.type === 'conversion-exclusion'));
});
