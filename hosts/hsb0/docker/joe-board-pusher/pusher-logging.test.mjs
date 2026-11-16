import assert from "node:assert/strict";
import test from "node:test";
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

test("JOED-196: an unreconciled all-desk ledger logs counts only and withholds the J result from v1 and the handoff", async () => {
  const family = { ok: true, equity: 5001, totalPnl: 1, realizedPnl: 0.5, unrealizedPnl: 0.5, observedAt: instant, executionCount: 1,
    positions: [{ desk: "j", symbol: "ACME", side: "Long", quantity: 1, accountingScope: "stage0", dayPnl: null,
      openPnl: 0.5, currency: "USD", mark: 11, updatedAt: instant }],
    accounting: { periodStart: "2026-09-10T04:00:00Z", method: "execution-fifo-net-current-fx", detail: "Synthetic." } };
  const allDesk = result => result.warnings.map(([line]) => JSON.parse(line)).filter(event => event.event === "all_desk_equity_unavailable");
  const jDesk = result => JSON.parse(result.v1Body).desks.find(desk => desk.id === "j");

  const unreconciled = await runPusher(new URL("./pusher.mjs", import.meta.url), { family,
    deskEquities: { ok: false, reason: "ledger_unreconciled", ledgerReconciliation: { accountMismatch: 0, crossBooked: 1 } } });
  assert.deepEqual(allDesk(unreconciled), [{ event: "all_desk_equity_unavailable", reason: "ledger_unreconciled",
    ledgerReconciliation: { accountMismatch: 0, crossBooked: 1 } }]);
  assert.deepEqual(jDesk(unreconciled).money, { equity: null, dayPnl: null, totalPnl: null, openPnl: null });
  assert.equal(jDesk(unreconciled).state, "stuck");
  assert.deepEqual(jDesk(unreconciled).issues, ["J accounting unavailable: ledger_unreconciled"]);
  assert.equal(Object.hasOwn(jDesk(unreconciled), "positions"), false, "J's half of the pair is not published as a position");
  assert.equal(unreconciled.observation.deskActivity.j.hasPositions, false);
  assert.deepEqual(unreconciled.requests[0].body, Buffer.from(unreconciled.v1Body), "the household POST continues");

  // Every other all-desk failure keeps J's own accounting and its fixed log shape.
  const other = await runPusher(new URL("./pusher.mjs", import.meta.url), { family,
    deskEquities: { ok: false, reason: "synthetic-unavailable" } });
  assert.deepEqual(allDesk(other), [{ event: "all_desk_equity_unavailable", reason: "synthetic-unavailable" }]);
  assert.equal(jDesk(other).money.equity, 5001);
  assert.equal(jDesk(other).state, "working");
  assert.equal(other.observation.deskActivity.j.hasPositions, true);
});
