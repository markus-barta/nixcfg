import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createCapture } from './capture.mjs';
import { readJournal } from './journal.mjs';
import { openProducer } from './producer.mjs';
import { dayFx, fxDayPartial, isSampleFx } from './fx.mjs';
import { brokerDayTotals } from './broker-backstop.mjs';
import { validateResults } from './results-validation.mjs';

const rth = { rate: '0.90000000', sampleAt: '2026-10-26T13:30:00.000Z', kind: 'rth' };
const close = { rate: '0.80000000', sampleAt: '2026-10-26T20:05:00.000Z', kind: 'close' };
const status = { enabled: true, reason: null };

for (const [source, prefix] of [[undefined, 'ib-fx'], ['ib-account-exchange-rate', 'ib-account-fx']]) test(`sample provenance ${prefix}: close and RTH sources, observation time and freshness are preserved`, () => {
  for (const sample of [rth, close]) {
    const tagged = { ...sample, ...(source ? { source } : {}) };
    const fx = dayFx({ samples: [tagged] }, '2026-10-26', sample.sampleAt);
    assert.deepEqual(fx, { base: 'USD', quote: 'EUR', rate: sample.rate, source: `${prefix}-${sample.kind}`, observedAt: sample.sampleAt });
    assert.equal(isSampleFx(fx, '2026-10-26'), true);
    assert.equal(isSampleFx(fx, '2026-10-27'), false);
    assert.equal(isSampleFx({ ...fx, observedAt: '2026-10-26T12:00:00.000Z' }, '2026-10-26'), false);
    assert.equal(dayFx({ samples: [tagged] }, '2026-10-27', '2026-10-27T22:00:00.000Z'), null);
  }
  const tagged = { ...rth, ...(source ? { source } : {}) };
  assert.equal(dayFx({ samples: [tagged] }, '2026-10-26', '2026-10-26T14:00:00.000Z').source, `${prefix}-rth`);
  assert.equal(dayFx({ samples: [tagged] }, '2026-10-26', '2026-10-26T14:00:00.001Z'), null);
  assert.equal(fxDayPartial({ samples: [tagged] }, '2026-10-26', status, '2026-10-26T14:00:00.001Z'), true);
});

test('unknown sample provenance and lookalike FX source names fail closed', () => {
  for (const source of ['unknown', null, 'ib-fx-close']) {
    assert.equal(dayFx({ samples: [{ ...close, source }] }, '2026-10-26', close.sampleAt), null);
  }
  for (const source of ['unknown', 'ib-account-exchange-rate', 'ib-account-fx-close-extra', 'ib-fx-rth-extra']) {
    assert.equal(isSampleFx({ rate: close.rate, observedAt: close.sampleAt, source }, '2026-10-26'), false);
  }
});

test('account-rate capture converts every USD round trip with the daily close; RTH expires and missing samples retain fx_missing', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'joed63-fx-producer-'));
  const input = path.join(dir, 'capture.jsonl'), output = path.join(dir, 'producer.jsonl');
  let at = '2026-10-26T13:30:00.000Z';
  const options = { account: 'synthetic-account', attribute: () => ({ desk: 'j', method: 'admin' }), executionTime: Date.parse, now: () => at };
  const capture = createCapture(input, { executorClientId: 705, foreignAlertSince: '2026-10-25T00:00:00.000Z' }, options);
  const fill = (id, side, time, price) => ({ contract: { conId: 123, symbol: 'ACME', currency: 'USD' }, execution: {
    execId: `${id}.01`, acctNumber: options.account, clientId: 705, shares: '1', price, side, time,
  } });
  const state = { ownershipComplete: true, executions: [], commissions: [], resultsFxSampler: { ...status, days: { '2026-10-26': { samples: [] } } } };
  const producer = openProducer(output, { now: () => at });
  const publish = () => { capture(state); producer.ingest(readJournal(input)); return producer.snapshot(); };
  const commissions = () => { state.commissions = state.executions.map(row => ({ execId: row.execution.execId, commission: '0', currency: 'USD',
    realizedPNL: row.execution.side === 'SLD' ? '2' : Number.MAX_VALUE })); };
  try {
    publish();
    at = '2026-10-26T14:00:00.000Z';
    state.executions = [fill('open-a', 'BOT', '2026-10-26T13:35:00.000Z', '10'), fill('close-a', 'SLD', '2026-10-26T13:45:00.000Z', '12'),
      fill('open-b', 'BOT', '2026-10-26T13:50:00.000Z', '10'), fill('close-b', 'SLD', at, '12')];
    commissions();
    const missing = publish();
    assert.equal(missing.trades.length, 0);
    assert.ok(missing.days[0].partialReasons.includes('fx_missing'));
    assert.ok(readJournal(output).some(row => row.type === 'conversion-exclusion' && row.record.kind === 'fx_missing'));
    state.resultsFxSampler.days['2026-10-26'].samples = [{ ...rth, source: 'ib-account-exchange-rate' }];
    const intraday = publish();
    assert.equal(intraday.trades.length, 2);
    assert.ok(intraday.trades.every(trade => trade.fx.source === 'ib-account-fx-rth' && trade.fx.observedAt === rth.sampleAt && trade.netEur.amount === '1.8'));
    at = '2026-10-26T14:00:00.001Z';
    const stale = producer.snapshot();
    assert.equal(stale.trades.length, 0);
    assert.ok(stale.days[0].partialReasons.includes('fx_missing'));
    at = '2026-10-26T19:45:00.000Z';
    state.executions.push(fill('open-c', 'BOT', '2026-10-26T19:30:00.000Z', '10'), fill('close-c', 'SLD', at, '12'));
    commissions(); publish();
    at = close.sampleAt;
    state.resultsFxSampler.days['2026-10-26'].samples.push({ ...close, source: 'ib-account-exchange-rate' });
    const frozen = publish();
    assert.equal(frozen.trades.length, 3);
    assert.ok(frozen.trades.every(trade => trade.fx.source === 'ib-account-fx-close' && trade.fx.observedAt === close.sampleAt && trade.netEur.amount === '1.6'));
    assert.equal(validateResults(frozen).ok, true);
    const captured = readJournal(input).flatMap(row => row.fxSampler?.days['2026-10-26']?.samples || []);
    assert.ok(captured.length >= 2);
    assert.ok(captured.every(sample => sample.source === 'ib-account-exchange-rate'));
    const converted = { currency: 'USD', closeFx: frozen.trades[0].fx, commission: { amount: '0', currency: 'USD' },
      brokerRealised: { amount: '2', currency: 'USD' }, desk: 'j', instrument: 'synthetic', at: '2026-10-26T14:00:00.000Z', side: 'SELL', quantity: '1', key: 'close' };
    assert.equal(brokerDayTotals([converted], rth.sampleAt).get('2026-10-26:j').complete, true);
    at = '2026-10-27T14:00:00.000Z';
    assert.deepEqual(producer.snapshot().trades, frozen.trades);
  } finally { producer.close(); capture.close(); }
  const replay = openProducer(output, { now: () => at });
  try { assert.ok(replay.snapshot().trades.every(trade => trade.fx.source === 'ib-account-fx-close')); }
  finally { replay.close(); }
});

for (const [name, value, metadata] of [
  ['stale account-rate rth flags', { ...rth, sampleAt: '2026-10-26T14:00:00.000Z' }, { staleFx: true, staleSeconds: 1800 }],
  ['stale account-rate close flags', close, { staleFx: true, staleSeconds: 11100 }],
  ['raw account-rate rth metadata', { ...rth, sampleAt: '2026-10-26T14:00:00.000Z' }, { ibRate: '0.900000001' }],
  ['raw account-rate off-session close metadata', { ...close, sampleAt: '2026-11-27T21:05:00.000Z' },
    { ibRate: '0.800000001', session: 'off', staleFx: true, staleSeconds: 23700 }],
]) test(`${name} survive both journals and replay without changing conversion`, () => {
  const sample = { ...value, source: 'ib-account-exchange-rate' }, { kind } = sample;
  const date = sample.sampleAt.slice(0, 10), hour = date === '2026-11-27' ? '14' : '13';
  const run = taggedMetadata => {
    const dir = mkdtempSync(path.join(tmpdir(), 'joed63-stale-producer-'));
    const input = path.join(dir, 'capture.jsonl'), output = path.join(dir, 'producer.jsonl');
    let at = `${date}T${hour}:30:00.000Z`;
    const options = { account: 'synthetic-account', attribute: () => ({ desk: 'j', method: 'admin' }), executionTime: Date.parse, now: () => at };
    const capture = createCapture(input, { executorClientId: 705 }, options);
    const producer = openProducer(output, { now: () => at });
    const state = { ownershipComplete: true, executions: [], commissions: [] };
    let result;
    try {
      capture(state);
      at = sample.sampleAt;
      state.executions = ['BOT', 'SLD'].map((side, i) => ({ contract: { conId: 123, symbol: 'ACME', currency: 'USD' }, execution: {
        execId: `synthetic-${i}.01`, acctNumber: options.account, clientId: 705, shares: '1', price: i ? '12' : '10', side,
        time: `${date}T${hour}:${i ? '45' : '35'}:00.000Z`,
      } }));
      state.commissions = state.executions.map((row, i) => ({ execId: row.execution.execId, commission: '0', currency: 'USD', realizedPNL: i ? '2' : Number.MAX_VALUE }));
      const tagged = { ...sample, ...(taggedMetadata ? metadata : {}) };
      state.resultsFxSampler = { ...status, days: { [date]: { samples: [tagged] } } };
      capture(state); producer.ingest(readJournal(input));
      result = producer.snapshot();
      assert.equal(result.trades.length, 1);
      assert.equal(result.trades[0].netEur.amount, kind === 'rth' ? '1.8' : '1.6');
      assert.equal(result.trades[0].fx.source, `ib-account-fx-${kind}`);
      assert.equal(result.trades[0].fx.rate, sample.rate);
      assert.equal(isSampleFx(result.trades[0].fx, date), true);
      assert.equal(validateResults(result).ok, true);
      assert.deepEqual(readJournal(input).flatMap(row => row.fxSampler?.days[date]?.samples || []), [tagged]);
      assert.deepEqual(readJournal(output).flatMap(row => row.entry?.fxSampler?.days[date]?.samples || []), [tagged]);
      assert.deepEqual(dayFx({ samples: [tagged] }, date, at), dayFx({ samples: [sample] }, date, at));
      assert.equal(fxDayPartial({ samples: [tagged] }, date, status, at), false);
    } finally { producer.close(); capture.close(); }
    const replay = openProducer(output, { now: () => at });
    try { assert.deepEqual(replay.snapshot().trades, result.trades); }
    finally { replay.close(); }
    return result;
  };
  assert.deepEqual(run(true), run(false));
});

test('open day becomes partial after 30 RTH minutes, when off or failing; only same-day fixed close freezes it', () => {
  const day = { samples: [rth] };
  assert.equal(fxDayPartial(day, '2026-10-26', status, '2026-10-26T14:00:00.000Z'), false);
  assert.equal(fxDayPartial(day, '2026-10-26', status, '2026-10-26T14:00:00.001Z'), true);
  assert.equal(dayFx(day, '2026-10-26', '2026-10-26T14:00:00.000Z').rate, rth.rate);
  assert.equal(dayFx(day, '2026-10-26', '2026-10-26T14:00:00.001Z'), null);
  assert.equal(dayFx(day, '2026-10-26', '2026-10-27T13:30:00.000Z'), null);
  assert.equal(fxDayPartial(day, '2026-10-26', { enabled: false }, rth.sampleAt), true);
  assert.equal(fxDayPartial(day, '2026-10-26', { enabled: true, reason: 'pacing_rejected' }, rth.sampleAt), true);
  assert.equal(fxDayPartial(day, '2026-10-26', status, '2026-10-26T20:06:00.000Z'), true);
  assert.equal(fxDayPartial(day, '2026-10-26', status, '2026-10-27T13:30:00.000Z'), true);
  assert.equal(dayFx({ samples: [close] }, '2026-10-26', rth.sampleAt), null);
  assert.equal(dayFx({ samples: [close] }, '2026-10-27', '2026-10-27T22:00:00.000Z'), null);
  assert.equal(dayFx({ samples: [{ ...close, sampleAt: '2026-10-26T21:05:00.000Z' }] }, '2026-10-26', '2026-10-26T22:00:00.000Z'), null);
  day.samples.push(close);
  assert.equal(fxDayPartial(day, '2026-10-26', { enabled: false }, close.sampleAt), true);
  assert.equal(fxDayPartial(day, '2026-10-26', { enabled: false }, '2026-10-27T22:00:00.000Z'), false);
  assert.equal(dayFx(day, '2026-10-26', '2026-10-27T22:00:00.000Z').rate, close.rate);
});

test('capture exposes samples and failures without raw IDs; producer uses frozen daily close across pruning and replay', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'joed20-fx-producer-'));
  const input = path.join(dir, 'capture.jsonl'), output = path.join(dir, 'producer.jsonl');
  let at = '2026-10-26T13:30:00.000Z';
  const options = { account: 'synthetic-account', attribute: () => ({ desk: 'j', method: 'admin' }), executionTime: Date.parse, now: () => at };
  const config = { executorClientId: 705, foreignAlertSince: '2026-10-25T00:00:00.000Z' };
  let capture = createCapture(input, config, options);
  const fill = (id, side, time, price) => ({ contract: { conId: 123, symbol: 'ACME', currency: 'USD' }, execution: { execId: `${id}.01`, acctNumber: options.account, clientId: 705, shares: '1', price, side, time } });
  const state = { ownershipComplete: true, executions: [], commissions: [], resultsFxSampler: { ...status, days: { '2026-10-26': { samples: [rth], attempts: { 0: { at: rth.sampleAt, reason: 'ok' } } } } } };
  capture(state);
  at = '2026-10-26T14:00:00.000Z';
  state.executions = [fill('synthetic-open', 'BOT', '2026-10-26T13:35:00.000Z', '10'), fill('synthetic-close', 'SLD', '2026-10-26T14:00:00.000Z', '12')];
  state.commissions = state.executions.map(row => ({ execId: row.execution.execId, commission: '0', currency: 'USD', realizedPNL: row.execution.side === 'SLD' ? '2' : Number.MAX_VALUE }));
  capture(state);
  let producer = openProducer(output, { now: () => at });
  producer.ingest(readJournal(input));
  assert.equal(producer.snapshot().trades[0].fx.source, 'ib-fx-rth');
  state.resultsFxSampler.enabled = false;
  capture(state); producer.ingest(readJournal(input));
  assert.equal(producer.snapshot().days[0].coverage, 'partial');
  state.resultsFxSampler.enabled = true;
  state.resultsFxSampler.days['2026-10-26'].samples.push(close);
  at = close.sampleAt; capture(state); producer.ingest(readJournal(input));
  const frozen = producer.snapshot();
  assert.equal(frozen.trades[0].fx.rate, close.rate);
  assert.equal(frozen.trades[0].fx.observedAt, close.sampleAt);
  assert.equal(frozen.trades[0].netEur.amount, '1.6');
  const converted = { currency: 'USD', closeFx: frozen.trades[0].fx, commission: { amount: '0', currency: 'USD' }, brokerRealised: { amount: '2', currency: 'USD' }, desk: 'j', instrument: 'synthetic', at: '2026-10-26T14:00:00.000Z', side: 'SELL', quantity: '1', key: 'close' };
  assert.equal(brokerDayTotals([converted], rth.sampleAt).get('2026-10-26:j').complete, true);
  state.resultsFxSampler.days['2026-10-26'].samples = [{ ...close, rate: '0.60000000' }];
  capture(state); producer.ingest(readJournal(input));
  assert.equal(producer.snapshot().trades[0].fx.rate, close.rate, 'first fixed close stays frozen even if a later cut differs');
  producer.close(); capture.close();
  // After sidecar retention and executor execution pruning, the producer keeps
  // the captured frozen rate; it never borrows the new day's quote.
  at = '2026-11-16T15:00:00.000Z';
  state.executions = []; state.commissions = [];
  state.resultsFxSampler.days = { '2026-11-16': { samples: [{ ...rth, rate: '0.70000000', sampleAt: at }] } };
  capture = createCapture(input, config, options); capture(state); capture.close();
  producer = openProducer(output, { now: () => at }); producer.ingest(readJournal(input));
  assert.deepEqual(producer.snapshot().trades, frozen.trades);
  const bytes = JSON.stringify(readJournal(input));
  for (const forbidden of ['synthetic-account', 'synthetic-open', 'synthetic-close', 'acctNumber', 'execId', 'clientId']) assert.equal(bytes.includes(forbidden), false);
  producer.close();
});
