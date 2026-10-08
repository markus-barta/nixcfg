import assert from "node:assert/strict";
import { Readable } from "node:stream";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { runClient } from "./client/paper-intent.mjs";

import { digest, parseIntent } from "./policy.mjs";
import { createServer } from "./server.mjs";
import { openLedger } from "./state.mjs";

// Exercise the real HTTP handler without requiring a listening socket. The
// separate security tests check production bind constraints; live transport
// verification belongs on the host, outside the restricted builder sandbox.
const handlers = new Map();
let nextPort = 9000;
async function fetch(url, options = {}) {
  const target = new URL(url);
  const handler = handlers.get(target.origin);
  if (!handler) throw new Error("test origin unavailable");
  const request = Readable.from(options.body ? [Buffer.from(options.body)] : []);
  request.method = options.method || "GET";
  request.url = `${target.pathname}${target.search}`;
  request.headers = options.headers || {};
  request.socket = { remoteAddress: "127.0.0.1" };
  let body; let status; let headers;
  const response = { headersSent: false, writeHead(code, values) { status = code; headers = values; this.headersSent = true; }, end(value) { body = value; } };
  await handler(request, response);
  return new Response(body, { status, headers });
}

function tempDir() {
  return mkdtempSync(path.join(tmpdir(), "paper-desk-"));
}

function removeTemp(stateDir) {
  if (!stateDir.includes(`${path.sep}paper-desk-`)) throw new Error("refusing to remove an unexpected directory");
  rmSync(stateDir, { recursive: true, force: true });
}

function valid(overrides = {}) {
  const now = Date.now();
  return {
    schema: "barta.paper-desk-intent.v2",
    intentId: "j-20261006-001",
    desk: "j",
    action: "place",
    createdAt: new Date(now - 10_000).toISOString(),
    expiresAt: new Date(now + 5 * 60_000).toISOString(),
    order: {
      symbol: "AAPL",
      side: "BUY",
      quantity: 2,
      limitPrice: 100,
      stopPrice: 99,
      currency: "USD",
    },
    ...overrides,
  };
}

function okResult(intent) {
  return {
    status: "ok",
    intentId: intent.intentId,
    desk: intent.desk,
    action: intent.action,
    observedAt: "2026-10-06T14:00:00.000Z",
  };
}

async function start(t, overrides = {}) {
  const stateDir = overrides.stateDir ?? tempDir();
  let calls = 0;
  const execute = overrides.execute ?? (async (intent) => {
    calls += 1;
    return okResult(intent);
  });
  const created = createServer({
    testMode: true,
    listenHost: "127.0.0.1",
    listenPort: 0,
    gatewayPort: 4002,
    gatewayHost: "100.64.0.6",
    allowlist: ["127.0.0.1"],
    gatewayReachable: async () => true,
    ...overrides,
    stateDir,
    execute,
  });
  const address = { port: nextPort++ };
  handlers.set(`http://127.0.0.1:${address.port}`, created.handle);
  const ctx = {
    calls: () => calls,
    stateDir,
    url: `http://127.0.0.1:${address.port}`,
  };
  t.after(async () => {
    handlers.delete(ctx.url);
    removeTemp(stateDir);
  });
  return ctx;
}

async function post(url, body) {
  const response = await fetch(`${url}/v1/intents`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  return { status: response.status, body: await response.json() };
}

async function runCli(args, origin) {
  let stdout = "";
  const code = await runClient(args, { fetch: (url, options) => {
    const target = new URL(url);
    assert.equal(target.origin, "http://100.64.0.6:8470");
    assert.equal(options.redirect, "error");
    return fetch(`${origin}${target.pathname}${target.search}`, options);
  }, write: (line) => { stdout += `${line}\n`; } });
  return { code, stdout, stderr: "" };
}

test("peer allowlist rejects every source that is not listed", async (t) => {
  const denied = await start(t, { allowlist: ["100.64.0.9"] });
  const response = await fetch(`${denied.url}/v1/health`, { headers: { "X-Forwarded-For": "100.64.0.9" } });
  assert.equal(response.status, 403);
  assert.deepEqual(await response.json(), { status: "rejected", reason: "source is not allowed" });

  const allowed = await start(t, { allowlist: ["127.0.0.1"] });
  const health = await fetch(`${allowed.url}/v1/health`);
  assert.equal(health.status, 200);
  const body = await health.json();
  assert.equal(body.gatewayReachable, true);
  assert.equal(body.halt.active, false);
  assert.equal(body.brakes.newToday, 0);
  assert.equal(body.brakes.dailyRiskEurLimit, 50);
  assert.equal(body.brakes.placementBlockedOnInitDay, false);
  assert.deepEqual(body.brakes.keep, ["SXR8", "TSLA"]);
});

test("idempotent resubmit returns the stored result and a different body conflicts", async (t) => {
  let calls = 0;
  const ctx = await start(t, {
    execute: async (intent) => {
      calls += 1;
      return okResult(intent);
    },
  });
  const intent = valid();
  const first = await post(ctx.url, intent);
  const reordered = {
    order: intent.order,
    expiresAt: intent.expiresAt,
    createdAt: intent.createdAt,
    action: intent.action,
    desk: intent.desk,
    intentId: intent.intentId,
    schema: intent.schema,
  };
  const second = await post(ctx.url, reordered);
  const changed = await post(ctx.url, {
    ...intent,
    order: { ...intent.order, symbol: "MSFT" },
  });
  assert.equal(calls, 1);
  assert.equal(first.status, 200);
  assert.equal(first.body.status, "ok");
  assert.equal(second.status, 200);
  assert.equal(second.body.idempotentReplay, true);
  assert.equal(second.body.intentId, first.body.intentId);
  assert.equal(changed.status, 409);
  assert.match(changed.body.reason, /different content/);
});

test("HALT blocks place and still allows recon and flatten", async (t) => {
  const seen = [];
  const ctx = await start(t, {
    execute: async (intent) => {
      seen.push(intent.action);
      return okResult(intent);
    },
  });
  const halt = await fetch(`${ctx.url}/v1/halt`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ reason: "operator stop" }),
  });
  assert.equal(halt.status, 200);
  assert.equal((await halt.json()).active, true);

  const placeBody = valid();
  const place = await post(ctx.url, placeBody);
  const again = await post(ctx.url, placeBody);
  const recon = await post(ctx.url, valid({
    intentId: "j-20261006-recon",
    action: "recon",
    order: undefined,
  }));
  const flatten = await post(ctx.url, valid({
    intentId: "j-20261006-flat",
    action: "flatten",
    order: undefined,
  }));
  assert.equal(place.status, 422);
  assert.match(place.body.reason, /HALT/);
  assert.equal(again.status, 422);
  assert.equal(again.body.idempotentReplay, true);
  assert.equal(recon.status, 200);
  assert.equal(flatten.status, 200);
  assert.deepEqual(seen, ["recon", "flatten"]);

  const health = await (await fetch(`${ctx.url}/v1/health`)).json();
  assert.equal(health.halt.active, true);
  assert.equal(health.halt.source, "local");
});

test("KEEP and schema failures are rejected before execution", async (t) => {
  let calls = 0;
  const ctx = await start(t, {
    execute: async () => {
      calls += 1;
      return { status: "ok" };
    },
  });
  const keep = await post(ctx.url, valid({ order: { ...valid().order, symbol: "TSLA" } }));
  const keepEtf = await post(ctx.url, valid({
    intentId: "j-20261006-sxr8",
    order: { ...valid().order, symbol: "SXR8" },
  }));
  const schema = await post(ctx.url, { schema: "barta.paper-desk-intent.v1", intentId: "j-20261006-001" });
  const extra = await post(ctx.url, { ...valid({ intentId: "j-20261006-extra" }), note: "nope" });
  const flattenOrder = await post(ctx.url, valid({
    intentId: "j-20261006-badflat",
    action: "flatten",
  }));
  assert.equal(keep.status, 400);
  assert.match(keep.body.reason, /KEEP/);
  assert.equal(keepEtf.status, 400);
  assert.match(keepEtf.body.reason, /KEEP/);
  assert.equal(schema.status, 400);
  assert.match(schema.body.reason, /schema/);
  assert.equal(extra.status, 400);
  assert.match(extra.body.reason, /unsupported field/);
  assert.equal(flattenOrder.status, 400);
  assert.match(flattenOrder.body.reason, /order is allowed only for place/);
  assert.equal(calls, 0);
});

test("live port 4001 and non-tailnet binds are refused before listen", () => {
  const stateDir = tempDir();
  try {
    const base = {
      testMode: true,
      listenHost: "127.0.0.1",
      listenPort: 0,
      allowlist: ["127.0.0.1"],
      stateDir,
      execute: async () => ({ status: "ok" }),
    };
    assert.throws(() => createServer({ ...base, gatewayPort: 4001 }), /live port 4001/);
    assert.throws(() => createServer({ ...base, gatewayPort: 4003 }), /non-paper port/);
    assert.throws(() => createServer({
      testMode: false,
      listenHost: "0.0.0.0",
      listenPort: 8470,
      gatewayPort: 4002,
      allowlist: ["100.64.0.9"],
      stateDir,
      execute: async () => ({ status: "ok" }),
    }), /tailnet address/);
    assert.throws(() => createServer({
      testMode: false,
      listenHost: "192.168.1.99",
      listenPort: 8470,
      gatewayPort: 4002,
      allowlist: ["100.64.0.9"],
      stateDir,
      execute: async () => ({ status: "ok" }),
    }), /tailnet address/);
    const production = createServer({
      testMode: false,
      listenHost: "100.64.0.6",
      listenPort: 8470,
      gatewayPort: 4002,
      allowlist: ["100.64.0.9", "100.64.0.14"],
      stateDir,
      execute: async () => ({ status: "ok" }),
    });
    assert.equal(production.listenHost, "100.64.0.6");
    assert.equal(production.listenPort, 8470);
    assert.equal(production.gatewayPort, 4002);
  } finally {
    removeTemp(stateDir);
  }
});

test("a claim without a stored result returns uncertain and is never replayed", async (t) => {
  const stateDir = tempDir();
  const raw = valid({ intentId: "j-20261006-crash", action: "recon", order: undefined });
  const intent = parseIntent(raw);
  const ledger = openLedger(stateDir);
  const state = ledger.load();
  state.intents.set(intent.intentId, {
    hash: digest(intent),
    action: intent.action,
    desk: intent.desk,
    status: "claimed",
    claimedAt: new Date().toISOString(),
  });
  ledger.save(state);

  let calls = 0;
  const ctx = await start(t, {
    stateDir,
    execute: async () => {
      calls += 1;
      return { status: "ok" };
    },
  });
  const first = await post(ctx.url, raw);
  const second = await post(ctx.url, raw);
  const lookup = await fetch(`${ctx.url}/v1/intents/${intent.intentId}`);
  assert.equal(calls, 0);
  assert.equal(first.status, 409);
  assert.equal(first.body.status, "uncertain");
  assert.match(first.body.reason, /no automatic replay/);
  assert.equal(second.status, 409);
  assert.equal(second.body.status, "uncertain");
  assert.equal(lookup.status, 409);
  assert.equal((await lookup.json()).status, "uncertain");
});

test("the desk client prints JSON for health, place, and status", async (t) => {
  let seen = null;
  const ctx = await start(t, {
    execute: async (intent) => {
      seen = intent;
      return okResult(intent);
    },
  });
  const health = await runCli(["health"], ctx.url);
  assert.equal(health.code, 0);
  assert.equal(JSON.parse(health.stdout).gatewayReachable, true);

  const place = await runCli([
    "place",
    "--desk", "j",
    "--intent-id", "j-20261006-cli1",
    "--symbol", "aapl",
    "--side", "buy",
    "--quantity", "2",
    "--limit", "100",
    "--stop", "99",
  ], ctx.url);
  assert.equal(place.code, 0);
  assert.equal(JSON.parse(place.stdout).status, "ok");
  assert.equal(seen.schema, "barta.paper-desk-intent.v2");
  assert.equal(seen.order.symbol, "AAPL");
  assert.equal(seen.order.side, "BUY");
  assert.equal(seen.order.quantity, 2);

  const status = await runCli(["status", "--intent-id", "j-20261006-cli1"], ctx.url);
  assert.equal(status.code, 0);
  assert.equal(JSON.parse(status.stdout).status, "ok");
  assert.equal(JSON.parse(status.stdout).ledgerStatus, "done");

  const denied = await start(t, { allowlist: ["100.64.0.14"] });
  const forbidden = await runCli(["health"], denied.url);
  assert.equal(forbidden.code, 1);
  assert.equal(JSON.parse(forbidden.stdout).reason, "source is not allowed");
});

test("HALT persists while an execution remains pending", async (t) => {
  let release;
  let entered;
  const ready = new Promise((resolve) => { entered = resolve; });
  const pending = new Promise((resolve) => { release = resolve; });
  const ctx = await start(t, { execute: async (intent, _state, { getHalt }) => {
    entered();
    await pending;
    assert.equal(getHalt().active, true);
    return { ...okResult(intent), status: "rejected", reason: "HALT" };
  } });
  const placing = post(ctx.url, valid());
  await ready;
  try {
    const response = await fetch(`${ctx.url}/v1/halt`, { method: "POST", body: "{}", signal: AbortSignal.timeout(1000) });
    assert.equal(response.status, 200);
    assert.equal(openLedger(ctx.stateDir).haltBody().length > 0, true);
  } finally { release(); }
  assert.equal((await placing).status, 422);
});

test("client treats a 200 rejection as failure with JSON reason", async () => {
  let output;
  const code = await runClient(["health"], { fetch: async () => new Response(JSON.stringify({ status: "rejected", reason: "broker refused" }), { status: 200 }), write: (line) => { output = line; } });
  assert.equal(code, 1);
  assert.equal(JSON.parse(output).reason, "broker refused");
});

test("client rejects unknown flags, reserved identifiers, and path input before fetching", async () => {
  let calls = 0;
  for (const args of [
    ...["__proto__", "constructor", "prototype", "unknown", "url"].map((key) => ["health", `--${key}`, "http://127.0.0.1:9000"]),
    ...["__proto__", "constructor", "prototype", "../health", "short", "https://example.com"].map((id) => ["status", "--intent-id", id]),
    ["health", "--reason", "one", "--reason", "two"],
    ["health", "--reason"],
  ]) {
    const code = await runClient(args, { fetch: async () => { calls++; throw new Error("must not fetch"); }, write: () => {} });
    assert.notEqual(code, 0);
  }
  assert.equal(calls, 0);
});

test("client pins the origin and paths and permits only a validated environment override", async () => {
  const previous = process.env.PAPER_DESK_EXECUTOR_ORIGIN;
  const requests = [];
  const options = { fetch: async (url, init) => {
    requests.push({ url, init });
    return new Response('{"status":"ok"}', { status: 200 });
  }, write: () => {} };
  try {
    delete process.env.PAPER_DESK_EXECUTOR_ORIGIN;
    assert.equal(await runClient(["health"], options), 0);
    assert.equal(requests.at(-1).url, "http://100.64.0.6:8470/v1/health");
    process.env.PAPER_DESK_EXECUTOR_ORIGIN = "http://100.64.255.254:1234";
    assert.equal(await runClient(["status", "--intent-id", "safe-id:123"], options), 0);
    assert.equal(requests.at(-1).url, "http://100.64.255.254:1234/v1/intents?intentId=safe-id%3A123");
    assert.equal(requests.at(-1).init.redirect, "error");
    assert.equal(await runClient(["halt", "--reason", "stop"], options), 0);
    assert.equal(requests.at(-1).url, "http://100.64.255.254:1234/v1/halt");
    const count = requests.length;
    for (const origin of ["", "http://localhost:8470", "http://127.0.0.1:8470", "http://169.254.169.254:80", "https://100.64.0.6:8470", "http://100.65.0.6:8470", "http://100.64.256.1:8470", "http://100.64.1.256:8470", "http://100.64.00.6:8470", "http://100.64.0.6:0", "http://100.64.0.6:65536", "http://100.64.0.6:8470/", "http://100.64.0.6:8470@evil.test", "http://100.64.0.6:8470?x=1", "http://100.64.0.6:8470#fragment"]) {
      process.env.PAPER_DESK_EXECUTOR_ORIGIN = origin;
      assert.equal(await runClient(["health"], options), 2);
    }
    assert.equal(requests.length, count);
  } finally {
    if (previous === undefined) delete process.env.PAPER_DESK_EXECUTOR_ORIGIN;
    else process.env.PAPER_DESK_EXECUTOR_ORIGIN = previous;
  }
});

test("reserved intent keys are rejected before execution", async (t) => {
  t.mock.method(console, "error", () => {});
  const ctx = await start(t);
  for (const key of ["__proto__", "constructor", "prototype"]) {
    for (const body of [valid({ intentId: key }), valid({ desk: key }), valid({ order: { ...valid().order, symbol: key } }), valid({ orderRef: `j|261006|${key}` })]) {
      const response = await post(ctx.url, body);
      assert.equal(response.status, 400);
      assert.equal(response.body.code, "invalid_intent");
    }
  }
  assert.equal(ctx.calls(), 0);
});

test("internal errors are recorded in audit and journal while clients receive stable errors", async (t) => {
  const logged = [];
  t.mock.method(console, "error", (error) => logged.push(error));
  const error = new Error("private diagnostic /state/internal-file at internal:123");
  const ctx = await start(t, { execute: async () => { throw error; } });
  const intent = valid();
  const response = await post(ctx.url, intent);
  assert.equal(response.status, 422);
  assert.equal(response.body.code, "executor_error");
  assert.equal(response.body.reason, "executor operation failed");
  assert.equal(JSON.stringify(response.body).includes("private diagnostic"), false);
  assert.equal(logged.includes(error), true);
  const events = readFileSync(openLedger(ctx.stateDir).auditPath, "utf8").trim().split("\n").map((row) => JSON.parse(row));
  assert.equal(events.find((row) => row.event === "executor_error").error.stack, error.stack);
  const replay = await post(ctx.url, intent);
  assert.equal(replay.body.code, "executor_error");
  const broken = await start(t);
  const ledger = openLedger(broken.stateDir);
  // Force a persistence failure with invalid JSON, without depending on permissions.
  writeFileSync(ledger.statePath, "private invalid JSON");
  const health = await fetch(`${broken.url}/v1/health`);
  assert.equal(health.status, 500);
  assert.deepEqual(await health.json(), { status: "rejected", code: "executor_error", reason: "executor operation failed" });
});

test("CLI modify-stop produces the exact shape for either selector and rejects malformed options before fetch", async () => {
  const base = ["modify-stop", "--desk", "J", "--intent-id", "j-trail-cli", "--symbol", "aapl", "--stop", "100"];
  const seen = [];
  const options = { fetch: async (_url, request) => {
    const intent = parseIntent(JSON.parse(request.body)); seen.push(intent);
    return new Response(JSON.stringify({ status: "ok" }), { status: 200 });
  }, write: () => {} };
  for (const selector of [["--order-id", "21"], ["--order-ref", "J|261006|Trail"]]) assert.equal(await runClient([...base, ...selector], options), 0);
  assert.deepEqual(seen[0].order, { stopPrice: 100 }); assert.equal(seen[0].symbol, "AAPL"); assert.equal(seen[0].orderId, 21);
  assert.equal(seen[1].orderRef, "j|261006|Trail"); assert.equal(seen[1].orderId, undefined);
  const before = seen.length;
  for (const argv of [
    base, [...base, "--order-id", "21", "--order-ref", "j|261006|trail"],
    ...["1.5", "0", "-1", "NaN", "Infinity"].map((id) => [...base, "--order-id", id]),
    ...["0", "-1", "NaN", "Infinity"].map((price) => [...base.slice(0, -1), price, "--order-id", "21"]),
    [...base, "--order-id", "21", "--quantity", "3"], [...base, "--order-id", "21", "--side", "SELL"],
    [...base, "--order-id", "21", "--currency", "USD"], [...base, "--order-id", "21", "--limit", "99"],
    [...base, "--order-ref", "joe|261006|trail"],
    ["modify-stop", "--desk", "j", "--intent-id", "j-trail-cli", "--stop", "100", "--order-id", "21"],
  ]) assert.notEqual(await runClient(argv, options), 0);
  assert.equal(seen.length, before);
});
