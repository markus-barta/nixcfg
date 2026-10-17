import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createFxSampler, requestFxSnapshot, fxSlot, FX_RETENTION_DAYS } from './fx-sampler.mjs';
import { createResultsSampler } from './server.mjs';

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

function fakeRuntime(mode, calls) {
  const EventName = Object.fromEntries(['nextValidId', 'error', 'disconnected', 'tickPrice', 'tickSnapshotEnd'].map(name => [name, name]));
  class IBApi extends EventEmitter {
    connect() { queueMicrotask(() => this.emit('nextValidId', 1)); }
    disconnect() { calls.disconnect++; }
    reqMktData(id, contract, generic, snapshot, regulatory) {
      calls.requests.push({ id, contract, generic, snapshot, regulatory }); calls.open.add(id);
      queueMicrotask(() => {
        if (mode === 'ok') { this.emit('tickPrice', id + 1, 1, 9); this.emit('tickPrice', id, 1, 1.1); this.emit('tickPrice', id, 2, 1.1); }
        if (mode === 'reject') this.emit('error', new Error('private broker message'), 420, id);
        if (mode === 'empty') this.emit('tickSnapshotEnd', id);
        if (mode === 'disconnect') this.emit('disconnected');
      });
      if (mode === 'throw') throw new Error('synthetic transport failure');
    }
    cancelMktData(id) { calls.open.delete(id); calls.cancel++; }
  }
  return { IBApi, EventName };
}
for (const mode of ['ok', 'reject', 'empty', 'disconnect', 'throw', 'slow']) test(`snapshot ${mode}: every request cancelled, client disconnected, no leftover subscription`, async () => {
  const calls = { requests: [], open: new Set(), disconnect: 0, cancel: 0 };
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20);
  try {
    const task = requestFxSnapshot({ id: 920000001, signal: controller.signal, runtime: fakeRuntime(mode, calls) });
    if (mode === 'ok') assert.equal(await task, '0.90909091'); else await assert.rejects(task);
  } finally { clearTimeout(timer); }
  assert.equal(calls.requests.length, 1);
  assert.deepEqual(calls.requests[0], { id: 920000001, contract: { symbol: 'EUR', secType: 'CASH', exchange: 'IDEALPRO', currency: 'USD' }, generic: '', snapshot: true, regulatory: false });
  assert.equal(calls.cancel, 1); assert.equal(calls.disconnect, 1); assert.equal(calls.open.size, 0);
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

test('a handshake crossing the end of an authorized slot never sends a quote request', async () => {
  const calls = { requests: [], open: new Set(), disconnect: 0, cancel: 0 };
  const controller = new AbortController();
  await assert.rejects(requestFxSnapshot({ id: 920000001, signal: controller.signal, runtime: fakeRuntime('ok', calls), allowed: () => false }), /timeout/);
  assert.equal(calls.requests.length, 0); assert.equal(calls.disconnect, 1);
});
