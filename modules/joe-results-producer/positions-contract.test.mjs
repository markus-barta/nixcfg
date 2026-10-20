import test from 'node:test';
import assert from 'node:assert/strict';
import { validateContract } from './contracts/index.mjs';

const at = '2026-10-18T12:00:00.000Z';
const row = { desk: 'j', symbol: 'ACME', side: 'long', quantity: '1', scope: 'stage0' };
const validate = position => validateContract('data', {
  schema: 'inspr.joe.household.v2', seq: 1, generatedAt: at, mode: 'PAPER', currency: 'EUR',
  source: { kind: 'live-ib-api', label: 'synthetic position contract' },
  safety: { halt: false, haltReason: null, gateway: { apiSessionReady: true, checkedAt: at } },
  desks: ['j', 'joe', 'joel'].map(id => ({ id, label: id, state: 'sit-out', action: 'Waiting', money: {} })),
  totals: {},
  positions: { source: 'live-ib-api', observedAt: at, rows: [position] },
}, { stage: 'ingress', receivedAt: at });

for (const [label, position] of [
  ['rev-8 mapped stage0 row', row],
  ['rev-8 null quantity with its own reason', { ...row, quantity: null, reasons: { quantity: 'source_unavailable' } }],
  ['rev-9 unmapped stage0 row', { ...row, desk: null, reasons: { desk: 'desk_unmapped' } }],
  ['rev-9 desk uses the shared reason codes', { ...row, desk: null, reasons: { desk: 'source_unavailable' } }],
  ['rev-8 KEEP row', { ...row, desk: null, symbol: 'TSLA', scope: 'keep' }],
]) {
  test(`position contracts accept ${label}`, () => {
    assert.deepEqual(validate(position), { ok: true, status: 200, reason: null, errors: [] });
  });
}

for (const [label, position, rule] of [
  ['stage0 null desk without a reason', { ...row, desk: null }, 'deskRequired'],
  ['quantity reason cannot explain a null desk', { ...row, desk: null, quantity: null, reasons: { quantity: 'source_unavailable' } }, 'deskRequired'],
  ['desk reason on a mapped row', { ...row, reasons: { desk: 'desk_unmapped' } }, 'contradictoryDesk'],
  ['desk reason on KEEP', { ...row, desk: null, symbol: 'TSLA', scope: 'keep', reasons: { desk: 'desk_unmapped' } }, 'contradictoryDesk'],
  ['unknown desk reason code', { ...row, desk: null, reasons: { desk: 'synthetic_unknown' } }, 'enum'],
]) {
  test(`position contracts reject ${label}`, () => {
    const result = validate(position);
    assert.equal(result.ok, false);
    assert.equal(result.status, 422);
    assert.ok(result.errors.some(error => error.rule === rule), JSON.stringify(result.errors));
  });
}
