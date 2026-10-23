import "../../tests/paper-desk-account-fixture.mjs";
import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createFxSampler, requestFxSnapshot, fxSlot, FX_RETENTION_DAYS } from './fx-sampler.mjs';
import { createResultsSampler } from './server.mjs';
import { ACCOUNT } from './policy.mjs';

const root = () => mkdtempSync(path.join(tmpdir(), 'joed20-fx-'));
const iso = time => new Date(time).toISOString();

test('Results-off has no sampler or ledger reads; bad ID JSON and client conflicts disable only the sampler', async () => {
  assert.equal(createResultsSampler({ ledger: { load() { assert.fail('Results off read ledger'); } } }), undefined);
  const prior = process.env.IB_DESK_CLIENT_IDS;
  try {
    for (const [value, reason] of [['{', 'fx_config_invalid'], ['null', 'fx_config_invalid'], ['[]', 'fx_config_invalid'], ['{"executor":709}', 'fx_client_conflict']]) {
      process.env.IB_DESK_CLIENT_IDS = value;
      const updates = [];
      const sampler = createResultsSampler({ root: root(), now: () => Date.parse('2026-10-26T13:30:00Z'),
        request: () => assert.fail('disabled sampler made request'),
        ledger: { load(options) { assert.deepEqual(options, { initialize: false, readOnly: true }); return {}; } },
        capture: state => updates.push(state.resultsFxSampler) });
      try {
        await sampler.tick(); await sampler.tick();
        assert.equal(sampler.snapshot().enabled, false);
        assert.equal(sampler.snapshot().reason, reason);
        assert.equal(updates.length, 1);
      } finally { sampler.close(); }
    }
  } finally {
    if (prior === undefined) delete process.env.IB_DESK_CLIENT_IDS; else process.env.IB_DESK_CLIENT_IDS = prior;
  }
});

test('a pending quote does not publish attempts or transient partial status', async () => {
  let now = Date.parse('2026-10-26T13:30:00Z'), resolve;
  const updates = [];
  const sampler = createFxSampler({ root: root(), now: () => now, onUpdate: value => updates.push(value),
    request: () => new Promise(done => { resolve = done; }) });
  try {
    let tick = sampler.tick();
    while (!resolve) await new Promise(done => setTimeout(done, 1));
    resolve('0.90000000'); await tick;
    now += 15 * 60_000; resolve = null;
    const previous = updates.length;
    tick = sampler.tick();
    while (!resolve) await new Promise(done => setTimeout(done, 1));
    assert.equal(updates.length, previous);
    assert.equal(sampler.snapshot().reason, null);
    assert.equal(JSON.stringify(sampler.snapshot()).includes('attempts'), false);
    resolve('0.90000000'); await tick;
    assert.equal(updates.length, previous + 1);
    assert.ok(updates.every(value => value.reason !== 'pending'));
  } finally { sampler.close(); }
});

test('invalid configuration notifies only once even when ledger capture throws', async () => {
  const prior = process.env.IB_DESK_CLIENT_IDS;
  process.env.IB_DESK_CLIENT_IDS = '{';
  let reads = 0, captures = 0;
  const sampler = createResultsSampler({ root: root(), request: () => assert.fail('invalid config requested FX'),
    ledger: { load(options) { reads++; assert.equal(options.readOnly, true); return {}; } },
    capture: () => { captures++; throw new Error('synthetic capture failure'); } });
  try {
    for (let i = 0; i < 10; i++) await sampler.tick();
    assert.equal(reads, 1); assert.equal(captures, 1);
    assert.equal(sampler.snapshot().reason, 'fx_config_invalid');
  } finally {
    sampler.close();
    if (prior === undefined) delete process.env.IB_DESK_CLIENT_IDS; else process.env.IB_DESK_CLIENT_IDS = prior;
  }
});

test('fake clock: one request per 15-min RTH bucket plus fixed 16:05, across EDT/CET week and restart', async () => {
  for (const date of ['2026-10-23', '2026-10-26', '2026-10-30', '2026-11-02']) {
    const dir = root(), calls = [];
    let now = Date.parse(`${date}T00:00:00Z`);
    const options = { root: dir, now: () => now, request: async args => { calls.push({ at: now, id: args.id }); return '0.90000000'; } };
    let sampler = createFxSampler(options);
    for (let minute = 0; minute < 1440; minute++) {
      now = Date.parse(`${date}T00:00:00Z`) + minute * 60_000;
      await sampler.tick(); await sampler.tick();
      if (minute === 900) { sampler.close(); sampler = createFxSampler(options); await sampler.tick(); }
    }
    sampler.close();
    assert.equal(calls.length, 27);
    assert.equal(new Set(calls.map(call => fxSlot(call.at).bucket)).size, 27);
    assert.ok(calls.every(call => call.id >= 920000000 && call.id < 930000000));
    assert.equal(new Set(calls.map(call => call.id)).size, 27);
    const close = calls.at(-1);
    assert.equal(iso(close.at), `${date}T${date === '2026-11-02' ? '21' : '20'}:05:00.000Z`);
    if (date === '2026-10-26') assert.equal(new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/Vienna', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date(close.at)), '21:05');
    assert.equal(sampler.snapshot().days[date].samples.at(-1).kind, 'close');
  }
});

test('weekend, off-hours, repeated failure and runtime off-file never create extra calls; state is bounded', async () => {
  const dir = root(); let now = Date.parse('2026-10-17T14:00:00Z'), calls = 0;
  const sampler = createFxSampler({ root: dir, now: () => now, request: async () => { calls++; throw Object.assign(new Error('synthetic'), { reason: 'pacing_rejected' }); } });
  await sampler.tick(); assert.equal(calls, 0);
  now = Date.parse('2026-10-19T13:30:00Z');
  await sampler.tick(); await sampler.tick(); assert.equal(calls, 1);
  assert.equal(sampler.snapshot().reason, 'pacing_rejected');
  assert.deepEqual(JSON.parse(readFileSync(path.join(dir, 'results-fx.json'), 'utf8')).days['2026-10-19'].attempts[0], { at: iso(now), reason: 'pacing_rejected' });
  writeFileSync(path.join(dir, 'FX-SAMPLER-OFF'), 'off\n');
  now += 15 * 60_000; await sampler.tick();
  assert.equal(calls, 1); assert.equal(sampler.snapshot().enabled, false);
  sampler.close();
  const other = root();
  const bounded = createFxSampler({ root: other, now: () => now, request: async () => '0.90000000' });
  for (let day = 1; day <= 31; day++) { now = Date.parse(`2026-10-${String(day).padStart(2, '0')}T14:00:00Z`); await bounded.tick(); }
  assert.equal(Object.keys(bounded.snapshot().days).length, FX_RETENTION_DAYS);
  assert.ok(readFileSync(path.join(other, 'results-fx.json')).length < 256 * 1024);
  bounded.close();
});

function fakeRuntime(mode, calls, { eur = '1', usd = '0.86', code = 10089, onUsd = () => {}, onEnd = () => {} } = {}) {
  const EventName = Object.fromEntries(['nextValidId', 'error', 'disconnected', 'accountUpdateMulti', 'accountUpdateMultiEnd'].map(name => [name, name]));
  class IBApi extends EventEmitter {
    constructor(options) { super(); calls.connection = options; calls.api = this; }
    connect() { queueMicrotask(() => this.emit('nextValidId', 1)); }
    disconnect() { calls.disconnect++; }
    reqAccountUpdatesMulti(id, account, modelCode, ledgerAndNLV) {
      calls.requests.push({ id, account, modelCode, ledgerAndNLV }); calls.open.add(id);
      queueMicrotask(() => {
        // Other requests/accounts/keys and unrelated errors must be ignored.
        this.emit('accountUpdateMulti', id + 1, account, '', 'ExchangeRate', '9', 'USD');
        this.emit('accountUpdateMulti', id, 'synthetic-other-account', '', 'ExchangeRate', '9', 'USD');
        this.emit('accountUpdateMulti', id, account, '', 'NetLiquidation', '9', 'USD');
        this.emit('accountUpdateMulti', id + 1, account, '', 'ExchangeRate', '2', 'EUR');
        this.emit('accountUpdateMulti', id, 'synthetic-other-account', '', 'ExchangeRate', '2', 'EUR');
        this.emit('accountUpdateMulti', id, account, '', 'NetLiquidation', '2', 'EUR');
        this.emit('accountUpdateMultiEnd', id + 1);
        this.emit('error', new Error('private unrelated message'), 321, id + 1);
        if (['ok', 'empty', 'no-end'].includes(mode)) {
          if (eur !== null) this.emit('accountUpdateMulti', id, account, '', 'ExchangeRate', eur, 'EUR');
          if (mode !== 'empty' && usd !== null) {
            onUsd(); this.emit('accountUpdateMulti', id, account, '', 'ExchangeRate', usd, 'USD');
          }
          if (mode !== 'no-end') { onEnd(); this.emit('accountUpdateMultiEnd', id); }
        }
        if (mode === 'reject' || mode === 'connection-error') this.emit('error', new Error('private broker message'), code, mode === 'reject' ? id : -1);
        if (mode === 'disconnect') this.emit('disconnected');
      });
      if (mode === 'throw') throw new Error('synthetic transport failure');
    }
    cancelAccountUpdatesMulti(id) { calls.open.delete(id); calls.cancel++; }
  }
  return { IBApi, EventName };
}
for (const [mode, reason] of [['ok', null], ['reject', 'quote_failed'], ['empty', 'missing_quote'], ['disconnect', 'disconnected'], ['throw', 'quote_failed'], ['slow', 'timeout'], ['no-end', 'timeout']]) test(`account snapshot ${mode}: every request cancelled, client disconnected, no leftover subscription`, async () => {
  const calls = { requests: [], open: new Set(), disconnect: 0, cancel: 0 };
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20);
  try {
    const task = requestFxSnapshot({ id: 920000001, signal: controller.signal, runtime: fakeRuntime(mode, calls), now: () => Date.parse('2026-10-26T13:30:02Z') });
    if (mode === 'ok') assert.deepEqual(await task, { rate: '0.86000000', ibRate: '0.86', sampleAt: '2026-10-26T13:30:02.000Z' });
    else await assert.rejects(task, error => error.reason === reason && (mode !== 'reject' || error.code === 10089));
  } finally { clearTimeout(timer); }
  assert.equal(calls.requests.length, 1);
  assert.deepEqual(calls.requests[0], { id: 920000001, account: ACCOUNT, modelCode: '', ledgerAndNLV: true });
  assert.equal(calls.connection.clientId, 709); assert.equal(calls.connection.port, 4002);
  assert.equal(calls.cancel, 1); assert.equal(calls.disconnect, 1); assert.equal(calls.open.size, 0);
  for (const event of ['accountUpdateMulti', 'accountUpdateMultiEnd', 'disconnected']) assert.equal(calls.api.listenerCount(event), 0);
  assert.equal(calls.api.listenerCount('error'), 1, 'only the dedicated session safety listener remains');
});

for (const [usd, expected] of [
  ['0.861234564', '0.86123456'], ['0.861234565', '0.86123456'],
  ['0.861234575', '0.86123458'], ['0.861234565000000001', '0.86123457'],
  ['0.999999995', '1.00000000'], ['1', '1.00000000'],
  ['0.860000000000000000000000000000', '0.86000000'],
]) test(`account rate rounds half-even with BigInt: ${usd} -> ${expected}`, async () => {
  const calls = { requests: [], open: new Set(), disconnect: 0, cancel: 0 };
  const result = await requestFxSnapshot({ id: 920000001, signal: new AbortController().signal,
    runtime: fakeRuntime('ok', calls, { usd, eur: '1.000000000000000000' }) });
  assert.equal(result.rate, expected);
  assert.equal(result.ibRate, usd, 'the raw rate is preserved without reformatting');
  assert.equal(calls.cancel, 1); assert.equal(calls.open.size, 0); assert.equal(calls.disconnect, 1);
});

for (const options of [
  { eur: '0.99' }, { eur: '1.000000000000000001' }, { eur: null },
  ...['0', '-0.86', 'Infinity', 'NaN', '8.6e-1', '0.000000005', ' 0.86', 0.86,
    '00.86', '.86', '0.86\n', '0.8600000000000000000000000000000'].map(usd => ({ usd })),
]) test(`account rate rejects invalid quotes and cancels: ${JSON.stringify(options)}`, async () => {
  const calls = { requests: [], open: new Set(), disconnect: 0, cancel: 0 };
  await assert.rejects(requestFxSnapshot({ id: 920000001, signal: new AbortController().signal,
    runtime: fakeRuntime('ok', calls, options) }), error => error.reason === 'invalid_quote');
  assert.equal(calls.cancel, 1); assert.equal(calls.open.size, 0); assert.equal(calls.disconnect, 1);
});

test('account rate success persists the source and USD receipt time, waiting for the end callback', async () => {
  const dir = root(), calls = { requests: [], open: new Set(), disconnect: 0, cancel: 0 };
  let now = Date.parse('2026-10-26T13:30:00Z');
  const received = now + 2000, ended = now + 7000;
  const sampler = createFxSampler({ root: dir, now: () => now, runtime: fakeRuntime('ok', calls, {
    onUsd: () => { now = received; }, onEnd: () => { now = ended; },
  }) });
  try {
    await sampler.tick(); await sampler.tick();
    assert.equal(now, ended);
    assert.deepEqual(sampler.snapshot().days['2026-10-26'].samples, [{ rate: '0.86000000',
      sampleAt: iso(received), kind: 'rth', source: 'ib-account-exchange-rate', ibRate: '0.86' }]);
    assert.equal(calls.requests.length, 1); assert.equal(calls.cancel, 1);
    const saved = readFileSync(path.join(dir, 'results-fx.json'), 'utf8');
    assert.equal(saved.includes(ACCOUNT), false);
    assert.deepEqual(JSON.parse(saved).days['2026-10-26'].samples, sampler.snapshot().days['2026-10-26'].samples);
  } finally { sampler.close(); }
});

for (const [mode, code] of [['reject', 10089], ['reject', 321], ['connection-error', 1100], ['connection-error', 2110], ['connection-error', 504]]) test(`account IB error ${code}: quote_failed persists only the code and never retries after restart`, async () => {
  const dir = root(), calls = { requests: [], open: new Set(), disconnect: 0, cancel: 0 };
  const options = { root: dir, now: () => Date.parse('2026-10-26T13:30:00Z'), runtime: fakeRuntime(mode, calls, { code }) };
  let sampler = createFxSampler(options);
  await sampler.tick(); await sampler.tick(); sampler.close();
  sampler = createFxSampler(options);
  try {
    await sampler.tick();
    assert.equal(sampler.snapshot().reason, 'quote_failed');
    const saved = readFileSync(path.join(dir, 'results-fx.json'), 'utf8');
    assert.deepEqual(JSON.parse(saved).days['2026-10-26'].attempts[0], {
      at: '2026-10-26T13:30:00.000Z', reason: 'quote_failed', code,
    });
    for (const forbidden of [ACCOUNT, 'private broker message', 'private unrelated message']) assert.equal(saved.includes(forbidden), false);
    assert.equal(calls.requests.length, 1); assert.equal(calls.cancel, 1); assert.equal(calls.disconnect, 1);
  } finally { sampler.close(); }
});

test('old sampler states without source/code load; optional known source/integer code load; unknown fields fail closed', async () => {
  for (const [sampleExtra, attemptExtra, valid] of [
    [{}, {}, true], [{ source: 'ib-account-exchange-rate' }, { code: 321 }, true],
    [{ source: 'unknown' }, {}, false], [{ source: null }, {}, false],
    [{}, { code: '321' }, false], [{}, { code: 3.21 }, false], [{ raw: 'synthetic' }, {}, false],
  ]) {
    const dir = root();
    const day = { attempts: {
      0: { at: '2026-10-26T13:30:00.000Z', reason: 'ok' },
      1: { at: '2026-10-26T13:45:00.000Z', reason: 'quote_failed', ...attemptExtra },
    }, samples: [{ rate: '0.86000000', sampleAt: '2026-10-26T13:30:02.000Z', kind: 'rth', ...sampleExtra }] };
    writeFileSync(path.join(dir, 'results-fx.json'), JSON.stringify({ schema: 1, days: { '2026-10-26': day } }));
    const sampler = createFxSampler({ root: dir, now: () => Date.parse('2026-10-26T22:00:00Z'),
      request: () => assert.fail('state load must not request FX outside a slot') });
    try {
      await sampler.tick();
      assert.equal(sampler.snapshot().reason, valid ? 'quote_failed' : 'state_unavailable');
      assert.deepEqual(sampler.snapshot().days, valid ? { '2026-10-26': { samples: day.samples } } : {});
    } finally { sampler.close(); }
  }
});

for (const [name, series] of [
  ['a single account-rate sample has no stale metadata', [['13:30', '0.86000000']]],
  ['identical rates at 0/15/30 minutes flag only the third sample stale at 1800 seconds', [
    ['13:30', '0.86000000'], ['13:45', '0.86000000'], ['14:00', '0.86000000', 1800],
  ]],
  ['a rate change resets the contiguous stale run', [
    ['13:30', '0.86000000'], ['13:45', '0.86000000'], ['14:00', '0.87000000'],
    ['14:15', '0.87000000'], ['14:30', '0.87000000', 1800],
  ]],
  ['A to B to A counts only the final contiguous run', [
    ['13:30', '0.86000000'], ['13:45', '0.86000000'], ['14:00', '0.87000000'],
    ['14:15', '0.86000000'], ['14:30', '0.86000000'], ['14:45', '0.86000000', 1800],
  ]],
  ['numerically equal but different rate strings reset the stale run', [
    ['13:30', '0.86000000'], ['13:45', '0.86000000'], ['14:00', '00.86000000'],
  ]],
  ['the close sample measures staleness from the unchanged afternoon run', [
    ['17:00', '0.86000000'], ['17:15', '0.86000000'], ['19:45', '0.86000000', 9900], ['20:05', '0.86000000', 11100],
  ]],
  ['failed attempts neither break nor extend the sampled stale run', [
    ['13:30', '0.86000000'], ['13:45', null], ['14:00', null], ['14:15', '0.86000000', 2700],
    ['14:30', null], ['14:45', '0.86000000', 4500],
  ]],
]) test(name, async () => {
  const dir = root(), expected = [];
  for (const [time, rate, staleSeconds] of series) {
    const sampleAt = `2026-10-26T${time}:00.000Z`;
    // Restart between every attempt to exercise persisted runs and metadata.
    const sampler = createFxSampler({ root: dir, now: () => Date.parse(sampleAt), request: async () => {
      if (rate === null) throw Object.assign(new Error('synthetic'), { reason: 'quote_failed' });
      return rate;
    } });
    try {
      await sampler.tick();
      if (rate !== null) expected.push({ rate, sampleAt, kind: time === '20:05' ? 'close' : 'rth', source: 'ib-account-exchange-rate',
        ...(staleSeconds === undefined ? {} : { staleFx: true, staleSeconds }) });
      assert.equal(sampler.snapshot().reason, rate === null ? 'quote_failed' : null, time);
      assert.deepEqual(sampler.snapshot().days['2026-10-26'].samples, expected, time);
      const saved = JSON.parse(readFileSync(path.join(dir, 'results-fx.json'), 'utf8'));
      assert.deepEqual(saved.days['2026-10-26'].samples, expected, time);
    } finally { sampler.close(); }
  }
});

for (const [name, rawRates, expectedSeconds] of [
  ['a raw tick beyond eight decimals resets the stale clock despite an identical conversion rate',
    ['0.860000001', '0.860000001', '0.860000002', '0.860000002', '0.860000002'], [undefined, undefined, undefined, undefined, 1800]],
  ['identical raw rates flag staleness at exactly 1800 seconds',
    ['0.860000001', '0.860000001', '0.860000001'], [undefined, undefined, 1800]],
  ['a mixed old and raw-rate run falls back to the eight-place rate for the old sample',
    [undefined, '0.860000001', '0.860000001'], [undefined, undefined, 1800]],
  ['a raw string change resets the run without numeric reformatting',
    ['0.860000001', '0.860000001', '0.8600000010'], [undefined, undefined, undefined]],
]) test(name, async () => {
  const dir = root();
  for (const [index, ibRate] of rawRates.entries()) {
    const sampleAt = iso(Date.parse('2026-10-26T13:30:00Z') + index * 15 * 60_000);
    // Restart on each sample to test validation of the evolving saved shape.
    const sampler = createFxSampler({ root: dir, now: () => Date.parse(sampleAt),
      request: async () => ({ rate: '0.86000000', sampleAt, ...(ibRate === undefined ? {} : { ibRate }) }) });
    try {
      await sampler.tick();
      assert.equal(sampler.snapshot().reason, null);
      const samples = sampler.snapshot().days['2026-10-26'].samples;
      assert.equal(samples.length, index + 1);
      assert.ok(samples.every(sample => sample.rate === '0.86000000'));
      assert.equal(samples.at(-1).ibRate, ibRate);
      assert.equal(samples.at(-1).staleSeconds, expectedSeconds[index]);
      assert.equal(Object.hasOwn(samples.at(-1), 'staleFx'), expectedSeconds[index] !== undefined);
      assert.deepEqual(JSON.parse(readFileSync(path.join(dir, 'results-fx.json'), 'utf8')).days['2026-10-26'].samples, samples);
    } finally { sampler.close(); }
  }
});

test('staleness uses receipt times and floors fractional seconds, not completion times', async () => {
  const dir = root();
  let now = Date.parse('2026-10-26T13:30:00.250Z');
  const sampler = createFxSampler({ root: dir, now: () => now, request: async () => {
    const sampleAt = iso(now); now += 10_000;
    return { rate: '0.86000000', sampleAt };
  } });
  try {
    await sampler.tick();
    now = Date.parse('2026-10-26T14:00:00.999Z'); await sampler.tick();
    assert.deepEqual(sampler.snapshot().days['2026-10-26'].samples.at(-1), { rate: '0.86000000',
      sampleAt: '2026-10-26T14:00:00.999Z', kind: 'rth', source: 'ib-account-exchange-rate', staleFx: true, staleSeconds: 1800 });
  } finally { sampler.close(); }
});

test('an unordered saved series is walked newest first and stops at the differing rate', async () => {
  const dir = root(), filename = path.join(dir, 'results-fx.json');
  const saved = { schema: 1, days: { '2026-10-26': { attempts: {}, samples: [] } } };
  const day = saved.days['2026-10-26'];
  for (const [bucket, time, rate] of [[0, '13:30', '0.86000000'], [1, '13:45', '0.87000000'], [2, '14:00', '0.86000000'], [3, '14:15', '0.86000000']]) {
    const sampleAt = `2026-10-26T${time}:00.000Z`;
    day.attempts[bucket] = { at: sampleAt, reason: 'ok' };
    day.samples.unshift({ rate, sampleAt, kind: 'rth', source: 'ib-account-exchange-rate' });
  }
  writeFileSync(filename, JSON.stringify(saved));
  const sampler = createFxSampler({ root: dir, now: () => Date.parse('2026-10-26T14:30:00Z'), request: async () => '0.86000000' });
  try {
    await sampler.tick();
    assert.equal(sampler.snapshot().reason, null);
    assert.equal(sampler.snapshot().days['2026-10-26'].samples.at(-1).staleSeconds, 1800);
  } finally { sampler.close(); }
});

test('an identical rate on a new NY day starts a fresh run', async () => {
  const dir = root(); let now = Date.parse('2026-10-26T20:05:00Z');
  const sampler = createFxSampler({ root: dir, now: () => now, request: async () => '0.86000000' });
  try {
    await sampler.tick();
    now = Date.parse('2026-10-27T13:30:00Z'); await sampler.tick();
    assert.deepEqual(sampler.snapshot().days['2026-10-27'].samples, [{ rate: '0.86000000', sampleAt: iso(now),
      kind: 'rth', source: 'ib-account-exchange-rate' }]);
  } finally { sampler.close(); }
});

test('stale state metadata accepts only a true/integer pair in range on account-rate samples; old files load', async () => {
  const source = { source: 'ib-account-exchange-rate' };
  for (const [name, extra, valid] of [
    ['legacy sample', {}, true], ['account-rate sample without flags', source, true],
    ['lower bound', { ...source, staleFx: true, staleSeconds: 1800 }, true],
    ['upper bound', { ...source, staleFx: true, staleSeconds: 86400 }, true],
    ['lone staleFx', { ...source, staleFx: true }, false],
    ['lone staleSeconds', { ...source, staleSeconds: 1800 }, false],
    ['false staleFx', { ...source, staleFx: false, staleSeconds: 1800 }, false],
    ['string staleFx', { ...source, staleFx: 'true', staleSeconds: 1800 }, false],
    ['null staleFx', { ...source, staleFx: null, staleSeconds: 1800 }, false],
    ['fractional staleSeconds', { ...source, staleFx: true, staleSeconds: 1800.5 }, false],
    ['string staleSeconds', { ...source, staleFx: true, staleSeconds: '1800' }, false],
    ['null staleSeconds', { ...source, staleFx: true, staleSeconds: null }, false],
    ['below lower bound', { ...source, staleFx: true, staleSeconds: 1799 }, false],
    ['above upper bound', { ...source, staleFx: true, staleSeconds: 86401 }, false],
    ['source-less sample', { staleFx: true, staleSeconds: 1800 }, false],
    ['unknown source', { source: 'unknown', staleFx: true, staleSeconds: 1800 }, false],
  ]) {
    const dir = root(), sampleAt = '2026-10-26T14:00:00.000Z';
    const day = { attempts: { 2: { at: sampleAt, reason: 'ok' } },
      samples: [{ rate: '0.86000000', sampleAt, kind: 'rth', ...extra }] };
    writeFileSync(path.join(dir, 'results-fx.json'), JSON.stringify({ schema: 1, days: { '2026-10-26': day } }));
    const sampler = createFxSampler({ root: dir, now: () => Date.parse('2026-10-26T22:00:00Z'),
      request: () => assert.fail('state load must not request FX outside a slot') });
    try {
      await sampler.tick();
      assert.equal(sampler.snapshot().reason, valid ? null : 'state_unavailable', name);
      assert.deepEqual(sampler.snapshot().days, valid ? { '2026-10-26': { samples: day.samples } } : {}, name);
    } finally { sampler.close(); }
  }
});

test('account-rate state metadata validates raw decimals and off-session placement; old shapes load', async () => {
  const source = { source: 'ib-account-exchange-rate' }, raw = { ibRate: '0.860000001' };
  const flags = { staleFx: true, staleSeconds: 1800 };
  const rthAt = '2026-10-26T14:00:00.000Z', closeAt = '2026-11-27T21:05:00.000Z';
  const cases = [
    ['raw rate', rthAt, { ...source, ...raw }, true],
    ['raw rate and flags', rthAt, { ...source, ...raw, ...flags }, true],
    ['raw rate at 32 characters', rthAt, { ...source, ibRate: '0.860000000000000000000000000000' }, true],
    ['positive tiny raw rate', rthAt, { ...source, ibRate: '0.000000000000000000000000000001' }, true],
    ['integer raw rate', rthAt, { ...source, ibRate: '1' }, true],
    ['off-session close', closeAt, { ...source, ...raw, session: 'off' }, true],
    ['off-session close and flags', closeAt, { ...source, ...raw, session: 'off', ...flags }, true],
    ['off-session close without raw rate', closeAt, { ...source, session: 'off' }, true],
    ['off-session close without raw rate and with flags', closeAt, { ...source, session: 'off', ...flags }, true],
    ['old source-less early close', closeAt, {}, true],
    ['old account-rate early close', closeAt, source, true],
    ['old flagged early close', closeAt, { ...source, ...flags }, true],
    ['raw rate on source-less sample', rthAt, raw, false],
    ['off-session on source-less sample', closeAt, { session: 'off' }, false],
    ['session on RTH', rthAt, { ...source, session: 'off' }, false],
    ['session on early-close RTH', '2026-11-27T17:45:00.000Z', { ...source, session: 'off' }, false],
    ['session on normal-day close', '2026-10-26T20:05:00.000Z', { ...source, session: 'off' }, false],
    ['rth session value', closeAt, { ...source, session: 'rth' }, false],
    ['null session', closeAt, { ...source, session: null }, false],
    ['unknown field', closeAt, { ...source, ...raw, session: 'off', unexpected: true }, false],
    ...['', '0', '0.000', '00.86', '01', '.86', '0.', '-0.86', '+0.86', '8.6e-1', 'NaN', 'Infinity', ' 0.86', '0.86\n',
      '0.8600000000000000000000000000000', 0.86, null].map(ibRate => [
      `invalid raw rate ${JSON.stringify(ibRate)}`, rthAt, { ...source, ibRate }, false,
    ]),
  ];
  for (const [name, sampleAt, extra, valid] of cases) {
    const dir = root(), slot = fxSlot(Date.parse(sampleAt));
    const day = { attempts: { [slot.bucket]: { at: sampleAt, reason: 'ok' } },
      samples: [{ rate: '0.86000000', sampleAt, kind: slot.kind, ...extra }] };
    writeFileSync(path.join(dir, 'results-fx.json'), JSON.stringify({ schema: 1, days: { [slot.date]: day } }));
    const sampler = createFxSampler({ root: dir, now: () => Date.parse(`${slot.date}T23:00:00Z`),
      request: () => assert.fail('state load must not request FX outside a slot') });
    try {
      await sampler.tick();
      assert.equal(sampler.snapshot().reason, valid ? null : 'state_unavailable', name);
      assert.deepEqual(sampler.snapshot().days, valid ? { [slot.date]: { samples: day.samples } } : {}, name);
    } finally { sampler.close(); }
  }
});

for (const [date, hour, early] of [
  ['2026-11-27', '21', true], ['2026-12-24', '21', true], ['2027-11-26', '21', true],
  ['2028-07-03', '20', true], ['2028-11-24', '21', true],
  ['2026-10-26', '20', false], ['2026-11-30', '21', false],
]) test(`${date}: only an early-close day's 16:05 close has session off; RTH omits session`, async () => {
  const dir = root();
  const opening = Date.parse(`${date}T${hour === '20' ? '13' : '14'}:30:00Z`);
  let now = opening;
  const options = { root: dir, now: () => now,
    request: async () => ({ rate: '0.86000000', ibRate: '0.860000001', sampleAt: iso(now) }) };
  let sampler = createFxSampler(options);
  try {
    await sampler.tick();
    now += 15 * 60_000; await sampler.tick();
    now = Date.parse(`${date}T${hour}:05:00Z`); await sampler.tick();
    const samples = sampler.snapshot().days[date].samples;
    assert.equal(samples.length, 3);
    assert.ok(samples.slice(0, -1).every(sample => sample.kind === 'rth' && !Object.hasOwn(sample, 'session')));
    assert.equal(samples.at(-1).kind, 'close');
    assert.equal(Object.hasOwn(samples.at(-1), 'session'), early);
    assert.equal(samples.at(-1).session, early ? 'off' : undefined);
    assert.equal(samples.at(-1).staleFx, true);
    assert.equal(samples.at(-1).staleSeconds, 23700);
    sampler.close(); sampler = createFxSampler(options);
    await sampler.tick();
    assert.equal(sampler.snapshot().reason, null);
    assert.deepEqual(sampler.snapshot().days[date].samples, samples);
  } finally { sampler.close(); }
});

test('NYSE holiday and early-close boundaries suppress RTH requests; unknown calendar years fail closed', () => {
  for (const at of ['2026-07-03T14:00:00Z', '2026-11-26T15:00:00Z', '2026-12-25T21:05:00Z', '2027-12-24T15:00:00Z', '2029-10-26T14:00:00Z']) assert.equal(fxSlot(Date.parse(at)).bucket, null, at);
  assert.equal(fxSlot(Date.parse('2026-11-27T17:59:00Z')).rth, true);
  assert.equal(fxSlot(Date.parse('2026-11-27T18:00:00Z')).bucket, null);
  assert.equal(fxSlot(Date.parse('2026-11-27T21:05:00Z')).kind, 'close');
});

test('late startup still spaces RTH requests by 15 minutes, while allowing fixed close; restart restores reason', async () => {
  const dir = root(); let now = Date.parse('2026-10-26T13:44:00Z');
  const calls = [];
  const options = { root: dir, now: () => now, request: async () => { calls.push(now); return '0.90000000'; } };
  let sampler = createFxSampler(options); await sampler.tick(); sampler.close();
  sampler = createFxSampler(options); await sampler.tick();
  assert.equal(sampler.snapshot().reason, null);
  now += 60_000; await sampler.tick(); assert.equal(calls.length, 1);
  now += 14 * 60_000; await sampler.tick(); assert.equal(calls.length, 2);
  now = Date.parse('2026-10-26T19:59:00Z'); await sampler.tick();
  now = Date.parse('2026-10-26T20:05:00Z'); await sampler.tick();
  assert.equal(calls.length, 4); sampler.close();
});

test('durable reservation precedes the IB request; slow out-of-slot results are discarded without retry', async () => {
  const dir = root(); let now = Date.parse('2026-10-26T20:05:59Z'), calls = 0;
  const sampler = createFxSampler({ root: dir, now: () => now, request: async () => {
    calls++;
    const state = JSON.parse(readFileSync(path.join(dir, 'results-fx.json'), 'utf8'));
    assert.equal(state.days['2026-10-26'].attempts[26].reason, 'pending');
    now += 2000;
    return '0.90000000';
  } });
  await sampler.tick(); await sampler.tick();
  assert.equal(calls, 1); assert.equal(sampler.snapshot().reason, 'timeout');
  assert.deepEqual(sampler.snapshot().days['2026-10-26'].samples, []); sampler.close();
});

test('corrupt sampler state fails closed without IB requests or executor ledger writes', async () => {
  const dir = root(); let calls = 0;
  writeFileSync(path.join(dir, 'results-fx.json'), JSON.stringify({ schema: 1, days: { '2026-10-26': { attempts: {}, samples: [], unexpected: 'synthetic' } } }));
  const sampler = createFxSampler({ root: dir, now: () => Date.parse('2026-10-26T13:30:00Z'), request: async () => { calls++; return '0.90000000'; } });
  await sampler.tick(); assert.equal(calls, 0); assert.equal(sampler.snapshot().reason, 'state_unavailable');
  assert.deepEqual(sampler.snapshot().days, {}); sampler.close();
});

test('deadline releases the scheduler even if an injected request ignores cancellation', async () => {
  const dir = root();
  const sampler = createFxSampler({ root: dir, now: () => Date.parse('2026-10-26T13:30:00Z'), timeoutMs: 5, request: () => new Promise(() => {}) });
  await sampler.tick(); assert.equal(sampler.snapshot().reason, 'timeout');
  await sampler.tick(); sampler.close();
});

test('a handshake crossing the end of an authorized slot never sends an account request', async () => {
  const calls = { requests: [], open: new Set(), disconnect: 0, cancel: 0 };
  const controller = new AbortController();
  await assert.rejects(requestFxSnapshot({ id: 920000001, signal: controller.signal, runtime: fakeRuntime('ok', calls), allowed: () => false }), /timeout/);
  assert.equal(calls.requests.length, 0); assert.equal(calls.disconnect, 1);
});
