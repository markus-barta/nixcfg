import test from 'node:test';
import assert from 'node:assert/strict';
import { appendFileSync, mkdtempSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createFxSampler, fxSlot } from '../paper-desk-executor/fx-sampler.mjs';
import { createCapture } from './capture.mjs';
import { captureBrokerRealised } from './broker-backstop.mjs';
import { openJournal, readJournal } from './journal.mjs';
import { openProducer } from './producer.mjs';
import { validateContract } from './contracts/index.mjs';

const iso = epoch => new Date(epoch).toISOString();
const directory = () => mkdtempSync(path.join(tmpdir(), 'joed20-r9-'));

test('65 trading days: real sampler/capture growth stays below 50 KB/day in both journals, one FX date per cut', async t => {
  const root = directory(), input = path.join(root, 'input.jsonl'), output = path.join(root, 'output.jsonl');
  let now = Date.parse('2026-01-01T00:00:00Z'), calls = 0;
  const state = { ownershipComplete: true, executions: [] };
  const options = { account: 'synthetic-account', attribute: () => ({}), executionTime: Date.parse, now: () => iso(now) };
  let capture = createCapture(input, {}, options);
  const sampler = createFxSampler({ root, now: () => now, request: async () => { calls++; return '0.86123457'; },
    onUpdate: fx => capture({ ...state, resultsFxSampler: fx }) });
  let producer = openProducer(output, { now: () => iso(now) });
  const growth = [], producerGrowth = [];
  try {
    capture(state);
    producer.ingestJournal(input);
    for (let date = now, tradingDays = 0; tradingDays < 65; date += 86400_000) {
      if (fxSlot(date + 16 * 3600_000).bucket === null) continue;
      const before = statSync(input).size, outputBefore = statSync(output).size, callCount = calls;
      for (let minute = 13 * 60; minute <= 21 * 60 + 5; minute++) {
        now = date + minute * 60_000;
        const slot = fxSlot(now);
        if (slot.bucket !== null && (minute % 15 === 0 || slot.kind === 'close')) await sampler.tick();
      }
      assert.equal(calls - callCount, 27);
      producer.ingestJournal(input);
      assert.equal(producer.retainedEntries, 0);
      growth.push(statSync(input).size - before);
      producerGrowth.push(statSync(output).size - outputBefore);
      assert.ok(growth.at(-1) < 50_000, `capture growth ${growth.at(-1)}`);
      assert.ok(producerGrowth.at(-1) < 50_000, `producer growth ${producerGrowth.at(-1)}`);
      if (++tradingDays % 13 === 0) {
        const size = statSync(input).size;
        capture.close(); capture = createCapture(input, {}, options);
        capture({ ...state, resultsFxSampler: sampler.snapshot() });
        assert.equal(statSync(input).size, size, 'startup seeded date hashes suppress duplicate FX cuts');
        producer.close(); producer = openProducer(output, { now: () => iso(now) });
        producer.ingestJournal(input);
        assert.equal(producer.retainedEntries, 0);
      }
    }
    const cuts = readJournal(input).filter(row => row.fxSampler);
    for (const cut of cuts) {
      assert.ok(Object.keys(cut.fxSampler.days).length <= 1);
      assert.equal(JSON.stringify(cut.fxSampler).includes('attempts'), false);
      assert.notEqual(cut.fxSampler.reason, 'pending');
    }
    t.diagnostic(`trading_days=65 calls=${calls} FX_cuts=${cuts.length} capture_max_bytes_per_day=${Math.max(...growth)} producer_max_bytes_per_day=${Math.max(...producerGrowth)} capture_mean_bytes_per_day=${Math.round(growth.reduce((a, b) => a + b) / 65)}`);
  } finally { sampler.close(); capture.close(); producer.close(); }
});

for (const opening of [null, Number.MAX_VALUE, String(Number.MAX_VALUE)]) test(`IB unset opening ${String(opening)} is distinct from unusable evidence`, () => {
  assert.deepEqual(captureBrokerRealised({ realizedPNL: opening, currency: 'USD' }), { unset: true, currency: 'USD' });
  assert.equal(captureBrokerRealised({ realizedPNL: undefined, currency: 'USD' }), null);
  assert.equal(captureBrokerRealised({ realizedPNL: 0.123, currency: 'USD' }), null);
});

for (const mode of ['gross', 'fee', 'missing', 'disabled']) test(`USD ${mode} exclusion publishes other portions, stays partial and replays without duplicate reasons`, t => {
  const root = directory(), output = path.join(root, 'output.jsonl');
  const start = '2026-10-25T23:00:00.000Z', at = '2026-10-27T23:00:00.000Z';
  const sample = { rate: '0.86123457', sampleAt: '2026-10-26T20:05:00.000Z', kind: 'close' };
  const fills = [];
  for (const [currency, desk, price, fee] of [['USD', 'j', mode === 'fee' ? '12' : '12.37', mode === 'fee' ? '0.01' : '0'], ['EUR', 'joe', '12', '0']]) {
    for (const [leg, side] of [[0, 'BUY'], [1, 'SELL']]) {
      const time = `2026-10-26T${leg ? '14' : '13'}:35:00.000Z`;
      fills.push({ key: `${currency}-${leg}`, desk, scope: 'stage0', instrument: `synthetic-${currency}`, symbol: 'ACME', currency, side,
        at: time, quantity: '1', price: leg ? price : '10',
        commission: { amount: fee, currency }, brokerRealised: leg ? { amount: '2', currency } : { unset: true, currency },
        closeFx: { base: currency, quote: 'EUR', rate: '1', source: 'identity', observedAt: time } });
    }
    // A following USD round trip is exactly representable at this rate. Its
    // quantity must not consume the excluded opening again.
    if (currency === 'USD' && !['missing', 'disabled'].includes(mode)) {
      fills.push(...fills.slice(0, 2).map((fill, leg) => ({ ...fill, key: `usd-next-${leg}`, at: `2026-10-26T${leg ? '16' : '15'}:35:00.000Z`,
        price: leg ? '12' : '10', commission: { amount: '0', currency } })));
    }
  }
  const cut = { type: 'cut', at, authoritative: true, fills,
    historyCoverage: { status: 'complete', target: { fromInclusive: start, toExclusive: at }, gaps: [] },
    fxSampler: { enabled: mode !== 'disabled', reason: mode === 'disabled' ? 'disabled' : null,
      days: ['missing', 'disabled'].includes(mode) ? {} : { '2026-10-26': { samples: [sample] } } } };
  let producer = openProducer(output, { now: () => at });
  t.after(() => producer.close());
  producer.ingest([{ type: 'start', at: start }, cut]);
  const first = producer.snapshot();
  assert.equal(validateContract('results', first, { stage: 'ingress' }).ok, true);
  assert.equal(first.days[0].coverage, 'partial');
  assert.ok(first.trades.some(trade => trade.desk === 'joe' && trade.netEur.amount === '2'));
  assert.equal(first.trades.filter(trade => trade.desk === 'j').length, ['missing', 'disabled'].includes(mode) ? 0 : 1);
  const records = () => readJournal(output).filter(row => row.type === 'conversion-exclusion');
  const reasons = records();
  assert.equal(reasons.length, 1);
  assert.deepEqual(Object.keys(reasons[0].record).sort(), ['day', 'deskHash', 'kind']);
  assert.equal(reasons[0].record.kind, { gross: 'eur_gross_precision', fee: 'eur_fee_precision', missing: 'fx_unavailable', disabled: 'fx_unavailable' }[mode]);
  producer.close(); producer = openProducer(output, { now: () => at });
  assert.deepEqual(producer.snapshot().trades, first.trades);
  assert.equal(records().length, 1);
});

test('EUR-only closed days ignore failed or disabled FX, including a US holiday', t => {
  const output = path.join(directory(), 'output.jsonl'), start = '2026-06-18T22:00:00.000Z', at = '2026-06-19T22:00:00.000Z';
  const producer = openProducer(output, { now: () => at }); t.after(() => producer.close());
  const fill = { key: 'synthetic', desk: 'j', scope: 'stage0', instrument: 'synthetic', symbol: 'ACME', currency: 'EUR', side: 'BUY',
    at: '2026-06-19T10:00:00.000Z', quantity: '1', price: '10', commission: { amount: '0', currency: 'EUR' }, brokerRealised: { unset: true, currency: 'EUR' } };
  const cut = { type: 'cut', at, authoritative: true, fills: [fill],
    historyCoverage: { status: 'complete', target: { fromInclusive: start, toExclusive: at }, gaps: [] } };
  const source = [{ type: 'start', at: start }, cut];
  for (const status of [{ enabled: false, reason: 'disabled' }, { enabled: true, reason: 'quote_failed' }]) {
    source.push({ ...cut, fills: [], fxSampler: { ...status, days: {} } });
    producer.ingest(source);
    assert.equal(producer.snapshot().days[0].coverage ?? 'full', 'full');
  }
});

test('incremental source ingestion handles partial tails, restart, rewritten anchors and truncation', t => {
  const root = directory(), input = path.join(root, 'input.jsonl'), output = path.join(root, 'output.jsonl');
  const writer = openJournal(input); t.after(() => writer.close());
  writer.append({ type: 'start', at: '2026-10-26T00:00:00.000Z' });
  let producer = openProducer(output); t.after(() => producer.close());
  producer.ingestJournal(input); assert.equal(producer.sourceCount, 1);
  for (let i = 0; i < 100; i++) producer.ingestJournal(input);
  assert.equal(producer.sourceCount, 1); assert.equal(producer.retainedEntries, 0);
  writer.append({ type: 'cut', at: '2026-10-26T10:00:00.000Z', authoritative: true, fills: [] });
  producer.ingestJournal(input); assert.equal(producer.sourceCount, 2);
  producer.close(); producer = openProducer(output); producer.ingestJournal(input);
  appendFileSync(input, '{'); producer.ingestJournal(input); assert.equal(producer.sourceCount, 2);
  const bytes = readFileSync(input, 'utf8');
  writeFileSync(input, bytes.replace('10:00:00', '11:00:00'));
  assert.throws(() => producer.ingestJournal(input), /rewritten/);
  producer.close(); producer = openProducer(output);
  assert.throws(() => producer.ingestJournal(input), /corrupt/);
  writeFileSync(input, '');
  assert.throws(() => producer.ingestJournal(input), /rewritten/);
});
