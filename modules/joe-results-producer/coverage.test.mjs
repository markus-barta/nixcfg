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

const floor = ['SXR8', 'TSLA'];
const instant = epoch => new Date(epoch).toISOString();

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
    const rows = [{ type: 'start', at: begin }, { type: 'cut', at, authoritative: true, disagreement: false, fills: [], historyCoverage }];
    producer.ingest(rows);
    producer.observe({ at: instant(a + 12 * 3600_000), desks: { j: { equity: { amount: '5000', currency: 'EUR' }, basisId: 'synthetic-coverage' } } });
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
    producer.ingest(rows);
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
  producer.ingest(readJournal(filename));
  producer.observe({ at: middle, desks: { j: { equity: { amount: '5000', currency: 'EUR' }, basisId: 'synthetic' } } });
  assert.equal(producer.snapshot().days[0].coverage, 'partial');
  producer.close(); capture.close();
  now = end;
  capture = createCapture(filename, {}, options);
  state.resultsHistoryCoverage = { status: 'known', target: { fromInclusive: middle, toExclusive: end },
    gaps: [{ fromInclusive: middle, toExclusive: instant(Date.parse(middle) + 1) }] };
  capture(state); capture.close();
  assert.equal(readJournal(filename).length, 4);
  producer = openProducer(output, { now: () => end });
  producer.ingest(readJournal(filename));
  assert.equal(producer.snapshot().days[0].coverage, 'partial'); // 1 ms between cuts is still a gap
  capture = createCapture(filename, {}, options);
  state.resultsHistoryCoverage.status = 'complete'; state.resultsHistoryCoverage.gaps = [];
  capture(state); capture.close();
  producer.ingest(readJournal(filename));
  assert.equal(producer.snapshot().days[0].coverage ?? 'full', 'full');
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
    commissions: [opening, unknown].map(row => ({ execId: row.execution.execId, commission: '0', currency: 'EUR' })),
    resultsHistoryCoverage: { status: 'complete', target: { fromInclusive: begin, toExclusive: end }, gaps: [] } };
  let capture = createCapture(filename, config, options);
  capture({ ownershipComplete: true, executions: [] });
  now = at; capture(state);
  let producer = openProducer(output, { now: () => at });
  producer.ingest(readJournal(filename));
  producer.observe({ at: fillAt, desks: { j: { equity: { amount: '5000', currency: 'EUR' }, basisId: 'synthetic' } } });
  assert.equal(producer.snapshot().days[0].coverage ?? 'full', 'full');
  state.executions = [opening, unknown,
    raw('synthetic-foreign-account', fillAt, { acctNumber: 'synthetic-other' }),
    raw('synthetic-keep', fillAt, {}, 'TSLA'), raw('synthetic-keep-other', fillAt, {}, 'SXR8'),
    raw('synthetic-before', instant(Date.parse(begin) - 1)), raw('synthetic-after-target', end),
  ];
  capture(state);
  const coverage = readJournal(filename).at(-1).historyCoverage;
  assert.equal(coverage.status, 'known');
  assert.deepEqual(coverage.gaps, [{ fromInclusive: fillAt, toExclusive: instant(Date.parse(fillAt) + 1) }]);
  producer.ingest(readJournal(filename));
  assert.equal(producer.snapshot().days[0].coverage, 'partial');
  producer.close(); capture.close();
  producer = openProducer(output, { now: () => at });
  assert.equal(producer.snapshot().days[0].coverage, 'partial');
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
  assert.equal(producer.snapshot().days[0].coverage ?? 'full', 'full');
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
    capture(state); producer.ingest(readJournal(filename));
  }
  assert.equal(readJournal(filename).length, 3);
  assert.equal(producer.entries.filter(row => row.type === 'source').length, 3);
  now = end; state.resultsHistoryCoverage.target.toExclusive = now; capture(state);
  producer.ingest(readJournal(filename));
  assert.equal(readJournal(filename).length, 4);
  // Explicit gap changes still record immediately without new fills or days.
  state.resultsHistoryCoverage.status = 'known';
  state.resultsHistoryCoverage.gaps = [{ fromInclusive: instant(Date.parse(begin) + 3600_000), toExclusive: instant(Date.parse(begin) + 3600_001) }];
  capture(state); producer.ingest(readJournal(filename));
  assert.equal(readJournal(filename).length, 5);
  state.resultsHistoryCoverage.status = 'complete'; state.resultsHistoryCoverage.gaps = [];
  capture(state); producer.ingest(readJournal(filename));
  assert.equal(readJournal(filename).length, 6);
  // Even proof with no remaining interval must revoke previously full days.
  state.resultsHistoryCoverage.status = 'known';
  state.resultsHistoryCoverage.gaps = [{ fromInclusive: begin, toExclusive: end }];
  capture(state); producer.ingest(readJournal(filename));
  assert.equal(readJournal(filename).length, 7);
  producer.observe({ at: instant(Date.parse(begin) + 12 * 3600_000),
    desks: { j: { equity: { amount: '5000', currency: 'EUR' }, basisId: 'synthetic-all-gap' } } });
  assert.equal(producer.snapshot().days[0].coverage, 'partial');
  capture(state); capture.close(); producer.close();
  const replay = openProducer(output, { now: () => end });
  replay.ingest(readJournal(filename));
  assert.equal(replay.entries.filter(row => row.type === 'source').length, 7);
  assert.equal(replay.snapshot().days[0].coverage, 'partial');
  replay.close();
});

test('legacy cuts without bounds stay partial and malformed proof fails closed', () => {
  assert.deepEqual(historyIntervals({ status: 'complete', target: { fromInclusive: 'bad', toExclusive: 'bad' }, gaps: [] }, '2026-10-17T00:00:00.000Z'), []);
  const dir = mkdtempSync(path.join(tmpdir(), 'joed20-legacy-'));
  const producer = openProducer(path.join(dir, 'results.jsonl'), { now: () => '2026-10-17T12:00:00.000Z' });
  producer.ingest([{ type: 'start', at: '2026-10-15T22:00:00.000Z' }, { type: 'authority', at: '2026-10-17T12:00:00.000Z', authoritative: true }]);
  producer.observe({ at: '2026-10-16T12:00:00.000Z', desks: { j: { equity: { amount: '5000', currency: 'EUR' }, basisId: 'synthetic' } } });
  assert.equal(producer.snapshot().days[0].coverage, 'partial');
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
