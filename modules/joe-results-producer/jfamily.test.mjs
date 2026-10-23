import '../../tests/paper-desk-account-fixture.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { ACCOUNT, DESKS as EXECUTOR_DESKS, activityAttribution, executionTimeMs } from '../paper-desk-executor/policy.mjs';
import { DESKS, resultsDesk, invalidFillField, roundTrips, dayCloses } from './fifo.mjs';
import { createCapture, reconciliationEvidence } from './capture.mjs';
import { capturePositionProof, earlierGapDays, PositionProofIndex } from './position-proof.mjs';
import { brokerDayTotals } from './broker-backstop.mjs';
import { hash, openJournal, readJournal } from './journal.mjs';
import { openProducer } from './producer.mjs';
import { validateResults } from './results-validation.mjs';
import { verifyContracts } from './verify-contracts.mjs';

const start = '2026-10-21T22:00:00.000Z', end = '2026-10-22T22:00:00.000Z';
const opened = '2026-10-22T14:16:46.000Z', closed = '2026-10-22T14:56:07.000Z';
const keep = ['SXR8', 'TSLA'];
const config = { executorClientId: 705, ownClientIds: [705], foreignAlertSince: start };
const dependencies = { account: ACCOUNT, attribute: activityAttribution, executionTime: executionTimeMs };
const contract = { conId: 1, symbol: 'ACME', currency: 'EUR' };
const instrument = hash([contract.conId, contract.symbol, contract.currency]);
const history = { status: 'complete', target: { fromInclusive: start, toExclusive: end }, gaps: [] };
const root = mkdtempSync(path.join(tmpdir(), 'joed68-jfamily-'));
const temp = () => mkdtempSync(path.join(root, 'case-'));

function raw(key, desk, side = 'BUY', at = opened, overrides = {}) {
  return { contract: { ...contract }, execution: { execId: `${key}.01`, acctNumber: ACCOUNT, clientId: 705,
    orderRef: `${desk}|261022|synthetic`, time: at, side, shares: '1', price: '10', ...overrides } };
}

function fill(key, book, side, at, overrides = {}) {
  return { key, desk: resultsDesk(book), book, scope: 'stage0', instrument, symbol: 'ACME', currency: 'EUR',
    side, at, quantity: '1', price: '10', commission: { amount: '0', currency: 'EUR' },
    brokerRealised: { unset: true, currency: 'EUR' },
    closeFx: { base: 'EUR', quote: 'EUR', rate: '1', source: 'identity', observedAt: at }, ...overrides };
}

function stateFor(executions, positions = []) {
  return { ownershipComplete: true, executions, commissions: executions.map(row => ({
    execId: row.execution.execId, commission: '0', currency: 'EUR', realizedPNL: Number.MAX_VALUE,
  })), resultsHistoryCoverage: history,
  ownershipSnapshot: { account: ACCOUNT, ownershipComplete: true, observedAt: end, positions } };
}

function setup(t, { seed = [], attribute = activityAttribution } = {}) {
  const dir = temp(), input = path.join(dir, 'capture.jsonl'), output = path.join(dir, 'producer.jsonl');
  if (seed.length) {
    const journal = openJournal(input);
    try { seed.forEach(entry => journal.append(entry)); } finally { journal.close(); }
  }
  let now = start;
  let capture = createCapture(input, config, { ...dependencies, attribute, now: () => now });
  if (!seed.length) capture(stateFor([]));
  now = end;
  let producer = openProducer(output, { now: () => now });
  t.after(() => { capture.close(); producer.close(); });
  return { input, get capture() { return capture; }, get producer() { return producer; },
    recapture(state) { capture(state); return readJournal(input).at(-1); },
    snapshot() { producer.ingestJournal(input); return producer.snapshot(); },
    restart() {
      capture.close(); producer.close();
      capture = createCapture(input, config, { ...dependencies, attribute, now: () => now });
      producer = openProducer(output, { now: () => now });
    } };
}

test('every executor DESKS entry maps to its contract desk and unknown identities map to null', () => {
  assert.deepEqual(EXECUTOR_DESKS.map(desk => [desk, resultsDesk(desk)]), [
    ['j', 'j'], ['j2', 'j'], ['j3', 'j'], ['j4', 'j'], ['j5', 'j'], ['joe', 'joe'], ['joel', 'joel'],
  ]);
  assert.ok(EXECUTOR_DESKS.every(desk => DESKS.includes(resultsDesk(desk))));
  for (const unknown of [null, undefined, '', 'j1', 'j6', 'J5', 'j5 ', 'joe2', '__proto__', 'constructor', 'toString', 2, {}, ['j5']]) {
    assert.equal(resultsDesk(unknown), null);
  }
});

test('capture retains every executor sub-desk as book and emits only contract desks', t => {
  const f = setup(t), executions = EXECUTOR_DESKS.map(desk => raw(`synthetic-${desk}`, desk));
  const cut = f.recapture(stateFor(executions));
  assert.deepEqual(cut.fills.map(({ desk, book }) => [desk, book]), EXECUTOR_DESKS.map(book => [resultsDesk(book), book]));
  assert.ok(cut.fills.every(row => row.scope === 'stage0' && !invalidFillField(row)));
  assert.deepEqual(cut.positionProof.foreign, []);
  assert.equal(cut.evidence[0].kind, 'fill_position_mismatch');
});

test('unknown desks, KEEP, outside accounts, retired clients and external ownership stay excluded', t => {
  const f = setup(t), unknown = raw('synthetic-unknown', 'j6');
  const executions = [unknown, raw('synthetic-retired', 'j5', 'BUY', opened, { clientId: 701 }),
    raw('synthetic-account', 'j5', 'BUY', opened, { acctNumber: 'synthetic-other-account' }),
    { ...raw('synthetic-external', 'j5'), attribution: { method: 'external', desk: null } },
    ...keep.map(symbol => ({ ...raw(`synthetic-${symbol}`, 'j5'), contract: { ...contract, symbol } })),
    raw('synthetic-before-cutover', 'j5', 'BUY', '2026-10-21T21:00:00.000Z')];
  assert.deepEqual(f.recapture(stateFor(executions)).fills, []);
  const unmapped = setup(t, { attribute: () => ({ desk: 'j6', method: 'broker' }) });
  assert.deepEqual(unmapped.recapture(stateFor([unknown])).fills, []);
});

for (const field of ['quantity', 'at', 'brokerRealised.amount']) test(`j5 capture issue ${field} hashes contract desk j`, t => {
  const f = setup(t), state = stateFor([raw('synthetic-refused', 'j5')]);
  if (field === 'quantity') state.executions[0].execution.shares = 1e-7;
  else if (field === 'at') state.executions[0].execution.time = 'invalid';
  else state.commissions[0].realizedPNL = Infinity;
  const issues = f.recapture(state).captureIssues;
  assert.ok(issues.some(issue => issue.field === field));
  assert.ok(issues.every(issue => issue.deskHash === hash('j')));
});

test('a tombstoned j5 key is re-captured, replaces the producer projection and stays deduplicated after restart', t => {
  const row = raw('synthetic-recapture', 'j5'), key = hash('synthetic-recapture.');
  const tombstone = { key, desk: null, scope: 'excluded' };
  const f = setup(t, { seed: [{ type: 'start', at: start }, { type: 'cut', at: opened, fills: [tombstone],
    authoritative: true, disagreement: false, evidence: [] }] });
  f.producer.ingestJournal(f.input); // Persist the old excluded projection first.
  const prefix = readFileSync(f.input), state = stateFor([row], [{ ...contract, position: '1' }]);
  const cut = f.recapture(state);
  assert.equal(cut.fills.length, 1);
  assert.deepEqual({ key: cut.fills[0].key, scope: cut.fills[0].scope, desk: cut.fills[0].desk, book: cut.fills[0].book },
    { key, scope: 'stage0', desk: 'j', book: 'j5' });
  assert.ok(readFileSync(f.input).subarray(0, prefix.length).equals(prefix));
  const snapshot = f.snapshot();
  assert.equal(snapshot.days[0].desks.j.trades, 0);
  const bytes = readFileSync(f.input);
  f.recapture(state); assert.deepEqual(readFileSync(f.input), bytes);
  f.restart(); f.recapture(state); assert.deepEqual(readFileSync(f.input), bytes);
  assert.deepEqual(f.snapshot().days, snapshot.days);
  assert.deepEqual(readJournal(f.input)[1].fills, [tombstone]);
});

test('j5 NVDA short SELL then BUY yields one short trade under j', () => {
  const usd = { symbol: 'NVDA', currency: 'USD', commission: { amount: '0', currency: 'USD' } };
  const fills = [fill('short-open', 'j5', 'SELL', opened, { ...usd, price: '15' }),
    fill('short-close', 'j5', 'BUY', closed, { ...usd,
      closeFx: { base: 'USD', quote: 'EUR', rate: '0.9', source: 'synthetic-close', observedAt: closed } })];
  const trades = roundTrips(fills, start, keep);
  assert.equal(trades.length, 1);
  assert.deepEqual([trades[0].desk, trades[0].side, trades[0].quantity, trades[0].netEur.amount], ['j', 'short', '1', '4.5']);
  assert.equal(Object.hasOwn(trades[0], 'book'), false);
});

test('j2 BUY and j5 SELL never pair; broker closing counts also keep their books separate', () => {
  const fills = [fill('j2-open', 'j2', 'BUY', opened), fill('j5-open', 'j5', 'SELL', closed)];
  assert.deepEqual(roundTrips(fills, start, keep), []);
  const day = dayCloses(fills, [], '2026-10-22').days[0];
  assert.deepEqual(Object.keys(day.desks), ['j']);
  assert.equal(day.desks.j.trades, 0);
  assert.deepEqual(brokerDayTotals(fills, start).get('2026-10-22:j'), { count: 0, net: 0n, complete: true });
  fills.push(fill('j2-close', 'j2', 'SELL', '2026-10-22T15:00:00.000Z', { brokerRealised: { amount: '0', currency: 'EUR' } }),
    fill('j5-close', 'j5', 'BUY', '2026-10-22T15:01:00.000Z', { brokerRealised: { amount: '0', currency: 'EUR' } }));
  const trades = roundTrips(fills, start, keep);
  assert.deepEqual(trades.map(trade => [trade.desk, trade.side]), [['j', 'long'], ['j', 'short']]);
  assert.equal(brokerDayTotals(fills, start).get('2026-10-22:j').count, 2);
});

test('old journals without book still pair with desk books and joe remains unchanged', () => {
  for (const desk of DESKS) {
    const opening = fill(`${desk}-open`, desk, 'BUY', opened);
    delete opening.book;
    const closing = fill(`${desk}-close`, desk, 'SELL', closed, { price: '12' });
    const current = roundTrips([opening, closing], start, keep);
    delete closing.book;
    assert.deepEqual(roundTrips([opening, closing], start, keep), current);
    assert.equal(current[0].desk, desk);
    assert.equal(current[0].netEur.amount, '2');
    assert.equal(invalidFillField(opening), null);
  }
});

test('KEEP SXR8 and TSLA stay absent from FIFO trades', () => {
  for (const symbol of keep) assert.deepEqual(roundTrips([
    fill(`${symbol}-open`, 'j5', 'BUY', opened, { symbol }),
    fill(`${symbol}-close`, 'j5', 'SELL', closed, { symbol }),
  ], start, keep), []);
});

test('fill validation accepts optional executor books and refuses unknown or mismatched books', () => {
  for (const book of EXECUTOR_DESKS) assert.equal(invalidFillField(fill(`valid-${book}`, book, 'BUY', opened)), null);
  for (const book of [null, undefined, '', 'j6', 'J5', '__proto__', 'constructor', 'joe']) {
    const excluded = [], invalid = fill('invalid-book', 'j5', 'BUY', opened, { book });
    assert.equal(invalidFillField(invalid), 'book');
    assert.deepEqual(roundTrips([invalid, fill('valid-close', 'j5', 'SELL', closed)], start, keep, () => {}, issue => excluded.push(issue)), []);
    assert.equal(excluded.length, 1);
    assert.equal(excluded[0].kind, 'source_not_authoritative');
  }
});

test('changing a fill desk without its book fails closed for every mismatched desk/book pair', () => {
  for (const book of EXECUTOR_DESKS) for (const desk of DESKS) {
    if (desk === resultsDesk(book)) continue;
    const originals = [fill('stale-book-open', book, 'BUY', opened), fill('stale-book-close', book, 'SELL', closed)];
    assert.equal(roundTrips(originals, start, keep).length, 1);
    const clones = originals.map(row => ({ ...row, desk })), excluded = [];
    assert.deepEqual(clones.map(invalidFillField), ['book', 'book']);
    assert.deepEqual(roundTrips(clones, start, keep, () => {}, issue => excluded.push(issue)), []);
    assert.deepEqual(excluded.map(({ deskHash, kind }) => [deskHash, kind]), [
      [hash(desk), 'source_not_authoritative'], [hash(desk), 'source_not_authoritative'],
    ]);
  }
});

test('position reconciliation includes all J sub-desks and preserves exact broker rows', () => {
  const executions = [raw('synthetic-j2', 'j2', 'BUY', opened, { shares: '2' }), raw('synthetic-j5', 'j5', 'SELL', closed)];
  const state = stateFor(executions, [{ ...contract, position: '1' }, { conId: 2, symbol: 'OTHER', currency: 'USD', position: '-0.125' }]);
  const proof = () => capturePositionProof(state, config, keep, dependencies, [], end);
  assert.deepEqual(reconciliationEvidence(state, config, keep, dependencies), []);
  assert.deepEqual(proof().foreign, []);
  assert.deepEqual(proof().positions, [
    { instrument, quantity: '1' }, { instrument: hash([2, 'OTHER', 'USD']), quantity: '-0.125' },
  ].sort((a, b) => a.instrument.localeCompare(b.instrument)));
  state.ownershipSnapshot.positions[0].position = '0';
  assert.equal(reconciliationEvidence(state, config, keep, dependencies)[0].kind, 'fill_position_mismatch');
  state.executions.push(raw('synthetic-foreign', 'j6'));
  assert.deepEqual(proof().foreign, [instrument]);
  assert.deepEqual(reconciliationEvidence(state, config, keep, dependencies), []);
  state.executions.pop(); state.ownershipSnapshot.positions.push({ ...contract, position: '0' });
  assert.equal(proof(), null); // Roll-up never collapses duplicate broker evidence.
});

test('opposing J sub-desks cannot prove flat books across an earlier history gap', () => {
  const begin = '2026-10-22T10:00:00.000Z', observedAt = '2026-10-22T11:00:00.000Z';
  const fills = [fill('j2-held', 'j2', 'BUY', '2026-10-22T08:00:00.000Z'),
    fill('j5-held', 'j5', 'SELL', '2026-10-22T08:01:00.000Z')];
  const proofs = new PositionProofIndex();
  proofs.add({ at: observedAt, foreign: [], positions: [{ instrument, quantity: '0' }] });
  const executions = [{ instrument, at: closed }], intervals = [[Date.parse(begin), Date.parse(end)]];
  assert.deepEqual([...earlierGapDays(fills, executions, intervals, proofs, start)], ['2026-10-22']);
  fills.push(fill('j2-flat', 'j2', 'SELL', '2026-10-22T10:01:00.000Z'),
    fill('j5-flat', 'j5', 'BUY', '2026-10-22T10:02:00.000Z'));
  assert.deepEqual([...earlierGapDays(fills, executions, intervals, proofs, start)], []);
});

test('capture and replay publish j5 and joe round trips under the unchanged pinned Results contract', t => {
  assert.equal(verifyContracts(), true);
  const f = setup(t), executions = [raw('synthetic-j5-sell', 'j5', 'SELL'), raw('synthetic-joe-buy', 'joe'),
    raw('synthetic-j5-buy', 'j5', 'BUY', closed), raw('synthetic-joe-sell', 'joe', 'SELL', closed)];
  const state = stateFor(executions);
  state.commissions.forEach((row, i) => { if (i >= 2) row.realizedPNL = '0'; });
  f.recapture(state);
  const first = f.snapshot();
  assert.deepEqual(first.trades.map(trade => [trade.desk, trade.side]).sort(), [['j', 'short'], ['joe', 'long']]);
  assert.equal(first.days[0].desks.j.trades, 1);
  assert.equal(first.days[0].desks.joe.trades, 1);
  assert.equal(first.days[0].coverage ?? 'full', 'full');
  assert.deepEqual(validateResults(first, { requirePartialReasons: true }), { ok: true, status: 200, reason: null, errors: [] });
  f.restart();
  const replay = f.snapshot();
  assert.deepEqual(replay.trades, first.trades);
  assert.deepEqual(replay.days, first.days);
});
