import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createCapture } from './capture.mjs';
import { readJournal } from './journal.mjs';
import { openProducer } from './producer.mjs';
import { validateResults, historyIntervals } from './results-validation.mjs';
import { IngressError, failureDiagnostic } from './transport.mjs';
import { activityAttribution } from '../paper-desk-executor/policy.mjs';
import { capturePositionProof, earlierGapDays, PositionProofIndex } from './position-proof.mjs';
import { hash } from './journal.mjs';

const floor = ['SXR8', 'TSLA'];
const instant = epoch => new Date(epoch).toISOString();

const activitySource = (entries, at) => [entries[0], { type: 'fill', fill: {
  key: 'synthetic-activity', ordinal: 1, desk: 'j', scope: 'stage0', instrument: 'synthetic-activity',
  symbol: 'ACME', currency: 'EUR', side: 'BUY', at, quantity: '1', price: '10',
  commission: { amount: '0', currency: 'EUR' }, brokerRealised: { unset: true, currency: 'EUR' },
} }, ...entries.slice(1)];

test('position proof uses the complete broker snapshot, exact quantities and no raw identifiers', () => {
  const at = '2026-10-16T12:00:00.000Z', account = 'synthetic-account';
  const c = { conId: 1, symbol: 'ACME', currency: 'EUR' }, instrument = hash([1, 'ACME', 'EUR']);
  const snapshot = { account, observedAt: at, ownershipComplete: true, positions: [{ ...c, position: 1 }] };
  const state = { ownershipComplete: true, ownershipSnapshot: snapshot, executions: [] };
  const options = { account, attribute: () => ({ desk: 'j' }) };
  const proof = () => capturePositionProof(state, { executorClientId: 705 }, floor, options, [instrument], at);
  assert.deepEqual(proof(), { at, foreign: [], positions: [{ instrument, quantity: '1', src: 'sdk_number_roundtrip' }] });
  assert.deepEqual(capturePositionProof(state, { executorClientId: 705 }, floor, options, [], at), proof());
  snapshot.positions[0].position = '0.12345678';
  assert.equal(proof().positions[0].quantity, '0.12345678');
  for (const invalid of [1e-7, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, null, 'bad']) {
    snapshot.positions[0].position = invalid;
    assert.equal(proof(), null);
  }
  snapshot.positions[0].position = 1;
  for (const changed of [{ observedAt: null }, { observedAt: '2026-10-16T13:00:00.000Z' },
    { ownershipComplete: false }, { account: 'synthetic-other' }, { positions: [{ ...c, position: '1' }, { ...c, position: '1' }] },
    { positions: [{ conId: 1, position: '1' }] }]) {
    state.ownershipSnapshot = { ...snapshot, ...changed };
    assert.equal(proof(), null);
  }
  state.ownershipSnapshot = snapshot;
  state.executions = [{ contract: c, execution: { acctNumber: account, clientId: 999 } }];
  assert.deepEqual(proof().foreign, [instrument]); // foreign/netted instruments supply no proof
});

test('earlier-gap proof is per instrument and every fill; corrections and conflicting receipts fail closed', () => {
  const start = '2026-10-14T22:00:00.000Z', begin = '2026-10-15T09:00:00.000Z';
  const at = '2026-10-15T10:00:00.000Z', closeAt = '2026-10-16T12:00:00.000Z';
  const intervals = [[Date.parse(begin), Date.parse('2026-10-17T22:00:00.000Z')]];
  const fill = (instrument, at, side, quantity = '1', desk = 'j') => ({ instrument, at, side, quantity, desk, scope: 'stage0' });
  const held = fill('synthetic-a', '2026-10-15T06:00:00.000Z', 'BUY');
  const close = { instrument: 'synthetic-a', at: closeAt };
  const proof = (quantity, time = at) => ({ at: time, positions: [{ instrument: 'synthetic-a', quantity }] });
  const partial = (fills, proofs, executions = [close], origin = start) => {
    const index = new PositionProofIndex();
    proofs.forEach(proof => index.add(proof));
    return [...earlierGapDays(fills, executions, intervals, index, origin)];
  };
  assert.deepEqual(partial([held], [proof('1')]), []);
  assert.deepEqual(partial([{ ...held, quantity: '2' }], [proof('1')]), ['2026-10-16']);
  assert.deepEqual(partial([held], [proof('1'), proof('2')]), ['2026-10-16']);
  assert.deepEqual(partial([held], [proof('1'), proof('2', '2026-10-15T11:00:00.000Z')]), ['2026-10-16']);
  assert.deepEqual(partial([held], [{ at, positions: [] }]), ['2026-10-16']);
  assert.deepEqual(partial([held], [proof('1')], [close, { instrument: 'synthetic-b', at: closeAt }]), ['2026-10-16']);
  assert.deepEqual(partial([held], [], [close], '2026-10-16T00:00:00.000Z'), ['2026-10-16']);
  assert.deepEqual(partial([{ ...held, side: 'SELL' }], [proof('-1')]), []);
  assert.deepEqual(partial([held, { ...held, side: 'SELL', desk: 'joe' }], [proof('0')]), ['2026-10-16']);
  // A position held across the gap is really flat after a captured close and
  // a matching broker-flat snapshot. New later closes may then be full.
  const flattened = [held, fill('synthetic-a', '2026-10-15T09:30:00.000Z', 'SELL')];
  assert.deepEqual(partial(flattened, [proof('0')]), []);
  assert.deepEqual(partial(flattened, [proof('0')], [{ instrument: 'synthetic-a', at: '2026-10-15T09:30:00.000Z' }, close]), ['2026-10-15']);
  // The nonzero start quantity is rolled back through a post-gap add.
  assert.deepEqual(partial([held, fill('synthetic-a', '2026-10-15T09:30:00.000Z', 'BUY')], [proof('2')]), []);
  // Complete receipts distinguish a genuinely new/flat instrument from an
  // omitted foreign one. Legacy omissions remain unproven.
  const opening = fill('synthetic-new', closeAt, 'BUY');
  const complete = { at, positions: [], foreign: [] };
  assert.deepEqual(partial([opening], [complete], [opening]), []);
  assert.deepEqual(partial([opening], [{ at, positions: [] }], [opening]), ['2026-10-16']);
  assert.deepEqual(partial([opening], [{ ...complete, foreign: ['synthetic-new'] }], [opening]), ['2026-10-16']);
  assert.deepEqual(partial([held], [complete]), ['2026-10-16']);
  assert.deepEqual(partial([held], [{ ...proof('1'), foreign: ['synthetic-a'] }]), ['2026-10-16']);
  assert.deepEqual(partial([held], [{ at, positions: [...proof('1').positions, ...proof('1').positions] }]), ['2026-10-16']);
  assert.deepEqual(partial([held], [proof('bad')]), ['2026-10-16']);
  // Out-of-order receipts are indexed chronologically. A later complete
  // omission or foreign marker must supersede an earlier explicit match.
  const later = { ...complete, at: '2026-10-15T11:00:00.000Z' };
  assert.deepEqual(partial([held], [later, proof('1')]), ['2026-10-16']);
  assert.deepEqual(partial([held], [proof('2', at), proof('1', begin)]), ['2026-10-16']);
  assert.deepEqual(partial([held], [proof('1'), { ...complete, foreign: ['synthetic-a'] }]), ['2026-10-16']);
});

for (const [name, openingAt, proofAt, quantity, gapAfter, expected] of [
  ['flat after the earlier gap', '2026-10-16T10:00:00.000Z', '2026-10-15T10:00:00.000Z', '0', false, 'full'],
  ['held across the earlier gap without reconciliation', '2026-10-15T06:00:00.000Z', null, null, false, 'partial'],
  ['matching reconciliation at interval start', '2026-10-15T06:00:00.000Z', '2026-10-15T09:00:00.000Z', '1', false, 'full'],
  ['matching reconciliation rolled back within proven interval', '2026-10-15T06:00:00.000Z', '2026-10-15T10:00:00.000Z', '1', false, 'full'],
  ['gap after the closed day', '2026-10-15T06:00:00.000Z', null, null, true, 'full'],
  ['mismatched reconciliation', '2026-10-15T06:00:00.000Z', '2026-10-15T09:00:00.000Z', '2', false, 'partial'],
  ['flat only after the close', '2026-10-15T06:00:00.000Z', '2026-10-16T13:00:00.000Z', '0', false, 'partial'],
  ['reconciliation before the last gap', '2026-10-15T06:00:00.000Z', '2026-10-15T07:00:00.000Z', '1', false, 'partial'],
  ['snapshot simultaneous with a fill is ambiguous', '2026-10-15T09:00:00.000Z', '2026-10-15T09:00:00.000Z', '1', false, 'partial'],
]) test(`earlier-gap rule: ${name}, capture and producer replay`, () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'joed20-earlier-gap-'));
  const input = path.join(dir, 'capture.jsonl'), output = path.join(dir, 'results.jsonl');
  const start = '2026-10-14T22:00:00.000Z', at = '2026-10-17T22:00:00.000Z';
  const closedAt = '2026-10-16T12:00:00.000Z', account = 'synthetic-account';
  const config = { executorClientId: 705, ownClientIds: [705], foreignAlertSince: start };
  const raw = (key, time, side, price) => ({ contract: { conId: 1, symbol: 'ACME', currency: 'EUR' },
    execution: { execId: `${key}.01`, acctNumber: account, clientId: 705, orderRef: 'j|261015|synthetic', time, side, shares: '1', price } });
  const executions = [raw('synthetic-open', openingAt, 'BOT', '10'), raw('synthetic-close', closedAt, 'SLD', '12')];
  const state = { ownershipComplete: true, executions,
    commissions: executions.map(row => ({ execId: row.execution.execId, commission: '0', currency: 'EUR', realizedPNL: row.execution.side === 'SLD' ? '2' : Number.MAX_VALUE })),
    resultsHistoryCoverage: { status: 'known', target: { fromInclusive: start, toExclusive: at }, gaps: [{
      fromInclusive: gapAfter ? '2026-10-17T08:00:00.000Z' : '2026-10-15T08:00:00.000Z',
      toExclusive: gapAfter ? '2026-10-17T09:00:00.000Z' : '2026-10-15T09:00:00.000Z',
    }] },
    ownershipSnapshot: { account, ownershipComplete: true, observedAt: proofAt,
      positions: quantity === null || quantity === '0' ? [] : [{ conId: 1, symbol: 'ACME', currency: 'EUR', position: quantity }] } };
  let now = start;
  const options = { account, attribute: activityAttribution, executionTime: Date.parse, now: () => now };
  let capture = createCapture(input, config, options);
  capture({ ownershipComplete: true, executions: [] });
  now = at; capture(state); capture.close();
  // Neither an executor restart nor a newer unrelated activity timestamp may
  // restamp a stale snapshot or manufacture a fresh quantity reconciliation.
  capture = createCapture(input, config, options);
  capture({ ...state, concurrentObservedAt: at }); capture.close();
  assert.equal(readJournal(input).length, 3);
  const serialized = JSON.stringify(readJournal(input));
  assert.equal(serialized.includes(account), false);
  assert.equal(serialized.includes('conId'), false);
  let producer = openProducer(output, { now: () => at });
  producer.ingest(readJournal(input));
  const payload = producer.snapshot();
  assert.equal(payload.trades.length, 1);
  assert.equal(payload.days.find(day => day.date === '2026-10-16').coverage ?? 'full', expected);
  assert.equal(validateResults(payload).ok, true);
  producer.close();
  producer = openProducer(output, { now: () => at });
  producer.ingest(readJournal(input));
  assert.deepEqual(producer.snapshot().days, payload.days);
  producer.close();
});

for (const [day, begin, end, hours] of [
  ['2026-10-16', '2026-10-15T22:00:00.000Z', '2026-10-16T22:00:00.000Z', 24],
  ['2026-03-29', '2026-03-28T23:00:00.000Z', '2026-03-29T22:00:00.000Z', 23],
  ['2026-10-25', '2026-10-24T22:00:00.000Z', '2026-10-25T23:00:00.000Z', 25],
]) test(`capture gaps and exact half-open boundaries on ${hours}-hour Vienna day`, () => {
  const a = Date.parse(begin), b = Date.parse(end), at = instant(b + 3600_000);
  assert.equal(b - a, hours * 3600_000);
  const from = instant(a - 86400_000);
  const gap = (x, y) => ({ fromInclusive: instant(x), toExclusive: instant(y) });
  const complete = { status: 'complete', target: { fromInclusive: from, toExclusive: at }, gaps: [] };
  const cases = [
    [complete, 'full'],
    [{ ...complete, status: 'known', gaps: [gap(a + 3600_000, a + 7200_000)] }, 'partial'],
    [{ ...complete, status: 'known', gaps: [gap(a - 3600_000, a)] }, 'full'],
    [{ ...complete, status: 'known', gaps: [gap(a - 1, a + 1)] }, 'partial'],
    [{ ...complete, status: 'known', gaps: [gap(b - 1, b + 1)] }, 'partial'],
    [{ ...complete, status: 'known', gaps: [gap(b, b + 1)] }, 'full'],
    [null, 'partial'],
    [{ ...complete, status: 'unknown' }, 'partial'],
    [{ ...complete, target: { fromInclusive: from } }, 'partial'],
    [{ ...complete, target: { fromInclusive: from, toExclusive: instant(b - 1) } }, 'partial'],
    [{ ...complete, target: { fromInclusive: from, toExclusive: instant(b + 7200_000) } }, 'partial'],
    [{ ...complete, status: 'known', gaps: [{ fromInclusive: begin }] }, 'partial'],
  ];
  for (const [historyCoverage, expected] of cases) {
    const dir = mkdtempSync(path.join(tmpdir(), 'joed20-coverage-'));
    const filename = path.join(dir, 'results.jsonl');
    let producer = openProducer(filename, { now: () => at });
    const rows = [{ type: 'start', at: begin }, { type: 'cut', at, authoritative: true, disagreement: false, fills: [], historyCoverage, positionProof: { at: instant(a + 12 * 3600_000 - 1),
      positions: [{ instrument: 'synthetic-activity', quantity: '0' }], foreign: [] } }];
    const captured = activitySource(rows, instant(a + 12 * 3600_000));
    producer.ingest(captured);
    const payload = producer.snapshot();
    assert.equal(payload.days[0].date, day);
    assert.equal(payload.days[0].coverage ?? 'full', expected);
    assert.equal(validateResults(payload).ok, true);
    if (expected === 'full') {
      const bad = structuredClone(payload); bad.days[0].desks.j.trades = 1;
      assert.ok(validateResults(bad).errors.some(error => error.rule === 'dayTradeCount'));
    }
    producer.close();
    producer = openProducer(filename, { now: () => at });
    producer.ingest(captured);
    assert.deepEqual(producer.snapshot().days, payload.days);
    producer.close();
  }
});

test('coverage-only cuts bridge adjacent proof intervals across capture and producer restart', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'joed20-cuts-'));
  const filename = path.join(dir, 'capture.jsonl'), output = path.join(dir, 'results.jsonl');
  const begin = '2026-10-15T22:00:00.000Z', middle = '2026-10-16T10:00:00.000Z', end = '2026-10-16T22:00:00.000Z';
  let now = begin;
  const options = { account: 'synthetic-account', attribute: () => ({}), executionTime: Date.parse, now: () => now, keepSymbols: floor };
  const state = { ownershipComplete: true, executions: [], resultsHistoryCoverage: null };
  let capture = createCapture(filename, {}, options);
  capture(state);
  now = middle;
  state.resultsHistoryCoverage = { status: 'complete', target: { fromInclusive: begin, toExclusive: middle }, gaps: [] };
  capture(state); capture(state); // identical proof must not add another cut
  assert.equal(readJournal(filename).length, 3);
  let producer = openProducer(output, { now: () => end });
  producer.ingest(activitySource(readJournal(filename), middle));
  assert.equal(producer.snapshot().days.find(day => day.date === '2026-10-16').coverage, 'partial');
  producer.close(); capture.close();
  now = end;
  capture = createCapture(filename, {}, options);
  state.resultsHistoryCoverage = { status: 'known', target: { fromInclusive: middle, toExclusive: end },
    gaps: [{ fromInclusive: middle, toExclusive: instant(Date.parse(middle) + 1) }] };
  capture(state); capture.close();
  assert.equal(readJournal(filename).length, 4);
  producer = openProducer(output, { now: () => end });
  producer.ingest(activitySource(readJournal(filename), middle));
  assert.equal(producer.snapshot().days.find(day => day.date === '2026-10-16').coverage, 'partial'); // 1 ms between cuts is still a gap
  capture = createCapture(filename, {}, options);
  state.resultsHistoryCoverage.status = 'complete'; state.resultsHistoryCoverage.gaps = [];
  capture(state); capture.close();
  producer.ingest(activitySource(readJournal(filename), middle));
  assert.equal(producer.snapshot().days.find(day => day.date === '2026-10-16').coverage ?? 'full', 'full');
  producer.close();
});

test('unattributed own executor fills make proven closed days partial until admin attribution, including replay', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'joed20-attribution-gap-'));
  const filename = path.join(dir, 'capture.jsonl'), output = path.join(dir, 'results.jsonl');
  const begin = '2026-10-15T22:00:00.000Z', end = '2026-10-16T22:00:00.000Z', at = '2026-10-17T12:00:00.000Z';
  const fillAt = '2026-10-16T12:00:00.000Z', account = 'synthetic-account';
  let now = begin;
  const config = { executorClientId: 705, ownClientIds: [705], foreignAlertSince: begin };
  const options = { account, attribute: activityAttribution, executionTime: Date.parse, now: () => now };
  const raw = (key, time = fillAt, overrides = {}, symbol = 'ACME') => ({
    contract: { conId: 1, symbol, currency: 'EUR' }, execution: { execId: `${key}.01`, acctNumber: account,
      clientId: 705, orderRef: '', time, side: 'BOT', shares: '1', price: '10', ...overrides },
  });
  const opening = raw('synthetic-opening', instant(Date.parse(fillAt) - 60_000), { orderRef: 'j|261016|synthetic' });
  const unknown = raw('synthetic-unknown', fillAt, { side: 'SLD', price: '12' });
  const state = { executions: [opening], ownershipComplete: true,
    commissions: [opening, unknown].map(row => ({ execId: row.execution.execId, commission: '0', currency: 'EUR', realizedPNL: row.execution.side === 'SLD' ? '2' : Number.MAX_VALUE })),
    resultsHistoryCoverage: { status: 'complete', target: { fromInclusive: begin, toExclusive: end }, gaps: [] } };
  let capture = createCapture(filename, config, options);
  capture({ ownershipComplete: true, executions: [] });
  now = at; capture(state);
  let producer = openProducer(output, { now: () => at });
  producer.ingest(readJournal(filename));
  assert.equal(producer.snapshot().days.find(day => day.date === '2026-10-16').coverage ?? 'full', 'full');
  state.executions = [opening, unknown,
    raw('synthetic-foreign-account', fillAt, { acctNumber: 'synthetic-other' }),
    raw('synthetic-keep', fillAt, {}, 'TSLA'), raw('synthetic-keep-other', fillAt, {}, 'SXR8'),
    raw('synthetic-before', instant(Date.parse(begin) - 1)), raw('synthetic-after-target', end),
  ];
  capture(state);
  const coverage = readJournal(filename).at(-1).historyCoverage;
  assert.equal(coverage.status, 'known');
  assert.deepEqual(coverage.gaps, [{ fromInclusive: fillAt, toExclusive: instant(Date.parse(fillAt) + 1) }]);
  assert.deepEqual(readJournal(filename).at(-1).historyGaps, []);
  assert.deepEqual(readJournal(filename).at(-1).fillGaps, [{ fromInclusive: fillAt, toExclusive: instant(Date.parse(fillAt) + 1), kind: 'unattributed_activity' }]);
  producer.ingest(readJournal(filename));
  assert.equal(producer.snapshot().days.find(day => day.date === '2026-10-16').coverage, 'partial');
  producer.close(); capture.close();
  producer = openProducer(output, { now: () => at });
  assert.equal(producer.snapshot().days.find(day => day.date === '2026-10-16').coverage, 'partial');
  capture = createCapture(filename, config, options);
  unknown.attribution = { method: 'admin', desk: 'j' };
  capture(state); capture.close();
  assert.deepEqual(readJournal(filename).at(-1).historyCoverage.gaps, []);
  producer.ingest(readJournal(filename));
  const attributed = producer.snapshot();
  assert.equal(attributed.days[0].coverage ?? 'full', 'full');
  assert.equal(attributed.trades.length, 1);
  assert.equal(attributed.days[0].desks.j.realisedNet.amount, '2');
  producer.close();
  producer = openProducer(output, { now: () => at });
  assert.equal(producer.snapshot().days.find(day => day.date === '2026-10-16').coverage ?? 'full', 'full');
  producer.close();
});

test('unattributed D0 opening and attributed D2 stop stay partial until admin attribution, across replay', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'joed20-missed-opening-'));
  const filename = path.join(dir, 'capture.jsonl'), output = path.join(dir, 'results.jsonl');
  const begin = '2026-10-13T22:00:00.000Z', at = '2026-10-16T22:00:00.000Z';
  const openingAt = '2026-10-14T12:00:00.000Z', stopAt = '2026-10-16T12:00:00.000Z';
  const account = 'synthetic-account', instrument = hash([1, 'ACME', 'EUR']);
  let now = begin;
  const config = { executorClientId: 705, ownClientIds: [705], foreignAlertSince: begin };
  const options = { account, attribute: activityAttribution, executionTime: Date.parse, now: () => now };
  const raw = (key, time, side, price, orderRef) => ({ contract: { conId: 1, symbol: 'ACME', currency: 'EUR' },
    execution: { execId: `${key}.01`, acctNumber: account, clientId: 705, time, side, price, shares: '1', orderRef } });
  const opening = raw('synthetic-missed-opening', openingAt, 'BOT', '10', '');
  const stop = raw('synthetic-attributed-stop', stopAt, 'SLD', '12', 'j|261016|synthetic');
  const state = { ownershipComplete: true, executions: [opening, stop],
    commissions: [opening, stop].map(row => ({ execId: row.execution.execId, commission: '0', currency: 'EUR', realizedPNL: row.execution.side === 'SLD' ? '2' : Number.MAX_VALUE })),
    ownershipSnapshot: { account, ownershipComplete: true, observedAt: '2026-10-16T13:00:00.000Z', positions: [] },
    resultsHistoryCoverage: { status: 'complete', target: { fromInclusive: begin, toExclusive: at }, gaps: [] } };
  let capture = createCapture(filename, config, options);
  capture({ ownershipComplete: true, executions: [] });
  now = at; capture(state); capture.close();
  assert.deepEqual(readJournal(filename).at(-1).positionProof.foreign, [instrument]);
  let producer = openProducer(output, { now: () => at });
  producer.ingest(readJournal(filename));
  const partial = producer.snapshot();
  assert.deepEqual(partial.days.map(day => [day.date, day.coverage]), [['2026-10-14', 'partial'], ['2026-10-16', 'partial']]);
  assert.equal(partial.trades.length, 0);
  assert.equal(validateResults(partial).ok, true);
  producer.close();
  producer = openProducer(output, { now: () => at });
  assert.deepEqual(producer.snapshot().days, partial.days);
  capture = createCapture(filename, config, options);
  opening.attribution = { method: 'admin', desk: 'j' };
  capture(state); capture.close();
  assert.deepEqual(readJournal(filename).at(-1).positionProof.foreign, []);
  producer.ingest(readJournal(filename));
  const attributed = producer.snapshot();
  assert.ok(attributed.days.every(day => (day.coverage ?? 'full') === 'full'));
  assert.equal(attributed.trades.length, 1);
  assert.equal(attributed.days[1].desks.j.trades, 1);
  assert.equal(attributed.days[1].desks.j.realisedNet.amount, '2');
  assert.equal(validateResults(attributed).ok, true);
  producer.close();
  producer = openProducer(output, { now: () => at });
  producer.ingest(readJournal(filename));
  assert.deepEqual(producer.snapshot().days, attributed.days);
  producer.close();
});

for (const [begin, end] of [
  ['2026-10-15T22:00:00.000Z', '2026-10-16T22:00:00.000Z'],
  ['2026-03-28T23:00:00.000Z', '2026-03-29T22:00:00.000Z'],
  ['2026-10-24T22:00:00.000Z', '2026-10-25T23:00:00.000Z'],
]) test(`coverage-only capture and producer journals grow once per closed Vienna day from ${begin}`, () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'joed20-cut-growth-'));
  const filename = path.join(dir, 'capture.jsonl'), output = path.join(dir, 'results.jsonl');
  let now = begin;
  const options = { account: 'synthetic-account', attribute: () => ({}), executionTime: Date.parse, now: () => now };
  let capture = createCapture(filename, {}, options);
  const state = { ownershipComplete: true, executions: [], resultsHistoryCoverage: null };
  capture(state);
  // First valid proof records the transition from unknown to an empty gap set.
  now = instant(Date.parse(begin) + 1);
  state.resultsHistoryCoverage = { status: 'complete', target: { fromInclusive: begin, toExclusive: now }, gaps: [] };
  capture(state);
  const producer = openProducer(output, { now: () => end });
  for (let i = 1; i < 250; i++) {
    if (i === 125) { capture.close(); capture = createCapture(filename, {}, options); }
    now = instant(Date.parse(begin) + Math.floor((Date.parse(end) - Date.parse(begin)) * i / 250));
    state.resultsHistoryCoverage.target.toExclusive = now;
    capture(state); producer.ingest(activitySource(readJournal(filename), instant(Date.parse(begin) + 12 * 3600_000)));
  }
  assert.equal(readJournal(filename).length, 3);
  assert.equal(producer.sourceCount, 4);
  now = end; state.resultsHistoryCoverage.target.toExclusive = now; capture(state);
  producer.ingest(activitySource(readJournal(filename), instant(Date.parse(begin) + 12 * 3600_000)));
  assert.equal(readJournal(filename).length, 4);
  // Explicit gap changes still record immediately without new fills or days.
  state.resultsHistoryCoverage.status = 'known';
  state.resultsHistoryCoverage.gaps = [{ fromInclusive: instant(Date.parse(begin) + 3600_000), toExclusive: instant(Date.parse(begin) + 3600_001) }];
  capture(state); producer.ingest(activitySource(readJournal(filename), instant(Date.parse(begin) + 12 * 3600_000)));
  assert.equal(readJournal(filename).length, 5);
  state.resultsHistoryCoverage.status = 'complete'; state.resultsHistoryCoverage.gaps = [];
  capture(state); producer.ingest(activitySource(readJournal(filename), instant(Date.parse(begin) + 12 * 3600_000)));
  assert.equal(readJournal(filename).length, 6);
  // Even proof with no remaining interval must revoke previously full days.
  state.resultsHistoryCoverage.status = 'known';
  state.resultsHistoryCoverage.gaps = [{ fromInclusive: begin, toExclusive: end }];
  capture(state); producer.ingest(activitySource(readJournal(filename), instant(Date.parse(begin) + 12 * 3600_000)));
  assert.equal(readJournal(filename).length, 7);
  assert.equal(producer.snapshot().days[0].coverage, 'partial');
  capture(state); capture.close(); producer.close();
  const replay = openProducer(output, { now: () => end });
  replay.ingest(activitySource(readJournal(filename), instant(Date.parse(begin) + 12 * 3600_000)));
  assert.equal(replay.sourceCount, 8);
  assert.equal(replay.snapshot().days[0].coverage, 'partial');
  replay.close();
});

test('legacy cuts without bounds stay partial and malformed proof fails closed', () => {
  assert.deepEqual(historyIntervals({ status: 'complete', target: { fromInclusive: 'bad', toExclusive: 'bad' }, gaps: [] }, '2026-10-17T00:00:00.000Z'), []);
  const dir = mkdtempSync(path.join(tmpdir(), 'joed20-legacy-'));
  const producer = openProducer(path.join(dir, 'results.jsonl'), { now: () => '2026-10-17T12:00:00.000Z' });
  producer.ingest(activitySource([{ type: 'start', at: '2026-10-15T22:00:00.000Z' }, { type: 'authority', at: '2026-10-17T12:00:00.000Z', authoritative: true }], '2026-10-16T12:00:00.000Z'));
  assert.equal(producer.snapshot().days.find(day => day.date === '2026-10-16').coverage, 'partial');
  producer.close();
});

test('positiveFxRate diagnostics accept vendored numeric paths while discarding values', () => {
  const errors = [
    { path: '$.trades.0.fx', rule: 'positiveFxRate', value: 'untrusted' },
    { path: '$.trades[12].fx.rate', rule: 'positiveFxRate', message: 'untrusted' },
    { path: '$.trades.secret.fx', rule: 'positiveFxRate' },
    { path: '$.trades.0.fx', rule: 'untrusted' },
  ];
  assert.deepEqual(failureDiagnostic(new IngressError(422, 'contract_invalid', errors)).errors,
    errors.slice(0, 2).map(({ path, rule }) => ({ path, rule })));
});
