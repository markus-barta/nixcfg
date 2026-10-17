import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { openProducer } from './producer.mjs';
import { DESKS } from './fifo.mjs';
import { CONTRACTS, validateContract } from './contracts/index.mjs';

// 10,000 ms CPU per build + ingress/served validation, below the 25 s cadence.
// Local Node fixture: spring 156.243 ms, autumn 143.316 ms CPU (macOS).
// Each served snapshot was 1,030,202 bytes including receivedAt (8 MiB limit).
const CPU_BOUND_MS = 10_000;
const iso = value => new Date(value).toISOString();

for (const [season, start, firstNoon, dstDay] of [
  ['spring', '2026-03-01T23:00:00.000Z', '2026-03-02T12:00:00.000Z', '2026-03-29'],
  ['autumn', '2026-09-27T22:00:00.000Z', '2026-09-28T12:00:00.000Z', '2026-10-25'],
]) test(`bounded CPU: 60 Vienna days, three desks, 4320 fills, KEEP and ${season} DST`, t => {
  const fills = [], observations = [], base = Date.parse(firstNoon);
  const at = iso(base + 60 * 86400_000);
  for (let day = 0; day < 60; day++) {
    const noon = base + day * 86400_000;
    observations.push({ at: iso(noon), desks: Object.fromEntries(DESKS.map(desk => [desk, {
      equity: { amount: '5000', currency: 'EUR' }, basisId: `synthetic-${season}-${day}-${desk}`,
    }])) });
    for (const desk of DESKS) for (let pair = 0; pair < 12; pair++) {
      const symbol = pair === 10 ? 'SXR8' : pair === 11 ? 'TSLA' : 'ACME';
      for (const [leg, side, price] of [[0, 'BUY', '100'], [1, 'SELL', '102']]) {
        const time = iso(noon - 3600_000 + pair * 60_000 + leg * 30_000);
        fills.push({ key: `synthetic-${season}-${day}-${desk}-${pair}-${leg}`, ordinal: fills.length + 1,
          desk, scope: 'stage0', instrument: `synthetic-${symbol}`, symbol, currency: 'EUR', side, at: time,
          quantity: '1', price, commission: { amount: '0.1', currency: 'EUR' },
          closeFx: { base: 'EUR', quote: 'EUR', rate: '1', source: 'identity', observedAt: time } });
      }
    }
  }
  assert.equal(fills.length, 4320);
  const producer = openProducer(path.join(mkdtempSync(path.join(tmpdir(), 'joed20-cpu-')), 'results.jsonl'), { now: () => at });
  try {
    producer.ingest([{ type: 'start', at: start }, { type: 'cut', at, authoritative: true, disagreement: false, fills,
      historyCoverage: { status: 'complete', target: { fromInclusive: start, toExclusive: at }, gaps: [] } }]);
    observations.forEach(producer.observe);
    const before = process.cpuUsage();
    const payload = producer.snapshot(); // includes vendored validation
    assert.equal(validateContract('results', payload, { stage: 'ingress' }).ok, true);
    // The board adds this server-owned property before its served-size check.
    const served = { ...payload, receivedAt: at };
    assert.equal(validateContract('results', served, { stage: 'served' }).ok, true);
    const usage = process.cpuUsage(before), cpuMs = (usage.user + usage.system) / 1000;
    const bytes = Buffer.byteLength(JSON.stringify(served));
    t.diagnostic(`cpu_ms=${cpuMs.toFixed(3)} bound_ms=${CPU_BOUND_MS} served_bytes=${bytes} limit_bytes=${CONTRACTS.limits.results}`);
    assert.ok(cpuMs < CPU_BOUND_MS, `CPU ${cpuMs} ms exceeds ${CPU_BOUND_MS} ms`);
    assert.ok(bytes < CONTRACTS.limits.results);
    assert.equal(payload.days.length, 60);
    assert.ok(payload.days.some(day => day.date === dstDay));
    assert.equal(payload.trades.length, 1800);
    assert.ok(payload.trades.every(trade => trade.symbol === 'ACME'));
    for (const day of payload.days) {
      assert.equal(day.coverage ?? 'full', 'full');
      for (const desk of DESKS) {
        assert.equal(day.desks[desk].trades, 10);
        assert.equal(day.desks[desk].realisedNet.amount, '18');
        assert.equal(day.desks[desk].fees.amount, '2');
      }
    }
  } finally { producer.close(); }
});
