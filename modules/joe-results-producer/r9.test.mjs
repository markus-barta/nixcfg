import test from 'node:test';
import assert from 'node:assert/strict';
import { appendFileSync, mkdtempSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { createFxSampler, fxSlot } from '../paper-desk-executor/fx-sampler.mjs';
import { createCapture } from './capture.mjs';
import { captureBrokerRealised } from './broker-backstop.mjs';
import { openJournal, readJournal } from './journal.mjs';
import { openProducer } from './producer.mjs';
import { validateContract } from './contracts/index.mjs';
import { PositionProofIndex } from './position-proof.mjs';

const iso = epoch => new Date(epoch).toISOString();
const directory = () => mkdtempSync(path.join(tmpdir(), 'joed20-r9-'));

test('65 trading days with 30 instruments: growth stays below 50 KB/day in both journals, one FX date per event', async t => {
  const root = directory(), input = path.join(root, 'input.jsonl'), output = path.join(root, 'output.jsonl');
  let now = Date.parse('2026-01-01T00:00:00Z'), calls = 0;
  const state = { ownershipComplete: true, executions: [], ownershipSnapshot: {
    account: 'synthetic-account', ownershipComplete: true, observedAt: iso(now),
    positions: Array.from({ length: 30 }, (_, i) => ({ conId: i + 1, symbol: `SYNTH${i}`, currency: 'EUR', position: '1' })),
  } };
  const fromInclusive = iso(now);
  const captureState = fx => {
    state.ownershipSnapshot.observedAt = iso(now);
    capture({ ...state, resultsFxSampler: fx,
      resultsHistoryCoverage: { status: 'complete', target: { fromInclusive, toExclusive: iso(now) }, gaps: [] } });
  };
  const options = { account: 'synthetic-account', attribute: () => ({}), executionTime: Date.parse, now: () => iso(now) };
  let capture = createCapture(input, {}, options);
  const sampler = createFxSampler({ root, now: () => now, request: async () => { calls++; return '0.86123457'; },
    onUpdate: captureState });
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
        captureState(sampler.snapshot());
        assert.equal(statSync(input).size, size, 'startup seeded date hashes suppress duplicate FX cuts');
        producer.close(); producer = openProducer(output, { now: () => iso(now) });
        producer.ingestJournal(input);
        assert.equal(producer.retainedEntries, 0);
      }
    }
    const cuts = readJournal(input).filter(row => row.fxSampler);
    assert.equal(readJournal(input).find(row => row.positionProof)?.positionProof.positions.length, 30);
    assert.ok(cuts.some(row => row.type === 'fx'));
    for (const cut of cuts) {
      if (cut.type === 'fx') assert.deepEqual(Object.keys(cut).sort(), ['at', 'fxSampler', 'type']);
      assert.ok(Object.keys(cut.fxSampler.days).length <= 1);
      assert.equal(JSON.stringify(cut.fxSampler).includes('attempts'), false);
      assert.notEqual(cut.fxSampler.reason, 'pending');
    }
    t.diagnostic(`instruments=30 trading_days=65 calls=${calls} FX_events=${cuts.length} capture_max_bytes_per_day=${Math.max(...growth)} producer_max_bytes_per_day=${Math.max(...producerGrowth)} capture_mean_bytes_per_day=${Math.round(growth.reduce((a, b) => a + b) / 65)} producer_mean_bytes_per_day=${Math.round(producerGrowth.reduce((a, b) => a + b) / 65)}`);
  } finally { sampler.close(); capture.close(); producer.close(); }
});

for (const opening of [undefined, null, Number.MAX_VALUE, String(Number.MAX_VALUE)]) test(`IB unset opening ${String(opening)} is distinct from unusable evidence`, () => {
  assert.deepEqual(captureBrokerRealised({ realizedPNL: opening, currency: 'USD' }), { unset: true, currency: 'USD' });
  assert.deepEqual(captureBrokerRealised({ currency: 'USD' }), { unset: true, currency: 'USD' });
  assert.deepEqual(captureBrokerRealised({ realizedPNL: 0.123, currency: 'USD' }), { amount: '0.123', src: 'sdk_number_roundtrip', currency: 'USD' });
});

for (const mode of ['missing', 'disabled']) test(`USD ${mode} exclusion publishes other portions, stays partial and replays without duplicate reasons`, t => {
  const root = directory(), output = path.join(root, 'output.jsonl');
  const start = '2026-10-25T23:00:00.000Z', at = '2026-10-27T23:00:00.000Z';
  const sample = { rate: '0.86123457', sampleAt: '2026-10-26T20:05:00.000Z', kind: 'close' };
  const fills = [];
  for (const [currency, desk, price, fee] of [['USD', 'j', '12.37', '0'], ['EUR', 'joe', '12', '0']]) {
    for (const [leg, side] of [[0, 'BUY'], [1, 'SELL']]) {
      const time = `2026-10-26T${leg ? '14' : '13'}:35:00.000Z`;
      fills.push({ key: `${currency}-${leg}`, desk, scope: 'stage0', instrument: `synthetic-${currency}`, symbol: 'ACME', currency, side,
        at: time, quantity: '1', price: leg ? price : '10',
        commission: { amount: fee, currency }, brokerRealised: leg ? { amount: '2', currency } : { unset: true, currency },
        closeFx: currency === 'USD' ? null : { base: currency, quote: 'EUR', rate: '1', source: 'identity', observedAt: time } });
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
  assert.equal(first.trades.filter(trade => trade.desk === 'j').length, 0);
  const records = () => readJournal(output).filter(row => row.type === 'conversion-exclusion');
  const reasons = records();
  assert.equal(reasons.length, 1);
  assert.deepEqual(Object.keys(reasons[0].record).sort(), ['day', 'deskHash', 'kind']);
  assert.equal(reasons[0].record.kind, 'fx_missing');
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

test('FX-only events preserve real authority on restart and add no position proof; round-9 replay ignores them', async t => {
  const root = directory(), input = path.join(root, 'input.jsonl');
  let at = '2026-10-26T12:00:00.000Z';
  const state = { ownershipComplete: true, executions: [], ownershipSnapshot: {
    account: 'synthetic-account', ownershipComplete: true, observedAt: at, positions: [],
  } };
  const options = { account: 'synthetic-account', attribute: () => ({}), executionTime: Date.parse, now: () => at };
  let capture = createCapture(input, {}, options);
  t.after(() => capture.close());
  capture(state);
  at = '2026-10-26T13:00:00.000Z';
  const fx = { enabled: true, reason: 'pending', days: {} };
  capture({ ...state, resultsFxSampler: fx });
  let source = readJournal(input);
  assert.equal(source.at(-1).type, 'fx');
  assert.equal(source.at(-1).fxSampler.reason, 'missing_sample');
  const size = statSync(input).size;
  capture.close(); capture = createCapture(input, {}, options);
  capture({ ...state, resultsFxSampler: fx });
  assert.equal(statSync(input).size, size, 'lastAuthority came from the last real cut');
  const producer = openProducer(path.join(root, 'new.jsonl'), { now: () => at });
  t.after(() => producer.close());
  let proofs = 0;
  const add = PositionProofIndex.prototype.add;
  PositionProofIndex.prototype.add = function(proof) { proofs++; return add.call(this, proof); };
  try { producer.ingest(source); } finally { PositionProofIndex.prototype.add = add; }
  assert.equal(proofs, 1);
  const baseline = producer.snapshot();
  // Frozen producer from 91b9198b, including its original apply implementation.
  // Resolve sibling dependencies against this module, independently of cwd/git.
  const frozen = readFileSync(new URL('./fixtures/round9-producer.mjs', import.meta.url), 'utf8');
  assert.equal(createHash('sha256').update(frozen).digest('hex'), '1c7bd5a1da1073441a9e8c50bd3de8b5ded97f38d2b952aa664a218e3f55f84f');
  const oldSource = frozen
    .replace(/from '(\.\/[^']+)'/g, (_, name) => `from '${new URL(name, import.meta.url).href}'`);
  const { openProducer: oldProducer } = await import(`data:text/javascript;base64,${Buffer.from(oldSource).toString('base64')}`);
  const old = oldProducer(path.join(root, 'old.jsonl'), { now: () => at });
  t.after(() => old.close());
  old.ingest(source);
  assert.deepEqual(old.snapshot(), baseline);
});

test('legacy USD execution-local FX survives absent sampler data and stays bounded to 60 seconds', t => {
  const root = directory(), end = '2026-10-27T23:00:00.000Z', start = '2026-10-25T23:00:00.000Z';
  const closeAt = '2026-10-26T14:35:00.000Z';
  const account = 'synthetic-account', config = { executorClientId: 705, foreignAlertSince: start };
  const executions = ['BUY', 'SELL'].map((side, i) => ({
    contract: { conId: 1, symbol: 'ACME', currency: 'USD' }, execution: { execId: `synthetic-${i}.01`,
      acctNumber: account, clientId: 705, time: i ? closeAt : '2026-10-26T13:35:00.000Z', side, shares: '1', price: i ? '12' : '10' },
  }));
  for (const stale of [false, true]) {
    let at = start;
    const input = path.join(root, `legacy-input-${stale}.jsonl`);
    const capture = createCapture(input, config, { account, attribute: () => ({ desk: 'j', method: 'admin' }), executionTime: Date.parse, now: () => at });
    t.after(() => capture.close());
    capture({ ownershipComplete: true, executions: [] });
    at = end;
    capture({ ownershipComplete: true, executions,
      commissions: executions.map((row, i) => ({ execId: row.execution.execId, commission: '0', currency: 'USD', realizedPNL: i ? '2' : undefined })),
      resultsFx: { USD: { base: 'USD', quote: 'EUR', rate: '0.9', source: 'synthetic-existing-rate', observedAt: iso(Date.parse(closeAt) - (stale ? 60_001 : 60_000)) } },
      resultsHistoryCoverage: { status: 'complete', target: { fromInclusive: start, toExclusive: at }, gaps: [] },
      resultsFxSampler: { enabled: true, reason: 'missing_sample', days: {} } });
    const producer = openProducer(path.join(root, `legacy-${stale}.jsonl`), { now: () => at });
    t.after(() => producer.close());
    producer.ingestJournal(input);
    const result = producer.snapshot();
    assert.equal(result.trades.length, stale ? 0 : 1);
    if (!stale) assert.equal(result.trades[0].netEur.amount, '1.8');
    assert.equal(result.days[0].coverage, 'partial');
  }
});

test('health journals only changed values across restart while each snapshot reserves a sequence', t => {
  const output = path.join(directory(), 'output.jsonl');
  let at = '2026-10-26T12:00:00.000Z';
  let producer = openProducer(output, { now: () => at });
  t.after(() => producer.close());
  producer.ingest([{ type: 'start', at }, { type: 'cut', at, authoritative: true, fills: [] }]);
  const health = { status: 'ok', halt: { active: false }, gatewayReachable: true,
    brakes: { placementBlockedOnInitDay: false, newPerDay: 1, notionalEur: 1 } };
  for (let i = 0; i < 5; i++) {
    at = iso(Date.parse(at) + 25_000);
    assert.equal(producer.health(health).checkedAt, at);
    assert.equal(producer.latestHealth.checkedAt, at);
    assert.equal(producer.snapshot().seq, i + 1);
  }
  assert.equal(readJournal(output).filter(row => row.type === 'health').length, 1);
  producer.close(); producer = openProducer(output, { now: () => at });
  producer.health(health);
  assert.equal(readJournal(output).filter(row => row.type === 'health').length, 1);
  producer.health({ ...health, gatewayReachable: false });
  assert.equal(readJournal(output).filter(row => row.type === 'health').length, 2);
  assert.equal(producer.latestHealth.status, 'degraded');
  assert.equal(producer.snapshot().seq, 6);
  assert.equal(readJournal(output).filter(row => row.type === 'sequence').length, 6);
});
