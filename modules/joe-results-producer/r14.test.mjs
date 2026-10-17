import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { roundTrips } from './fifo.mjs';
import { createCapture } from './capture.mjs';
import { openProducer } from './producer.mjs';
import { readJournal } from './journal.mjs';
import { decimalUnits } from './contracts/decimal.mjs';
import { validateContract } from './contracts/index.mjs';
import { validateResults, historyGaps, withFillGaps } from './results-validation.mjs';
import { httpTransport } from './transport.mjs';
import { consumerDayNote, consumerPartialReasons, PARTIAL_REASON } from './consumer-note.mjs';

const start = '2026-10-15T22:00:00.000Z', at = '2026-10-16T18:00:00.000Z';
const instant = (day, hour = '10') => `2026-10-${day}T${hour}:00:00.000Z`;
const history = through => ({ status: 'complete', target: { fromInclusive: start, toExclusive: through }, gaps: [] });
function directory(t) {
  const root = fileURLToPath(new URL('../../tests/.tmp/', import.meta.url));
  mkdirSync(root, { recursive: true });
  const dir = mkdtempSync(path.join(root, 'joed20-r14-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}
function fill(key, side, time, quantity = '1', fee = '0', rate = '1') {
  return { key, desk: 'j', instrument: 'synthetic-acme', symbol: 'ACME', scope: 'stage0', side, at: time,
    currency: 'EUR', quantity, price: '10', commission: { amount: fee, currency: 'EUR' },
    brokerRealised: side === 'BUY' ? { unset: true, currency: 'EUR' } : { amount: '0', currency: 'EUR' },
    closeFx: { base: 'EUR', quote: 'EUR', rate, source: 'identity', observedAt: time } };
}
function snapshot(t, { from = start, through = at, historyEnd = new Date(Date.parse(through) - 600_000).toISOString(), fills = [fill('open', 'BUY', instant('16'))], extra = {} } = {}) {
  const p = openProducer(path.join(directory(t), 'producer.jsonl'), { now: () => through });
  t.after(() => p.close());
  p.ingest([{ type: 'start', at: from }, { type: 'cut', at: new Date(Date.parse(through) - 1).toISOString(), authoritative: true, fills, historyCoverage: history(historyEnd), ...extra }]);
  return p.snapshot();
}

test('open Vienna day with no cause has no reasons; rev 6 validator accepts it', t => {
  const value = snapshot(t);
  assert.equal(value.days[0].coverage, 'partial');
  assert.equal(Object.hasOwn(value.days[0], 'partialReasons'), false);
  assert.equal(validateResults(value, { requirePartialReasons: true }).ok, true);
  assert.equal(validateContract('results', value, { stage: 'ingress', receivedAt: at }).ok, true);
});

test('open Vienna day with missing close FX has only fx_missing', t => {
  const fills = [fill('open', 'BUY', instant('16')), fill('close', 'SELL', instant('16', '11'))]
    .map(f => ({ ...f, currency: 'USD', commission: { amount: '0', currency: 'USD' }, closeFx: null }));
  const value = snapshot(t, { fills });
  assert.deepEqual(value.days[0].partialReasons, ['fx_missing']);
  assert.equal(validateResults(value, { requirePartialReasons: true }).ok, true);
});

test('reasonless yesterday fails locally without an explicit receipt option, exactly like the board', async t => {
  const value = snapshot(t);
  value.generatedAt = '2026-10-16T22:00:00.000Z'; // Vienna next day, still the same UTC date
  const board = validateContract('results', value, { stage: 'ingress', receivedAt: value.generatedAt });
  assert.equal(validateContract('results', value, { stage: 'ingress' }).ok, true); // raw API pitfall
  for (const options of [{}, { requirePartialReasons: true }]) {
    assert.deepEqual(validateResults(value, options), board);
  }
  assert.deepEqual(board.errors, [{ path: '$.days[0].partialReasons', rule: 'partialReasonsRequired' }]);
  let requests = 0;
  const transport = httpTransport('https://board.example.invalid/joe/inbox/results', {
    origin: 'https://board.example.invalid', headers: () => ({ authorization: 'Bearer synthetic-token' }),
    fetchImpl: async () => { requests++; return new Response('{}'); },
  });
  await assert.rejects(transport.send(value), error => {
    assert.deepEqual(error.errors, board.errors); return error.status === 422;
  });
  assert.equal(requests, 0);
  assert.equal(validateResults(value, { receivedAt: null }).status, 422);
});

test('real mid-day tracking start emits capture_gap only', t => {
  const value = snapshot(t, { from: instant('16', '09') });
  assert.deepEqual(value.days[0].partialReasons, ['capture_gap']);
});

test('open-day board rule shows no note without a cause and shows FX when present', t => {
  const day = snapshot(t).days[0], today = '2026-10-16';
  assert.deepEqual(consumerPartialReasons(day), []);
  assert.equal(consumerDayNote(day, today), '');
  const fxDay = { ...day, partialReasons: ['fx_missing'] };
  assert.equal(consumerPartialReasons(fxDay)[0].label, 'FX missing');
  assert.equal(consumerDayNote(fxDay, today), '');
  assert.equal(consumerDayNote(day, '2026-10-17'), PARTIAL_REASON);
  assert.equal(consumerDayNote(day, '2026-10-17', { note: 'synthetic-warning' }), 'synthetic-warning');
  assert.equal(consumerDayNote(fxDay, '2026-10-17'), '');
  assert.deepEqual(consumerPartialReasons({ partialReasons: ['fx_missing', 'fx_disabled', 'future_code'] }),
    [{ code: 'fx_disabled', label: 'FX sampling off' }]);
});

const usd = f => ({ ...f, currency: 'USD', commission: { ...f.commission, currency: 'USD' }, closeFx: { ...f.closeFx, base: 'USD', source: 'synthetic' } });
test('USD allocation stays rational until the combined fee rounds once', () => {
  const fills = [fill('open', 'BUY', instant('15'), '3', '0.00000001'),
    fill('pre-tracking', 'SELL', instant('15', '11'), '2'), fill('other-lot', 'BUY', instant('15', '12'), '2'),
    fill('close', 'SELL', instant('16'), '3', '0.00000001')].map(usd);
  const trades = roundTrips(fills, start, []);
  // First portion: 1/3 opening unit + 1/3 closing unit => 2/3, rounded to 1.
  // Rounding either USD share first would lose both of them.
  assert.deepEqual(trades.map(row => row.feesEur.amount), ['0.00000001', '0.00000001']);
});

test('multi-portion USD fee sums exactly to its rounded EUR total', () => {
  const fills = [fill('open', 'BUY', instant('16'), '7', '3', '0.5'),
    fill('close3', 'SELL', instant('16', '11'), '3', '0', '0.5'),
    fill('close4', 'SELL', instant('16', '12'), '4', '0', '0.5')].map(usd);
  const trades = roundTrips(fills, start, []);
  assert.deepEqual(trades.map(row => row.feesEur.amount), ['0.64285714', '0.85714286']);
  assert.equal(trades.reduce((sum, row) => sum + decimalUnits(row.feesEur.amount), 0n), decimalUnits('1.5'));
});

function captureFixture(t, through = '2026-10-18T22:00:00.000Z') {
  const dir = directory(t), input = path.join(dir, 'capture.jsonl');
  let now = start;
  const capture = createCapture(input, { executorClientId: 705, foreignAlertSince: start }, {
    now: () => now, account: 'synthetic-account', executionTime: Date.parse,
    attribute: row => row.unknown ? { needsAttribution: true } : { desk: 'j', method: 'admin' },
  });
  t.after(() => capture.close());
  capture({ ownershipComplete: true, executions: [] }); now = through;
  const state = { ownershipComplete: true, executions: [], commissions: [], resultsHistoryCoverage: history(through) };
  let producer = openProducer(path.join(dir, 'producer.jsonl'), { now: () => through });
  t.after(() => producer.close());
  return { state, input, capture, refresh() { state.commissions = state.executions.map(row => ({ execId: row.execution.execId, commission: '0', currency: row.contract.currency, realizedPNL: Number.MAX_VALUE })); capture(state); producer.ingest(readJournal(input)); return producer.snapshot(); },
    replay() { producer.close(); producer = openProducer(path.join(dir, 'producer.jsonl'), { now: () => through }); return producer.snapshot(); } };
}
const raw = (id, day, extra = {}) => ({ contract: { conId: 1, symbol: 'ACME', currency: 'EUR' },
  execution: { execId: `synthetic-${id}.01`, acctNumber: 'synthetic-account', clientId: 705,
    time: instant(day), side: 'BUY', shares: '1', price: '10', ...extra } });

for (const refused of [false, true]) test(`${refused ? 'refused' : 'unattributed'} fill has only its own reason; later unproven day retains history_gap`, t => {
  const f = captureFixture(t), bad = raw('gap', '16', refused ? { price: 1e-7 } : {});
  if (!refused) bad.unknown = true;
  f.state.executions = [bad, raw('later', '17')];
  const value = f.refresh(), own = value.days.find(day => day.date === '2026-10-16');
  assert.deepEqual(own.partialReasons, [refused ? 'capture_gap' : 'unattributed_activity']);
  assert.equal(own.unattributedCount, refused ? undefined : 1);
  assert.deepEqual(value.days.find(day => day.date === '2026-10-17').partialReasons, ['history_gap']);
  const cut = readJournal(f.input).at(-1);
  assert.deepEqual(cut.historyGaps, []);
  assert.equal(cut.historyCoverage.status, 'known');
  assert.deepEqual(cut.historyCoverage.gaps, cut.fillGaps.map(({ fromInclusive, toExclusive }) => ({ fromInclusive, toExclusive })));
  assert.equal(historyGaps(cut.historyCoverage, cut.at).length, 1, 'older readers still see the coverage omission');
  assert.deepEqual(Object.keys(cut.fillGaps[0]).sort(), ['fromInclusive', 'kind', 'toExclusive']);
  assert.equal(Date.parse(cut.fillGaps[0].toExclusive) - Date.parse(cut.fillGaps[0].fromInclusive), 1);
  assert.deepEqual(f.replay().days, value.days);
});

test('a real history gap on an unattributed fill day keeps both real reasons', t => {
  const f = captureFixture(t), row = raw('gap', '16'); row.unknown = true;
  f.state.executions = [row];
  f.state.resultsHistoryCoverage.status = 'known';
  f.state.resultsHistoryCoverage.gaps = [{ fromInclusive: instant('16', '08'), toExclusive: instant('16', '09') }];
  assert.deepEqual(f.refresh().days[0].partialReasons, ['history_gap', 'unattributed_activity']);
});

for (const field of ['sample.rate', 'closeFx.rate']) test(`refused ${field} maps to fx_missing with value-free capture evidence`, t => {
  const f = captureFixture(t), row = raw('fx', '16'); row.contract.currency = 'USD';
  f.state.executions = [row];
  if (field === 'sample.rate') f.state.resultsFxSampler = { enabled: true, days: { '2026-10-16': {
    samples: [{ rate: 1e-7, sampleAt: instant('16'), kind: 'rth' }],
  } } };
  else f.state.resultsFx = { USD: { rate: 1e-7, base: 'USD', quote: 'EUR', observedAt: instant('16'), source: 'synthetic' } };
  const value = f.refresh(), cut = readJournal(f.input).findLast(row => row.type === 'cut');
  const issue = cut.captureIssues.find(issue => issue.field === field);
  assert.equal(issue.kind, 'broker_evidence_missing', 'journal kind stays readable by round-12b/13 producers');
  assert.deepEqual(Object.keys(issue).sort(), ['day', 'deskHash', 'field', 'id', 'kind', 'refused']);
  assert.deepEqual(value.days[0].partialReasons, ['fx_missing']);
});

for (const status of ['complete', 'unknown']) test(`fill gaps cannot promote invalid ${status} history proof to known`, () => {
  const bad = { ...history(at), status, gaps: [{ fromInclusive: instant('16'), toExclusive: instant('16', '11') }] };
  const gap = { fromInclusive: instant('16', '12'), toExclusive: new Date(Date.parse(instant('16', '12')) + 1).toISOString(), kind: 'capture_gap' };
  assert.equal(historyGaps(withFillGaps(bad, [gap]), at), null);
});

test('EUR commission budget on a USD fill still takes its EUR remainder without FX conversion', () => {
  const fills = [fill('open', 'BUY', instant('16'), '7', '3', '0.5'),
    fill('close3', 'SELL', instant('16', '11'), '3', '0', '0.5'),
    fill('close4', 'SELL', instant('16', '12'), '4', '0', '0.5')].map(f => ({ ...usd(f), commission: f.commission }));
  assert.deepEqual(roundTrips(fills, start, []).map(row => row.feesEur.amount), ['1.28571429', '1.71428571']);
});
