import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import test from "node:test";
import { contractRevision, decimal } from "./v2-exact-values.mjs";
import { copyObservation } from "./v2-stage-handoff.mjs";
import { buildCandidate, StageStore, prepareLock, validObservation, launchLocked, CONTRACT_SHA } from "./v2-stage-worker.mjs";
import { validateContract } from "./contracts/index.mjs";

const at = "2026-10-25T20:00:00.000Z";
const old = "2026-10-25T19:54:59.000Z";
const desks = ["j", "joe", "joel"];
const fields = ["equity", "dayPnl", "openPnl", "totalPnl"];
const fx = { base: "USD", quote: "EUR", rate: 0.91, source: "ib-account-ExchangeRate", observedAt: at };
function source() {
  const portfolio = [
    { symbol: "TEST", contract: { conId: 101, currency: "USD" }, currency: "USD", pos: 2, marketPrice: 10.12345678, marketValue: 20.24691356, unrealizedPNL: -1.12345678 },
    { symbol: "SXR8", contract: { conId: 102, currency: "EUR" }, currency: "EUR", pos: 1401, marketPrice: 100, marketValue: 140100, unrealizedPNL: 100 },
    { symbol: "TSLA", contract: { conId: 103, currency: "USD" }, currency: "USD", pos: 1, marketPrice: 200, marketValue: 200, unrealizedPNL: -10 },
  ].map(row => ({ ...row, observedAt: at, markObservedAt: at,
    portfolioFieldObservedAt: Object.fromEntries(["quantity", "mark", "marketValue", "openPnl"].map(field => [field, at])) }));
  return {
    book: { ts: at, gateway: true, apiReplyCheckedAt: at,
      summary: { NetLiquidation: { value: "170000.25", currency: "EUR" }, TotalCashValue: { value: "1234.56", currency: "EUR" } },
      summaryObservedAt: { NetLiquidation: at, TotalCashValue: at },
      positionsCoverage: { status: "complete", observedAt: at }, portfolio,
      positions: portfolio.map(row => ({ symbol: row.symbol, contract: row.contract, currency: row.currency, pos: row.pos })) },
    deskEquities: { ok: true,
      desks: { j: { positions: [{ symbol: "TEST", currency: "USD", side: "Long" }] }, joe: { positions: [] }, joel: { positions: [] } },
      phaseBDesks: Object.fromEntries(desks.map((id, index) => [id, { reconciled: true, base: 5000,
        equity: 5001 + index, totalPnl: 1 + index, openPnl: 0.5 + index,
        observedAt: at, oldestInputAt: at, fx: id === "j" ? fx : null }])) },
    dayPnl: { ok: true, values: { j: 1, joe: 2, joel: 3, total: 6 },
      source: { status: "available", method: "sod-virtual-equity", sodSource: "new_york_midnight_exact", approximate: false,
        currency: "EUR", scope: "virtual-desks", observedAt: at, periodStart: "2026-10-25T04:00:00.000Z" },
      evidence: { sourceObservedAt: "2026-10-25T03:59:59.000Z", oldestSourceObservedAt: "2026-10-25T03:59:59.000Z",
        proofObservedAt: "2026-10-25T04:00:01.000Z", maxAgeMs: 300000, ageAtBoundaryMs: 1000,
        historyRevision: "a".repeat(64), historyRevisionMethod: "sha256-effective-all-desk-economic-history-v1" } },
  };
}
function build(input = source(), now = at) {
  const observation = copyObservation(input, 10);
  assert.equal(validObservation(observation), true);
  const snapshot = buildCandidate(1, now, observation, now, null, 10);
  const checked = validateContract("data", snapshot, { stage: "ingress" });
  assert.equal(checked.ok, true, JSON.stringify(checked.errors));
  const store = new StageStore({ revision: 10 }); store.validateContract = validateContract;
  assert.equal(store.validProjection(snapshot), true);
  return snapshot;
}
function twoRateSource() {
  const input = source();
  for (const id of ["j", "joe"]) input.deskEquities.phaseBDesks[id].fx = { ...fx };
  input.dayPnl.evidence.sodFx = Object.fromEntries(desks.map(id => [id, id === "joel" ? null
    : { ...fx, rate: 0.90, observedAt: input.dayPnl.evidence.sourceObservedAt }]));
  return input;
}

test("rev 9 is the default and remains byte-identical to the pre-change stager, even with exact evidence", async t => {
  for (const value of [undefined, "", "9", "11", "10 ", "true"]) assert.equal(contractRevision(value), 9);
  assert.equal(contractRevision("10"), 10);
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "joed86-rev9-"));
  t.after(() => spawnSync("trash", [root]));
  // Load the pre-JOED-86 stager from a FIXED commit (main before #1136; CI checks out full history), with its exact
  // relative imports. Never origin/main: once this change is merged, origin/main is the new stager itself (OPS fix).
  const BASELINE = "70872310c3f829bbdd56e31e5e759f81c0f459c9";
  for (const name of ["v2-stage-worker.mjs", "v2-stage-handoff.mjs", "verify-contracts.mjs", "v1-cycle.mjs", "desk-activity.mjs", "desk-ledger.mjs", "day-baseline.mjs", "execution-history.mjs", "execution-reconciliation.mjs", "family-ledger.mjs", "family-state.mjs", "flat-net-marks.mjs", "pusher-recovery.mjs", "executor-attribution.mjs", "executor-attribution-memory.mjs", "positions-state.mjs"]) {
    fs.writeFileSync(path.join(root, name), execFileSync("git", ["show", `${BASELINE}:hosts/hsb0/docker/joe-board-pusher/${name}`]));
  }
  const prior = await import(pathToFileURL(path.join(root, "v2-stage-worker.mjs")));
  const input = source();
  const observation = copyObservation(input, 10);
  const oldObservation = { ...observation }; delete oldObservation.exactValues;
  assert.equal(JSON.stringify(buildCandidate(7, at, observation, at)), JSON.stringify(prior.buildCandidate(7, at, oldObservation, at)));
  assert.equal(Object.hasOwn(copyObservation(input), "exactValues"), false);
});

test("fresh IB callbacks preserve decimal position values, native currencies and KEEP account scope", () => {
  const snapshot = build();
  const [position, keep, tsla] = snapshot.positions.rows;
  assert.equal(position.quantity, "2");
  assert.deepEqual(position.mark, { amount: "10.12345678", currency: "USD" });
  assert.deepEqual(position.marketValue, { amount: "20.24691356", currency: "USD" });
  assert.deepEqual(position.openPnl, { amount: "-1.12345678", currency: "USD" });
  assert.equal(position.updatedAt, at);
  assert.equal(position.dayPnl, null);
  for (const row of [keep, tsla]) { assert.equal(row.scope, "keep"); assert.equal(row.desk, null); }
  assert.equal(snapshot.totals.equity.amount, "15006.00000000");
  assert.equal(snapshot.desks[0].action, "Some paper desk values are unavailable.");
  assert.deepEqual(snapshot.brokerAccount.cash, { amount: "1234.56", currency: "EUR" });
  for (const desk of snapshot.desks) assert.equal(Object.hasOwn(desk.money, "cash"), false);
});

test("reconciled current FIFO values carry their actual FX rate; DAY needs its own SOD rate proof", () => {
  const snapshot = build();
  for (const field of ["equity", "openPnl", "totalPnl"]) {
    assert.deepEqual(snapshot.desks[0].money[field].fx, { ...fx, rate: "0.91" });
  }
  assert.equal(snapshot.desks[0].money.dayPnl, null);
  assert.equal(snapshot.desks[0].money.reasons.dayPnl, "not_exact_yet");
  for (const field of fields) assert.equal(snapshot.desks[1].money[field].fx, undefined);
  assert.equal(snapshot.desks[1].pnlSources.day.method, "sod-virtual-equity");
  assert.equal(snapshot.desks[0].pnlSources.open.method, "owned-lots-current-mark-fx");
});

test("DAY is exact when its recorded SOD and current figures used the same numeric rate", () => {
  const input = source();
  input.dayPnl.evidence.sodFx = { j: { ...fx, rate: "0.91000000", observedAt: input.dayPnl.evidence.sourceObservedAt }, joe: null, joel: null };
  const snapshot = build(input);
  assert.deepEqual(snapshot.desks[0].money.dayPnl, { amount: "1", currency: "EUR", fx: { ...fx, rate: "0.91" } });
  assert.equal(snapshot.desks[0].pnlSources.day.method, "sod-virtual-equity");
  assert.equal(Object.hasOwn(snapshot.desks[0].pnlSources.day, "detail"), false);
  assert.equal(snapshot.desks[0].action, "Paper desk values are available.");
  assert.equal(snapshot.totals.dayPnl.amount, "6.00000000");
});

for (const rate of [0.90, 0.91000001]) test(`DAY is exact across two proven rates (SOD ${rate}) with rev-10 source/time detail`, () => {
  const input = twoRateSource();
  for (const id of ["j", "joe"]) input.dayPnl.evidence.sodFx[id].rate = rate;
  const snapshot = build(input);
  for (const [index, id] of ["j", "joe"].entries()) {
    const desk = snapshot.desks[index];
    assert.deepEqual(desk.money.dayPnl, { amount: String(input.dayPnl.values[id]), currency: "EUR", fx: { ...fx, rate: "0.91" } });
    assert.equal(desk.pnlSources.day.status, "available");
    assert.equal(desk.pnlSources.day.detail,
      `New York SOD conversion: ib-account-ExchangeRate; observedAt ${input.dayPnl.evidence.sourceObservedAt}.`);
    assert.ok(desk.pnlSources.day.detail.length <= 240);
    assert.equal(Object.hasOwn(desk.money, "reasons"), false);
    assert.equal(desk.action, "Paper desk values are available.");
  }
  assert.deepEqual(snapshot.desks[2], build().desks[2], "EUR-only Joel is unchanged");
  assert.equal(snapshot.totals.dayPnl.amount, "6.00000000");
  assert.equal(snapshot.pnlSources.day.status, "available");
  for (const desk of snapshot.desks) assert.equal(Object.hasOwn(desk, "accounting"), false);
});

test("two-rate DAY detail fits rev 10 even with the longest permitted rate source", () => {
  const input = twoRateSource();
  input.dayPnl.evidence.sodFx.j.source = "s".repeat(80);
  const detail = build(input).desks[0].pnlSources.day.detail;
  assert.equal(detail, `New York SOD conversion: ${"s".repeat(80)}; observedAt ${input.dayPnl.evidence.sourceObservedAt}.`);
  assert.ok(detail.length <= 240);
});

test("a SOD rate observed exactly at periodStart can prove two-rate DAY", () => {
  const input = twoRateSource();
  const periodStart = input.dayPnl.source.periodStart;
  Object.assign(input.dayPnl.evidence, { sourceObservedAt: periodStart, oldestSourceObservedAt: periodStart, ageAtBoundaryMs: 0 });
  for (const id of ["j", "joe"]) input.dayPnl.evidence.sodFx[id].observedAt = periodStart;
  const snapshot = build(input);
  assert.equal(snapshot.totals.dayPnl.amount, "6.00000000");
  for (const desk of snapshot.desks.slice(0, 2)) assert.ok(desk.pnlSources.day.detail.includes(periodStart));
});

for (const id of desks) test(`household DAY requires all three exact desks (${id} SOD FX missing)`, () => {
  const input = twoRateSource();
  input.dayPnl.evidence.sodFx[id] = false;
  const snapshot = build(input);
  assert.equal(snapshot.totals.dayPnl, null);
  assert.equal(snapshot.totals.reasons.dayPnl, "not_exact_yet");
  assert.equal(snapshot.pnlSources.day.status, "unavailable");
  for (const desk of snapshot.desks) {
    if (desk.id === id) {
      assert.equal(desk.money.dayPnl, null);
      assert.equal(desk.money.reasons.dayPnl, "not_exact_yet");
      assert.equal(Object.hasOwn(desk.pnlSources.day, "detail"), false);
    } else assert.notEqual(desk.money.dayPnl, null);
  }
});

for (const variant of ["missing-desk", "different-currency", "unrecorded", "eur-only-sod", "missing-time", "after-snapshot", "after-sod", "before-oldest", "zero", "precision", "multiple"]) test(`DAY with ${variant} SOD FX stays null/not_exact_yet`, () => {
  const input = source();
  const sodFx = { ...fx, rate: 0.90, observedAt: input.dayPnl.evidence.sourceObservedAt };
  input.dayPnl.evidence.sodFx = { j: sodFx, joe: null, joel: null };
  if (variant === "missing-desk") delete input.dayPnl.evidence.sodFx.j;
  if (variant === "different-currency") sodFx.base = "GBP";
  if (variant === "unrecorded") delete input.dayPnl.evidence.sodFx;
  if (variant === "eur-only-sod") input.dayPnl.evidence.sodFx.j = null;
  if (variant === "missing-time") delete sodFx.observedAt;
  if (variant === "after-snapshot") sodFx.observedAt = "2026-10-25T04:00:00.000Z";
  if (variant === "after-sod") sodFx.observedAt = "2026-10-25T04:00:01.000Z";
  if (variant === "before-oldest") sodFx.observedAt = "2026-10-25T03:59:58.000Z";
  if (variant === "zero") sodFx.rate = 0;
  if (variant === "precision") sodFx.rate = 0.910000001;
  if (variant === "multiple") input.dayPnl.evidence.sodFx.j = false;
  const snapshot = build(input);
  assert.equal(snapshot.desks[0].money.dayPnl, null);
  assert.equal(snapshot.desks[0].money.reasons.dayPnl, "not_exact_yet");
  assert.equal(snapshot.desks[0].pnlSources.day.status, "unavailable");
  assert.equal(snapshot.desks[0].pnlSources.day.reason, "not_exact_yet");
  assert.equal(Object.hasOwn(snapshot.desks[0].pnlSources.day, "detail"), false);
  assert.equal(snapshot.totals.dayPnl, null);
  assert.equal(snapshot.totals.reasons.dayPnl, "not_exact_yet");
  for (const field of ["equity", "openPnl", "totalPnl"]) assert.notEqual(snapshot.desks[0].money[field], null);
  for (const desk of snapshot.desks.slice(1)) assert.notEqual(desk.money.dayPnl, null);
});

test("current FX freshness still gates two-rate DAY at the inclusive 300-second bound", () => {
  for (const [observedAt, exact] of [["2026-10-25T19:55:00.000Z", true], [old, false]]) {
    const input = twoRateSource();
    input.deskEquities.phaseBDesks.j.fx.observedAt = observedAt;
    const snapshot = build(input);
    const desk = snapshot.desks[0];
    if (exact) {
      assert.equal(desk.money.dayPnl.fx.observedAt, observedAt);
      assert.notEqual(snapshot.totals.dayPnl, null);
    } else {
      assert.equal(desk.money.dayPnl, null);
      assert.equal(desk.money.reasons.dayPnl, "not_exact_yet");
      assert.equal(desk.pnlSources.day.reason, "not_exact_yet");
      assert.equal(Object.hasOwn(desk.pnlSources.day, "detail"), false);
      assert.equal(snapshot.totals.dayPnl, null);
      assert.equal(snapshot.totals.reasons.dayPnl, "not_exact_yet");
    }
    assert.notEqual(snapshot.desks[1].money.dayPnl, null);
    assert.deepEqual(snapshot.desks[2], build().desks[2]);
  }
});

test("a current EUR figure cannot hide a foreign rate used by its SOD figure", () => {
  const input = source();
  input.deskEquities.phaseBDesks.j.fx = null;
  input.dayPnl.evidence.sodFx = { j: { ...fx, observedAt: input.dayPnl.evidence.sourceObservedAt }, joe: null, joel: null };
  const snapshot = build(input);
  assert.equal(snapshot.desks[0].money.dayPnl, null);
  assert.equal(snapshot.desks[0].money.reasons.dayPnl, "not_exact_yet");
  assert.equal(snapshot.desks[0].money.equity.fx, undefined);
  assert.notEqual(snapshot.desks[1].money.dayPnl, null);
});

test("unreconciled desk withholds all its money and every incomplete total; reconciled siblings survive", () => {
  const input = source(); input.deskEquities.phaseBDesks.j = { reconciled: false };
  const snapshot = build(input);
  for (const field of fields) {
    assert.equal(snapshot.desks[0].money[field], null);
    assert.equal(snapshot.desks[0].money.reasons[field], "ledger_unreconciled");
    assert.equal(snapshot.totals[field], null);
    assert.notEqual(snapshot.desks[1].money[field], null);
  }
});

for (const variant of ["missing", "proxy", "reseeded", "missed", "bad-proof", "old-day"]) test(`DAY with ${variant} SOD stays null/sod_missing`, () => {
  const input = source();
  if (variant === "missing") input.dayPnl = null;
  if (variant === "proxy") Object.assign(input.dayPnl.source, { sodSource: "session_open_proxy", approximate: true });
  if (variant === "reseeded") input.dayPnl.evidence.sourceObservedAt = "2026-10-25T04:00:02.000Z";
  if (variant === "missed") input.dayPnl.ok = false;
  if (variant === "bad-proof") input.dayPnl.evidence.ageAtBoundaryMs = 0;
  if (variant === "old-day") input.dayPnl.source.observedAt = old;
  const snapshot = build(input);
  for (const desk of snapshot.desks) {
    assert.equal(desk.money.dayPnl, null);
    assert.equal(desk.money.reasons.dayPnl, "sod_missing");
    assert.notEqual(desk.money.openPnl, null);
    assert.equal(desk.action, "Some paper desk values are unavailable.");
  }
});

test("unknown since-start base withholds totalPnl without withholding known current equity", () => {
  const input = source(); input.deskEquities.phaseBDesks.j.base = null;
  const snapshot = build(input);
  assert.equal(snapshot.desks[0].money.totalPnl, null);
  assert.equal(snapshot.desks[0].money.reasons.totalPnl, "not_exact_yet");
  assert.notEqual(snapshot.desks[0].money.equity, null);
  assert.equal(snapshot.totals.totalPnl, null);
});

for (const variant of ["missing-time", "old", "future", "missing-rate", "zero", "multiple"]) test(`J FX ${variant} never becomes exact`, () => {
  const input = source(); const row = input.deskEquities.phaseBDesks.j;
  row.fx = { ...fx };
  if (variant === "missing-time") row.fx.observedAt = null;
  if (variant === "old") row.fx.observedAt = old;
  if (variant === "future") row.fx.observedAt = "2026-10-25T20:00:01.000Z";
  if (variant === "missing-rate") row.fx.rate = null;
  if (variant === "zero") row.fx.rate = 0;
  if (variant === "multiple") row.fx = false;
  const snapshot = build(input);
  for (const field of fields) assert.equal(snapshot.desks[0].money[field], null);
});

test("fresh envelope and positions coverage do not refresh a stale conid callback", () => {
  const input = source();
  input.book.portfolio[0].markObservedAt = old;
  input.book.portfolio[0].portfolioFieldObservedAt = Object.fromEntries(["quantity", "mark", "marketValue", "openPnl"].map(field => [field, old]));
  const snapshot = build(input);
  for (const field of ["quantity", "mark", "marketValue", "openPnl"]) {
    assert.equal(snapshot.positions.rows[0][field], null);
    assert.equal(snapshot.positions.rows[0].reasons[field], "position_stale");
  }
  assert.notEqual(snapshot.positions.rows[1].mark, null);
});

test("missing, mismatched and ambiguous conid callbacks cannot borrow a same-symbol mark", () => {
  for (const variant of ["missing", "conid", "quantity", "duplicate"]) {
    const input = source();
    if (variant === "missing") input.book.portfolio.shift();
    if (variant === "conid") input.book.portfolio[0].contract = { conId: 999 };
    if (variant === "quantity") input.book.portfolio[0].pos = 3;
    if (variant === "duplicate") input.book.portfolio.push(structuredClone(input.book.portfolio[0]));
    const snapshot = build(input);
    assert.equal(snapshot.positions.rows[0].mark, null);
    assert.equal(snapshot.positions.rows[0].reasons.mark, "not_exact_yet");
  }
});

test("per-field callback clocks keep retained worth and OPEN stale beside a fresh last price", () => {
  const input = source();
  Object.assign(input.book.portfolio[0].portfolioFieldObservedAt, { marketValue: old, openPnl: old });
  const row = build(input).positions.rows[0];
  assert.notEqual(row.mark, null);
  assert.equal(row.marketValue, null);
  assert.equal(row.openPnl, null);
});

test("retained/stale ledger values and lost Gateway confirmation cannot be relabelled exact", () => {
  const input = source(); input.deskEquities.phaseBDesks.j.oldestInputAt = old;
  const stale = build(input);
  for (const field of fields) assert.equal(stale.desks[0].money[field], null);
  input.book.apiReplyCheckedAt = old;
  const down = build(input);
  for (const field of fields) for (const desk of down.desks) assert.equal(desk.money[field], null);
  assert.equal(down.brokerAccount.cash, null);
  assert.equal(down.positions.rows[0].mark, null);
});

test("cash needs its own fresh EUR TotalCashValue; NAV never substitutes for it", () => {
  for (const variant of ["absent", "currency", "old"]) {
    const input = source();
    if (variant === "absent") delete input.book.summary.TotalCashValue;
    if (variant === "currency") input.book.summary.TotalCashValue.currency = "USD";
    if (variant === "old") input.book.summaryObservedAt.TotalCashValue = "2026-10-25T19:52:00.000Z";
    const snapshot = build(input);
    assert.equal(snapshot.brokerAccount.cash, null);
    assert.equal(snapshot.brokerAccount.cash?.amount, undefined);
    assert.notEqual(snapshot.brokerAccount.equity, null);
  }
});

test("wire decimal conversion does not silently round unsupported callback/rate precision", () => {
  assert.equal(decimal(0.00000001), "0.00000001");
  assert.equal(decimal(1.234567891), null);
  assert.equal(decimal(Number.MAX_VALUE), null);
  const input = source(); input.book.portfolio[0].marketPrice = 1.234567891;
  assert.equal(build(input).positions.rows[0].mark, null);
});

test("activated staging persists rev 10, recovers without reset, and accepts prior rev-9 history", async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "joed86-stage-"));
  t.after(() => spawnSync("trash", [root])); fs.chmodSync(root, 0o700);
  const options = { root, uid: process.getuid(), gid: process.getgid() };
  prepareLock(root, options.uid, options.gid);
  const rev9 = new StageStore({ ...options, revision: 9 }); rev9.enroll(); await rev9.open();
  assert.equal(rev9.stage(copyObservation(source()), () => at).status, 200);
  // Preserve an actual prior-revision receipt alongside new-contract pairs.
  const receiptFile = path.join(root, "pair-1/receipt.json");
  const receipt = JSON.parse(fs.readFileSync(receiptFile));
  receipt.contractSetSha256 = "000045fb7843a16be95f6a7e42d46d4b4ecb34b0efd39fc987bee444817fc9d5";
  fs.writeFileSync(receiptFile, JSON.stringify(receipt));
  const active = await new StageStore({ ...options, revision: 10 }).open();
  const now = "2026-10-25T20:00:01.000Z";
  assert.equal(active.stage(copyObservation(source(), 10), () => now).status, 200);
  assert.equal(JSON.parse(fs.readFileSync(path.join(root, "pair-2/receipt.json"))).contractSetSha256, CONTRACT_SHA);
  const restart = await new StageStore({ ...options, revision: 9 }).open();
  const committed = JSON.parse(restart.readCommittedPair().bytes);
  assert.equal(committed.seq, 2);
  assert.equal(committed.desks[0].money.equity.amount, "5001");
});

test("explicit rev-10 activation reaches the isolated lock worker without forwarding unrelated environment", () => {
  const previous = process.env.JOE_V2_CONTRACT_REV;
  process.env.JOE_V2_CONTRACT_REV = "10";
  try {
    // prepareLock is tested separately; use the same safe private local root.
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "joed86-env-")); fs.chmodSync(root, 0o700);
    try {
      let launch;
      launchLocked({ root, uid: process.getuid(), gid: process.getgid(), spawnWorker: (...args) => { launch = args; return {}; } });
      assert.equal(launch[2].env.JOE_V2_CONTRACT_REV, "10");
      assert.deepEqual(Object.keys(launch[2].env).sort(), ["JOE_V2_CONTRACT_REV", "NODE_ENV", "PATH"]);
    } finally { spawnSync("trash", [root]); }
  } finally { if (previous === undefined) delete process.env.JOE_V2_CONTRACT_REV; else process.env.JOE_V2_CONTRACT_REV = previous; }
});
