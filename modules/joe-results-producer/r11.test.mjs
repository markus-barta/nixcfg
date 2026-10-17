import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, readFileSync, cpSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { sdkDecimal } from './sdk-decimal.mjs';
import { createCapture } from './capture.mjs';
import { openProducer } from './producer.mjs';
import { readJournal } from './journal.mjs';
import { dayCloses } from './fifo.mjs';
import { endpointUrl, credentialHeaders } from './transport.mjs';
import { executorHealthUrl, readJson } from './main.mjs';
import { verifyContracts } from './verify-contracts.mjs';

const begin = '2026-10-15T22:00:00.000Z', end = '2026-10-16T22:00:00.000Z';
const account = 'synthetic-account';
const dir = () => mkdtempSync(path.join(tmpdir(), 'joed20-r11-'));
const health = { status: 'ok', halt: { active: false }, brakes: { newPerDay: 1, notionalEur: 1 }, gatewayReachable: true };
function setup(t) {
  const root = dir(), input = path.join(root, 'input.jsonl'), output = path.join(root, 'results.jsonl');
  let now = begin;
  const capture = createCapture(input, { executorClientId: 705, foreignAlertSince: begin }, {
    account, attribute: () => ({ desk: 'j', method: 'admin' }), executionTime: Date.parse, now: () => now,
  });
  capture({ ownershipComplete: true, executions: [] }); now = end;
  const producer = openProducer(output, { now: () => now });
  const executions = [10, 12].map((price, i) => ({ contract: { conId: 1, symbol: 'ACME', currency: 'EUR' },
    execution: { execId: `synthetic-${i}.01`, acctNumber: account, clientId: 705, time: `2026-10-16T${i ? '12' : '10'}:00:00.000Z`, side: i ? 'SELL' : 'BUY', shares: 1, price } }));
  const state = { ownershipComplete: true, executions, commissions: executions.map((row, i) => ({
    execId: row.execution.execId, commission: 0.1, currency: 'EUR', realizedPNL: i ? 1.8 : Number.MAX_VALUE,
  })), resultsHistoryCoverage: { status: 'complete', target: { fromInclusive: begin, toExclusive: end }, gaps: [] } };
  const refresh = () => { capture(state); producer.ingest(readJournal(input)); return producer.snapshot(); };
  t.after(() => { capture.close(); producer.close(); });
  return { input, output, capture, producer, state, refresh };
}

test('SDK Number policy handles sentinels first, decimals, precision and negative zero', () => {
  for (const value of [Number.MAX_VALUE, String(Number.MAX_VALUE), 2147483647, '2147483647', null, undefined]) assert.deepEqual(sdkDecimal(value), { unset: true });
  for (const value of [0.1, 123.456, 0.000001, 123456789012345]) assert.deepEqual(sdkDecimal(value), { amount: String(value), src: 'sdk_number_roundtrip' });
  assert.deepEqual(sdkDecimal(-0), { amount: '0', src: 'sdk_number_roundtrip' });
  for (const value of [1e-7, 1e21, 123456789012345678, NaN, Infinity, -Infinity]) assert.deepEqual(sdkDecimal(value), { refused: true });
  assert.deepEqual(sdkDecimal('0.12345678'), { amount: '0.12345678' });
});

test('real SDK Number fills and commissions produce a full EUR day with field provenance', t => {
  const f = setup(t), result = f.refresh();
  assert.equal(result.days[0].coverage ?? 'full', 'full');
  assert.equal(result.trades[0].netEur.amount, '1.8');
  const fills = readJournal(f.input).flatMap(event => event.fills || []);
  assert.deepEqual(fills[0].provenance, ['quantity', 'price', 'commission.amount'].map(field => ({ field, src: 'sdk_number_roundtrip' })));
  assert.equal(fills[1].brokerRealised.src, 'sdk_number_roundtrip');
  assert.deepEqual(f.capture.health(), { refusals: 0 });
});

for (const field of ['price', 'shares', 'commission', 'realizedPNL']) test(`refused SDK ${field} is value-free, partial and counted across capture/producer replay`, t => {
  const f = setup(t);
  if (field === 'price' || field === 'shares') f.state.executions[1].execution[field] = 1e-7;
  else f.state.commissions[1][field] = Infinity;
  const first = f.refresh();
  assert.equal(first.days[0].coverage, 'partial');
  const issues = readJournal(f.input).flatMap(event => event.captureIssues || []);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].kind, field === 'realizedPNL' ? 'broker_evidence_missing' : 'capture_gap');
  assert.deepEqual(Object.keys(issues[0]).sort(), ['id', 'day', 'deskHash', 'kind', 'field', 'refused'].sort());
  assert.deepEqual(f.capture.health(), { refusals: 1 });
  assert.equal(f.producer.health(health, end).captureRefusals, 1);
  f.refresh();
  assert.equal(readJournal(f.input).flatMap(event => event.captureIssues || []).length, 1);
  const replay = openProducer(path.join(dir(), 'replay.jsonl'), { now: () => end });
  try { replay.ingest(readJournal(f.input)); assert.deepEqual(replay.snapshot().days, first.days); assert.equal(replay.health(health).captureRefusals, 1); }
  finally { replay.close(); }
  const captureReplay = createCapture(f.input, { executorClientId: 705, foreignAlertSince: begin }, { account, attribute: () => ({ desk: 'j', method: 'admin' }), executionTime: Date.parse, now: () => end });
  try { captureReplay(f.state); assert.equal(captureReplay.health().refusals, 1); } finally { captureReplay.close(); }
  assert.equal(readFileSync(f.input, 'utf8').includes(account), false);
});

test('configured origin pins scheme, host and port; health always uses literal loopback', () => {
  const origin = 'https://board.example.invalid';
  assert.equal(endpointUrl(`${origin}/joe/inbox/results`, origin).href, `${origin}/joe/inbox/results`);
  for (const url of ['https://evil.example.invalid/joe/inbox/results', `${origin}:444/joe/inbox/results`, 'http://board.example.invalid/joe/inbox/results', `${origin}/joe/inbox/results?redirect=evil`]) assert.throws(() => endpointUrl(url, origin));
  assert.throws(() => endpointUrl(`${origin}/joe/inbox/results`));
  assert.equal(executorHealthUrl('http://127.0.0.1:8472/v1/health').origin, 'http://127.0.0.1:8472');
  for (const url of ['http://127.0.0.1:8471/v1/health', 'http://127.0.0.2:8472/v1/health', 'http://127.0.0.1:8472/v1/health?x=1']) assert.throws(() => executorHealthUrl(url));
});

test('settings and credentials reject traversal and directory/file symlink escapes', () => {
  for (const filename of ['/tmp/settings.json', '/nix/store/../settings.json', '/nix/store/' + 'a'.repeat(32) + '-joe-results-producer.json/../other']) assert.throws(() => readJson(filename), /invalid_settings_path/);
  const root = dir(), trusted = path.join(root, 'credentials'), other = path.join(root, 'other'); mkdirSync(trusted); mkdirSync(other);
  const name = 'joe-board-push-token'; writeFileSync(path.join(other, name), 'synthetic-only');
  assert.throws(() => credentialHeaders(other, trusted)(), /auth_required/);
  const alias = path.join(root, 'alias'); symlinkSync(other, alias);
  assert.throws(() => credentialHeaders(alias, trusted)(), /auth_required/);
  assert.throws(() => credentialHeaders(path.join(trusted, '..', 'other'), trusted)(), /auth_required/);
  symlinkSync(path.join(other, name), path.join(trusted, name));
  assert.throws(() => credentialHeaders(trusted, trusted)(), /auth_required/);
});

test('IB and journal-derived property keys reject prototype names and invalid dates', t => {
  const f = setup(t);
  for (const key of ['__proto__', 'constructor', '2026-02-30', '../2026-10-16']) {
    f.state.resultsFxSampler = { enabled: true, days: JSON.parse(`{"${key}":{"samples":[]}}`) };
    assert.throws(() => f.capture(f.state), /source_not_authoritative/);
  }
  for (const desk of ['__proto__', 'constructor', 'invalid']) {
    assert.throws(() => dayCloses([{ at: end, desk }], [], '2026-10-16'), /source_not_authoritative/);
    assert.throws(() => dayCloses([], [{ desk, closedAt: end }], '2026-10-16'), /source_not_authoritative/);
  }
  assert.equal({}.equityClose, undefined);
});

test('contract checker runs when imported regardless of the CLI invocation guard', () => {
  assert.equal(verifyContracts(), true);
  const root = dir(); cpSync(new URL('./contracts/', import.meta.url), path.join(root, 'contracts'), { recursive: true });
  cpSync(new URL('./contracts.lock.json', import.meta.url), path.join(root, 'contracts.lock.json'));
  writeFileSync(path.join(root, 'contracts/manifest.json'), '{}');
  assert.throws(() => verifyContracts(root), /contract_bytes_drift/);
});

test('SDK broker quantity refusals all reach their day and health counter', t => {
  const f = setup(t);
  f.state.ownershipSnapshot = { account, ownershipComplete: true, observedAt: end, positions: [1, 2].map(conId => ({ conId, symbol: 'ACME', currency: 'EUR', position: 1e-7 })) };
  const value = f.refresh();
  assert.equal(value.days.find(day => day.date === '2026-10-17').coverage, 'partial');
  assert.equal(f.capture.health().refusals, 2);
  assert.equal(readJournal(f.input).flatMap(row => row.captureIssues || []).filter(row => row.kind === 'broker_evidence_missing').length, 2);
});

test('numeric FX provenance survives cached cuts and a refused correction does not grow every poll', t => {
  const f = setup(t);
  f.state.executions.forEach(row => { row.contract.currency = 'USD'; });
  f.state.commissions.forEach(row => { row.currency = 'USD'; row.commission = 0; });
  f.state.commissions[1].realizedPNL = 2;
  f.state.resultsFx = { USD: { base: 'USD', quote: 'EUR', rate: 0.9, source: 'synthetic', observedAt: '2026-10-16T12:00:00.000Z' } };
  f.refresh();
  f.refresh();
  let fills = readJournal(f.input).flatMap(row => row.fills || []);
  assert.equal(fills.at(-1).provenance.some(row => row.field === 'closeFx.rate'), true);
  f.state.executions[1].execution.price = 1e-7;
  f.refresh(); const count = readJournal(f.input).length;
  f.refresh(); assert.equal(readJournal(f.input).length, count);
});
