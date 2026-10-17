import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { createCapture, authorityHash } from './capture.mjs';
import { openProducer } from './producer.mjs';
import { hash, readJournal } from './journal.mjs';
import { historyIntervals, withFillGaps } from './results-validation.mjs';

const start = '2026-10-15T22:00:00.000Z', now = '2026-10-16T18:00:00.000Z';
const at = hour => `2026-10-16T${hour}:00:00.000Z`;
const history = (end, gaps = []) => ({ status: gaps.length ? 'known' : 'complete',
  target: { fromInclusive: start, toExclusive: end }, gaps });
const gap = (fromInclusive, toExclusive) => ({ fromInclusive, toExclusive });
function directory(t) {
  const root = fileURLToPath(new URL('../../tests/.tmp/', import.meta.url));
  mkdirSync(root, { recursive: true });
  const dir = mkdtempSync(path.join(root, 'joed20-r14b-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}
const fill = (key, side, time, fxMissing = false) => ({ key, desk: 'j', scope: 'stage0',
  instrument: 'synthetic-acme', symbol: 'ACME', currency: fxMissing ? 'USD' : 'EUR',
  side, at: time, quantity: '1', price: '10',
  commission: { amount: '0', currency: fxMissing ? 'USD' : 'EUR' },
  brokerRealised: side === 'BUY' ? { unset: true, currency: 'EUR' } : { amount: '0', currency: 'EUR' },
  closeFx: fxMissing ? null : { base: 'EUR', quote: 'EUR', rate: '1', source: 'identity', observedAt: time } });

for (const lag of [1, 600_000]) {
  for (const cause of ['none', 'fx', 'explicit gap', 'midnight hole']) {
    test(`open day: history lags by ${lag} ms, cut predates snapshot, ${cause}`, t => {
      const end = new Date(Date.parse(now) - lag).toISOString();
      const coverage = history(end, cause === 'explicit gap' ? [gap(at('08'), at('09'))] : []);
      if (cause === 'midnight hole') coverage.target.fromInclusive = at('01');
      const producer = openProducer(path.join(directory(t), 'producer.jsonl'), { now: () => now });
      t.after(() => producer.close());
      producer.ingest([{ type: 'start', at: start }, { type: 'cut', at: end, authoritative: true,
        fills: [fill('open', 'BUY', at('10'), cause === 'fx'), fill('close', 'SELL', at('11'), cause === 'fx')],
        historyCoverage: coverage }]);
      const value = producer.snapshot(), day = value.days[0];
      assert.equal(value.generatedAt, now);
      assert.equal(day.coverage, 'partial');
      assert.deepEqual(day.partialReasons || [], cause === 'none' ? [] : cause === 'fx' ? ['fx_missing'] : ['history_gap']);
    });
  }
}

test('a trailing explicit history gap stays visible even when the last interval ends earlier', t => {
  const end = at('17');
  const producer = openProducer(path.join(directory(t), 'producer.jsonl'), { now: () => now });
  t.after(() => producer.close());
  producer.ingest([{ type: 'start', at: start }, { type: 'cut', at: end, authoritative: true,
    fills: [fill('open', 'BUY', at('10'))], historyCoverage: history(end, [gap(at('16'), end)]) }]);
  assert.deepEqual(producer.snapshot().days[0].partialReasons, ['history_gap']);
});

function captureFixture(t, cutover = start) {
  const input = path.join(directory(t), 'capture.jsonl');
  let clock = start;
  const config = { executorClientId: 705, foreignAlertSince: cutover };
  const options = { now: () => clock, account: 'synthetic-account', executionTime: Date.parse,
    attribute: row => row.unknown ? { needsAttribution: true } : { desk: 'j', method: 'admin' } };
  let capture = createCapture(input, config, options);
  t.after(() => capture.close());
  capture({ ownershipComplete: true, executions: [] });
  clock = at('17');
  const state = { ownershipComplete: true, executions: [], commissions: [],
    resultsHistoryCoverage: { ...history(clock), target: { fromInclusive: cutover, toExclusive: clock } } };
  return { input, get capture() { return capture; }, state,
    restart() { capture.close(); capture = createCapture(input, config, options); } };
}
const raw = (id, time, unknown = false) => ({ unknown, contract: { conId: 1, symbol: 'ACME', currency: 'EUR' },
  execution: { execId: `synthetic-${id}.01`, acctNumber: 'synthetic-account', clientId: 705,
    time, side: 'BUY', shares: '1', price: '10' } });

test('pre-tracking unattributed fill creates no earlier row and still revokes later position proof', t => {
  const f = captureFixture(t, '2026-10-12T22:00:00.000Z');
  f.state.executions = [raw('before', '2026-10-15T10:00:00.000Z', true), raw('current', at('10'))];
  f.state.commissions = [{ execId: 'synthetic-current.01', commission: '0', currency: 'EUR', realizedPNL: Number.MAX_VALUE }];
  f.capture(f.state);
  const cut = readJournal(f.input).at(-1);
  assert.equal(cut.fillGaps.length, 1);
  assert.deepEqual(cut.unattributedActivity, {});
  assert.equal(historyIntervals(cut.historyCoverage, cut.at).length, 2, 'pre-tracking gap remains in proof maths');
  const filename = path.join(path.dirname(f.input), 'producer.jsonl');
  let producer = openProducer(filename, { now: () => now });
  t.after(() => producer.close());
  producer.ingest(readJournal(f.input));
  const days = producer.snapshot().days;
  assert.deepEqual(days.map(day => day.date), ['2026-10-16']);
  assert.deepEqual(days[0].partialReasons, ['history_gap'], 'unproven earlier activity still taints the current book');
  producer.close(); producer = openProducer(filename, { now: () => now });
  assert.deepEqual(producer.snapshot().days, days);
});

for (const field of ['sample.rate', 'closeFx.rate']) test(`refused ${field} journal replays through frozen rollback producers and new replay says fx_missing`, async t => {
  const f = captureFixture(t);
  if (field === 'sample.rate') f.state.resultsFxSampler = { enabled: true, days: { '2026-10-16': {
    samples: [{ rate: 1e-7, sampleAt: at('10'), kind: 'rth' }],
  } } };
  else {
    const row = raw('fx', at('10')); row.contract.currency = 'USD';
    f.state.executions = [row];
    f.state.commissions = [{ execId: row.execution.execId, commission: '0', currency: 'USD', realizedPNL: Number.MAX_VALUE }];
    f.state.resultsFx = { USD: { rate: 1e-7, base: 'USD', quote: 'EUR', observedAt: at('10'), source: 'synthetic' } };
  }
  f.capture(f.state);
  const entries = readJournal(f.input), issues = entries.flatMap(row => row.captureIssues || []);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].field, field);
  // Byte-for-byte producer sources: exercise their actual apply/issue checks
  // on ingestion and restart, with sibling dependencies resolved as in r9.
  for (const [name, digest] of [
    ['round12b', 'c9039167f39f9b3f383a5bf732d57d99bc98d5c659d2cc63c44829643d10d53e'], // 6c6e15f1
    ['round13', '37c8ee80eb8b01eb6f6ab30b0192e6b9c868c7774a77ae55ecd283f9d1127fa0'], // fce6709b
  ]) {
    const frozen = readFileSync(new URL(`./fixtures/${name}-producer.mjs`, import.meta.url), 'utf8');
    assert.equal(createHash('sha256').update(frozen).digest('hex'), digest);
    const source = frozen.replace(/from '(\.\/[^']+)'/g, (_, sibling) => `from '${new URL(sibling, import.meta.url).href}'`);
    const { openProducer: rollback } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
    const file = path.join(path.dirname(f.input), `${name}.jsonl`);
    let old = rollback(file, { now: () => now });
    t.after(() => old.close());
    old.ingest(entries);
    assert.equal(old.sourceCount, entries.length);
    const days = old.snapshot().days;
    old.close(); old = rollback(file, { now: () => now });
    assert.equal(old.sourceCount, entries.length);
    assert.deepEqual(old.snapshot().days, days);
    // A new kind would fail in precisely the old code this test protects.
    assert.throws(() => old.ingest([...entries, { type: 'fx', captureIssues: [{ ...issues[0], kind: 'fx_missing' }] }]),
      /source_not_authoritative/);
  }
  const filename = path.join(path.dirname(f.input), 'producer.jsonl');
  let producer = openProducer(filename, { now: () => now });
  t.after(() => producer.close());
  producer.ingest(entries);
  const days = producer.snapshot().days;
  assert.deepEqual(days[0].partialReasons, ['fx_missing']);
  producer.close(); producer = openProducer(filename, { now: () => now });
  assert.deepEqual(producer.snapshot().days, days);
});

test('combined fill gaps are idempotent and authority hashing stays compatible with round 14', t => {
  const f = captureFixture(t);
  f.state.executions = [raw('unattributed', at('10'), true)];
  f.state.ownershipSnapshot = { account: 'synthetic-account', ownershipComplete: true, observedAt: at('12'), positions: [] };
  f.capture(f.state);
  const rows = readJournal(f.input), cut = rows.at(-1);
  assert.equal(cut.fillGaps.length, 1);
  const combined = withFillGaps(cut.historyCoverage, cut.fillGaps);
  assert.deepEqual(combined, cut.historyCoverage);
  assert.deepEqual(withFillGaps(combined, cut.fillGaps), combined);
  // Round 14 applied the same omissions twice before authorityHash, which
  // hashes the containing interval's start rather than the gap list itself.
  const oldCombined = { ...cut.historyCoverage, gaps: [...cut.historyCoverage.gaps,
    ...cut.fillGaps.map(({ fromInclusive, toExclusive }) => ({ fromInclusive, toExclusive }))] };
  const proof = cut.positionProof, epoch = Date.parse(proof.at);
  const interval = historyIntervals(oldCombined, cut.at).find(([a, b]) => a <= epoch && epoch < b);
  const round14Hash = hash([cut.authoritative, cut.disagreement, cut.evidence, proof.positions, proof.foreign, interval[0], cut.unattributedActivity]);
  assert.equal(authorityHash(cut), round14Hash);
  f.restart();
  f.capture(f.state);
  assert.deepEqual(readJournal(f.input), rows, 'restart must not add a duplicate authority cut');
});
