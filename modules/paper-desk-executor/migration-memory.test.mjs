import "../../tests/paper-desk-account-fixture.mjs";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { MAX_STATE_BYTES, openLedger } from "./state.mjs";

function snapshot(intentId, at) {
  const positions = Array.from({ length: 8 }, (_, index) => ({ account: "DU0000001", conId: 265598 + index, symbol: "AAPL", secType: "STK", currency: "USD", exchange: "SMART", primaryExch: "NASDAQ", position: index + 1, averageCost: 100.25, keep: false, desks: [{ desk: "j", quantity: index + 1 }] }));
  const openOrders = Array.from({ length: 12 }, (_, index) => ({ orderId: index + 100, permId: index + 70000, conId: 265598, symbol: "AAPL", secType: "STK", currency: "USD", clientId: 705, action: "SELL", orderType: "STP", quantity: 2, parentId: 99, orderRef: "j|261014|memory", auxPrice: 99.5, account: "DU0000001", tif: "DAY", status: "Submitted", attribution: { desk: "j", source: "orderRef" } }));
  const executions = Array.from({ length: 160 }, (_, index) => ({
    contract: { conId: 265598, symbol: "AAPL", secType: "STK", exchange: "SMART", primaryExch: "NASDAQ", currency: "USD", localSymbol: "AAPL", tradingClass: "NMS" },
    execution: { execId: `${intentId}-fill-${index}`, time: "20261014 14:00:00", acctNumber: "DU0000001", exchange: "NASDAQ", side: "BOT", shares: 2, price: 100.25, permId: index + 70000, clientId: 705, orderId: index + 100, liquidation: 0, cumQty: 2, avgPrice: 100.25, orderRef: "j|261014|memory", evRule: "", evMultiplier: 0 },
    attribution: { desk: "j", source: "orderRef", needsAttribution: false }, orderRef: "j|261014|memory",
  }));
  return { action: "recon", desk: "j", hash: `hash-${intentId}`, status: "done", claimedAt: at, finishedAt: at, result: { status: "ok", action: "recon", intentId, desk: "j", observedAt: at, account: "DU0000001", gateway: true, paperPort: 4002, ownershipComplete: true, ownershipHistory: { status: "complete" }, positions, openOrders, executions } };
}

// Fresh child isolates fixture construction and earlier tests from migration
// memory. Samples at filesystem/hash boundaries include live parsed objects,
// normalized results, canonical digest strings and archive publication. The
// OS high-water RSS additionally includes peaks between synchronous samples.
const measure = `
  import fs from "node:fs";
  import crypto from "node:crypto";
  import { syncBuiltinESMExports } from "node:module";
  let baseline, peakHeap = 0, peakRss = 0, samples = 0;
  function sample() {
    if (!baseline) return;
    const memory = process.memoryUsage();
    peakHeap = Math.max(peakHeap, memory.heapUsed);
    peakRss = Math.max(peakRss, memory.rss);
    samples++;
  }
  for (const name of ["openSync", "readFileSync", "writeFileSync", "fstatSync", "renameSync", "fsyncSync", "closeSync", "linkSync"]) {
    const original = fs[name];
    fs[name] = (...args) => { sample(); const value = original(...args); sample(); return value; };
  }
  const createHash = crypto.createHash;
  crypto.createHash = (...args) => {
    sample();
    const hash = createHash(...args), update = hash.update;
    hash.update = function(...args) { sample(); const value = update.apply(this, args); sample(); return value; };
    return hash;
  };
  syncBuiltinESMExports();
  const { openLedger } = await import(process.argv[1]);
  const ledger = openLedger(process.argv[2]);
  global.gc();
  baseline = process.memoryUsage();
  const beforeMaxRss = process.resourceUsage().maxRSS * 1024;
  sample();
  const state = ledger.load();
  sample();
  peakRss = Math.max(peakRss, process.resourceUsage().maxRSS * 1024);
  const usage = ledger.usage();
  process.stdout.write(JSON.stringify({ node: process.version, ledgerBytes: Number(process.argv[3]), receiptCount: state.intents.size, compactedBytes: usage.ledgerBytes, baseline, peakHeap, peakRss, heapDelta: peakHeap - baseline.heapUsed, rssDelta: peakRss - Math.max(baseline.rss, beforeMaxRss), beforeMaxRss, samples }));
`;

test("near-16-MiB object-shaped migration and crash retry have a bounded peak working set", async (t) => {
  const root = mkdtempSync(path.join(tmpdir(), "ops331-memory-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const ledger = openLedger(root);
  ledger.load();
  const legacy = JSON.parse(readFileSync(ledger.statePath, "utf8"));
  delete legacy.reconStorageVersion;
  let bytes = Buffer.byteLength(JSON.stringify(legacy));
  let count = 0;
  while (true) {
    const id = `recon-memory-${String(count).padStart(4, "0")}`;
    const row = snapshot(id, legacy.initializedAt);
    const size = Buffer.byteLength(JSON.stringify({ [id]: row })) - 1;
    if (bytes + size > MAX_STATE_BYTES - 1024) break;
    legacy.intents[id] = row;
    bytes += size;
    count++;
  }
  const body = JSON.stringify(legacy);
  const ledgerBytes = Buffer.byteLength(body);
  assert.ok(ledgerBytes > MAX_STATE_BYTES - 262144 && ledgerBytes < MAX_STATE_BYTES);
  for (const retry of [false, true]) {
    await t.test(retry ? "retry with immutable backup and full existing evidence" : "first migration", (t) => {
      // Retry restores the original un-migrated ledger while retaining the
      // complete backup and archive generations from the first child run.
      writeFileSync(ledger.statePath, body);
      const metrics = JSON.parse(execFileSync(process.execPath, ["--expose-gc", "--max-old-space-size=128", "--input-type=module", "-e", measure, new URL("./state.mjs", import.meta.url).href, ledger.root, String(ledgerBytes)], { encoding: "utf8" }));
      assert.equal(metrics.receiptCount, count);
      assert.ok(metrics.samples > count * 2, "measure throughout compaction, not just its endpoints");
      assert.ok(metrics.heapDelta < ledgerBytes * 6, `heap delta exceeds six ledger sizes: ${JSON.stringify(metrics)}`);
      assert.ok(metrics.rssDelta < ledgerBytes * 11, `RSS delta exceeds eleven ledger sizes: ${JSON.stringify(metrics)}`);
      // The service limit is 384m (OPS-331); 256 MiB keeps the old ceiling as a tighter regression guard.
      assert.ok(metrics.peakRss < 256 * 1024 * 1024, `workstation child RSS exceeds the 256 MiB regression ceiling (service limit is 384m): ${JSON.stringify(metrics)}`);
      assert.ok(metrics.compactedBytes < ledgerBytes / 10);
      assert.equal(statSync(ledger.backupPath).size, ledgerBytes);
      t.diagnostic(`migration memory (${retry ? "retry" : "first"}): ${JSON.stringify(metrics)}`);
    });
  }
});
