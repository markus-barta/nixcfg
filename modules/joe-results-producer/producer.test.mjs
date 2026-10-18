import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, appendFileSync, cpSync, mkdirSync, symlinkSync, renameSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { roundTrips, dayCloses, viennaDate } from './fifo.mjs';
import { openProducer, createRunner, executorHealth, CADENCE_MS } from './producer.mjs';
import { hash, openJournal, readJournal } from './journal.mjs';
import { verifyContracts } from './verify-contracts.mjs';
import { fixtureIngress, httpTransport } from './transport.mjs';
import { validateContract } from './contracts/index.mjs';
import { createCapture, reconciliationEvidence } from './capture.mjs';
import { ACCOUNT, activityAttribution, executionTimeMs } from '../paper-desk-executor/policy.mjs';
import { openLedger } from '../paper-desk-executor/state.mjs';
import { createHealthServer } from '../paper-desk-executor/server.mjs';

const root = path.dirname(fileURLToPath(import.meta.url));
const fixture = name => JSON.parse(readFileSync(path.join(root, 'fixtures', name), 'utf8'));
const fills = fixture('fills.json'), health = fixture('health.json');
const start = '2026-10-16T11:00:00.000Z', at = '2026-10-16T14:00:00.000Z';
const floor = ['SXR8', 'TSLA'];
const temp = () => mkdtempSync(path.join(tmpdir(), 'joed20-'));
const source = () => [{ type: 'start', at: start }, ...fills.map(fill => ({ type: 'fill', fill })), { type: 'authority', at, authoritative: true, disagreement: false, evidence: [] }];
const open = dir => openProducer(path.join(dir, 'results.jsonl'), { now: () => '2026-12-01T00:00:00.000Z' });
const config = { executorClientId: 705, ownClientIds: [705], foreignAlertSince: '2026-10-12T00:00:00.000Z' };
const dependencies = { account: ACCOUNT, attribute: activityAttribution, executionTime: executionTimeMs };

function rawFill(key, overrides = {}) {
  return { contract: { conId: 123, symbol: 'ACME', currency: 'EUR' }, execution: { execId: `${key}.01`, acctNumber: ACCOUNT, orderRef: 'j|261016|synthetic', orderId: 555, clientId: 705, shares: '1', price: '10', side: 'BOT', time: start, ...overrides } };
}

test('FIFO partial closes, two lots, opening/closing commissions and FX observed at each close', () => {
  const trades = roundTrips(fills, start, floor);
  assert.equal(trades.length, 3);
  assert.deepEqual(trades.map(t => t.quantity), ['3', '1', '1']);
  assert.deepEqual(trades.map(t => t.grossEur.amount), ['5.4', '0.9', '1.6']);
  assert.deepEqual(trades.map(t => t.feesEur.amount), ['0.54', '0.18', '0.16']);
  assert.deepEqual(trades.map(t => t.netEur.amount), ['4.86', '0.72', '1.44']);
  assert.deepEqual(trades.map(t => t.fx.rate), ['0.9', '0.9', '0.8']);
  assert.equal(new Set(trades.map(t => t.id)).size, 3);
});

test('exact gross multiplies quantity, move and rate together without intermediate rounding', () => {
  const exact = [
    { ...fills[0], quantity: '0.1', price: '0.00000001', commission: { amount: '0', currency: 'USD' } },
    { ...fills[2], quantity: '0.1', price: '0.00000002', commission: { amount: '0', currency: 'USD' }, closeFx: { ...fills[2].closeFx, rate: '10' } },
  ];
  assert.equal(roundTrips(exact, start, floor)[0].grossEur.amount, '0.00000001');
  exact[1].closeFx.rate = '0.9';
  assert.equal(roundTrips(exact, start, floor)[0].grossEur.amount, '0');
});

test('short FIFO is desk isolated and fees work in EUR or native currency', () => {
  const short = [
    { ...fills[0], side: 'SELL', quantity: '1', price: '15', commission: { amount: '0.1', currency: 'EUR' } },
    { ...fills[2], side: 'BUY', quantity: '1', price: '10' },
    { ...fills[0], key: 'other', desk: 'joe', side: 'BUY' },
  ];
  const [trade] = roundTrips(short, start, floor);
  assert.equal(trade.side, 'short'); assert.equal(trade.grossEur.amount, '4.5');
  assert.equal(trade.feesEur.amount, '0.46');
});

test('missing commission and USD FX exclude portions; legacy and unowned rows are excluded', () => {
  const excluded = [];
  const remaining = roundTrips(fills.map(f => f.key === 'close-a' ? { ...f, closeFx: null } : f), start, floor, () => {}, row => excluded.push(row));
  assert.equal(excluded.length, 2);
  assert.ok(excluded.every(row => row.kind === 'fx_missing'));
  assert.equal(remaining.length, 1);
  const missingFees = [];
  assert.deepEqual(roundTrips(fills.map(f => ({ ...f, commission: null })), start, floor, () => {}, row => missingFees.push(row)), []);
  assert.equal(missingFees.length, 3);
  assert.ok(missingFees.every(row => row.kind === 'broker_evidence_missing' && !('portionHash' in row) && !('at' in row)));
  assert.deepEqual(roundTrips(fills.map(f => ({ ...f, scope: 'legacy' })), start, floor), []);
  assert.deepEqual(roundTrips(fills.map(f => ({ ...f, desk: null })), start, floor), []);
});

test('every configured KEEP symbol is excluded from trades and day totals, including open lots', () => {
  for (const symbol of [...floor, 'ACME']) {
    const producer = openProducer(path.join(temp(), 'results.jsonl'), { keepSymbols: [...floor, 'ACME'], now: () => at });
    producer.ingest(source().concat({ type: 'fill', fill: { ...fills[0], key: 'keep', symbol } }));
    const value = producer.snapshot(at);
    assert.deepEqual(value.trades, []);
    assert.deepEqual(value.days, []);
    producer.close();
  }
});

test('execution days carry null equity, exact totals and omit sessionless dates', () => {
  const trades = roundTrips(fills, start, floor);
  const result = dayCloses(fills, trades, '2026-10-16');
  assert.equal(result.days.length, 1);
  assert.equal(result.days[0].desks.j.equityClose, null);
  assert.equal(result.days[0].desks.j.realisedNet.amount, '7.02');
  assert.equal(result.days[0].desks.j.fees.amount, '0.88');
  assert.equal(result.days[0].desks.j.trades, 3);
  assert.equal(viennaDate('2026-10-25T23:30:00.000Z'), '2026-10-26');
  assert.equal(viennaDate('2026-03-28T23:30:00.000Z'), '2026-03-29');
});

test('own append-only store survives source ledger compaction, restart and old History cuts', () => {
  const dir = temp(), producer = open(dir);
  producer.ingest(source());
  const first = producer.snapshot(at);
  const prefix = readFileSync(path.join(dir, 'results.jsonl'));
  producer.close();
  // Executor ledger has lost every old fill. Capture and accumulated store stay.
  const ledger = { executions: [] }; assert.equal(ledger.executions.length, 0);
  const restarted = open(dir);
  restarted.ingest([...source(), { type: 'authority', at: '2026-11-16T14:00:00.000Z', authoritative: true, disagreement: false }]);
  const next = restarted.snapshot('2026-11-16T14:00:00.000Z');
  // Numeric history survives; closing this day enables the broker backstop,
  // which can now explain its missing reports in rev-5 diagnostics.
  assert.deepEqual(next.days.map(({ partialReasons, ...day }) => day), first.days.map(({ partialReasons, ...day }) => day));
  assert.deepEqual(first.days[0].partialReasons, ['capture_gap']);
  assert.deepEqual(next.days[0].partialReasons, ['capture_gap', 'broker_evidence_missing']);
  assert.deepEqual(next.trades, first.trades);
  assert.equal(next.seq, first.seq + 1); assert.equal(next.trackingStart, '2026-10-16');
  assert.equal(readFileSync(path.join(dir, 'results.jsonl')).subarray(0, prefix.length).equals(prefix), true);
  assert.throws(() => restarted.ingest(source().slice(0, 1)), /regressed/);
  assert.throws(() => restarted.ingest(source().map((s, i) => i === 1 ? { ...s, fill: { ...s.fill, price: '2' } } : s)), /regressed|rewritten/);
  restarted.close();
});

test('every record passes pinned validator; seq advances on re-send and receive time is server owned', async () => {
  const producer = open(temp()); producer.ingest(source());
  const ingress = fixtureIngress({ now: () => at });
  const first = producer.snapshot(at);
  assert.equal(validateContract('results', first, { stage: 'ingress' }).ok, true);
  assert.equal(Object.hasOwn(first, 'receivedAt'), false);
  await ingress.send(first);
  assert.equal(ingress.accepted.value.receivedAt, at);
  await assert.rejects(ingress.send(first), /sequence_replayed/);
  await assert.rejects(ingress.send({ ...producer.snapshot(at), receivedAt: at }), /contract_invalid/);
  assert.throws(() => producer.snapshot(start), /clock_regressed/);
  producer.close();
});

test('25-second re-sends advance generation without fabricating observations; failed send burns seq', async () => {
  let clock = Date.parse(at), fail = false;
  const producer = open(temp()), received = [];
  const runner = createRunner({ producer, now: () => clock, readSource: source, readHealth: () => health,
    transport: { keepSymbols: floor, async send(value) { received.push(value); if (fail) throw new Error('network'); } } });
  assert.equal(await runner.tick(), true);
  clock += CADENCE_MS - 1; assert.equal(await runner.tick(), false);
  clock += 1; fail = true; await assert.rejects(runner.tick(), /network/);
  clock += CADENCE_MS; fail = false; assert.equal(await runner.tick(), true);
  assert.deepEqual(received.map(r => r.seq), [1, 2, 3]);
  assert.deepEqual(received.map(r => r.generatedAt), [at, '2026-10-16T14:00:25.000Z', '2026-10-16T14:00:50.000Z']);
  assert.equal(received.every(r => r.days.length === 1 && r.days[0].desks.j.equityClose === null), true);
  producer.close();
});

test('true fill/broker mismatch emits exact disagreement code; gateway flaps do not', () => {
  const state = { ownershipComplete: true, executions: [rawFill('owned')], ownershipSnapshot: { ownershipComplete: true, positions: [{ conId: 123, position: '0' }] } };
  const evidence = reconciliationEvidence(state, config, floor, dependencies);
  assert.equal(evidence.length, 1); assert.equal(evidence[0].kind, 'fill_position_mismatch');
  const producer = open(temp());
  producer.ingest(source().concat({ type: 'authority', at, authoritative: true, disagreement: true, evidence }));
  assert.equal(producer.snapshot(at).reason, 'executor_broker_disagreement');
  assert.equal(producer.health(health, at).reason, 'executor_broker_disagreement');
  producer.close();
  state.ownershipSnapshot.positions[0].position = '1';
  assert.deepEqual(reconciliationEvidence(state, config, floor, dependencies), []);
  assert.equal(executorHealth({ ...health, gatewayReachable: false }, at).reason, undefined);
  assert.equal(executorHealth({ ...health, gatewayReachable: false }, at).status, 'degraded');
});

test('fractional KEEP positions cannot suppress disagreement; unusable non-KEEP quantities emit evidence', () => {
  const positions = [{ conId: 123, symbol: 'ACME', position: '0' }, { conId: 456, symbol: 'TSLA', position: 0.5 }];
  const state = { ownershipComplete: true, executions: [rawFill('owned')],
    ownershipSnapshot: { ownershipComplete: true, positions } };
  const evidence = () => reconciliationEvidence(state, config, floor, dependencies);
  assert.equal(evidence().length, 1);
  assert.equal(evidence()[0].kind, 'fill_position_mismatch');
  positions[0].position = '1';
  assert.deepEqual(evidence(), []);
  positions[0].position = 1e-7;
  assert.ok(evidence().some(row => row.kind === 'position_unavailable' && row.instrument === hash('123')));
  state.executions = [];
  assert.deepEqual(evidence(), [{ kind: 'position_unavailable', instrument: hash('123') }]);
});

test('foreign/netted broker residuals and incomplete snapshots do not manufacture disagreements', () => {
  const state = { ownershipComplete: true, executions: [rawFill('owned'), rawFill('foreign', { clientId: 999 })], ownershipSnapshot: { ownershipComplete: true, positions: [] } };
  assert.deepEqual(reconciliationEvidence(state, config, floor, dependencies), []);
  state.executions.pop(); state.ownershipSnapshot.ownershipComplete = false;
  assert.deepEqual(reconciliationEvidence(state, config, floor, dependencies), []);
});

test('capture is durable before pruning, never writes raw identifiers, and persists commission updates', () => {
  const dir = temp(); mkdirSync(path.join(dir, 'executor'));
  const capture = createCapture(path.join(dir, 'input.jsonl'), config, { ...dependencies, now: () => start });
  const ledger = openLedger(path.join(dir, 'executor'), { beforePrune: capture });
  const state = ledger.load(); state.ownershipComplete = true; state.executions = [rawFill('private-execution')];
  state.placements.push({ desk: 'j', symbol: 'ACME', status: 'filled', day: '2026-01-01', reservedAt: '2026-01-01T00:00:00.000Z' });
  ledger.save(state);
  assert.equal(state.placements.length, 0);
  let rows = readJournal(path.join(dir, 'input.jsonl'));
  assert.equal(rows.some(r => r.type === 'cut' && r.fills.length), true);
  state.commissions = [{ execId: 'private-execution.01', commission: '0.1', currency: 'EUR' }];
  ledger.save(state);
  rows = readJournal(path.join(dir, 'input.jsonl'));
  assert.equal(rows.flatMap(r => r.fills || []).length, 2);
  const bytes = readFileSync(path.join(dir, 'input.jsonl'), 'utf8');
  for (const forbidden of [ACCOUNT, 'private-execution', 'orderRef', 'orderId', 'acctNumber']) assert.equal(bytes.includes(forbidden), false);
  capture.close();
});

test('capture failure prevents compaction and pre-admission pruning without rewriting ledger', () => {
  const dir = temp(), ledger = openLedger(dir), initial = ledger.load();
  const before = readFileSync(path.join(dir, 'ledger.json'));
  const failing = openLedger(dir, { beforePrune: () => { throw new Error('capture_disk_full'); } });
  assert.throws(() => failing.save(initial), /capture_disk_full/);
  assert.equal(readFileSync(path.join(dir, 'ledger.json')).equals(before), true);
});

test('capture excludes KEEP fills before financial conversion', () => {
  const filename = path.join(temp(), 'capture.jsonl');
  const capture = createCapture(filename, config, { ...dependencies, now: () => start });
  const protectedRows = floor.map(symbol => ({ ...rawFill(`synthetic-${symbol}`), contract: { conId: 321, symbol, currency: 'EUR' } }));
  capture({ ownershipComplete: true, executions: protectedRows });
  assert.deepEqual(readJournal(filename).flatMap(event => event.fills || []), []);
  capture.close();
});

test('real executor ledger compaction and capture/producer restarts preserve accumulated trades', () => {
  const dir = temp(), executor = path.join(dir, 'executor'); mkdirSync(executor);
  const capturePath = path.join(dir, 'input.jsonl');
  let capture = createCapture(capturePath, config, { ...dependencies, now: () => start });
  const ledger = openLedger(executor, { beforePrune: state => capture(state) });
  const state = ledger.load();
  const buy = rawFill('buy'), sell = rawFill('sell', { side: 'SLD', price: '12', time: at });
  state.ownershipComplete = true; state.executions = [buy, sell];
  state.ownershipSnapshot = { ownershipComplete: true, positions: [] };
  state.commissions = [buy, sell].map(row => ({ execId: row.execution.execId, commission: '0.1', currency: 'EUR' }));
  ledger.save(state);
  const producerDir = path.join(dir, 'producer'); let producer = open(producerDir);
  producer.ingest(readJournal(capturePath)); const first = producer.snapshot(at);
  assert.equal(first.trades.length, 1); assert.equal(first.trades[0].netEur.amount, '1.8');
  // Simulated future fill-window compaction: the saved ledger truly loses fills.
  state.executions = []; state.commissions = []; ledger.save(state);
  assert.equal(ledger.load().executions.length, 0);
  capture.close(); producer.close();
  capture = createCapture(capturePath, config, { ...dependencies, now: () => at }); capture(ledger.load());
  producer = open(producerDir); producer.ingest(readJournal(capturePath));
  assert.deepEqual(producer.snapshot(at).trades, first.trades);
  capture.close(); producer.close();
});

test('capture cuts are atomic: an in-flight final line never exposes a partial fill batch', () => {
  const dir = temp(), filename = path.join(dir, 'capture.jsonl');
  const journal = openJournal(filename); journal.append({ type: 'start', at: start });
  const cut = { type: 'cut', at, fills, authoritative: true, disagreement: false, evidence: [] };
  journal.append(cut); journal.close();
  const bytes = readFileSync(filename);
  writeFileSync(filename, bytes.subarray(0, bytes.length - 20));
  assert.deepEqual(readJournal(filename), [{ type: 'start', at: start }]);
});

test('explicit external reattribution revokes old captured ownership without deleting history', () => {
  const dir = temp(), filename = path.join(dir, 'input.jsonl');
  const capture = createCapture(filename, config, { ...dependencies, now: () => start });
  const row = rawFill('assigned'); const state = { ownershipComplete: true, executions: [row] };
  capture(state);
  row.attribution = { method: 'external', desk: null }; capture(state);
  const events = readJournal(filename), updates = events.flatMap(e => e.fills || []);
  assert.equal(updates.length, 2);
  assert.equal(updates[0].desk, 'j'); assert.equal(updates[1].scope, 'excluded');
  const producer = open(temp()); producer.ingest(events);
  assert.deepEqual(producer.snapshot(at).trades, []);
  producer.close(); capture.close();
});

test('historical fills never receive current FX; capture uses exact observed close rate', () => {
  const dir = temp(), filename = path.join(dir, 'input.jsonl');
  const capture = createCapture(filename, config, { ...dependencies, now: () => at });
  const state = { ownershipComplete: true, executions: [{ ...rawFill('usd'), contract: { conId: 123, symbol: 'ACME', currency: 'USD' } }], resultsFx: { USD: { base: 'USD', quote: 'EUR', rate: '0.91234567', source: 'synthetic', observedAt: at } } };
  capture(state);
  assert.equal(readJournal(filename).flatMap(e => e.fills || [])[0].closeFx, null);
  state.resultsFx.USD.observedAt = start; capture(state);
  assert.equal(readJournal(filename).flatMap(e => e.fills || []).at(-1).closeFx.rate, '0.91234567');
  capture.close();
});

test('journal tampering and torn tails fail closed, and source symlinks are refused', () => {
  const dir = temp(), filename = path.join(dir, 'journal.jsonl');
  const journal = openJournal(filename); journal.append({ type: 'start', at }); journal.close();
  const bytes = readFileSync(filename, 'utf8');
  writeFileSync(filename, bytes.replace(at, start));
  assert.throws(() => openJournal(filename), /journal_corrupt/);
  writeFileSync(filename, bytes); appendFileSync(filename, '{');
  assert.throws(() => openJournal(filename), /journal_torn_tail/);
  symlinkSync(filename, path.join(dir, 'link'));
  assert.throws(() => readJournal(path.join(dir, 'link')));
});

test('byte-exact closure check rejects altered, missing and extra vendored contract bytes', () => {
  assert.equal(verifyContracts(), true);
  function copy() {
    const dir = temp(); cpSync(path.join(root, 'contracts'), path.join(dir, 'contracts'), { recursive: true });
    cpSync(path.join(root, 'contracts.lock.json'), path.join(dir, 'contracts.lock.json'));
    return dir;
  }
  const dir = copy();
  appendFileSync(path.join(dir, 'contracts/results.schema.json'), '\n');
  assert.throws(() => verifyContracts(dir), /contract_bytes_drift/);
  // Rehashing candidate bytes in the lock must not move the independent pin.
  const lock = JSON.parse(readFileSync(path.join(dir, 'contracts.lock.json'), 'utf8'));
  const altered = readFileSync(path.join(dir, 'contracts/results.schema.json'));
  lock.files['results.schema.json'] = { bytes: altered.length, sha256: createHash('sha256').update(altered).digest('hex') };
  writeFileSync(path.join(dir, 'contracts.lock.json'), JSON.stringify(lock));
  assert.throws(() => verifyContracts(dir), /contract_set_drift/);
  writeFileSync(path.join(dir, 'contracts/unexpected.json'), '{}');
  assert.throws(() => verifyContracts(dir), /contract_closure_drift/);
  const missing = copy();
  renameSync(path.join(missing, 'contracts/vienna-date.mjs'), path.join(missing, 'saved-vienna-date.mjs'));
  assert.throws(() => verifyContracts(missing), /contract_closure_drift/);
  const incomplete = JSON.parse(readFileSync(path.join(missing, 'contracts.lock.json'), 'utf8'));
  delete incomplete.files['vienna-date.mjs'];
  writeFileSync(path.join(missing, 'contracts.lock.json'), JSON.stringify(incomplete));
  assert.throws(() => verifyContracts(missing), /contract_set_drift/);
  for (const [key, value, error] of [['revision', '0'.repeat(40), 'contract_pin_drift'], ['manifest_revision', 2, 'contract_pin_drift'], ['contract_set_sha256', '0'.repeat(64), 'contract_set_drift']]) {
    const drift = copy(), pinned = JSON.parse(readFileSync(path.join(drift, 'contracts.lock.json'), 'utf8'));
    pinned[key] = value;
    writeFileSync(path.join(drift, 'contracts.lock.json'), JSON.stringify(pinned));
    assert.throws(() => verifyContracts(drift), new RegExp(error));
  }
  const linked = copy();
  renameSync(path.join(linked, 'contracts/vienna-date.mjs'), path.join(linked, 'saved-vienna-date.mjs'));
  symlinkSync('../saved-vienna-date.mjs', path.join(linked, 'contracts/vienna-date.mjs'));
  assert.throws(() => verifyContracts(linked), /contract_regular_files_required/);
});

test('transport allows only configured endpoint, refuses redirects/receipt headers and validates before send', async () => {
  assert.throws(() => httpTransport('http://example.invalid/joe/inbox/results'), /invalid_ingress_endpoint/);
  assert.throws(() => httpTransport('https://user:password@example.invalid/joe/inbox/results'), /invalid_ingress_endpoint/);
  const producer = open(temp()); producer.ingest(source());
  let call;
  const transport = httpTransport('https://example.invalid/joe/inbox/results', { origin: 'https://example.invalid', headers: () => ({ authorization: 'Bearer synthetic-joed20-token' }), fetchImpl: async (url, request) => { call = { url, request }; return new Response('{}', { status: 200 }); } });
  await transport.send(producer.snapshot(at));
  assert.equal(call.request.redirect, 'error'); assert.equal(call.request.method, 'POST');
  assert.equal(call.request.headers.has('x-joe-received-at'), false);
  await assert.rejects(transport.send({ schema: 'bad' }), /schema_unsupported/);
  await assert.rejects(httpTransport('https://example.invalid/joe/inbox/results', { origin: 'https://example.invalid', headers: () => ({ 'X-Joe-Received-At': at }) }).send(producer.snapshot(at)), /server_owned_header/);
  producer.close();
});

test('loopback health listener has no write, admin or order routes', async () => {
  const server = createHealthServer(() => health);
  // Same socket-free HTTP handler strategy as paper-desk-executor/server.test.
  // Actual loopback bind/transport is part of the operator's paper proof.
  const request = (url, method = 'GET') => new Promise(resolve => {
    server.emit('request', { url, method, resume() {} }, { writeHead(status) { this.status = status; }, end(body) { resolve({ status: this.status, body: JSON.parse(body) }); } });
  });
  assert.equal((await request('/v1/health')).status, 200);
  for (const endpoint of ['/v1/intents', '/v1/halt', '/v1/admin/attribution', '/v1/health']) assert.equal((await request(endpoint, 'POST')).status, 404);
  assert.equal((await request('/v1/health?write=true')).status, 404);
});
