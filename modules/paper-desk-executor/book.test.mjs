import "../../tests/paper-desk-account-fixture.mjs";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtempSync, readFileSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { Readable } from "node:stream";
import test from "node:test";
import { BOOK_CLIENT_ID, createBook } from "./book.mjs";
import { createMarketData } from "./market-data.mjs";
import { ACCOUNT } from "./policy.mjs";
import { attributionConfig } from "./attribution.mjs";
import { createServer } from "./server.mjs";

const events = Object.fromEntries(["connected", "disconnected", "nextValidId", "error", "managedAccounts", "position", "positionEnd", "openOrder", "openOrderEnd", "accountSummary", "accountSummaryEnd", "updateAccountValue", "updatePortfolio", "accountDownloadEnd"].map((key) => [key, key]));
const contract = { conId: 1, symbol: "AAPL", exchange: "SMART", currency: "USD", secType: "STK" };
const kept = { ...contract, conId: 2, symbol: "TSLA" };
const fill = { contract, execution: { execId: "book-fill.01", acctNumber: ACCOUNT, clientId: 705, orderRef: "j|261012|book-test", shares: 2, side: "BOT", price: 100, time: "2026-10-12T15:00:00Z" } };

function harness(options = {}) {
  const calls = [];
  let instance, connections = 0;
  const invoke = (name, api) => { calls.push(name); options.onCall?.(name, api); };
  class ReadOnlyIB extends EventEmitter {
    constructor({ clientId, port }) { super(); assert.equal(port, 4002); assert.equal(clientId, options.expectedClientId || BOOK_CLIENT_ID); instance = this; }
    connect() {
      connections++; invoke("connect", this);
      if (options.inUse && connections === 1) { this.emit(events.error, new Error("test ID in use"), 326); return; }
      if (options.stall === "handshake") return;
      this.emit(events.connected); this.emit(events.nextValidId, 900);
    }
    disconnect() { invoke("disconnect", this); this.emit(events.disconnected); }
    reqManagedAccts() { invoke("managed", this); this.emit(events.managedAccounts, options.accounts || ACCOUNT); }
    reqPositions() {
      invoke("positions", this);
      if (options.stall === "positions") return;
      for (const row of options.positions ?? [{ contract, pos: 2, avgCost: 100 }, { contract: kept, pos: 1, avgCost: 200 }]) this.emit(events.position, ACCOUNT, row.contract, row.pos, row.avgCost);
      this.emit(events.position, "U0000001", { ...contract, conId: 3 }, 100, 1);
      this.emit(events.positionEnd);
    }
    reqAllOpenOrders() {
      invoke("orders", this);
      this.emit(events.openOrder, 900, contract, { account: ACCOUNT, clientId: 705, orderRef: "j|261012|book-test", action: "BUY", totalQuantity: 2, orderType: "LMT" }, { status: "Submitted" });
      this.emit(events.openOrder, 900, contract, { account: ACCOUNT, clientId: 28, action: "SELL", totalQuantity: 1, orderType: "LMT" }, { status: "Submitted" });
      if (options.stall !== "orders") this.emit(events.openOrderEnd);
    }
    reqAccountSummary(id, group, tags) {
      invoke("summary", this); assert.equal(group, "All"); assert.match(tags, /NetLiquidation/);
      this.emit(events.accountSummary, id + 1, ACCOUNT, "NetLiquidation", "wrong-id", "USD");
      this.emit(events.accountSummaryEnd, id + 1);
      this.emit(events.accountSummary, id, ACCOUNT, "NetLiquidation", "1000", "USD");
      this.emit(events.accountSummary, id, ACCOUNT, "TotalCashValue", "500", "USD");
      this.emit(events.accountSummary, id, "U0000001", "BuyingPower", "wrong-account", "USD");
      if (options.stall !== "summary") this.emit(events.accountSummaryEnd, id);
    }
    reqAccountUpdates(subscribe, account) {
      assert.fail("book reads must not replace or unsubscribe the pusher's account subscription");
    }
    cancelPositions() { invoke("cancelPositions", this); }
    cancelAccountSummary() { invoke("cancelSummary", this); }
    placeOrder() { assert.fail("read-only proof: placeOrder called"); }
    cancelOrder() { assert.fail("read-only proof: cancelOrder called"); }
    reqGlobalCancel() { assert.fail("read-only proof: global cancellation called"); }
    exerciseOptions() { assert.fail("read-only proof: exerciseOptions called"); }
    reqAutoOpenOrders() { assert.fail("read-only proof: order binding called"); }
    reqIds() { assert.fail("read-only proof: order ID allocation called"); }
    reqExecutions() { assert.fail("book reads must not perform execution reconciliation"); }
  }
  const ledger = { ownershipComplete: true, executions: [fill], concurrentObservedAt: "2026-10-12T15:01:00Z" };
  const runtime = { IBApi: ReadOnlyIB, EventName: events };
  return { runtime, ledger, calls, instance: () => instance };
}

function book(h, extra = {}) {
  return createBook({ runtime: h.runtime, readLedger: () => h.ledger, ownershipClientIds: { j: [28] }, reconnectDelayMs: 0, accountEnabled: true, ...extra });
}

async function request(app, method, url, body, peer = "127.0.0.1") {
  const req = Readable.from(body ? [Buffer.from(JSON.stringify(body))] : []);
  req.method = method; req.url = url; req.socket = { remoteAddress: peer };
  let result;
  const res = { headersSent: false, writeHead(status) { this.headersSent = true; this.status = status; }, end(raw) { this.writableEnded = true; result = { status: this.status, body: JSON.parse(raw) }; } };
  await app.handle(req, res);
  return result;
}

function server(h, extra = {}) {
  return createServer({ testMode: true, listenHost: "127.0.0.1", listenPort: 0, allowlist: ["127.0.0.1"], adminAllowlist: ["127.0.0.1"], stateDir: mkdtempSync(path.join(tmpdir(), "ops313-book-http-")), gatewayReachable: () => true, book: { runtime: h.runtime, reconnectDelayMs: 0, ownershipClientIds: { j: [28] }, accountEnabled: true }, marketDataAudit: () => {}, ...extra });
}

test("book endpoints provide positions, all open orders and summary without the pusher account subscription", async () => {
  const h = harness(), service = book(h);
  const positions = await service.read("positions");
  assert.equal(positions.statusCode, 200);
  assert.equal(positions.body.positions.length, 2);
  assert.equal(positions.body.positions[0].desk, "j");
  assert.equal(positions.body.positions[0].foreign, false);
  assert.equal(positions.body.positions[1].keep, true);
  const orders = await service.read("open-orders");
  assert.equal(orders.statusCode, 200);
  assert.equal(orders.body.openOrders.length, 2, "order IDs are scoped by client");
  assert.equal(orders.body.openOrders[0].desk, "j");
  assert.equal(orders.body.openOrders[1].desk, null);
  assert.equal(orders.body.openOrders[1].foreign, true);
  assert.equal(orders.body.openOrders[1].suggestedDesk, "j");
  const account = await service.read("account");
  assert.deepEqual(account.body.accounts, [ACCOUNT]);
  assert.equal(account.body.summary.NetLiquidation.value, "1000");
  assert.equal(account.body.summary.BuyingPower, undefined);
  assert.equal(account.body.values.find((row) => row.tag === "TotalCashValue").value, "500");
  assert.equal(account.body.portfolio[0].avgCost, 100);
  assert.equal(account.body.portfolio[0].unrealizedPNL, null);
  assert.equal(account.body.portfolio[1].keep, true);
  assert.equal(account.body.cached, true);
  assert.equal(h.calls.filter((call) => call === "connect").length, 1);
  for (const call of ["cancelPositions", "cancelSummary", "disconnect"]) assert.ok(h.calls.includes(call));
});

test("cached book data refreshes attribution after a ledger-only reassignment", async () => {
  const h = harness(); h.ledger.executions = [{ ...fill, execution: { ...fill.execution, clientId: 28, orderRef: "" } }];
  const service = book(h);
  assert.equal((await service.read("positions")).body.positions[0].foreign, true);
  h.ledger.executions[0].attribution = { method: "admin", desk: "joe" };
  const refreshed = await service.read("positions");
  assert.equal(refreshed.body.cached, true);
  assert.equal(refreshed.body.positions[0].desk, "joe");
  assert.equal(refreshed.body.positions[0].foreign, false);
  assert.equal(h.calls.filter((call) => call === "connect").length, 1);
});

test("the book exposes a desk short and its foreign cover even when IB omits the flat account position", async () => {
  const h = harness({ positions: [] });
  h.ledger.executions = [
    { ...fill, execution: { ...fill.execution, execId: "short-book.01", shares: 4, side: "SLD", orderRef: "joe|261012|short" } },
    { ...fill, execution: { ...fill.execution, execId: "cover-book.01", shares: 4, clientId: 28, orderRef: "" } },
  ];
  const result = await book(h).read("positions");
  assert.equal(result.statusCode, 200);
  assert.deepEqual(result.body.positions, []);
  assert.deepEqual(result.body.deskPositions.map((row) => [row.desk, row.quantity]), [["joe", -4]]);
  assert.equal(result.body.foreignPositions[0].quantity, 4);
  h.ledger.ownershipComplete = false;
  assert.deepEqual((await book(h).read("positions")).body.deskPositions, []);
});

test("book client IDs reject collisions in both read paths", () => {
  for (const clientId of [40, 92, 94, 700, 701, 702, 703, 704, 705, 706, 707, 28]) assert.throws(() => createBook({ clientId, ownershipClientIds: { j: [28] } }), /distinct/);
  assert.throws(() => createBook({ clientId: 900, orderClientIds: { executor: 705, recon: 900 } }), /distinct/);
  assert.throws(() => createBook({ clientId: 900, marketDataClientId: 900 }), /distinct/);
  assert.throws(() => createMarketData({ clientId: 708 }), /distinct/);
  assert.throws(() => createMarketData({ clientId: 900, bookClientId: 900 }), /distinct/);
  assert.equal(createBook().clientId, 708);
});

test("book reads share a short snapshot cache, coalesce concurrent requests and expire after 15 seconds", async () => {
  const h = harness(); let now = 100000;
  const service = book(h, { now: () => now });
  const reads = await Promise.all(["positions", "open-orders", "account"].map((endpoint) => service.read(endpoint)));
  assert.ok(reads.every((read) => read.statusCode === 200));
  assert.equal(h.calls.filter((call) => call === "connect").length, 1);
  now += 14999; assert.equal((await service.read("positions")).body.cached, true);
  now += 1; assert.equal((await service.read("positions")).body.cached, false);
  assert.equal(h.calls.filter((call) => call === "connect").length, 2);
});

test("book rejects bad queries before IB calls", async () => {
  const h = harness(), service = book(h);
  for (const params of ["desk=unknown", "desk=j&desk=joe", "account=DU0000001", "clientId=705"]) assert.equal((await service.read("positions", new URLSearchParams(params))).statusCode, 400);
  assert.equal((await service.read("unknown")).statusCode, 400);
  assert.deepEqual(h.calls, []);
});

test("book fails closed on mixed/live accounts, incomplete callbacks and broker errors, with cleanup", async () => {
  for (const options of [
    { accounts: "U0000001" }, { accounts: `${ACCOUNT},U0000001` },
    ...["handshake", "positions", "orders", "summary"].map((stall) => ({ stall })),
    { onCall: (name, api) => { if (name === "summary") api.emit(events.error, new Error("private broker details"), 321); } },
  ]) {
    const h = harness(options);
    const result = await book(h, { timeoutMs: 15 }).read("account");
    assert.equal(result.statusCode, 503);
    assert.doesNotMatch(JSON.stringify(result), /private broker details/);
    assert.equal(h.calls.at(-1), "disconnect");
    assert.equal(h.instance().listenerCount(events.position), 0);
  }
});

test("book paces failed snapshots before opening another connection and retries ID-in-use once", async () => {
  const h = harness({ accounts: "U0000001" }); let now = 1000;
  const service = book(h, { now: () => now });
  assert.equal((await service.read("positions")).statusCode, 503);
  const limited = await service.read("account");
  assert.equal(limited.statusCode, 429); assert.equal(limited.body.retry_after_s, 2);
  assert.equal(h.calls.filter((call) => call === "connect").length, 1);
  now += 2000; assert.equal((await service.read("positions")).statusCode, 503);
  const retried = harness({ inUse: true });
  assert.equal((await book(retried).read("positions")).statusCode, 200);
  assert.equal(retried.calls.filter((call) => call === "connect").length, 2);
});

test("IB 100 imposes a ten-minute book cooldown without another Gateway connection", async () => {
  const h = harness({ onCall: (name, api) => { if (name === "summary") api.emit(events.error, new Error("private pacing details"), 100); } });
  let now = 1000;
  const service = book(h, { now: () => now });
  assert.equal((await service.read("account")).statusCode, 503);
  const paused = await service.read("positions");
  assert.equal(paused.statusCode, 429);
  assert.equal(paused.body.retry_after_s, 600);
  now += 599000;
  assert.equal((await service.read("account")).body.retry_after_s, 1);
  assert.equal(h.calls.filter((call) => call === "connect").length, 1);
  now += 1000;
  assert.equal((await service.read("account")).statusCode, 503);
  assert.equal(h.calls.filter((call) => call === "connect").length, 2);
});

test("an unsolicited order-end callback cannot complete a book order request", async () => {
  const h = harness({ stall: "orders", onCall: (name, api) => { if (name === "positions") api.emit(events.openOrderEnd); } });
  const result = await book(h, { timeoutMs: 15 }).read("open-orders");
  assert.equal(result.statusCode, 503);
  assert.equal(h.calls.at(-1), "disconnect");
});

test("aborted book reads and queued requests close reads without dispatching queued IB calls", async () => {
  const h = harness({ stall: "positions" }), service = book(h, { timeoutMs: 100 });
  const active = new AbortController(), queued = new AbortController();
  const first = service.read("positions", undefined, { signal: active.signal });
  await new Promise((resolve) => setImmediate(resolve));
  const second = service.read("account", undefined, { signal: queued.signal });
  queued.abort(); active.abort();
  assert.equal((await first).statusCode, 503); assert.equal((await second).statusCode, 503);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(h.calls.filter((call) => call === "connect").length, 1);
  assert.ok(h.calls.includes("cancelPositions")); assert.equal(h.calls.at(-1), "disconnect");
});

test("HTTP book reads share the quote peer allowlist, work under HALT and leave ledger/audit bytes unchanged", async () => {
  const h = harness(), app = server(h);
  const state = app.ledger.load(); Object.assign(state, h.ledger); app.ledger.save(state); app.ledger.setHalt("test halt");
  const before = [app.ledger.statePath, app.ledger.auditPath, app.ledger.haltPath].map((file) => readFileSync(file, "utf8"));
  for (const endpoint of ["positions", "open-orders", "account"]) {
    assert.equal((await request(app, "GET", `/v1/book/${endpoint}`, undefined, "192.0.2.1")).status, 403);
    assert.equal((await request(app, "GET", `/v1/book/${endpoint}`)).status, 200);
    assert.equal((await request(app, "POST", `/v1/book/${endpoint}`)).status, 404);
  }
  assert.deepEqual([app.ledger.statePath, app.ledger.auditPath, app.ledger.haltPath].map((file) => readFileSync(file, "utf8")), before);
  const empty = server(h);
  assert.equal((await request(empty, "GET", "/v1/book/positions")).status, 200);
  assert.deepEqual(readdirSync(empty.ledger.root), [], "reads must not initialize a ledger");
});

test("HTTP admin attribution is allowlisted and serialized with the intent ledger lock", async () => {
  const h = harness(); let release, started;
  const running = new Promise((resolve) => { started = resolve; });
  const app = server(h, { attributionConfig: attributionConfig({ ownership: { j: [28] } }), execute: async (_intent, state) => {
    started(); await new Promise((resolve) => { release = resolve; }); state.concurrentObservedAt = "2026-10-12T16:00:00Z"; return { status: "ok" };
  } });
  const state = app.ledger.load(); state.executions = [{ ...fill, execution: { ...fill.execution, clientId: 28, orderRef: "" } }]; app.ledger.save(state);
  const change = { execId: fill.execution.execId, desk: "joe", actor: "ops-test", reason: "test assignment", dryRun: false };
  assert.equal((await request(app, "POST", "/v1/admin/attribution", change, "192.0.2.1")).status, 403);
  const intent = request(app, "POST", "/v1/intents", { schema: "barta.paper-desk-intent.v2", intentId: "book-admin-lock-test", desk: "j", action: "recon", createdAt: new Date(Date.now() - 1000).toISOString(), expiresAt: new Date(Date.now() + 60000).toISOString() });
  await running;
  let completed = false;
  const admin = request(app, "POST", "/v1/admin/attribution", change).then((result) => { completed = true; return result; });
  await new Promise((resolve) => setImmediate(resolve)); assert.equal(completed, false);
  release(); assert.equal((await intent).status, 200); assert.equal((await admin).status, 200);
  const saved = app.ledger.load(); assert.equal(saved.concurrentObservedAt, "2026-10-12T16:00:00Z"); assert.equal(saved.attributionJournal.length, 1);
  assert.equal((await request(app, "POST", "/v1/admin/attribution", change)).status, 409);
  assert.deepEqual(h.calls, [], "admin must never connect to IB");
});

test("account book reads default off, including cached snapshots, without making IB calls", async (t) => {
  const prior = process.env.PAPER_DESK_BOOK_ACCOUNT_ENABLED;
  delete process.env.PAPER_DESK_BOOK_ACCOUNT_ENABLED;
  t.after(() => { if (prior === undefined) delete process.env.PAPER_DESK_BOOK_ACCOUNT_ENABLED; else process.env.PAPER_DESK_BOOK_ACCOUNT_ENABLED = prior; });
  const h = harness(), service = createBook({ runtime: h.runtime, reconnectDelayMs: 0 });
  const disabled = await service.read("account");
  assert.equal(disabled.statusCode, 503);
  assert.match(disabled.body.reason, /disabled until OPS verifies/);
  assert.deepEqual(h.calls, []);
  assert.equal((await service.read("positions")).statusCode, 200);
  assert.equal(h.calls.includes("summary"), false, "default book reads must not consume optional account-summary subscriptions");
  const before = [...h.calls];
  assert.equal((await service.read("account")).statusCode, 503);
  assert.deepEqual(h.calls, before);
  const app = server(h, { book: { runtime: h.runtime, reconnectDelayMs: 0 } });
  assert.equal((await request(app, "GET", "/v1/book/account")).status, 503);
  assert.deepEqual(h.calls, before);
});

test("IB 2100 is informational in both the book connection and snapshot", async () => {
  const h = harness({ onCall: (name, api) => { if (["connect", "summary"].includes(name)) api.emit(events.error, new Error("account subscription information"), 2100); } });
  assert.equal((await book(h).read("account")).statusCode, 200);
  assert.equal(h.calls.at(-1), "disconnect");
});

test("IB account-summary limit refuses the optional account read with cleanup", async () => {
  const h = harness({ onCall: (name, api) => { if (name === "summary") api.emit(events.error, new Error("summary subscription limit"), 322); } });
  assert.equal((await book(h).read("account")).statusCode, 503);
  assert.ok(h.calls.includes("cancelSummary"));
  assert.equal(h.calls.at(-1), "disconnect");
});

test("an order-allowlisted desk peer is refused before parsing the admin body; OPS journals its peer", async () => {
  const h = harness(), app = server(h, { allowlist: ["127.0.0.1", "100.64.0.15"], adminAllowlist: undefined, execute: async () => ({ status: "ok" }) });
  assert.deepEqual(app.adminAllowlist, ["100.64.0.14"]);
  const state = app.ledger.load(); state.executions = [{ ...fill, execution: { ...fill.execution, clientId: 28, orderRef: "" } }]; app.ledger.save(state);
  const before = readFileSync(app.ledger.statePath, "utf8");
  let bodyReads = 0, status;
  const req = Readable.from([Buffer.from("invalid admin JSON")]);
  req.method = "POST"; req.url = "/v1/admin/attribution"; req.socket = { remoteAddress: "::ffff:100.64.0.15" };
  req[Symbol.asyncIterator] = () => { bodyReads++; throw new Error("admin body must not be parsed"); };
  await app.handle(req, { writeHead(code) { status = code; }, end() {} });
  assert.equal(status, 403); assert.equal(bodyReads, 0);
  assert.equal(readFileSync(app.ledger.statePath, "utf8"), before);
  const change = { execId: fill.execution.execId, desk: "joe", actor: "ops-test", reason: "test assignment", dryRun: false };
  assert.equal((await request(app, "POST", "/v1/admin/attribution", change, "::ffff:100.64.0.14")).status, 200);
  const journal = app.ledger.load().attributionJournal[0];
  assert.equal(journal.actor, "ops-test"); assert.equal(journal.peer, "100.64.0.14");
  assert.equal((await request(app, "POST", "/v1/intents", { schema: "barta.paper-desk-intent.v2", intentId: "desk-still-allowed", desk: "j", action: "recon", createdAt: new Date(Date.now() - 1000).toISOString(), expiresAt: new Date(Date.now() + 60000).toISOString() }, "100.64.0.15")).status, 200);
  assert.deepEqual(h.calls, []);
});

test("external disposition uses the same OPS-only admin route for dry run and apply without IB effects", async () => {
  const h = harness(), app = server(h, { allowlist: ["127.0.0.1", "100.64.0.15"], adminAllowlist: undefined });
  const state = app.ledger.load();
  state.executions = [{ ...fill, execution: { ...fill.execution, clientId: 28, orderRef: "" } }];
  app.ledger.save(state);
  const before = readFileSync(app.ledger.statePath, "utf8");
  const change = { execId: fill.execution.execId, disposition: "external", actor: "ops-test", reason: "Acknowledge external activity" };
  for (const dryRun of [true, false]) assert.equal((await request(app, "POST", "/v1/admin/attribution", { ...change, dryRun }, "100.64.0.15")).status, 403);
  const preview = await request(app, "POST", "/v1/admin/attribution", change, "100.64.0.14");
  assert.equal(preview.status, 200); assert.equal(preview.body.dryRun, true);
  assert.equal(readFileSync(app.ledger.statePath, "utf8"), before);
  assert.equal((await request(app, "POST", "/v1/admin/attribution", { ...change, dryRun: false }, "100.64.0.14")).status, 200);
  const saved = app.ledger.load(), journal = saved.attributionJournal[0];
  assert.equal(journal.actor, "ops-test"); assert.equal(journal.peer, "100.64.0.14");
  assert.equal(journal.disposition, "external"); assert.equal(journal.to, "external");
  assert.equal(saved.executions[0].attribution.desk, null);
  assert.equal(saved.executions[0].attribution.needsAttribution, false);
  assert.equal((await request(app, "POST", "/v1/admin/attribution", { ...change, dryRun: false }, "100.64.0.14")).status, 409);
  assert.deepEqual(h.calls, []);
});

test("routine admin 400/404/409 refusals are audit lines without executor errors or stacks", async (t) => {
  const h = harness(), app = server(h), errors = t.mock.method(console, "error", () => {});
  const state = app.ledger.load(); state.executions = [{ ...fill, execution: { ...fill.execution, clientId: 28, orderRef: "" } }]; app.ledger.save(state);
  const change = { execId: fill.execution.execId, desk: "joe", actor: "ops-test", reason: "test assignment", dryRun: false };
  for (const [extra, expected] of [[{ desk: "unknown" }, 400], [{ execId: "unknown.01" }, 404]]) assert.equal((await request(app, "POST", "/v1/admin/attribution", { ...change, ...extra })).status, expected);
  assert.equal((await request(app, "POST", "/v1/admin/attribution", change)).status, 200);
  assert.equal((await request(app, "POST", "/v1/admin/attribution", change)).status, 409);
  const audit = readFileSync(app.ledger.auditPath, "utf8").trim().split("\n").map(JSON.parse);
  assert.deepEqual(audit.filter((row) => row.event === "attribution_refused").map((row) => row.status), [400, 404, 409]);
  assert.ok(audit.every((row) => row.event !== "executor_error" && !row.error?.stack && !row.stack));
  assert.equal(errors.mock.callCount(), 0);
});
