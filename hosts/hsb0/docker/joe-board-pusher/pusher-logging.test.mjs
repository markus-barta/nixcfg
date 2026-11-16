import assert from "node:assert/strict";
import test from "node:test";
import { DESK_HISTORY_REVISION_METHOD, deskOwnershipPolicyContract } from "./desk-ledger.mjs";
import { instant, runPusher } from "./fixtures/pusher-harness.mjs";

test("flat-net failures log only on reason change and recur after successful sync", async () => {
  const result = await runPusher(new URL("./pusher.mjs", import.meta.url), { refreshTicks: 6,
    flatNetFailures: ["synthetic-count-error", "synthetic-count-error", "synthetic-other-error", null,
      "synthetic-other-error", "synthetic-other-error"] });
  assert.deepEqual(result.warnings.map(([line]) => JSON.parse(line)).filter(event => event.event === "family_unavailable"), [
    { event: "family_unavailable", reason: "synthetic-count-error" },
    { event: "family_unavailable", reason: "synthetic-other-error" },
    { event: "family_unavailable", reason: "synthetic-other-error" },
  ]);
  assert.equal(result.flatNetResets, 5, "every failing sync still resets marks");
});

// Synthetic J long 1 / Joe short 1 on one contract that is flat in the account.
const lot = (side, quantity, openPnl) => ({ desk: "j", symbol: "ACME", side, quantity, accountingScope: "stage0",
  dayPnl: null, openPnl, currency: "USD", mark: 11, updatedAt: instant });
const family = { ok: true, equity: 5001, totalPnl: 1, realizedPnl: 0.5, unrealizedPnl: 0.5, observedAt: instant, executionCount: 1,
  positions: [lot("Long", 1, 0.5)],
  accounting: { periodStart: "2026-09-10T04:00:00Z", method: "execution-fifo-net-current-fx", detail: "Synthetic." } };
function valued(ledgerReconciliation) {
  const sourceContract = deskOwnershipPolicyContract();
  return { ok: true, ...(ledgerReconciliation ? { ledgerReconciliation } : {}),
    desks: { j: { equity: 5001, totalPnl: 1, realizedPnl: 0.5, unrealizedPnl: 0.5, positions: family.positions },
      joe: { equity: 4999.5, totalPnl: -0.5, realizedPnl: 0, unrealizedPnl: -0.5, positions: [lot("Short", -1, -0.5)] },
      joel: { equity: 5000, totalPnl: 0, realizedPnl: 0, unrealizedPnl: 0, positions: [] } },
    equity: { j: 5001, joe: 4999.5, joel: 5000, total: 15000.5 },
    sourceObservedAt: instant, oldestSourceObservedAt: instant,
    historyRevisionMethod: DESK_HISTORY_REVISION_METHOD, historyRevision: "a".repeat(64),
    executionCoverage: { status: "complete", fromInclusive: "2026-09-10T04:00:00.000Z", throughInclusive: instant },
    sourceContract,
    ownershipEvidence: { status: "complete", policyHash: sourceContract.policyHash, unclaimedExecutionCount: 0 } };
}
const pusher = options => runPusher(new URL("./pusher.mjs", import.meta.url), { family, ...options });
const events = (result, name) => result.warnings.map(([line]) => JSON.parse(line)).filter(event => event.event === name);
const desk = (result, id) => JSON.parse(result.v1Body).desks.find(row => row.id === id);

test("JOED-196: a desk lot on a flat contract is a health event with its count only, every cycle, and money keeps publishing", async () => {
  const alerted = await pusher({ deskEquities: valued({ accountMismatch: 0, crossBooked: 1 }), cycles: 2 });
  const alert = { event: "desk_ledger_alert", reason: "desk_lot_on_flat_contract", crossBooked: 1 };
  assert.deepEqual(events(alerted, "desk_ledger_alert"), [alert, alert], "one event per cycle while the count holds");
  assert.deepEqual(events(alerted, "all_desk_equity_unavailable"), []);
  assert.deepEqual(["j", "joe", "joel"].map(id => desk(alerted, id).money.equity), [5001, 4999.5, 5000]);
  assert.deepEqual(["j", "joe", "joel"].map(id => desk(alerted, id).state), ["working", "working", "sit-out"]);
  assert.equal(JSON.parse(alerted.v1Body).totals.equity, 15000.5);
  assert.deepEqual(["j", "joe", "joel"].map(id => alerted.observation.deskActivity[id].hasPositions), [true, true, false]);
  assert.equal(alerted.requests.length, 2);
  assert.deepEqual(alerted.requests.at(-1).body, Buffer.from(alerted.v1Body), "the household POST continues");

  // The same book without the count: no event, and neither a published byte
  // nor a field of the stager's observation differs (its cycle id is random).
  const clean = await pusher({ deskEquities: valued(), cycles: 2 });
  assert.deepEqual(events(clean, "desk_ledger_alert"), []);
  assert.equal(clean.v1Body, alerted.v1Body);
  const observed = result => ({ ...result.observation, v1Cycle: { ...result.observation.v1Cycle, observationId: null } });
  assert.deepEqual(observed(clean), observed(alerted));
});

test("JOED-196: desk lots that do not add up to the account stay fail-closed and log both counts on the existing event", async () => {
  const counts = { accountMismatch: 1, crossBooked: 0 };
  const unreconciled = await pusher({ deskEquities: { ok: false, reason: "ledger_unreconciled", ledgerReconciliation: counts } });
  assert.deepEqual(events(unreconciled, "all_desk_equity_unavailable"), [{ event: "all_desk_equity_unavailable",
    reason: "ledger_unreconciled", ledgerReconciliation: counts }]);
  assert.deepEqual(events(unreconciled, "desk_ledger_alert"), [], "a mismatch alone is not the alert");
  for (const id of ["joe", "joel"]) assert.equal(desk(unreconciled, id).money.equity, null, id);
  assert.equal(JSON.parse(unreconciled.v1Body).totals.equity, null);
  assert.deepEqual(unreconciled.requests[0].body, Buffer.from(unreconciled.v1Body), "the household POST continues");

  // A counted flat contract beside a mismatch elsewhere keeps its own health event.
  const both = await pusher({ deskEquities: { ok: false, reason: "ledger_unreconciled",
    ledgerReconciliation: { accountMismatch: 1, crossBooked: 2 } } });
  assert.deepEqual(events(both, "all_desk_equity_unavailable"), [{ event: "all_desk_equity_unavailable",
    reason: "ledger_unreconciled", ledgerReconciliation: { accountMismatch: 1, crossBooked: 2 } }]);
  assert.deepEqual(events(both, "desk_ledger_alert"),
    [{ event: "desk_ledger_alert", reason: "desk_lot_on_flat_contract", crossBooked: 2 }]);

  // Every other all-desk failure keeps its fixed log shape and J's own accounting.
  const other = await pusher({ deskEquities: { ok: false, reason: "synthetic-unavailable" } });
  assert.deepEqual(events(other, "all_desk_equity_unavailable"), [{ event: "all_desk_equity_unavailable", reason: "synthetic-unavailable" }]);
  assert.deepEqual(events(other, "desk_ledger_alert"), []);
  assert.equal(desk(other, "j").money.equity, 5001);
  assert.equal(desk(other, "j").state, "working");
  assert.equal(other.observation.deskActivity.j.hasPositions, true);
});
