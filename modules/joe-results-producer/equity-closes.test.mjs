import '../../tests/paper-desk-account-fixture.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { readEquityCloses } from './equity-closes.mjs';
import { openProducer, createRunner } from './producer.mjs';
import { validateResults } from './results-validation.mjs';
import { verifyContracts } from './verify-contracts.mjs';
import { createDeskEquityCloseRecorder } from '../../hosts/hsb0/docker/joe-board-pusher/desk-equity-closes.mjs';

const now = '2026-10-17T10:00:00.000Z', start = '2026-10-16T11:00:00.000Z';
const fills = JSON.parse(readFileSync(new URL('./fixtures/fills.json', import.meta.url)));
const source = () => [{ type: 'start', at: start }, ...fills.map(fill => ({ type: 'fill', fill })),
  { type: 'authority', at: now, authoritative: true, disagreement: false, evidence: [] }];
function outcome(overrides = {}) {
  return { schema: 'inspr.joe.desk-equity-close.v1', vienna_day: '2026-10-16', desk: 'j',
    closeAt: '2026-10-16T22:00:00.000Z', observedAt: '2026-10-16T21:59:45.000Z', oldestInputAt: '2026-10-16T21:59:30.000Z',
    equityClose: { amount: '5001.12345678', currency: 'EUR' }, reason: null, maxAgeMs: 60000, ...overrides };
}
function fixture() {
  const dir = mkdtempSync(path.join(tmpdir(), 'ops556-results-')), filename = path.join(dir, 'outcomes.jsonl'), diagnostics = [];
  const producer = openProducer(path.join(dir, 'results.jsonl'), { now: () => now, equityClosePath: filename,
    diagnostic: detail => diagnostics.push(detail) });
  producer.ingest(source());
  return { dir, filename, producer, diagnostics, write: rows => writeFileSync(filename, rows.map(r => JSON.stringify(r)).join('\n') + '\n') };
}
const equity = snapshot => snapshot.days.find(d => d.date === '2026-10-16').desks.j.equityClose;
function valid(snapshot) { const checked = validateResults(snapshot, { requirePartialReasons: true }); assert.equal(checked.ok, true, JSON.stringify(checked)); }

test('exact outcome fills equityClose and leaves Results v2 and non-equity economics unchanged', () => {
  const f = fixture(), missing = f.producer.snapshot(now);
  f.write([outcome()]); const snapshot = f.producer.snapshot(now);
  assert.deepEqual(equity(snapshot), outcome().equityClose); valid(snapshot); verifyContracts();
  const stripped = structuredClone(snapshot); stripped.seq = missing.seq;
  for (const day of stripped.days) for (const desk of Object.values(day.desks)) desk.equityClose = null;
  assert.deepEqual(stripped, missing);
  assert.equal(JSON.stringify(snapshot).includes('maxAgeMs'), false);
  assert.equal(JSON.stringify(snapshot).includes('reason":"stale'), false);
  f.producer.close();
});
test('producer restart re-reads the same durable outcome', () => {
  const f = fixture(); f.write([outcome()]); const first = f.producer.snapshot(now); f.producer.close();
  const producer = openProducer(path.join(f.dir, 'results.jsonl'), { now: () => now, equityClosePath: f.filename });
  const replay = producer.snapshot(now); assert.deepEqual(equity(replay), equity(first)); valid(replay); producer.close();
});
test('missing stream gives all null with a value-free diagnostic', () => {
  const f = fixture(), snapshot = f.producer.snapshot(now); valid(snapshot);
  assert.equal(equity(snapshot), null); assert.equal(f.diagnostics.at(-1).reason, 'stream_missing'); f.producer.close();
});
test('unreadable stream gives all null and still publishes', async () => {
  const f = fixture(), other = path.join(f.dir, 'other.jsonl'); writeFileSync(other, JSON.stringify(outcome()) + '\n'); symlinkSync(other, f.filename);
  let sent;
  const runner = createRunner({ producer: f.producer, readSource: source, now: () => Date.parse(now),
    readHealth: async () => ({}), transport: { send: async snapshot => { sent = snapshot; } } });
  assert.equal(await runner.tick(), true); valid(sent); assert.equal(equity(sent), null);
  assert.equal(f.diagnostics.at(-1).reason, 'stream_unreadable'); f.producer.close();
});
test('a valid null outcome keeps its reason in diagnostics only', () => {
  const f = fixture(); f.write([outcome({ equityClose: null, reason: 'stale', observedAt: null, oldestInputAt: null })]);
  const snapshot = f.producer.snapshot(now); valid(snapshot); assert.equal(equity(snapshot), null);
  assert.equal(f.producer.equityCloseDiagnostics[0].reason, 'stale');
  assert.equal(JSON.stringify(snapshot).includes('stale'), false); f.producer.close();
});
for (const [name, change] of [
  ['schema', { schema: 'unknown' }], ['desk', { desk: 'j2' }], ['day-format', { vienna_day: '2026-2-3' }],
  ['invalid-day', { vienna_day: '2026-02-30' }], ['currency', { equityClose: { amount: '1', currency: 'USD' } }],
  ['number', { equityClose: { amount: 5000, currency: 'EUR' } }], ['precision', { equityClose: { amount: '1.123456789', currency: 'EUR' } }],
  ['exponent', { equityClose: { amount: '1e3', currency: 'EUR' } }], ['rounding', { equityClose: { amount: '01.2', currency: 'EUR' } }],
  ['extra-field', { privateLedger: [] }], ['late-observation', { observedAt: '2026-10-16T22:00:00.000Z' }],
  ['wrong-boundary', { closeAt: '2026-10-16T22:00:01.000Z' }], ['stale', { observedAt: '2026-10-16T21:58:59.999Z', oldestInputAt: '2026-10-16T21:58:59.999Z' }],
  ['unbounded-age', { maxAgeMs: 9999999999 }], ['unknown-reason', { equityClose: null, observedAt: null, oldestInputAt: null, reason: 'raw secret' }],
  ['future-input', { oldestInputAt: '2026-10-16T21:59:50.000Z' }],
]) test(`strict invalid ${name} outcome stays null without blocking publication`, () => {
  const f = fixture(); f.write([outcome(change)]); const snapshot = f.producer.snapshot(now); valid(snapshot);
  assert.equal(equity(snapshot), null); assert.equal(f.diagnostics.at(-1).reason, 'stream_invalid');
  assert.equal(JSON.stringify(f.diagnostics).includes('5001.12345678'), false); f.producer.close();
});
for (const name of ['identical', 'conflicting', 'triple']) test(`${name} duplicate key is unusable; an unrelated key survives`, () => {
  const f = fixture(), rows = [outcome(), outcome({ equityClose: { amount: name === 'identical' ? '5001.12345678' : '7000', currency: 'EUR' } }), outcome({ desk: 'joe' })];
  if (name === 'triple') rows.push(outcome()); f.write(rows);
  const snapshot = f.producer.snapshot(now); valid(snapshot); assert.equal(equity(snapshot), null);
  assert.deepEqual(snapshot.days[0].desks.joe.equityClose, outcome().equityClose);
  assert.ok(f.diagnostics.some(d => d.reason === 'duplicate_outcome')); f.producer.close();
});
test('malformed or partial stream revokes previously readable closes', () => {
  const f = fixture(); f.write([outcome()]); assert.notEqual(equity(f.producer.snapshot(now)), null);
  for (const bytes of ['{bad}\n', JSON.stringify(outcome()), JSON.stringify(outcome()) + '\n{bad}\n']) {
    writeFileSync(f.filename, bytes); const snapshot = f.producer.snapshot(now); valid(snapshot); assert.equal(equity(snapshot), null);
  }
  f.producer.close();
});
test('an open-day outcome cannot populate a close and earlier tracking days are not added', () => {
  const f = fixture(); f.write([outcome()]);
  assert.equal(readEquityCloses(f.filename, '2026-10-16T21:59:59.000Z').closes.size, 0);
  assert.equal(readEquityCloses(f.filename, '2026-10-16T21:59:59.000Z').diagnostics[0].reason, 'day_not_closed');
  f.write([outcome({ vienna_day: '2026-10-15', closeAt: '2026-10-15T22:00:00.000Z', observedAt: '2026-10-15T21:59:45.000Z', oldestInputAt: '2026-10-15T21:59:45.000Z' })]);
  const snapshot = f.producer.snapshot(now); assert.ok(snapshot.days.every(d => d.date >= '2026-10-16')); f.producer.close();
});
test('closed-day desk without activity can carry its recorded equity with zero activity totals', () => {
  const f = fixture(); f.write([outcome({ desk: 'joel' })]); const snapshot = f.producer.snapshot(now); valid(snapshot);
  const row = snapshot.days[0].desks.joel; assert.deepEqual(row.equityClose, outcome().equityClose);
  assert.equal(row.trades, 0); assert.equal(row.realisedNet.amount, '0'); assert.equal(row.fees.amount, '0'); f.producer.close();
});
test('pusher outcome stream is consumed end to end without pusher state access', () => {
  const f = fixture(), before = '2026-10-16T21:59:45.000Z', boundary = '2026-10-16T22:00:05.000Z';
  const recorder = createDeskEquityCloseRecorder({ firstDay: '2026-10-16', intervalSec: 30, revision: 11,
    statePath: path.join(f.dir, 'private-state.json'), outcomePath: f.filename });
  const input = { book: { ts: before, gateway: true, apiReplyCheckedAt: before, summary: {}, positions: [], portfolio: [],
    positionsCoverage: { status: 'complete', observedAt: before } }, deskEquities: { ok: true,
    desks: Object.fromEntries(['j', 'joe', 'joel'].map(id => [id, { positions: [] }])),
    phaseBDesks: Object.fromEntries(['j', 'joe', 'joel'].map(id => [id, { reconciled: id !== 'joe', base: 5000, equity: 5001.25,
      totalPnl: 1.25, openPnl: 0, observedAt: before, oldestInputAt: before, fx: null, positions: [] }])) } };
  assert.equal(recorder.observe(input, before), true); assert.equal(recorder.observe(null, boundary), true);
  const snapshot = f.producer.snapshot(now); valid(snapshot);
  assert.deepEqual(equity(snapshot), { amount: '5001.25', currency: 'EUR' });
  assert.equal(snapshot.days[0].desks.joe.equityClose, null);
  assert.ok(f.producer.equityCloseDiagnostics.some(d => d.desk === 'joe' && d.reason === 'inexact')); f.producer.close();
});
