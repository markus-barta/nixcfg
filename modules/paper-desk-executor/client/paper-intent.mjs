#!/usr/bin/env node
// Dependency-free desk client for the hsb0 paper desk executor.
const SCHEMA = "barta.paper-desk-intent.v2";
const DEFAULT_URL = "http://100.64.0.6:8470";

function usage() {
  return [
    "usage: paper-intent <recon|place|flatten|status|health|halt> [options]",
    "  --url http://100.64.0.6:8470",
    "  --desk NAME --intent-id ID",
    "  --symbol SYM --side BUY|SELL --quantity N --limit N --stop N",
    "  --reason TEXT",
  ].join("\n");
}

function fail(message) {
  console.error(JSON.stringify({ status: "rejected", reason: message }));
  process.exit(2);
}

function args(argv) {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--") || token.length < 3) fail(`unexpected argument ${token}`);
    const key = token.slice(2);
    const value = argv[index + 1];
    if (value === undefined || value.startsWith("--")) fail(`missing value for --${key}`);
    if (Object.hasOwn(parsed, key)) fail(`duplicate option --${key}`);
    parsed[key] = value;
    index += 1;
  }
  return parsed;
}

function required(parsed, key) {
  const value = parsed[key];
  if (typeof value !== "string" || !value.trim()) fail(`--${key} is required`);
  return value.trim();
}

function positiveNumber(parsed, key) {
  const value = Number(required(parsed, key));
  if (!Number.isFinite(value) || value <= 0) fail(`--${key} must be a positive number`);
  return value;
}

function intentEnvelope(parsed, action) {
  const now = Date.now();
  const intent = {
    schema: SCHEMA,
    intentId: required(parsed, "intent-id"),
    desk: required(parsed, "desk").toLowerCase(),
    action,
    createdAt: new Date(now - 1000).toISOString(),
    expiresAt: new Date(now + 5 * 60_000).toISOString(),
  };
  if (action === "place") {
    const quantity = Number(required(parsed, "quantity"));
    if (!Number.isSafeInteger(quantity) || quantity <= 0) fail("--quantity must be a positive integer");
    const side = required(parsed, "side").toUpperCase();
    intent.order = {
      symbol: required(parsed, "symbol").toUpperCase(),
      side,
      quantity,
      limitPrice: positiveNumber(parsed, "limit"),
      stopPrice: positiveNumber(parsed, "stop"),
      currency: (parsed.currency || "USD").toUpperCase(),
    };
  }
  return intent;
}

async function request(url, method, body) {
  let response;
  try {
    response = await fetch(url, {
      method,
      headers: { accept: "application/json", "content-type": "application/json" },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      signal: AbortSignal.timeout(180_000),
    });
  } catch (error) {
    console.log(JSON.stringify({ status: "rejected", reason: String(error?.message || error).slice(0, 500) }));
    process.exit(1);
  }
  const text = await response.text();
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    parsed = { status: "rejected", reason: text.slice(0, 500) };
  }
  console.log(JSON.stringify(parsed));
  process.exit(response.ok ? 0 : 1);
}

const [command, ...rest] = process.argv.slice(2);
if (!command || command === "--help" || command === "-h") fail(usage());
const parsed = args(rest);
const root = (parsed.url || DEFAULT_URL).replace(/\/$/, "");
if (!/^http:\/\/[A-Za-z0-9.-]+(?::\d+)?$/.test(root)) fail("--url must be an http origin");

if (command === "health") {
  await request(`${root}/v1/health`, "GET");
} else if (command === "halt") {
  await request(`${root}/v1/halt`, "POST", parsed.reason ? { reason: parsed.reason } : {});
} else if (command === "status") {
  await request(`${root}/v1/intents/${encodeURIComponent(required(parsed, "intent-id"))}`, "GET");
} else if (command === "recon" || command === "flatten" || command === "place") {
  await request(`${root}/v1/intents`, "POST", intentEnvelope(parsed, command));
} else {
  fail(usage());
}
