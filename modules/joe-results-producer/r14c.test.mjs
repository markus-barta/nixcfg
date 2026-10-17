import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { openProducer } from './producer.mjs';
import { dayCoverage } from './results-validation.mjs';

const start = '2026-10-15T22:00:00.000Z', now = '2026-10-17T18:00:00.000Z';
const at = (day, time) => `2026-10-${day}T${time}:00.000Z`;
const midnight = '2026-10-16T22:00:00.000Z';
const interval = (a, b) => [Date.parse(a), Date.parse(b)];
const gap = (fromInclusive, toExclusive) => ({ fromInclusive, toExclusive });
const history = (from, end, gaps = []) => ({ status: gaps.length ? 'known' : 'complete',
  target: { fromInclusive: from, toExclusive: end }, gaps });
const fill = (key, side, time) => ({ key, desk: 'j', scope: 'stage0',
  instrument: 'synthetic-acme', symbol: 'ACME', currency: 'EUR', side, at: time, quantity: '1', price: '10',
  commission: { amount: '0', currency: 'EUR' },
  brokerRealised: side === 'BUY' ? { unset: true, currency: 'EUR' } : { amount: '0', currency: 'EUR' },
  closeFx: { base: 'EUR', quote: 'EUR', rate: '1', source: 'identity', observedAt: time } });

function producerFixture(t, clock = now) {
  const root = fileURLToPath(new URL('../../tests/.tmp/', import.meta.url));
  mkdirSync(root, { recursive: true });
  const dir = mkdtempSync(path.join(root, 'joed20-r14c-'));
  const filename = path.join(dir, 'producer.jsonl');
  let producer = openProducer(filename, { now: () => clock });
  t.after(() => { producer.close(); rmSync(dir, { recursive: true, force: true }); });
  return { get producer() { return producer; }, replay() {
    producer.close(); producer = openProducer(filename, { now: () => clock });
    return producer.snapshot();
  } };
}

for (const [name, intervals, expected] of [
  ['midnight to ten minutes before now', [interval(midnight, at('17', '17:50'))], 'full'],
  ['starts three hours after midnight', [interval(at('17', '01:00'), at('17', '17:50'))], 'partial'],
  ['hole from 08:00 to 09:00', [interval(midnight, at('17', '08:00')), interval(at('17', '09:00'), at('17', '17:50'))], 'partial'],
  ['proof ends before midnight', [interval(start, at('16', '21:00'))], 'partial'],
]) test(`direct open-day coverage: ${name}`, () => {
  assert.equal(dayCoverage('2026-10-17', start, now, intervals, true), expected);
});

for (const [name, sellAt, matching, reasons] of [
  ['sell after last proof, mismatching baseline', at('17', '17:55'), false, ['history_gap']],
  ['sell after last proof, matching post-gap baseline', at('17', '17:55'), true, []],
  ['sell inside last proof, mismatching baseline', at('17', '17:45'), false, ['history_gap']],
  ['sell at last proof end, mismatching baseline', at('17', '17:50'), false, ['history_gap']],
]) test(`earlier own-fill gap: ${name}`, t => {
  const f = producerFixture(t), missingAt = at('16', '12:00');
  const fillGap = { ...gap(missingAt, new Date(Date.parse(missingAt) + 1).toISOString()), kind: 'unattributed_activity' };
  f.producer.ingest([{ type: 'start', at: start }, {
    type: 'cut', at: at('17', '17:59'), authoritative: true,
    fills: [fill('buy', 'BUY', at('16', '10:00')), fill('sell', 'SELL', sellAt)],
    historyCoverage: history(start, at('17', '17:50')), historyGaps: [], fillGaps: [fillGap],
    unattributedActivity: { '2026-10-16': 1 },
    positionProof: { at: at('16', '13:00'), foreign: [],
      positions: [{ instrument: 'synthetic-acme', quantity: matching ? '1' : '2' }] },
  }]);
  const days = f.producer.snapshot().days;
  assert.deepEqual(days.find(day => day.date === '2026-10-16').partialReasons, ['unattributed_activity']);
  assert.deepEqual(days.find(day => day.date === '2026-10-17').partialReasons || [], reasons);
  assert.deepEqual(f.replay().days, days);
});

test('only day coverage labels a hole after the last fill and before later proof', t => {
  const f = producerFixture(t);
  f.producer.ingest([{ type: 'start', at: midnight },
    { type: 'cut', at: at('17', '08:00'), authoritative: true,
      fills: [fill('buy', 'BUY', at('17', '07:00'))], historyCoverage: history(midnight, at('17', '08:00')) },
    { type: 'cut', at: at('17', '17:59'), authoritative: true,
      fills: [], historyCoverage: history(at('17', '09:00'), at('17', '17:50')) },
  ]);
  const days = f.producer.snapshot().days;
  assert.deepEqual(days[0].partialReasons, ['history_gap']);
  assert.deepEqual(f.replay().days, days);
});

for (const laterHistory of ['unknown', 'earlier target']) test(`trailing explicit gap survives a later authoritative cut with ${laterHistory}`, t => {
  const f = producerFixture(t), end = at('17', '17:50');
  f.producer.ingest([{ type: 'start', at: midnight },
    { type: 'cut', at: end, authoritative: true,
      fills: [fill('buy', 'BUY', at('17', '07:00'))],
      historyCoverage: history(midnight, end, [gap(at('17', '16:00'), end)]) },
    { type: 'cut', at: at('17', '17:59'), authoritative: true, fills: [],
      historyCoverage: laterHistory === 'unknown' ? null : history(midnight, at('17', '15:00')) },
  ]);
  const days = f.producer.snapshot().days;
  assert.deepEqual(days[0].partialReasons, ['history_gap']);
  assert.deepEqual(f.replay().days, days);
});

test('explicit open-day target retains a trailing gap but never shortens closed-day coverage', () => {
  const intervals = [interval(start, at('16', '21:50'))], target = Date.parse(at('16', '21:50'));
  assert.equal(dayCoverage('2026-10-16', start, at('16', '22:00'), intervals, true, target), 'partial');
  assert.equal(dayCoverage('2026-10-16', start, at('16', '21:59'), intervals, true, target), 'full');
  assert.equal(dayCoverage('2026-10-16', start, at('16', '21:59'), [interval(start, at('16', '21:00'))], true, target), 'partial');
});
