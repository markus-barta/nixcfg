import '../../tests/paper-desk-account-fixture.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { readEquityCloses } from './equity-closes.mjs';
import { dayCloses } from './fifo.mjs';
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
    equityClose: { amount: '5001.12345678', currency: 'EUR' }, reason: null, maxAgeMs: 120000, ...overrides };
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
  assert.ok(f.producer.equityCloseDiagnostics.some(row => row.reason === 'stale'));
  assert.equal(readEquityCloses(f.filename, now).closes.size, 0);
  assert.equal(JSON.stringify(snapshot).includes('stale'), false); f.producer.close();
});
for (const [name, change] of [
  ['schema', { schema: 'unknown' }], ['desk', { desk: 'j2' }], ['day-format', { vienna_day: '2026-2-3' }],
  ['invalid-day', { vienna_day: '2026-02-30' }], ['currency', { equityClose: { amount: '1', currency: 'USD' } }],
  ['number', { equityClose: { amount: 5000, currency: 'EUR' } }], ['precision', { equityClose: { amount: '1.123456789', currency: 'EUR' } }],
  ['exponent', { equityClose: { amount: '1e3', currency: 'EUR' } }], ['rounding', { equityClose: { amount: '01.2', currency: 'EUR' } }],
  ['extra-field', { privateLedger: [] }], ['late-observation', { observedAt: '2026-10-16T22:00:00.000Z' }],
  ['wrong-boundary', { closeAt: '2026-10-16T22:00:01.000Z' }], ['stale', { observedAt: '2026-10-16T21:57:59.999Z', oldestInputAt: '2026-10-16T21:57:59.999Z' }],
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
  assert.deepEqual(readEquityCloses(f.filename, now).closes.get('2026-10-16:joe'), outcome().equityClose);
  assert.equal(snapshot.days[0].desks.joe, undefined);
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
test('an exact close alone cannot create a desk with invented zero activity totals', () => {
  const f = fixture(); f.write([outcome({ desk: 'joel' })]); const snapshot = f.producer.snapshot(now); valid(snapshot);
  assert.equal(snapshot.days[0].desks.joel, undefined); f.producer.close();
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
  assert.equal(snapshot.days[0].desks.joe, undefined);
  assert.ok(f.producer.equityCloseDiagnostics.some(d => d.desk === 'joe' && d.reason === 'inexact')); f.producer.close();
});

function nullControl(read = readEquityCloses) {
  const f = fixture();
  f.write(['j', 'joe', 'joel'].map(desk => outcome({ desk, equityClose: null, observedAt: null, oldestInputAt: null, reason: 'no_observation' })));
  assert.equal(read(f.filename, now).closes.size, 0); f.producer.close();
}
test('null outcomes remain diagnostics and never enter the close map', () => nullControl());
for (const reason of ['recorder_gap', 'contract_unsupported']) test(`${reason} is accepted only as a null diagnostic`, () => {
  const f = fixture(); f.write([outcome({ equityClose: null, reason, observedAt: null, oldestInputAt: null })]);
  const result = readEquityCloses(f.filename, now);
  assert.equal(result.closes.size, 0);
  assert.deepEqual(result.diagnostics, [{ reason, day: '2026-10-16', desk: 'j' }]); f.producer.close();
});

function rowControl(project = dayCloses) {
  const equityCloses = new Map(['j', 'joe', 'joel'].map(desk => [`2026-10-16:${desk}`, null]));
  assert.deepEqual(project([], [], '2026-10-16', { from: start, through: now, equityCloses }).days, []);
  equityCloses.set('2026-10-16:joel', outcome().equityClose);
  assert.deepEqual(project([], [], '2026-10-16', { from: start, through: now, equityCloses }).days, []);
}
test('neither null nor exact outcomes alone create a day or desk row', () => rowControl());

for (const exact of [false, true]) test(`partial gap day retains empty desks with ${exact ? 'exact' : 'null'} handoff outcomes`, () => {
  const f = fixture(); f.producer.close();
  const producer = openProducer(path.join(f.dir, 'partial-results.jsonl'), { now: () => now, equityClosePath: f.filename, diagnostic: () => {} });
  producer.ingest([{ type: 'start', at: start }, { type: 'cut', at: now, authoritative: true, disagreement: false, fills: [], evidence: [],
    captureIssues: ['capture_gap', 'broker_evidence_missing'].map((kind, i) => ({ day: '2026-10-16', kind, id: String(i).repeat(64) })) }]);
  f.write(['j', 'joe', 'joel'].map(desk => outcome({ desk, ...(!exact ? { equityClose: null, observedAt: null, oldestInputAt: null, reason: 'no_observation' } : {}) })));
  const snapshot = producer.snapshot(now); valid(snapshot);
  assert.deepEqual(snapshot.days[0].desks, {});
  assert.equal(snapshot.days[0].coverage, 'partial');
  assert.deepEqual(snapshot.days[0].partialReasons, ['capture_gap', 'broker_evidence_missing']); producer.close();
});

for (const [day, boundary, wrong] of [
  ['2026-10-25', '2026-10-25T23:00:00.000Z', '2026-10-25T22:00:00.000Z'],
  ['2027-03-28', '2027-03-28T22:00:00.000Z', '2027-03-28T23:00:00.000Z'],
]) test(`producer validates DST boundary on ${day} and the last millisecond before midnight`, () => {
  const f = fixture(), at = new Date(Date.parse(boundary) + 2000).toISOString();
  const last = new Date(Date.parse(boundary) - 1).toISOString();
  f.write([outcome({ vienna_day: day, closeAt: boundary, observedAt: last, oldestInputAt: last })]);
  assert.deepEqual(readEquityCloses(f.filename, at).closes.get(`${day}:j`), outcome().equityClose);
  f.write([outcome({ vienna_day: day, closeAt: wrong, observedAt: last, oldestInputAt: last })]);
  assert.equal(readEquityCloses(f.filename, at).diagnostics[0].reason, 'stream_invalid'); f.producer.close();
});

for (const seconds of [119, 121]) test(`producer ${seconds}-second age boundary`, () => {
  const f = fixture(), observedAt = new Date(Date.parse(outcome().closeAt) - seconds * 1000).toISOString();
  f.write([outcome({ observedAt, oldestInputAt: observedAt })]);
  const result = readEquityCloses(f.filename, now);
  assert.equal(result.closes.size, seconds < 120 ? 1 : 0);
  if (seconds > 120) assert.equal(result.diagnostics[0].reason, 'stream_invalid'); f.producer.close();
});

test('missing day/desk records have no_record diagnostics even without activity rows', () => {
  const f = fixture(); f.write([outcome()]); f.producer.snapshot(now);
  assert.deepEqual(f.producer.equityCloseDiagnostics, ['joe', 'joel'].map(desk => ({ reason: 'no_record', day: '2026-10-16', desk })));
  f.producer.close();
});
test('producer logs only newly changed close diagnostics', () => {
  const f = fixture(); f.write([]); f.producer.snapshot(now); const count = f.diagnostics.length;
  assert.equal(count, 3); f.producer.snapshot(now); assert.equal(f.diagnostics.length, count);
  f.write([outcome({ equityClose: null, observedAt: null, oldestInputAt: null, reason: 'stale' })]);
  f.producer.snapshot(now); assert.equal(f.diagnostics.length, count + 1);
  assert.equal(f.diagnostics.at(-1).reason, 'stale'); f.producer.close();
});
test('producer bounds a large missing-history diagnostic batch', () => {
  const f = fixture(); f.producer.close(); const diagnostics = [];
  const producer = openProducer(path.join(f.dir, 'long-results.jsonl'), { now: () => now, equityClosePath: f.filename, diagnostic: row => diagnostics.push(row) });
  producer.ingest([{ type: 'start', at: '2026-01-01T00:00:00.000Z' }, { type: 'authority', at: now, authoritative: true, disagreement: false, evidence: [] }]);
  producer.snapshot(now); assert.equal(diagnostics.length, 21);
  assert.ok(diagnostics.some(row => row.reason === 'stream_missing'), 'stream failure must survive the missing-day log budget');
  assert.equal(diagnostics.at(-1).reason, 'diagnostics_truncated');
  assert.ok(producer.equityCloseDiagnostics.length > 800);
  producer.snapshot(now); assert.equal(diagnostics.length, 21); producer.close();
});

test('M2 mutation controls reject null close entries and synthetic desk rows', async () => {
  for (const [name, file, needle, replacement, check] of [
    ['null-map', './equity-closes.mjs', 'if (row.equityClose !== null) closes.set(key, row.equityClose);', 'closes.set(key, row.equityClose);', module => nullControl(module.readEquityCloses)],
    ['row-creation', './fifo.mjs', 'const result = [...days]', `for (const [key, equityClose] of equityCloses) {
      const [date, desk] = key.split(':'); const desks = days.get(date) || Object.create(null);
      desks[desk] ||= { equityClose }; days.set(date, desks);
    }
    const result = [...days]`, module => rowControl(module.dayCloses)],
  ]) {
    const original = readFileSync(new URL(file, import.meta.url), 'utf8'); assert.ok(original.includes(needle), name);
    const changed = original.replace(needle, replacement).replace(/from '(\.\/[^']+)'/g, (_, specifier) => `from '${new URL(specifier, import.meta.url).href}'`);
    const dir = mkdtempSync(path.join(tmpdir(), 'ops556-m2-mutant-')), filename = path.join(dir, 'mutant.mjs');
    writeFileSync(filename, changed); const module = await import(pathToFileURL(filename));
    assert.throws(() => check(module), { name: 'AssertionError' }, `${name} mutation survived`);
  }
});
