import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { openProducer } from './producer.mjs';
import { DESKS } from './fifo.mjs';
import { CONTRACTS, validateContract } from './contracts/index.mjs';

// 2,500 ms CPU per ingest/build or restart-replay/build operation, including
// ingress/served validation; each processes 1,920 cuts (32 per day), per-cut
// proofs and a persistent earlier gap, exercising indexed baseline lookups.
// Workload calibrated on Apple silicon below; the fixed limit leaves >=5x
// headroom for the often 2-3x slower ubuntu CI runners, including full replay.
// macOS Node 24.20.0 calibration includes the complete T100 producer run.
// Spring/autumn ingest: 492.682/386.657 ms; replay: 185.286/186.565 ms.
// The worst T100 operation leaves 5.07x headroom to the 2,500 ms bound.
const CPU_BOUND_MS = 2_500;
const iso = value => new Date(value).toISOString();

for (const [season, start, firstNoon, dstDay] of [
  ['spring', '2026-03-01T23:00:00.000Z', '2026-03-02T12:00:00.000Z', '2026-03-29'],
  ['autumn', '2026-09-27T22:00:00.000Z', '2026-09-28T12:00:00.000Z', '2026-10-25'],
]) test(`bounded CPU: 60 Vienna days, three desks, 4320 fills, KEEP and ${season} DST`, t => {
  const fills = [], cuts = [], base = Date.parse(firstNoon);
  const historyFrom = iso(Date.parse(start) - 86400_000);
  const gaps = [{ fromInclusive: iso(Date.parse(start) - 7200_000), toExclusive: iso(Date.parse(start) - 3600_000) }];
  const at = iso(base + 60 * 86400_000);
  for (let day = 0; day < 60; day++) {
    const noon = base + day * 86400_000;
    const firstFill = fills.length;
    for (const desk of DESKS) for (let pair = 0; pair < 12; pair++) {
      const symbol = pair === 10 ? 'SXR8' : pair === 11 ? 'TSLA' : 'ACME';
      for (const [leg, side, price] of [[0, 'BUY', '100'], [1, 'SELL', '102']]) {
        const time = iso(noon - 3600_000 + pair * 60_000 + leg * 30_000);
        fills.push({ key: `synthetic-${season}-${day}-${desk}-${pair}-${leg}`, ordinal: fills.length + 1,
          desk, scope: 'stage0', instrument: `synthetic-${symbol}`, symbol, currency: 'EUR', side, at: time,
          quantity: '1', price, brokerRealised: leg ? { amount: '1.8', currency: 'EUR' } : { unset: true, currency: 'EUR' }, commission: { amount: '0.1', currency: 'EUR' },
          closeFx: { base: 'EUR', quote: 'EUR', rate: '1', source: 'identity', observedAt: time } });
      }
    }
    for (let cut = 0; cut < 32; cut++) {
      const capturedAt = iso(noon + (cut + 1) * 86400_000 / 32);
      cuts.push({ type: 'cut', at: capturedAt, authoritative: true, disagreement: false,
        fills: cut === 0 ? fills.slice(firstFill) : [],
        fxSampler: { enabled: true, reason: null, days: {
          [iso(noon).slice(0, 10)]: { samples: Array.from({ length: Math.min(cut + 1, 27) }, (_, i) => ({
            rate: '0.86123457', sampleAt: iso(noon + i * 900_000), kind: i === 26 ? 'close' : 'rth',
          })) },
        } },
        positionProof: { at: cut === 0 ? iso(noon - 7200_000) : capturedAt,
          positions: [{ instrument: 'synthetic-ACME', quantity: '0' }], foreign: [] },
        historyCoverage: { status: 'known', target: { fromInclusive: historyFrom, toExclusive: capturedAt }, gaps } });
    }
  }
  assert.equal(fills.length, 4320);
  assert.equal(cuts.length, 1_920);
  const filename = path.join(mkdtempSync(path.join(tmpdir(), 'joed20-cpu-')), 'results.jsonl');
  const source = [{ type: 'start', at: start }, ...cuts];
  const before = process.cpuUsage();
  let producer = openProducer(filename, { now: () => at });
  try {
    producer.ingest(source);
    const payload = producer.snapshot(); // includes vendored validation
    assert.equal(validateContract('results', payload, { stage: 'ingress' }).ok, true);
    // The board adds this server-owned property before its served-size check.
    const served = { ...payload, receivedAt: at };
    assert.equal(validateContract('results', served, { stage: 'served' }).ok, true);
    const usage = process.cpuUsage(before), cpuMs = (usage.user + usage.system) / 1000;
    const bytes = Buffer.byteLength(JSON.stringify(served));
    t.diagnostic(`ingest_cpu_ms=${cpuMs.toFixed(3)} bound_ms=${CPU_BOUND_MS} cuts=${cuts.length} proofs=${cuts.length} gaps=${gaps.length} served_bytes=${bytes} limit_bytes=${CONTRACTS.limits.results}`);
    assert.ok(cpuMs < CPU_BOUND_MS, `ingest CPU ${cpuMs} ms exceeds ${CPU_BOUND_MS} ms`);
    producer.close();
    const beforeReplay = process.cpuUsage();
    producer = openProducer(filename, { now: () => at }); // stream and replay all durable cuts
    producer.ingest(source); // verify the entire already-ingested capture prefix
    const replayed = producer.snapshot();
    assert.equal(validateContract('results', replayed, { stage: 'ingress' }).ok, true);
    assert.equal(validateContract('results', { ...replayed, receivedAt: at }, { stage: 'served' }).ok, true);
    const replayUsage = process.cpuUsage(beforeReplay), replayMs = (replayUsage.user + replayUsage.system) / 1000;
    t.diagnostic(`replay_cpu_ms=${replayMs.toFixed(3)} bound_ms=${CPU_BOUND_MS} cuts=${cuts.length}`);
    assert.ok(replayMs < CPU_BOUND_MS, `replay CPU ${replayMs} ms exceeds ${CPU_BOUND_MS} ms`);
    assert.deepEqual(replayed.days, payload.days); assert.deepEqual(replayed.trades, payload.trades);
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
