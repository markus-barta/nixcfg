import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { openProducer, createRunner, CADENCE_MS, MIDNIGHT_RETRIES } from './producer.mjs';
import { httpTransport, failureDiagnostic } from './transport.mjs';
import { validateResults, markPartial, viennaDate } from './results-validation.mjs';
import { roundTrips } from './fifo.mjs';
import { readJournal } from './journal.mjs';

const start = '2026-10-15T22:00:00.000Z';
const before = '2026-10-16T21:59:59.999Z', after = '2026-10-16T22:00:00.500Z';
const health = { status: 'ok', halt: { active: false }, brakes: { newPerDay: 1, notionalEur: 1 }, gatewayReachable: true };
const required = { path: '$.days[0].partialReasons', rule: 'partialReasonsRequired' };
const fill = (key, side = 'BUY', at = '2026-10-16T10:00:00.000Z', quantity = '1', fee = '0') => ({
  key, desk: 'j', instrument: 'synthetic-acme', symbol: 'ACME', scope: 'stage0', side, at,
  currency: 'EUR', quantity, price: '10', commission: { amount: fee, currency: 'EUR' },
  brokerRealised: side === 'BUY' ? { unset: true, currency: 'EUR' } : { amount: '0', currency: 'EUR' },
  closeFx: { base: 'EUR', quote: 'EUR', rate: '1', source: 'identity', observedAt: at },
});
const history = (from, to, gaps = []) => ({ status: gaps.length ? 'known' : 'complete',
  target: { fromInclusive: from, toExclusive: to }, gaps });
function directory(t) {
  const root = fileURLToPath(new URL('../../tests/.tmp/', import.meta.url));
  mkdirSync(root, { recursive: true });
  const dir = mkdtempSync(path.join(root, 'joed20-r15-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}
function fixture(t, { advance = true, freshHistory = true, reject, snapshot } = {}) {
  const filename = path.join(directory(t), 'producer.jsonl');
  let clock = Date.parse(before), sourceReads = 0;
  const producer = openProducer(filename, { now: () => new Date(clock).toISOString() });
  t.after(() => producer.close());
  const original = producer.snapshot;
  if (snapshot) producer.snapshot = at => snapshot(original(at));
  const source = [{ type: 'start', at: start }], attempts = [], records = [];
  const transport = httpTransport('https://board.example.invalid/joe/inbox/results', {
    origin: 'https://board.example.invalid', headers: () => ({ authorization: 'Bearer synthetic-token' }),
    fetchImpl: async (_url, options) => {
      const value = JSON.parse(options.body); attempts.push(value);
      if (advance) clock = Date.parse(after);
      const result = reject ? reject(value) : validateResults(value, { receivedAt: after });
      return new Response(JSON.stringify(result), { status: result.ok ? 200 : 422 });
    },
  });
  const runner = createRunner({ producer, transport, now: () => clock, readHealth: () => health,
    readSource() {
      sourceReads++;
      if (!source[1] || freshHistory) {
        const end = new Date(clock - 1).toISOString();
        source.push({ type: 'cut', at: end, authoritative: true, fills: [fill('open')], historyCoverage: history(start, end) });
      }
      return source;
    },
  });
  return { producer, attempts, records, filename, get sourceReads() { return sourceReads; },
    set clock(value) { clock = value; },
    // main.mjs records thrown failures through this same diagnostic boundary.
    async tick() {
      try { return await runner.tick(); }
      catch (error) { records.push(failureDiagnostic(error)); throw error; }
    } };
}

for (const freshHistory of [false, true]) test(`midnight straddle silently retries a fresh snapshot; refreshed history=${freshHistory}`, async t => {
  const f = fixture(t, { freshHistory });
  assert.equal(await f.tick(), true);
  assert.equal(f.sourceReads, 2);
  assert.deepEqual(f.attempts.map(p => p.seq), [1, 2]);
  assert.deepEqual(f.attempts.map(p => p.generatedAt), [before, after]);
  assert.equal(f.attempts[0].days[0].coverage, 'partial');
  assert.equal(Object.hasOwn(f.attempts[0].days[0], 'partialReasons'), false);
  const closed = f.attempts[1].days[0];
  assert.deepEqual(closed.partialReasons || [], freshHistory ? [] : ['history_gap']);
  assert.equal(closed.coverage, freshHistory ? undefined : 'partial');
  assert.deepEqual(f.records, []);
  const rows = readJournal(f.filename);
  assert.deepEqual(rows.filter(row => row.type === 'sequence').map(row => row.seq), [1, 2]);
  assert.deepEqual(rows.filter(row => row.type === 'health').map(row => row.value), [{
    status: 'running', halt: false, brakes: true, gatewayReachable: true,
    checkedAt: before, captureRefusals: 0, portionExclusions: 0,
  }]);
  assert.ok(rows.every(row => ['start', 'source', 'sequence', 'health'].includes(row.type)));
  f.clock = Date.parse(before) + CADENCE_MS - 1;
  assert.equal(await f.tick(), false, 'successful retry keeps normal cadence');
  f.clock = Date.parse(before) + CADENCE_MS;
  assert.equal(await f.tick(), true);
});

test('a genuine reasonless closed day fails preflight and keeps its failure record', async t => {
  const f = fixture(t, { snapshot: value => ({ ...value, generatedAt: after,
    days: value.days.map(({ partialReasons: _reasons, ...day }) => ({ ...day, coverage: 'partial' })) }) });
  await assert.rejects(f.tick(), error => error.status === 422);
  assert.equal(f.sourceReads, 1);
  assert.equal(f.attempts.length, 0, 'already-closed reasonless day never reaches HTTP');
  assert.deepEqual(f.records, [{ status: 'ingress_rejected', httpStatus: 422,
    reason: 'contract_invalid', errors: [required] }]);
  f.clock = Date.parse(before) + 999;
  assert.equal(await f.tick(), false);
  f.clock = Date.parse(before) + 1000;
  await assert.rejects(f.tick());
  assert.equal(f.sourceReads, 2);
  assert.equal(f.records.length, 2);
});

test('midnight retry is bounded even if the producer clock never crosses midnight', async t => {
  const f = fixture(t, { advance: false, reject: () => ({ ok: false, reason: 'contract_invalid', errors: [required] }) });
  await assert.rejects(f.tick(), error => error.status === 422);
  assert.equal(f.attempts.length, MIDNIGHT_RETRIES + 1);
  assert.equal(f.sourceReads, MIDNIGHT_RETRIES + 1);
  assert.deepEqual(f.attempts.map(p => p.seq), [1, 2]);
  assert.deepEqual(f.records, [{ status: 'ingress_rejected', httpStatus: 422,
    reason: 'contract_invalid', errors: [required] }]);
  f.clock = Date.parse(before) + 999;
  assert.equal(await f.tick(), false, 'only the exhausted race counts as one failure');
  f.clock = Date.parse(before) + 1000;
  await assert.rejects(f.tick());
  assert.equal(f.attempts.length, 3, 'after midnight this is an ordinary closed-day rejection');
});

for (const [name, errors, reason = 'contract_invalid'] of [
  ['another rule', [{ path: '$.generatedAt', rule: 'clockAhead' }]],
  ['another path', [{ ...required, path: '$.days[1].partialReasons' }]],
  ['mixed errors', [required, { path: '$.seq', rule: 'sequenceReplayed' }]],
  ['filtered mixed errors', [required, { path: '$.synthetic-untrusted', rule: 'unknown_rule' }]],
  ['truncated mixed errors', [...Array(20).fill(required), { path: '$.seq', rule: 'sequenceReplayed' }]],
  ['another reason', [required], 'sequence_replayed'],
]) test(`422 ${name} stays an ordinary failure`, async t => {
  const f = fixture(t, { reject: () => ({ ok: false, reason, errors }) });
  await assert.rejects(f.tick());
  assert.equal(f.attempts.length, 1);
  assert.equal(f.sourceReads, 1);
  assert.equal(f.records.length, 1);
});

test('markPartial asserts the backstop day invariant with a clear error', () => {
  assert.throws(() => markPartial(undefined, 'broker_evidence_missing'), /^Error: partial_day_missing$/);
  const day = { date: '2026-10-16', desks: {} };
  markPartial(day, 'broker_evidence_missing');
  assert.deepEqual(day.partialReasons, ['broker_evidence_missing']);
});

test('tiny EUR fee remainder fails closed after prior rounded portions exhaust its budget', () => {
  const fills = [fill('open', 'BUY', undefined, '5', '0.00000003'),
    ...Array.from({ length: 5 }, (_, i) => fill(`close-${i}`, 'SELL', `2026-10-16T1${i + 1}:00:00.000Z`))];
  const excluded = [], trades = roundTrips(fills, start, [], () => {}, row => excluded.push(row));
  assert.equal(trades.length, 4);
  assert.deepEqual(trades.map(row => row.feesEur.amount), Array(4).fill('0.00000001'));
  assert.equal(excluded.length, 1);
  assert.equal(excluded[0].kind, 'source_not_authoritative');
  assert.equal(excluded[0].at, fills.at(-1).at);
  assert.ok(trades.every(row => !row.feesEur.amount.startsWith('-')));
});

test('seeded gaps and starts explain every closed partial day and only real open-day causes', t => {
  let seed = 0x152026;
  const random = n => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed % n; };
  const base = Date.parse(start), through = '2026-10-19T18:00:00.000Z';
  const iso = epoch => new Date(epoch).toISOString();
  const dir = directory(t), seenOpen = new Set(), seenClosed = new Set();
  for (let i = 0; i < 48; i++) {
    const from = iso(base + random(2) * 3600_000), end = iso(Date.parse(through) - 600_000);
    const gaps = Array.from({ length: random(5) }, () => {
      const begin = base + random(4) * 86400_000 + (3 + random(5)) * 3600_000;
      return { fromInclusive: iso(begin), toExclusive: iso(begin + (1 + random(2)) * 3600_000) };
    });
    const p = openProducer(path.join(dir, `producer-${i}.jsonl`), { now: () => through });
    try {
      const fills = Array.from({ length: 4 }, (_, j) => fill(`day-${j}`, 'BUY', iso(base + j * 86400_000 + 12 * 3600_000)));
      p.ingest([{ type: 'start', at: from }, { type: 'cut', at: end, authoritative: true, fills, historyCoverage: history(from, end, gaps) }]);
      const value = p.snapshot();
      assert.equal(validateResults(value, { requirePartialReasons: true }).ok, true);
      for (const day of value.days) {
        if (day.date < viennaDate(through)) {
          if (day.coverage === 'partial') assert.ok(day.partialReasons?.length, `seeded case ${i}: ${day.date}`);
          seenClosed.add(day.coverage || 'full');
        } else {
          // This book stays open across all four days; an earlier gap is a
          // real cause too, since no post-gap position baseline was supplied.
          const hasGap = gaps.length > 0;
          assert.equal(day.coverage, 'partial');
          assert.deepEqual(day.partialReasons || [], hasGap ? ['history_gap'] : []);
          seenOpen.add(hasGap);
        }
      }
    } finally { p.close(); }
  }
  assert.deepEqual([...seenClosed].sort(), ['full', 'partial']);
  assert.deepEqual([...seenOpen].sort(), [false, true]);
});
