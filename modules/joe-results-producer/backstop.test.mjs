import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createCapture } from './capture.mjs';
import { captureBrokerRealised, brokerMismatches } from './broker-backstop.mjs';
import { openProducer, createRunner } from './producer.mjs';
import { openJournal, readJournal, hash } from './journal.mjs';
import { CLOSE_BASIS, roundTrips, dayCloses } from './fifo.mjs';
import { CONTRACTS, SCHEMA_FILES, validateContract } from './contracts/index.mjs';

const begin = '2026-10-15T22:00:00.000Z', end = '2026-10-16T22:00:00.000Z';
const openAt = '2026-10-16T10:00:00.000Z', closeAt = '2026-10-16T12:00:00.000Z';
const account = 'synthetic-account';
function setup(t, { pnl = '1.8', multiLot = false, currency = 'EUR' } = {}) {
  const dir = mkdtempSync(path.join(tmpdir(), 'joed20-r8-'));
  const capturePath = path.join(dir, 'input.jsonl'), output = path.join(dir, 'results.jsonl');
  let clock = begin;
  const raw = (id, time, side, price, shares = '1') => ({ desk: 'j', contract: { conId: 1, symbol: 'ACME', currency },
    execution: { execId: `synthetic-${id}.01`, acctNumber: account, clientId: 705, time, side, price, shares } });
  const executions = [raw('open', openAt, 'BUY', '10'), raw('close', closeAt, 'SELL', '12', multiLot ? '2' : '1')];
  if (multiLot) executions.splice(1, 0, raw('open2', '2026-10-16T11:00:00.000Z', 'BUY', '11'));
  const state = { ownershipComplete: true, executions, commissions: executions.map(row => ({
    execId: row.execution.execId, commission: multiLot ? '0' : '0.1', currency,
    realizedPNL: row.execution.side === 'SELL' ? pnl : Number.MAX_VALUE,
  })), resultsFx: { [currency]: { base: currency, quote: 'EUR', rate: '0.9', source: 'synthetic-existing-rate', observedAt: closeAt } },
  resultsHistoryCoverage: { status: 'complete', target: { fromInclusive: begin, toExclusive: end }, gaps: [] } };
  const config = { foreignAlertSince: begin, executorClientId: 705 };
  const capture = createCapture(capturePath, config, { account, attribute: row => ({ desk: row.desk, method: 'admin' }), executionTime: Date.parse, now: () => clock });
  capture({ ownershipComplete: true, executions: [] }); clock = end;
  let producer = openProducer(output, { now: () => clock });
  const refresh = () => { capture(state); producer.ingest(readJournal(capturePath)); return producer.snapshot(); };
  t.after(() => { producer.close(); capture.close(); });
  return { state, refresh, capturePath, output, get producer() { return producer; },
    replay() { producer.close(); producer = openProducer(output, { now: () => clock }); producer.ingest(readJournal(capturePath)); return producer.snapshot(); } };
}

for (const [pnl, expected] of [['1.8', 'full'], ['1.81', 'full'], ['1.811', 'partial'], ['1.789', 'partial']]) {
  test(`closed-day broker net ${pnl} against FIFO 1.8 yields ${expected}; replay is stable`, t => {
    const f = setup(t, { pnl });
    const first = f.refresh();
    assert.equal(first.days[0].coverage ?? 'full', expected);
    assert.equal(first.days[0].desks.j.equityClose, null);
    assert.equal(first.trades[0].netEur.amount, '1.8');
    assert.deepEqual(f.replay().days, first.days);
    f.refresh();
    const logs = readJournal(f.output).filter(row => row.type === 'broker-mismatch');
    assert.deepEqual(logs, expected === 'full' ? [] : [{ type: 'broker-mismatch', record: {
      day: '2026-10-16', deskHash: hash('j'), kind: 'broker_realised_pnl_mismatch',
    } }]);
    assert.equal(Object.hasOwn(first, 'missingDays'), false);
    const bytes = readFileSync(f.capturePath, 'utf8');
    for (const forbidden of [account, 'synthetic-close.01', 'execId', 'acctNumber', 'conId']) assert.equal(bytes.includes(forbidden), false);
  });
}

test('one broker closing execution versus two FIFO portions is a count mismatch even with equal PnL', t => {
  const f = setup(t, { pnl: '3', multiLot: true });
  const value = f.refresh();
  assert.equal(value.days[0].coverage, 'partial');
  assert.equal(value.days[0].desks.j.trades, 2);
  assert.equal(value.days[0].desks.j.realisedNet.amount, '3');
  assert.deepEqual(readJournal(f.output).filter(row => row.type === 'broker-mismatch').map(row => row.record.kind), ['broker_trade_count_mismatch']);
  assert.deepEqual(f.replay().days, value.days);
});

test('SDK undefined opening PnL survives ledger JSON save and capture to a full EUR round trip', t => {
  const f = setup(t);
  const report = f.state.commissions[0];
  f.state.commissions[0] = JSON.parse(JSON.stringify({ ...report, realizedPNL: undefined }));
  assert.equal(Object.hasOwn(f.state.commissions[0], 'realizedPNL'), false);
  const first = f.refresh();
  assert.equal(first.days[0].coverage ?? 'full', 'full');
  assert.equal(first.trades[0].netEur.amount, '1.8');
  assert.deepEqual(readJournal(f.output).filter(row => row.type === 'broker-mismatch'), []);
  assert.deepEqual(f.replay().days, first.days);
});

for (const pnl of [undefined, null, Number.MAX_VALUE, 1e-7, 'NaN', '1.7976931348623157e+308']) {
  test(`missing or unusable broker PnL (${String(pnl)}) fails closed`, t => {
    const f = setup(t); f.state.commissions[1].realizedPNL = pnl;
    const value = f.refresh();
    assert.equal(value.days[0].coverage, 'partial');
    assert.deepEqual(readJournal(f.output).filter(row => row.type === 'broker-mismatch').map(row => row.record.kind), ['broker_evidence_missing']);
    assert.deepEqual(f.replay().days, value.days);
  });
}

test('a late commission correction downgrades the next push without heartbeat log growth', t => {
  const f = setup(t);
  assert.equal(f.refresh().days[0].coverage ?? 'full', 'full');
  f.state.commissions[1].realizedPNL = '1.811';
  const partial = f.refresh();
  assert.equal(partial.days[0].coverage, 'partial');
  for (let i = 0; i < 5; i++) assert.equal(f.refresh().days[0].coverage, 'partial');
  assert.equal(readJournal(f.output).filter(row => row.type === 'broker-mismatch').length, 1);
  assert.deepEqual(f.replay().days, partial.days);
  f.state.commissions[1].realizedPNL = '1.8';
  assert.equal(f.refresh().days[0].coverage ?? 'full', 'full');
  assert.equal(readJournal(f.output).filter(row => row.type === 'broker-mismatch').length, 1);
});

test('existing close FX converts broker net once and numeric exact integers are accepted', t => {
  const f = setup(t, { currency: 'USD' });
  const value = f.refresh();
  assert.equal(value.days[0].coverage ?? 'full', 'full');
  assert.equal(value.days[0].desks.j.realisedNet.amount, '1.62');
  assert.deepEqual(captureBrokerRealised({ realizedPNL: 2, currency: 'EUR' }), { amount: '2', src: 'sdk_number_roundtrip', currency: 'EUR' });
});

test('a zero-PnL closing execution still counts, and compacted broker input preserves proof on replay', t => {
  const f = setup(t, { pnl: '0' });
  f.state.executions[1].execution.price = '10';
  for (const commission of f.state.commissions) commission.commission = '0';
  const first = f.refresh();
  assert.equal(first.days[0].coverage ?? 'full', 'full');
  assert.equal(first.days[0].desks.j.trades, 1);
  assert.equal(first.days[0].desks.j.realisedNet.amount, '0');
  f.state.executions = []; f.state.commissions = [];
  assert.deepEqual(f.refresh().days, first.days);
  assert.deepEqual(f.replay().days, first.days);
});

test('a broker report in an incompatible currency supplies no reconciliation evidence', t => {
  const f = setup(t); f.refresh();
  const captured = readJournal(f.capturePath).flatMap(row => row.fills || []);
  const { days } = dayCloses(captured, roundTrips(captured, begin, []), '2026-10-16');
  captured[1].brokerRealised.currency = 'GBP';
  assert.equal(brokerMismatches(days, captured, begin, end)[0].kind, 'broker_evidence_missing');
});

test('desk mismatches never cancel across desks; unknown bounds cannot become full', t => {
  const f = setup(t); const value = f.refresh();
  const fills = readJournal(f.capturePath).flatMap(row => row.fills || []);
  const other = fills.map(fill => ({ ...fill, desk: 'joe', key: `synthetic-joe-${fill.key}` }));
  fills[1].brokerRealised.amount = '1.811'; other[1].brokerRealised.amount = '1.789';
  const combined = [...fills, ...other], trades = roundTrips(combined, begin, []);
  const { days } = dayCloses(combined, trades, '2026-10-16');
  assert.deepEqual(brokerMismatches(days, combined, begin, end).map(row => row.deskHash).sort(), [hash('j'), hash('joe')].sort());
  const unknown = setup(t); unknown.state.resultsHistoryCoverage = null;
  assert.equal(unknown.refresh().days[0].coverage, 'partial');
  assert.equal(validateContract('results', value, { stage: 'ingress' }).ok, true);
});

test('household v2 health/account inputs and legacy household observations never affect Results', async t => {
  const f = setup(t); const original = f.refresh();
  const journal = openJournal(f.output);
  journal.append({ type: 'observation', key: 'synthetic-old-household', value: { at: closeAt,
    desks: { j: { equity: { amount: '999999', currency: 'EUR' }, basisId: 'synthetic-household' } } } });
  journal.close();
  assert.deepEqual(f.replay().days, original.days);
  let reads = 0, sent;
  const runner = createRunner({ producer: f.producer, now: () => Date.parse(end), readSource: () => readJournal(f.capturePath),
    readHousehold: () => { reads++; throw new Error('household_must_not_be_read'); },
    readHealth: () => ({ status: 'ok', account: 'synthetic-private-account', halt: { active: false }, gatewayReachable: true,
      brakes: { newPerDay: 1, notionalEur: 1 } }), transport: { async send(value) { sent = value; } } });
  assert.equal(await runner.tick(), true); assert.equal(reads, 0);
  assert.deepEqual(sent.days, original.days);
  assert.equal(readFileSync(f.output, 'utf8').includes('synthetic-private-account'), false);
  for (const file of ['producer.mjs', 'main.mjs', 'default.nix']) {
    const source = readFileSync(new URL(file, import.meta.url), 'utf8');
    for (const forbidden of ['readHousehold', 'householdPath', 'household-v2.json', 'brokerAccount', 'moneyEvidence']) assert.equal(source.includes(forbidden), false, `${file}: ${forbidden}`);
  }
});

test('the approved close basis cannot change without a manifest revision bump', () => {
  const requireBump = (basis, revision) => assert.ok(basis === 'execution-fifo-net-current-fx' || revision > 4, 'basis_change_requires_manifest_revision_bump');
  requireBump(CLOSE_BASIS, CONTRACTS.revision);
  assert.equal(SCHEMA_FILES['results.schema.json'].properties.trades.items.properties.method.const, CLOSE_BASIS);
  assert.throws(() => requireBump('synthetic-new-basis', 4), /basis_change_requires_manifest_revision_bump/);
  assert.doesNotThrow(() => requireBump('synthetic-new-basis', 5));
});
