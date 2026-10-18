import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import { openProducer, createRunner, CADENCE_MS } from './producer.mjs';
import { roundTrips, dayCloses } from './fifo.mjs';
import { dayCoverage, validateResults } from './results-validation.mjs';
import { httpTransport, credentialHeaders, IngressError, failureDiagnostic, RESULTS_PATH } from './transport.mjs';
import { createFixtureIngressServer } from './fixture-ingress.mjs';
import { CONTRACTS, REASONS, validateContract } from './contracts/index.mjs';

const at = '2026-10-17T12:00:00.000Z', start = '2026-10-15T22:00:00.000Z'; // Vienna midnight
const fixture = name => JSON.parse(readFileSync(new URL(`fixtures/${name}`, import.meta.url), 'utf8'));
const fills = fixture('fills.json'), health = fixture('health.json');
const keep = ['SXR8', 'TSLA'];
const headers = () => ({ authorization: 'Bearer synthetic-joed20-token' });
const endpoint = `https://board.example.invalid${RESULTS_PATH}`;
const temp = () => mkdtempSync(path.join(tmpdir(), 'joed20-r3-'));
const intervals = [[Date.parse(start), Date.parse(at)]];
const source = () => [{ type: 'start', at: start }, { type: 'cut', at, fills, authoritative: true, disagreement: false, historyCoverage: { status: 'complete', target: { fromInclusive: start, toExclusive: at }, gaps: [] } }];
function ready({ directory = temp(), now = () => at } = {}) {
  const producer = openProducer(path.join(directory, 'results.jsonl'), { now });
  producer.ingest(source());
  return producer;
}

// Exercise the actual Node HTTP handler without binding a socket in Codex.
function request(fixture, body, { authorization = headers().authorization, url = RESULTS_PATH, method = 'POST' } = {}) {
  const req = Readable.from([Buffer.from(typeof body === 'string' ? body : JSON.stringify(body))]);
  Object.assign(req, { url, method, headers: { authorization, 'content-type': 'application/json' } });
  return new Promise(resolve => fixture.server.emit('request', req, {
    writeHead(status, responseHeaders) { this.status = status; this.headers = responseHeaders; },
    end(raw) { resolve({ status: this.status, headers: this.headers, body: JSON.parse(raw) }); },
  }));
}

test('fixture results inbox mirrors 200/422/401/413/400/503 and retains last good', async () => {
  let clock = Date.parse(at);
  const server = createFixtureIngressServer({ now: () => new Date(clock).toISOString() });
  const producer = ready(), first = producer.snapshot();
  const good = await request(server, first);
  assert.equal(good.status, 200);
  assert.equal(good.headers['X-Joe-Received-At'], at);
  const accepted = server.accepted;
  for (const seq of [first.seq, first.seq - 1]) {
    // seq=0 is a schema failure; use an already accepted higher seq below too.
    assert.equal((await request(server, { ...first, seq })).status, 422);
    assert.equal(server.accepted, accepted);
  }
  const ahead = await request(server, { ...first, seq: 2, generatedAt: '2026-10-17T12:00:05.001Z' });
  assert.equal(ahead.status, 422); assert.equal(ahead.body.reason, 'clock_ahead');
  assert.equal(server.accepted, accepted);
  const tolerance = await request(server, { ...first, seq: 2, generatedAt: '2026-10-17T12:00:05.000Z' });
  assert.equal(tolerance.status, 200);
  const replay = await request(server, first);
  assert.equal(replay.body.reason, 'sequence_replayed');
  const regressed = await request(server, { ...first, seq: 3 });
  assert.equal(regressed.body.reason, 'clock_regressed');
  assert.equal((await request(server, first, { authorization: 'Bearer synthetic-wrong-token' })).status, 401);
  assert.equal((await request(createFixtureIngressServer({ token: null }), first)).status, 503);
  assert.equal((await request(server, '{')).status, 400);
  assert.equal((await request(server, ' '.repeat(CONTRACTS.limits.results + 1))).status, 413);
  assert.equal((await request(server, [first])).status, 422);
  assert.equal((await request(server, { ...first, receivedAt: at })).status, 422);
  assert.equal(Object.hasOwn(first, 'missingDays'), false);
  const serverOwned = await request(server, { ...first, missingDays: ['2026-10-16'] });
  assert.equal(serverOwned.status, 422);
  assert.ok(serverOwned.body.errors.some(error => error.path === '$.missingDays' && error.rule === 'serverOwned'));
  const duplicate = validateContract('results', { ...first, receivedAt: at, missingDays: ['2026-10-16', '2026-10-16'] }, { stage: 'served' });
  assert.ok(duplicate.errors.some(error => error.path === '$.missingDays' && error.rule === 'uniqueItems'));
  assert.equal((await request(server, first, { url: '/joe/inbox' })).status, 404);
  assert.equal((await request(server, first, { method: 'GET' })).status, 405);
  clock += 59_999; assert.equal(server.stale, false);
  clock++; assert.equal(server.stale, true);
  producer.close();
});

test('HTTP transport posts exactly one snapshot with shared-token auth and contract size limit', async () => {
  const producer = ready(), server = createFixtureIngressServer({ now: () => at });
  const transport = httpTransport(endpoint, { origin: 'https://board.example.invalid', headers, fetchImpl: async (url, options) => {
    assert.equal(url.href, endpoint); assert.equal(options.method, 'POST'); assert.equal(options.redirect, 'error');
    assert.equal(options.headers.get('content-type'), 'application/json');
    assert.equal(options.headers.has('x-joe-received-at'), false);
    const result = await request(server, options.body, { authorization: options.headers.get('authorization') });
    return new Response(JSON.stringify(result.body), { status: result.status, headers: result.headers });
  } });
  const first = producer.snapshot(); await transport.send(first);
  assert.deepEqual(transport.lastGood, first);
  await assert.rejects(transport.send(first), error => error.status === 422 && error.reason === 'sequence_replayed');
  assert.deepEqual(transport.lastGood, first);
  await transport.send(producer.snapshot());
  assert.equal(server.accepted.value.seq, 2);
  await assert.rejects(transport.send({ ...first, unexpected: 'x'.repeat(CONTRACTS.limits.results) }), error => error.status === 413);
  await assert.rejects(httpTransport(endpoint, { origin: 'https://board.example.invalid' }).send(first), /auth_required/);
  for (const url of ['http://board.example.invalid/joe/inbox/results', 'https://board.example.invalid/joe/inbox', `${endpoint}?token=synthetic`, `${endpoint}#fragment`]) assert.throws(() => httpTransport(url, { origin: 'https://board.example.invalid' }), /invalid_ingress_endpoint/);
  assert.doesNotThrow(() => httpTransport(`http://127.0.0.1:2345${RESULTS_PATH}`, { origin: "http://127.0.0.1:2345" }));
  await assert.rejects(httpTransport(endpoint, { origin: 'https://board.example.invalid', headers: () => new Headers({ ...headers(), 'x-joe-received-at': at }) }).send(first), /server_owned_header/);
  producer.close();
});

test('transport refuses an ingress-valid payload whose server timestamp would exceed the served limit', async () => {
  const producer = ready();
  try {
    const payload = { ...producer.snapshot(), days: [], trades: [] };
    const trade = { ...roundTrips(fills, start, keep)[0], id: 'rt-synthetic-00000000', company: 'x' };
    const emptyBytes = Buffer.byteLength(JSON.stringify(payload));
    const perTrade = Buffer.byteLength(JSON.stringify(trade)) + 1;
    const count = Math.floor((CONTRACTS.limits.results - emptyBytes + 1) / perTrade);
    payload.trades = Array.from({ length: count }, (_, i) => ({ ...trade, id: `rt-synthetic-${String(i).padStart(8, '0')}` }));
    let remaining = CONTRACTS.limits.results - Buffer.byteLength(JSON.stringify(payload));
    for (const row of payload.trades) {
      const padding = Math.min(remaining, 99);
      row.company += 'x'.repeat(padding); remaining -= padding;
      if (!remaining) break;
    }
    assert.equal(remaining, 0);
    assert.equal(Buffer.byteLength(JSON.stringify(payload)), CONTRACTS.limits.results);
    assert.equal(validateResults(payload).ok, true);
    assert.ok(Buffer.byteLength(JSON.stringify({ ...payload, receivedAt: at })) > CONTRACTS.limits.results);
    let accessed = false;
    const transport = httpTransport(endpoint, { origin: 'https://board.example.invalid', headers: () => { accessed = true; return headers(); },
      fetchImpl: async () => { accessed = true; throw new Error('unexpected_send'); } });
    await assert.rejects(transport.send(payload), error => error.status === 413 && error.reason === 'too_large');
    assert.equal(accessed, false); assert.equal(transport.lastGood, null);
  } finally { producer.close(); }
});

test('only the systemd credential copy is read; missing, empty and symlink tokens fail closed', () => {
  const directory = temp(), tokenFile = path.join(directory, 'joe-board-push-token');
  writeFileSync(tokenFile, 'synthetic-joed20-token\n', { mode: 0o600 });
  assert.deepEqual(credentialHeaders(directory, directory)(), headers());
  assert.throws(() => credentialHeaders(undefined)(), /auth_required/);
  assert.throws(() => credentialHeaders(temp())(), /auth_required/);
  writeFileSync(tokenFile, ''); assert.throws(() => credentialHeaders(directory, directory)(), /auth_required/);
  writeFileSync(tokenFile, 'synthetic\ninjected'); assert.throws(() => credentialHeaders(directory, directory)(), /auth_required/);
  const linkDir = temp(); symlinkSync(tokenFile, path.join(linkDir, 'joe-board-push-token'));
  assert.throws(() => credentialHeaders(linkDir, linkDir)(), /auth_required/);
});

test('rejection diagnostics are bounded and value-free for each HTTP outcome', async () => {
  const producer = ready(), candidate = producer.snapshot();
  for (const [status, reason] of [[400, 'contract_invalid'], [401, 'auth_required'], [413, 'too_large'], [503, 'ingress_unavailable'], [422, 'clock_ahead']]) {
    const errors = Array.from({ length: 25 }, () => ({ path: '$.generatedAt', rule: 'clockAhead', value: 'synthetic-private-body' }));
    errors.unshift({ path: '$.synthetic-private-body', rule: 'clockAhead' });
    const transport = httpTransport(endpoint, { origin: 'https://board.example.invalid', headers, fetchImpl: async () => new Response(JSON.stringify({ reason: 'clock_ahead', errors, private: 'synthetic-private-body' }), { status }) });
    await assert.rejects(transport.send(candidate), error => {
      const log = failureDiagnostic(error);
      assert.equal(log.reason, reason); assert.equal(log.httpStatus, status);
      assert.ok(log.errors.length <= 20);
      assert.equal(JSON.stringify(log).includes('synthetic-private-body'), false);
      assert.ok(log.errors.every(item => Object.keys(item).join(',') === 'path,rule'));
      return true;
    });
  }
  const huge = httpTransport(endpoint, { origin: 'https://board.example.invalid', headers, fetchImpl: async () => new Response('x'.repeat(16_385), { status: 422 }) });
  await assert.rejects(huge.send(candidate), error => error.reason === 'ingress_rejected' && error.errors.length === 0);
  const network = httpTransport(endpoint, { origin: 'https://board.example.invalid', headers, fetchImpl: async () => { throw new Error('synthetic-private-body'); } });
  await assert.rejects(network.send(candidate), /transport_failed/);
  producer.close();
});

test('bounded backoff covers rejection statuses; every retry reserves a fresh sequence', async () => {
  for (const status of [400, 401, 413, 422, 503]) {
    let clock = Date.parse(at), attempts = [], failed = true;
    const producer = ready({ now: () => new Date(clock).toISOString() });
    const runner = createRunner({ producer, now: () => clock, readSource: source, readHealth: () => health,
      transport: { keepSymbols: keep, async send(payload) { attempts.push(payload); if (failed) throw new IngressError(status, 'contract_invalid'); } } });
    for (const delay of [1000, 2000, 4000, 8000, 16000, CADENCE_MS, CADENCE_MS]) {
      await assert.rejects(runner.tick());
      clock += delay - 1; assert.equal(await runner.tick(), false);
      clock++; // exactly the retry deadline
    }
    failed = false; assert.equal(await runner.tick(), true);
    assert.deepEqual(attempts.map(p => p.seq), [1, 2, 3, 4, 5, 6, 7, 8]);
    assert.ok(attempts.every((p, i) => i === 0 || Date.parse(p.generatedAt) - Date.parse(attempts[i - 1].generatedAt) <= 30_000));
    producer.close();
  }
});

test('ambiguous send burns durable seq across restart; future requests clamp to now, rollback holds', async () => {
  const directory = temp(); let clock = Date.parse(at), lastSeq;
  let producer = ready({ directory, now: () => new Date(clock).toISOString() });
  const runner = createRunner({ producer, now: () => clock, readSource: source, readHealth: () => health,
    transport: { keepSymbols: keep, async send(payload) { lastSeq = payload.seq; throw new IngressError(0, 'transport_failed'); } } });
  await assert.rejects(runner.tick()); producer.close();
  producer = ready({ directory, now: () => new Date(clock).toISOString() });
  const after = producer.snapshot('2026-12-01T00:00:00.000Z');
  assert.equal(after.seq, lastSeq + 1); assert.equal(after.generatedAt, at);
  clock--; assert.throws(() => producer.snapshot(), /clock_regressed/);
  clock++; assert.equal(producer.snapshot().seq, after.seq + 1);
  producer.close();
});

test('health and transport time consume the retry budget instead of extending the 25-second cycle', async () => {
  let clock = Date.parse(at);
  const producer = ready({ now: () => new Date(clock).toISOString() });
  const runner = createRunner({ producer, now: () => clock, readSource: source,
    readHealth: () => { clock += 3000; return health; },
    transport: { keepSymbols: keep, async send() { clock += 4000; throw new IngressError(503, 'ingress_unavailable'); } } });
  for (const backoff of [1000, 2000, 4000, 8000, 16000, 25000]) {
    const cycleStart = clock;
    await assert.rejects(runner.tick(), /ingress_unavailable/);
    const deadline = Math.min(cycleStart + CADENCE_MS, clock + backoff);
    clock = deadline - 1; assert.equal(await runner.tick(), false);
    clock = deadline;
  }
  producer.close();
});

test('full Vienna day totals include later closes and every traded desk without inventing equity', () => {
  const extra = ['joe', 'joel'].flatMap(desk => fills.map(fill => ({ ...fill, desk, key: `${desk}-${fill.key}` })));
  const trades = roundTrips([...fills, ...extra], start, keep);
  // Every execution desk contributes totals without household equity.
  const close = dayCloses([...fills, ...extra], trades, '2026-10-16', { from: start, through: at, intervals });
  assert.equal(close.coverage['2026-10-16'], 'full');
  assert.equal(close.days[0].desks.j.trades, 3);
  assert.equal(close.days[0].desks.j.realisedNet.amount, '7.02');
  assert.equal(close.days[0].desks.j.fees.amount, '0.88');
  assert.equal(Object.hasOwn(close.days[0], 'coverage'), false); // documented full default
  assert.equal(close.days[0].desks.joe.trades, 3);
  assert.equal(close.days[0].desks.joe.equityClose, null);
  assert.equal(close.days[0].desks.joel.trades, 3);
  assert.equal(close.days[0].desks.joel.equityClose, null);
  const producer = ready(), payload = { ...producer.snapshot(), days: close.days, trades };
  assert.equal(validateResults(payload).ok, true);
  for (const [field, value, rule] of [['trades', 2, 'dayTradeCount'], ['realisedNet', { amount: '7.01', currency: 'EUR' }, 'dayNetSum'], ['fees', { amount: '0.87', currency: 'EUR' }, 'dayFeeSum']]) {
    const bad = structuredClone(payload); bad.days[0].desks.j[field] = value;
    const checked = validateContract('results', bad, { stage: 'ingress' });
    assert.equal(checked.status, 422); assert.equal(checked.reason, 'contract_invalid');
    assert.deepEqual(validateResults(bad), checked);
    assert.ok(checked.errors.some(error => error.rule === rule));
  }
  for (const desk of ['j', 'joe', 'joel']) {
    const missing = structuredClone(payload); delete missing.days[0].desks[desk];
    assert.ok(validateResults(missing).errors.some(error => error.path === `$.days[0].desks.${desk}` && error.rule === 'dayDeskRequired'));
  }
  assert.equal(validateResults({ ...payload, days: [] }).ok, true);
  producer.close();
});

test('partial coverage travels on the wire at window boundaries and Vienna DST', () => {
  assert.equal(dayCoverage('2026-10-16', '2026-10-16T11:00:00.000Z', at), 'partial');
  assert.equal(dayCoverage('2026-10-17', start, at), 'partial');
  assert.equal(dayCoverage('2026-10-16', start, at, intervals), 'full');
  assert.equal(dayCoverage('2026-10-25', '2026-10-24T22:00:00.000Z', '2026-10-25T23:00:00.000Z', [[Date.parse('2026-10-24T22:00:00.000Z'), Date.parse('2026-10-25T23:00:00.000Z')]]), 'full');
  assert.equal(dayCoverage('2026-03-29', '2026-03-28T23:00:00.000Z', '2026-03-29T22:00:00.000Z', [[Date.parse('2026-03-28T23:00:00.000Z'), Date.parse('2026-03-29T22:00:00.000Z')]]), 'full');
  const trades = roundTrips(fills, start, keep);
  const partial = dayCloses(fills, trades, '2026-10-16', { from: '2026-10-16T11:00:00.000Z', through: at });
  assert.equal(partial.coverage['2026-10-16'], 'partial');
  assert.equal(partial.days[0].coverage, 'partial');
  const producer = ready(), payload = { ...producer.snapshot(), days: partial.days };
  assert.equal(validateContract('results', payload, { stage: 'ingress' }).ok, true);
  const windowed = { ...payload, trades: payload.trades.slice(1) };
  assert.equal(validateContract('results', windowed, { stage: 'ingress' }).ok, true);
  assert.equal(validateResults(windowed).ok, true);
  for (const coverage of [undefined, 'full']) {
    const full = structuredClone(windowed);
    delete full.days[0].partialReasons;
    if (coverage) full.days[0].coverage = coverage;
    else delete full.days[0].coverage;
    const checked = validateResults(full);
    assert.equal(checked.status, 422); assert.equal(checked.reason, 'contract_invalid');
    assert.ok(checked.errors.some(error => error.rule === 'dayTradeCount'));
  }
  const invalid = structuredClone(windowed); invalid.trades[0].netEur.amount = '999';
  assert.ok(validateResults(invalid).errors.some(error => error.rule === 'netAfterFees'));
  const invalidCoverage = structuredClone(windowed); invalidCoverage.days[0].coverage = 'unknown';
  assert.equal(validateResults(invalidCoverage).status, 422);
  producer.close();
});

test('KEEP round trips are excluded from both arrays, leaving exact ordinary trade day totals', () => {
  const producer = ready();
  const protectedFills = keep.flatMap(symbol => fills.map(fill => ({ ...fill, key: `${symbol}-${fill.key}`, symbol, instrument: `synthetic-${symbol}` })));
  producer.ingest([...source(), ...protectedFills.map(fill => ({ type: 'fill', fill }))]);
  const value = producer.snapshot();
  assert.equal(value.trades.length, 3); assert.ok(value.trades.every(trade => !keep.includes(trade.symbol)));
  assert.equal(value.days[0].desks.j.trades, 3);
  assert.equal(value.days[0].desks.j.realisedNet.amount, '7.02');
  assert.equal(value.days[0].desks.j.fees.amount, '0.88');
  assert.equal(validateResults(value).ok, true);
  const partial = dayCloses(fills, value.trades, '2026-10-16', { from: '2026-10-16T11:00:00.000Z', through: at });
  assert.equal(partial.days[0].coverage, 'partial');
  assert.deepEqual(partial.days[0].desks, value.days[0].desks);
  assert.equal(validateContract('results', { ...value, days: partial.days }, { stage: 'ingress' }).ok, true);
  for (const symbol of keep) {
    const forbidden = structuredClone(value); forbidden.days = partial.days; forbidden.trades[0].symbol = symbol;
    assert.ok(validateResults(forbidden).errors.some(error => error.rule === 'keepExcluded'));
  }
  producer.close();
});

test('EUR fee allocation uses the pre-tracking budget and final remainder', () => {
  const input = [
    { ...fills[0], quantity: '3', price: '10', commission: { amount: '0.00000001', currency: 'EUR' } },
    { ...fills[2], quantity: '1', price: '11', commission: { amount: '0', currency: 'EUR' }, closeFx: { ...fills[2].closeFx, rate: '1' } },
  ];
  assert.equal(roundTrips(input, start, keep)[0].feesEur.amount, '0');
  // Pre-tracking allocation rounded the opening share up; its final remainder
  // is zero. The closing allocation rounds to one source-currency unit.
  input[0].at = '2026-10-15T12:00:00.000Z';
  input[1].quantity = '3'; input[1].commission.amount = '0.00000002';
  input.splice(1, 0, { ...input[0], key: 'pre-tracking-close', side: 'SELL', quantity: '2', at: '2026-10-15T13:00:00.000Z' });
  assert.equal(roundTrips(input, start, keep)[0].feesEur.amount, '0.00000001');
});


test('fixture accepts partial coverage and rejects full-day mismatches with vendored 422 rules', async () => {
  const producer = ready(), server = createFixtureIngressServer({ now: () => at });
  const full = producer.snapshot();
  // This test exercises ingress full-day reconciliation independently of the
  // backstop: this fixture lacks broker reports and carries a partial marker.
  delete full.days[0].coverage; delete full.days[0].partialReasons;
  const partial = structuredClone(full);
  partial.days[0].coverage = 'partial'; partial.days[0].partialReasons = ['history_gap']; partial.trades = partial.trades.slice(1);
  assert.equal((await request(server, partial)).status, 200);
  const accepted = server.accepted;
  for (const [field, value, rule] of [['trades', 0, 'dayTradeCount'], ['realisedNet', { amount: '0', currency: 'EUR' }, 'dayNetSum'], ['fees', { amount: '0', currency: 'EUR' }, 'dayFeeSum']]) {
    const bad = structuredClone(full); bad.seq++;
    bad.days[0].desks.j[field] = value;
    const response = await request(server, bad);
    assert.equal(response.status, 422); assert.equal(response.body.reason, 'contract_invalid');
    assert.ok(response.body.errors.some(error => error.path === `$.days[0].desks.j.${field}` && error.rule === rule));
    assert.equal(server.accepted, accepted);
  }
  const missing = structuredClone(full); missing.seq++; delete missing.days[0].desks.j;
  const rejected = await request(server, missing);
  assert.equal(rejected.status, 422);
  assert.ok(rejected.body.errors.some(error => error.rule === 'dayDeskRequired'));
  assert.equal(server.accepted, accepted);
  producer.close();
});

test('producer emits partial coverage from its capture interval and removed reasons fail closed', () => {
  const producer = openProducer(path.join(temp(), 'results.jsonl'), { now: () => at });
  const rows = source(); rows[0].at = '2026-10-16T11:00:00.000Z';
  producer.ingest(rows);
  const value = producer.snapshot();
  assert.equal(value.days[0].coverage, 'partial');
  assert.equal(validateContract('results', value, { stage: 'ingress' }).ok, true);
  assert.equal(CONTRACTS.revision, 6);
  assert.equal(REASONS.includes('results_not_wired'), false);
  assert.equal(validateResults({ ...value, reason: 'results_not_wired' }).status, 422);
  producer.close();
});
