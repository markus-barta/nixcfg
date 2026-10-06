import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { Worker } from "node:worker_threads";
import { admitIntent, openLedger, pruneState, RETENTION_MS } from "./state.mjs";
import { newYorkDay } from "./policy.mjs";

test("retention preserves recent idempotency and unresolved evidence while pruning expired terminal claims", () => {
  const now = Date.now();
  const recent = new Date(now - RETENTION_MS + 1000).toISOString();
  const old = new Date(now - RETENTION_MS - 1000).toISOString();
  const state = { intents: {
    "recent-id": { status: "done", finishedAt: recent },
    "expired-id": { status: "done", finishedAt: old },
    uncertain: { status: "uncertain", claimedAt: old },
    "crash-id": { status: "claimed", claimedAt: old },
  }, placements: [{ status: "uncertain", reservedAt: old }, { status: "submitted", reservedAt: old }], executions: [{ execution: "retained ownership" }] };
  pruneState(state, now);
  assert.deepEqual(Object.keys(state.intents), ["recent-id", "uncertain", "crash-id"]);
  assert.equal(state.placements.length, 1); assert.equal(state.executions.length, 1);
});

test("bounded admission refuses overload without discarding existing claims", () => {
  const state = { intents: Object.fromEntries(Array.from({ length: 5000 }, (_, index) => [`test-${String(index).padStart(4, "0")}`, { status: "uncertain" }])), placements: [], executions: [] };
  assert.throws(() => admitIntent(state), /capacity/);
  assert.equal(Object.keys(state.intents).length, 5000);
});

test("loaded dictionaries retain null prototypes and reject reserved or malformed keys", () => {
  const root = mkdtempSync(path.join(tmpdir(), "ops266-keys-"));
  const ledger = openLedger(root);
  const state = ledger.load();
  state.intents["valid-id"] = { status: "uncertain" };
  state.firstOrders.j = { AAPL: "2026-10-01" };
  ledger.save(state);
  const loaded = ledger.load();
  for (const map of [loaded.intents, loaded.firstOrders, loaded.firstOrders.j]) assert.equal(Object.getPrototypeOf(map), null);
  assert.equal(loaded.firstOrders.j.AAPL, "2026-10-01");
  for (const key of ["__proto__", "constructor", "prototype", "short", "bad/path"]) {
    const poisoned = JSON.parse(JSON.stringify(state));
    Object.defineProperty(poisoned.intents, key, { value: { status: "uncertain" }, enumerable: true });
    writeFileSync(ledger.statePath, JSON.stringify(poisoned));
    assert.throws(() => ledger.load(), /intentId is invalid/);
    assert.throws(() => ledger.save(poisoned), /intentId is invalid/);
  }
  for (const key of ["__proto__", "constructor", "prototype", "other-desk"]) {
    const poisoned = JSON.parse(JSON.stringify(state));
    Object.defineProperty(poisoned.firstOrders, key, { value: {}, enumerable: true });
    writeFileSync(ledger.statePath, JSON.stringify(poisoned));
    assert.throws(() => ledger.load(), /desk is invalid/);
  }
  for (const key of ["__proto__", "constructor", "prototype", "bad/symbol"]) {
    const poisoned = JSON.parse(JSON.stringify(state));
    Object.defineProperty(poisoned.firstOrders.j, key, { value: "2026-10-01", enumerable: true });
    writeFileSync(ledger.statePath, JSON.stringify(poisoned));
    assert.throws(() => ledger.load(), /symbol is invalid/);
  }
});

test("ledger and audit reads refuse symlinks; atomic writes ignore predictable temporary links", () => {
  const root = mkdtempSync(path.join(tmpdir(), "ops266-files-"));
  const ledger = openLedger(root);
  const state = ledger.load();
  const victim = path.join(root, "unrelated.txt");
  writeFileSync(victim, "preserve me");
  symlinkSync(victim, `${ledger.statePath}.new`);
  ledger.save(state);
  assert.equal(readFileSync(victim, "utf8"), "preserve me");
  symlinkSync(victim, ledger.haltPath);
  assert.throws(() => ledger.haltBody(), /ELOOP/);
  ledger.setHalt("operator stop");
  assert.match(ledger.haltBody(), /operator stop/);
  assert.equal(readFileSync(victim, "utf8"), "preserve me");
  for (const file of ["ledger.json", "audit.jsonl"]) {
    const otherRoot = mkdtempSync(path.join(tmpdir(), "ops266-links-"));
    symlinkSync(victim, path.join(otherRoot, file));
    const other = openLedger(otherRoot);
    assert.throws(() => file === "ledger.json" ? other.load() : other.audit({ event: "test" }), /ELOOP/);
    assert.equal(readFileSync(victim, "utf8"), "preserve me");
  }
});

test("concurrent ledger initialization publishes one complete ledger without overwriting the winner", async () => {
  const root = mkdtempSync(path.join(tmpdir(), "ops266-init-"));
  const initializations = Array.from({ length: 6 }, () => new Promise((resolve, reject) => {
    const worker = new Worker(`
      const { parentPort, workerData } = require("node:worker_threads");
      import(workerData.module).then(({ openLedger }) => {
        parentPort.postMessage(openLedger(workerData.root).load().initializedAt);
      });
    `, { eval: true, workerData: { root, module: new URL("./state.mjs", import.meta.url).href } });
    worker.once("message", resolve);
    worker.once("error", reject);
    worker.once("exit", (code) => { if (code !== 0) reject(new Error(`ledger worker exited ${code}`)); });
  }));
  const timestamps = await Promise.all(initializations);
  assert.equal(new Set(timestamps).size, 1);
  assert.equal(openLedger(root).load().initializedAt, timestamps[0]);
  const events = readFileSync(openLedger(root).auditPath, "utf8").trim().split("\n").map((row) => JSON.parse(row));
  assert.equal(events.filter((row) => row.event === "ledger_initialized").length, 1);
});

test("first-order coverage dates survive pruning old filled placements", () => {
  const now = Date.now();
  const first = new Date(now - RETENTION_MS - 86400000).toISOString();
  const state = { intents: {}, placements: [
    { desk: "j", symbol: "AAPL", status: "filled", reservedAt: first },
    { desk: "j", symbol: "AAPL", status: "submitted", reservedAt: new Date(now).toISOString() },
  ], executions: [] };
  pruneState(state, now);
  assert.equal(state.placements.length, 1);
  assert.equal(state.firstOrders.j.AAPL, newYorkDay(Date.parse(first)));
  pruneState(state, now + RETENTION_MS + 1);
  assert.deepEqual(state.placements, []);
  assert.equal(state.firstOrders.j.AAPL, newYorkDay(Date.parse(first)));
});

test("audit rotation remains bounded and HALT and ledger persist independently", () => {
  const root = mkdtempSync(path.join(tmpdir(), "ops266-ledger-"));
  const ledger = openLedger(root);
  const state = ledger.load();
  ledger.setHalt("operator stop");
  state.intents["durable-id"] = { status: "uncertain", claimedAt: new Date().toISOString() };
  ledger.save(state);
  for (let index = 0; index < 40; index++) ledger.audit({ event: "large", payload: "x".repeat(64000) });
  assert.ok(statSync(ledger.auditPath).size <= 1024 * 1024);
  assert.ok(statSync(`${ledger.auditPath}.1`).size <= 1024 * 1024);
  assert.equal(openLedger(root).load().intents["durable-id"].status, "uncertain");
  assert.match(openLedger(root).haltBody(), /operator stop/);
});
