import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { EventEmitter } from "node:events";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { createBrokerSessionAdapter } from "./pusher-state.mjs";
import { copyObservation, createStageHandoff, FRAME_FORMAT, MAX_FRAME_BYTES } from "./v2-stage-handoff.mjs";
import { buildCandidate, StageStore, prepareLock, validObservation, acceptStage } from "./v2-stage-worker.mjs";
import { validateContract } from "./contracts/index.mjs";
import { acceptSnapshot } from "./contracts/accept.mjs";

const instant = "2026-10-19T07:00:00.000Z";
const later = "2026-10-19T07:00:01.000Z";
const before = "2026-10-19T06:59:59.999Z";
const source = (at = instant) => ({ format: FRAME_FORMAT, bookTs: at,
  equity: { value: "12345.67000000", currency: "EUR" }, cash: { value: "-12.3400", currency: "EUR" },
  apiReplyCheckedAt: at, positions: [] });
const candidate = observation => buildCandidate(1, observation.bookTs, observation);
const check = value => validateContract("data", value, { stage: "ingress" });
const unmappedRow = {
  symbol: "UNKNOWN", side: "short", scope: "stage0", desk: null,
  quantity: null, mark: null, marketValue: null, dayPnl: null, openPnl: null,
  reasons: { desk: "desk_unmapped", quantity: "not_exact_yet", mark: "not_exact_yet",
    marketValue: "not_exact_yet", dayPnl: "not_exact_yet", openPnl: "not_exact_yet" },
};
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "ops392-switch-"));
  fs.chmodSync(root, 0o700);
  t.after(() => { spawnSync("trash", [root]); });
  const options = { root, uid: process.getuid(), gid: process.getgid() };
  prepareLock(root, options.uid, options.gid);
  const store = new StageStore(options); store.enroll();
  return { root, store, options };
}

for (const lexeme of ["12345.67000000", "-12.3400", "0", "0.00000000", "-0.0000", "9007199254740993.01000000"]) {
  test(`NAV and cash preserve exact raw bytes ${lexeme}`, () => {
    const observation = source();
    observation.equity.value = observation.cash.value = lexeme;
    const value = candidate(observation);
    for (const field of ["equity", "cash"]) assert.ok(Buffer.from(value.brokerAccount[field].amount).equals(Buffer.from(lexeme)));
    assert.equal(check(value).ok, true);
  });
}
for (const field of ["equity", "cash"]) for (const fault of ["missing", "USD", "invalid", "too-precise", "numeric"]) {
  test(`${field} ${fault} is null with source_unavailable, independently of the other field`, () => {
    const observation = source();
    if (fault === "missing") observation[field] = null;
    if (fault === "USD") observation[field].currency = "USD";
    if (fault === "invalid") observation[field].value = "1e3";
    if (fault === "too-precise") observation[field].value = "1.123456789";
    if (fault === "numeric") observation[field].value = 12;
    const value = candidate(observation);
    assert.equal(value.brokerAccount[field], null);
    assert.equal(field === "equity" ? value.brokerAccount.reason : value.brokerAccount.reasons.cash, "source_unavailable");
    assert.ok(value.brokerAccount[field === "cash" ? "equity" : "cash"]);
    assert.equal(check(value).ok, true);
  });
}

test("readiness requires a completed target API reply; raw NAV/cash remain strings at ingress callbacks", () => {
  const events = Object.fromEntries(["connected", "disconnected", "error", "info", "managedAccounts", "accountSummary",
    "accountSummaryEnd", "position", "positionEnd", "updatePortfolio", "accountDownloadEnd", "openOrder", "currentTime"].map(x => [x, x]));
  const account = "SYNTHETIC-PAPER";
  const adapter = createBrokerSessionAdapter({ targetAccount: account, eventNames: events, now: () => instant });
  const api = () => Object.assign(new EventEmitter(), Object.fromEntries(["reqManagedAccts", "reqPositions", "reqAllOpenOrders",
    "reqAccountSummary", "reqAccountUpdates"].map(x => [x, () => {}])));
  const first = api(); adapter.attach(first); first.emit("connected");
  first.emit("managedAccounts", account);
  first.emit("accountSummary", 9501, account, "NetLiquidation", "12345.67000000", "EUR");
  first.emit("accountSummary", 9501, account, "TotalCashValue", "-0.0000", "EUR");
  first.emit("accountSummaryEnd", 9501); first.emit("positionEnd"); first.emit("accountDownloadEnd", account);
  const book = adapter.snapshot();
  assert.equal(book.summary.NetLiquidation.value, "12345.67000000");
  assert.equal(book.summary.TotalCashValue.value, "-0.0000");
  assert.equal(book.summary.TotalCashValue.currency, "EUR");
  assert.equal(book.apiReplyCheckedAt, instant);
  const second = api(); adapter.attach(second); second.emit("connected");
  second.emit("currentTime", 0); second.emit("accountDownloadEnd", account);
  second.emit("accountSummary", 9501, "SYNTHETIC-OTHER", "NetLiquidation", "999", "EUR");
  second.emit("accountSummaryEnd", 9501); second.emit("accountSummaryEnd", 999);
  first.emit("accountSummaryEnd", 9501); // Retired generation.
  assert.equal(adapter.snapshot().apiReplyCheckedAt, null);
  second.emit("managedAccounts", account);
  second.emit("accountSummary", 9501, account, "TotalCashValue", "0.00000000", "EUR");
  assert.equal(adapter.snapshot().apiReplyCheckedAt, null);
  second.emit("accountSummaryEnd", 9501);
  assert.equal(adapter.snapshot().apiReplyCheckedAt, instant);
  second.emit("info", "synthetic upstream loss", 1100);
  assert.equal(adapter.snapshot().apiReplyCheckedAt, null);
  second.emit("connected"); second.emit("managedAccounts", account); second.emit("positionEnd");
  assert.equal(adapter.snapshot().apiReplyCheckedAt, instant, "complete authenticated empty position reply is sufficient");
});

test("gateway check freshness, future and missing replies cannot expose account money", () => {
  for (const [checkedAt, receipt, reason] of [
    ["2026-10-19T06:59:00.001Z", instant, null],
    ["2026-10-19T06:59:00.000Z", instant, "gateway_unconfirmed"],
    [later, later, "clock_ahead"],
    [instant, before, "clock_ahead"],
    [instant, "2026-10-19T07:01:00.000Z", "gateway_unconfirmed"],
  ]) {
    const value = buildCandidate(1, instant, { ...source(), apiReplyCheckedAt: checkedAt }, receipt);
    assert.equal(value.safety.gateway.apiSessionReady, reason === null);
    assert.equal(value.safety.gateway.checkedAt, checkedAt);
    assert.equal(value.safety.gateway.reason ?? null, reason);
    assert.equal(check(value).ok, true);
    if (reason) { assert.equal(value.brokerAccount.equity, null); assert.equal(value.brokerAccount.cash, null); }
  }
  const missing = candidate({ ...source(), apiReplyCheckedAt: null });
  assert.equal(Object.hasOwn(missing.safety, "gateway"), false);
  assert.equal(missing.brokerAccount.equity, null);
  assert.equal(missing.positions.reason, "gateway_unconfirmed");
  assert.equal(check(missing).ok, true);
});

test("gateway high-water is durable; equal passes, older rejects after local accept, future never poisons recovery", async t => {
  const { store, options } = fixture(t); await store.open();
  assert.equal(store.stage(source(), () => instant).status, 200);
  const restarted = await new StageStore(options).open();
  assert.equal(restarted.state.lastGatewayCheckedAt, instant);
  assert.equal(restarted.stage(source(), () => later).status, 200);
  const old = buildCandidate(3, later, { ...source(later), apiReplyCheckedAt: before }, later, instant);
  assert.equal(old.safety.gateway.reason, "clock_regressed");
  assert.equal(acceptSnapshot("data", old, restarted.previous, later).status, 200);
  assert.equal(acceptStage(acceptSnapshot, old, restarted.previous, later, 0, instant).reason, "clock_regressed");
  assert.equal(restarted.stage({ ...source(later), apiReplyCheckedAt: before }, () => later).reason, "clock_regressed");
  assert.equal(restarted.stage({ ...source(later), apiReplyCheckedAt: "2026-10-19T08:00:00.000Z" }, () => later).status, 200);
  const recovered = await new StageStore(options).open();
  assert.equal(recovered.state.lastGatewayCheckedAt, instant);
  assert.equal(recovered.stage(source(later), () => later).status, 200);
  assert.equal((await new StageStore(options).open()).state.lastGatewayCheckedAt, later);
});

test("a reply ahead of receipt but within a skewed generation cannot diverge from the board watermark", async t => {
  const { store, options } = fixture(t); await store.open();
  assert.equal(store.stage(source(later), () => instant).reason, "clock_ahead");
  assert.equal(store.state.lastGatewayCheckedAt, null);
  assert.equal(store.current, null);
  const recovered = await new StageStore(options).open();
  assert.equal(recovered.stage(source(later), () => later).status, 200);
  assert.equal(recovered.state.lastGatewayCheckedAt, later);
});

for (const point of ["gateway_write", "gateway_fsync", "gateway_rename", "gateway_dir_fsync", "pair_mkdir", "pointer_rename"]) {
  test(`death at ${point} preserves the durable reply watermark and burns sequence`, async t => {
    const { root, store, options } = fixture(t); await store.open(); store.stage(source(), () => instant);
    const program = `import { StageStore } from ${JSON.stringify(new URL("./v2-stage-worker.mjs", import.meta.url).href)};
      const store = await new StageStore({root:process.argv[1],uid:process.getuid(),gid:process.getgid()}).open();
      store.boundary = name => { if (name === process.argv[2]) process.kill(process.pid, 'SIGKILL'); };
      store.stage(JSON.parse(process.argv[3]), () => ${JSON.stringify(later)});`;
    const result = spawnSync(process.execPath, ["--input-type=module", "-e", program, root, point, JSON.stringify(source(later))], { encoding: "utf8" });
    assert.equal(result.signal, "SIGKILL", result.stderr);
    const recovered = await new StageStore(options).open();
    const persisted = JSON.parse(fs.readFileSync(path.join(root, "sequence-state.json")));
    assert.ok([instant, later].includes(persisted.lastGatewayCheckedAt));
    assert.equal(recovered.stage(source(later), () => later).status, 200);
    assert.equal(recovered.state.lastReservedSeq, persisted.lastReservedSeq + 1);
    assert.equal((await new StageStore(options).open()).state.lastGatewayCheckedAt, later);
  });
}

test("KEEP rows exist even without broker rows; reporting and mapping never give them a desk", () => {
  for (const reported of [[], [
    { symbol: "SXR8", side: "short", desk: "joe", scope: "keep" },
    { symbol: "TSLA", side: "long", desk: "joel", scope: "keep" },
  ]]) {
    const value = candidate({ ...source(), positions: reported });
    assert.equal(check(value).ok, true);
    for (const symbol of ["SXR8", "TSLA"]) {
      const row = value.positions.rows.find(row => row.symbol === symbol);
      assert.equal(row.scope, "keep"); assert.equal(row.desk, null);
      assert.equal(Object.hasOwn(row.reasons, "desk"), false);
      assert.ok(row.side);
      for (const field of ["quantity", "mark", "marketValue", "dayPnl", "openPnl"]) {
        assert.equal(row[field], null);
        assert.equal(row.reasons[field], reported.length ? "not_exact_yet" : "source_unavailable");
      }
    }
  }
});

test("handoff copies precomputed ownership, overrides KEEP, and retains every unmapped broker row", () => {
  const row = (symbol, pos) => ({ symbol, pos, currency: "USD" });
  const projection = (symbol, side = "Long") => ({ symbol, side, currency: "USD" });
  const input = { book: { ts: instant, apiReplyCheckedAt: instant, summary: { NetLiquidation: source().equity, TotalCashValue: source().cash },
    positions: [row("SYNTHJ", 3), row("SYNTHJOE", -2), row("SXR8", 1), row("TSLA", 1), row("UNKNOWN", 1)] },
    deskEquities: { ok: true, desks: { j: { positions: [projection("SYNTHJ")] },
      joe: { positions: [projection("SYNTHJOE", "Short"), projection("SXR8")] }, joel: { positions: [projection("TSLA")] } } } };
  const original = JSON.stringify(input);
  const observation = copyObservation(input);
  assert.equal(JSON.stringify(input), original);
  assert.equal(validObservation(observation), true);
  assert.deepEqual(observation.positions.map(row => [row.symbol, row.side, row.desk]), [
    ["SYNTHJ", "long", "j"], ["SYNTHJOE", "short", "joe"], ["SXR8", "long", null], ["TSLA", "long", null], ["UNKNOWN", "long", null],
  ]);
  const value = candidate(observation);
  assert.equal(value.positions.rows.length, 5);
  assert.equal(value.positions.rows.at(-1).reasons.desk, "desk_unmapped");
  assert.equal(check(value).ok, true, "rev 9 accepts every row without dropping or guessing ownership");
  for (const row of value.positions.rows.filter(row => row.scope === "keep" || row.desk !== null)) {
    assert.equal(Object.hasOwn(row.reasons, "desk"), false);
  }
  observation.positions.pop();
  assert.equal(check(candidate(observation)).ok, true);
  input.deskEquities.desks.joe.positions.push(projection("SYNTHJ"));
  assert.equal(copyObservation(input).positions[0].desk, null, "split ownership is not a single desk");
  input.book.positions.push(row("SYNTHJ", 1));
  assert.equal(copyObservation(input).positions.at(-1).desk, null, "multiple contracts sharing an identity are ambiguous");
  delete input.deskEquities;
  input.family = { ok: true, positions: [projection("SYNTHJ")] };
  input.book.positions.pop();
  assert.equal(copyObservation(input).positions[0].desk, "j");
  assert.equal(copyObservation(input).positions[1].desk, null, "no legacy symbol attribution");
});

test("unmapped desk-null validator acceptance", () => {
  const observation = source(); observation.positions.push({ symbol: "UNKNOWN", side: "short", desk: null, scope: "stage0" });
  const value = candidate(observation);
  assert.deepEqual(value.positions.rows[0], unmappedRow);
  assert.equal(check(value).ok, true);
});

test("desk-null stage0 requires a desk reason; mapped and KEEP rows forbid it", () => {
  for (const [scope, desk, reason, rule] of [
    ["stage0", null, null, "deskRequired"],
    ...["j", "joe", "joel"].map(desk => ["stage0", desk, "desk_unmapped", "contradictoryDesk"]),
    ["keep", null, "desk_unmapped", "contradictoryDesk"],
  ]) {
    const value = candidate({ ...source(), positions: [{ symbol: scope === "keep" ? "SXR8" : "UNKNOWN", side: "short", desk, scope }] });
    const row = value.positions.rows[0];
    if (reason) row.reasons.desk = reason;
    else delete row.reasons.desk;
    const result = check(value);
    assert.equal(result.ok, false);
    assert.ok(result.errors.some(error => error.rule === rule), JSON.stringify(result.errors));
  }
});

test("unmapped observation stages a complete rev 9 pair and survives restart", async t => {
  const { root, store, options } = fixture(t); await store.open(); store.stage(source(), () => instant);
  const pointer = fs.readFileSync(path.join(root, "current.json"));
  const observation = source(later); observation.positions.push(
    { symbol: "UNKNOWN", side: "short", desk: null, scope: "stage0" },
    ...["j", "joe", "joel"].map(desk => ({ symbol: `SYNTH${desk.toUpperCase()}`, side: "long", desk, scope: "stage0" })),
    { symbol: "SXR8", side: "long", desk: null, scope: "keep" },
  );
  assert.equal(store.stage(observation, () => later).status, 200);
  assert.equal(store.disabled, false);
  assert.equal(fs.readFileSync(path.join(root, "current.json")).equals(pointer), false);
  const { pair } = JSON.parse(fs.readFileSync(path.join(root, "current.json")));
  assert.equal(pair, "pair-2");
  const snapshot = JSON.parse(fs.readFileSync(path.join(root, pair, "snapshot.json")));
  const receipt = JSON.parse(fs.readFileSync(path.join(root, pair, "receipt.json")));
  assert.equal(check(snapshot).ok, true);
  assert.equal(receipt.seq, snapshot.seq);
  assert.equal(receipt.contractSetSha256, "000045fb7843a16be95f6a7e42d46d4b4ecb34b0efd39fc987bee444817fc9d5");
  assert.deepEqual(snapshot.positions.rows[0], unmappedRow);
  assert.equal(snapshot.positions.rows.length, 6);
  for (const row of snapshot.positions.rows.slice(1)) assert.equal(Object.hasOwn(row.reasons, "desk"), false);
  const restarted = await new StageStore(options).open();
  assert.equal(restarted.state.lastReservedSeq, 2);
  assert.deepEqual(restarted.previous.value.positions.rows, snapshot.positions.rows);
  assert.equal(restarted.stage(observation, () => later).status, 200);
  assert.equal(restarted.state.lastReservedSeq, 3);
});

test("all null fields require individual reasons and no desk subtotal can masquerade as totals", () => {
  const value = candidate(source());
  for (const bag of [...value.desks.map(desk => desk.money), value.totals]) {
    for (const field of ["equity", "dayPnl", "openPnl", "totalPnl"]) {
      assert.equal(bag[field], null); assert.equal(bag.reasons[field], "not_exact_yet");
      const reason = bag.reasons[field]; delete bag.reasons[field];
      // Rev 9 permits missing desk money reasons when ready; this producer is stricter.
      assert.equal(new StageStore().validProjection(value), false); bag.reasons[field] = reason;
    }
  }
  for (const row of value.positions.rows) for (const field of ["quantity", "mark", "marketValue", "dayPnl", "openPnl"]) {
    const reason = row.reasons[field]; delete row.reasons[field]; assert.equal(check(value).ok, false); row.reasons[field] = reason;
  }
  value.totals.equity = { amount: "0.0000", currency: "EUR" };
  assert.equal(check(value).ok, false);
});

test("16 KiB frame bound drops overflow without truncating broker rows or spending the credit", () => {
  class Socket extends EventEmitter {
    writable = true; writableLength = 0; writes = [];
    connect() {} destroy() {} write(frame) { this.writes.push(frame); return true; }
  }
  const socket = new Socket();
  const handoff = createStageHandoff({ socketPath: "/run/joe-household-v2/stage.sock", makeSocket: () => socket });
  const input = { book: { ts: instant, positions: Array.from({ length: 256 }, (_, n) => ({ symbol: `SYNTHETIC${String(n).padStart(7, "0")}`, pos: 1 })) } };
  assert.ok(Buffer.byteLength(JSON.stringify(copyObservation(input))) > MAX_FRAME_BYTES);
  socket.emit("data", Buffer.from([1])); assert.equal(handoff.offer(input), false); assert.equal(socket.writes.length, 0);
  input.book.positions = input.book.positions.slice(0, 100);
  assert.equal(handoff.offer(input), true);
  const frame = socket.writes[0]; assert.equal(frame.readUInt32BE(), frame.length - 4); assert.ok(frame.length - 4 <= MAX_FRAME_BYTES);
  assert.equal(JSON.parse(frame.subarray(4)).positions.length, 100);
  assert.equal(handoff.offer(input), false); handoff.stop();
});

test("masked golden straddles Vienna midnight on a partial-coverage day without publishing partial totals", () => {
  const fixture = JSON.parse(fs.readFileSync(new URL("./fixtures/switch-set-observation.masked.json", import.meta.url)));
  const golden = JSON.parse(fs.readFileSync(new URL("./fixtures/household-v2-phase-a.masked.json", import.meta.url)));
  const day = at => new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Vienna", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(at));
  assert.notEqual(day(golden.generatedAt), day(fixture.receivedAt));
  assert.equal(fixture.syntheticCoverage.coverage, "partial");
  assert.equal(golden.brokerAccount.equity.amount, "12345.67000000");
  assert.equal(golden.brokerAccount.cash.amount, "-0.0000");
  assert.equal(golden.totals.dayPnl, null); assert.equal(golden.desks.every(desk => desk.money.dayPnl === null), true);
  assert.equal(check(golden).ok, true);
  assert.equal(acceptSnapshot("data", golden, null, fixture.receivedAt).status, 200);
});
