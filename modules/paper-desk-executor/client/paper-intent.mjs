#!/usr/bin/env node
// Dependency-free desk client for the hsb0 paper desk executor.
import path from "node:path";
import { pathToFileURL } from "node:url";
import { validateKey } from "../policy.mjs";
const SCHEMA = "barta.paper-desk-intent.v2";
const DEFAULT_URL = "http://100.64.0.6:8470";
const FLAGS = new Set(["desk", "intent-id", "symbol", "side", "quantity", "limit", "stop", "currency", "order-ref", "order-id", "reason"]);

function executorOrigin() {
  const configured = process.env.PAPER_DESK_EXECUTOR_ORIGIN ?? DEFAULT_URL;
  const match = /^http:\/\/100\.64\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2}):([1-9][0-9]{0,4})$/.exec(configured);
  if (!match || Number(match[1]) > 255 || Number(match[2]) > 255 || Number(match[3]) > 65535) fail("PAPER_DESK_EXECUTOR_ORIGIN must be an http://100.64.x.y:port origin");
  return configured;
}

function usage() {
  return [
    "usage: paper-intent <recon|place|flatten|cancel|status|health|halt> [options]",
    "  origin: http://100.64.0.6:8470 (PAPER_DESK_EXECUTOR_ORIGIN may select http://100.64.x.y:port)",
    "  --desk NAME --intent-id ID",
    "  --symbol SYM --side BUY|SELL --quantity N --limit N --stop N",
    "  --order-ref desk|yymmdd|thesis-id (place/cancel) --order-id N (cancel)",
    "  --reason TEXT",
  ].join("\n");
}

function fail(message) { const error = new Error(message); error.exitCode = 2; throw error; }
function args(argv) {
  const parsed = Object.create(null);
  for (let index = 0; index < argv.length; index += 2) {
    const token = argv[index];
    if (!token.startsWith("--") || token.length < 3) fail(`unexpected argument ${token}`);
    const key = token.slice(2);
    if (!FLAGS.has(key)) fail(`unsupported option --${key}`);
    const value = argv[index + 1];
    if (value === undefined || value.startsWith("--")) fail(`missing value for --${key}`);
    if (Object.hasOwn(parsed, key)) fail(`duplicate option --${key}`);
    parsed[key] = value;
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
  const intent = { schema: SCHEMA, intentId: validateKey(required(parsed, "intent-id"), "intentId"), desk: validateKey(required(parsed, "desk").toLowerCase(), "desk"), action, createdAt: new Date(now - 1000).toISOString(), expiresAt: new Date(now + 300000).toISOString() };
  if (action === "place") {
    const quantity = Number(required(parsed, "quantity"));
    if (!Number.isSafeInteger(quantity) || quantity <= 0) fail("--quantity must be a positive integer");
    intent.order = { symbol: validateKey(required(parsed, "symbol").toUpperCase(), "symbol"), side: required(parsed, "side").toUpperCase(), quantity, limitPrice: positiveNumber(parsed, "limit"), stopPrice: positiveNumber(parsed, "stop"), currency: (parsed.currency || "USD").toUpperCase() };
  }
  if (parsed["order-ref"]) intent.orderRef = validateKey(parsed["order-ref"], "orderRef");
  if (parsed["order-id"]) intent.orderId = positiveNumber(parsed, "order-id");
  return intent;
}

export async function runClient(argv, { fetch: fetchImpl = globalThis.fetch, write = (line) => console.log(line) } = {}) {
  try {
    const [command, ...rest] = argv;
    if (!command || command === "--help" || command === "-h") fail(usage());
    const parsed = args(rest);
    const root = executorOrigin();
    let route; let method = "GET"; let body; let intentId;
    if (command === "health") route = "/v1/health";
    else if (command === "halt") { route = "/v1/halt"; method = "POST"; body = parsed.reason ? { reason: parsed.reason } : {}; }
    else if (command === "status") { route = "/v1/intents"; intentId = validateKey(required(parsed, "intent-id"), "intentId"); }
    else if (["recon", "flatten", "place", "cancel"].includes(command)) { route = "/v1/intents"; method = "POST"; body = intentEnvelope(parsed, command); }
    else fail(usage());
    const target = new URL(route, root);
    if (intentId) target.searchParams.set("intentId", intentId);
    const response = await fetchImpl(target.href, { method, redirect: "error", headers: { accept: "application/json", "content-type": "application/json" }, ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(180000) });
    const text = await response.text();
    let result;
    try { result = JSON.parse(text); } catch { result = { status: "rejected", reason: text.slice(0, 500) }; }
    write(JSON.stringify(result));
    return response.ok && ["ok", "halted"].includes(result.status) ? 0 : 1;
  } catch (error) {
    write(JSON.stringify({ status: "rejected", reason: String(error?.message || error).slice(0, 500) }));
    return error.exitCode || 1;
  }
}
const entry = process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;
if (entry) process.exitCode = await runClient(process.argv.slice(2));
