import assert from "node:assert/strict";
import { mkdtempSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { admitIntent, openLedger, pruneState, RETENTION_MS } from "./state.mjs";
import { newYorkDay } from "./policy.mjs";

test("retention preserves recent idempotency and unresolved evidence while pruning expired terminal claims", () => {
  const now = Date.now();
  const recent = new Date(now - RETENTION_MS + 1000).toISOString();
  const old = new Date(now - RETENTION_MS - 1000).toISOString();
  const state = { intents: {
    recent: { status: "done", finishedAt: recent },
    old: { status: "done", finishedAt: old },
    uncertain: { status: "uncertain", claimedAt: old },
    crash: { status: "claimed", claimedAt: old },
  }, placements: [{ status: "uncertain", reservedAt: old }, { status: "submitted", reservedAt: old }], executions: [{ execution: "retained ownership" }] };
  pruneState(state, now);
  assert.deepEqual(Object.keys(state.intents), ["recent", "uncertain", "crash"]);
  assert.equal(state.placements.length, 1); assert.equal(state.executions.length, 1);
});

test("bounded admission refuses overload without discarding existing claims", () => {
  const state = { intents: Object.fromEntries(Array.from({ length: 5000 }, (_, index) => [String(index), { status: "uncertain" }])), placements: [], executions: [] };
  assert.throws(() => admitIntent(state), /capacity/);
  assert.equal(Object.keys(state.intents).length, 5000);
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
