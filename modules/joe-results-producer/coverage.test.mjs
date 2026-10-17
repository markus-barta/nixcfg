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
  state.resultsHistoryCoverage.target = { fromInclusive: instant(Date.parse(middle) + 1), toExclusive: end };
  capture(state); capture.close();
  assert.equal(readJournal(filename).length, 4);
  producer = openProducer(output, { now: () => end });
  producer.ingest(readJournal(filename));
  assert.equal(producer.snapshot().days[0].coverage, 'partial'); // 1 ms between cuts is still a gap
  capture = createCapture(filename, {}, options);
  state.resultsHistoryCoverage.target.fromInclusive = middle;
  capture(state); capture.close();
  producer.ingest(readJournal(filename));
  assert.equal(producer.snapshot().days[0].coverage ?? 'full', 'full');
  producer.close();
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
