#!/usr/bin/env bash
# OPS: the CodexBar Grok Bot plugin must never render "unknown" as a number.
#
# The plugin exists because a previous tool showed "no data available" in a way
# that was indistinguishable from real information. The single property that
# matters is therefore: an ABSENT `usagePercent` and a GENUINE `usagePercent: 0`
# must produce different outcomes. A `.get(field, 0)`-shaped regression would
# silently report a healthy 0% while the account is actually at 100%.
#
# CodexBar's plugin runtime is QuickJS inside the app, so this stubs the parts of
# the runtime contract the plugin touches (defineProvider, ctx.browser,
# ctx.settings, ctx.http, ctx.date, ctx.fail) and drives every branch offline.
# No network, no credentials, no CodexBar required.
#
# Contract reference: /Applications/CodexBar.app/.../provider-plugin-prelude.js
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plugin="${repo}/hosts/mbp2607/files/codexbar-grokbot.js"

if [[ ! -f "$plugin" ]]; then
  echo "❌ plugin not found: $plugin"
  exit 1
fi

if command -v node >/dev/null 2>&1; then
  node_cmd=(node)
elif command -v nix >/dev/null 2>&1; then
  node_cmd=(nix run --quiet nixpkgs#nodejs-slim --)
else
  echo "❌ no JavaScript runtime available (need node, or nix to fetch one)"
  exit 1
fi

harness="$(mktemp -t codexbar-grokbot-XXXXXX).mjs"
trap 'rm -f "$harness"' EXIT
cat >"$harness" <<'HARNESS'
// Failure-mode harness for the CodexBar Grok Bot plugin.
// Stubs CodexBar's plugin runtime (defineProvider + ctx) so every row of the
// failure-mode table can be triggered deliberately, offline, in one run.
import { readFileSync } from "node:fs";

const PLUGIN = process.argv[2];
const SESSION = "WorkosCursorSessionToken";
const GOOD_COOKIE = `${SESSION}=stub-value-not-a-real-token; other=1`;

let provider;
globalThis.defineProvider = (p) => { provider = p; };

// --- ctx, mirroring provider-plugin-prelude.js semantics -------------------
const MARK = "__CODEXBAR_FAILURE_V2__";
const kinds = ["authenticationExpired","missingCredential","permissionDenied","rateLimited",
               "providerUnavailable","parseFailure","networkFailure","apiFailure"];
const slug = {authenticationExpired:"authentication-expired",missingCredential:"missing-credential",
  permissionDenied:"permission-denied",rateLimited:"rate-limited",providerUnavailable:"provider-unavailable",
  parseFailure:"parse-failure",networkFailure:"network-failure",apiFailure:"api-failure"};
const fail = Object.fromEntries(kinds.map(k => [k, (msg, opts) => {
  const retry = opts ? String(Number(opts.retryAfterSeconds)) : "";
  return new Error(`${MARK}:${slug[k]}:${retry}:${msg}`);
}]));

function makeCtx({ cookie, secret, http }) {
  return {
    fail,
    browser: { cookieHeader: async () => { if (cookie instanceof Error) throw cookie; return cookie; } },
    settings: { getSecret: async () => { if (secret instanceof Error) throw secret; return secret; },
                get: async () => undefined },
    http: { postJSON: async (url, opts) => http(url, opts), getJSON: async () => { throw new Error("unused"); } },
    date: { iso: (v) => { const d = new Date(v); if (!Number.isFinite(d.getTime())) throw new TypeError("invalid date"); return d; },
            now: () => new Date(), nowMillis: () => Date.now() },
    format: { monthDay: (d) => `${["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][d.getMonth()]} ${d.getDate()}` },
    pct: (u, l) => (l > 0 ? (u / l) * 100 : 0),
    log: () => {},
    cache: { get: () => undefined, set: () => {} },
  };
}

const OK_BODY = {
  currentPeriodStart: "2026-08-26T17:22:03.913Z",
  nextResetTimestampUtc: "2026-09-01T19:28:16.957Z",
  usagePercent: 78.814712,
  hasAvailableUsage: true,
  hasNonZeroIncludedLimit: true,
  grokPlanLabel: "Grok Bot Plan",
};
const ok = (json) => async () => ({ status: 200, json });
const code = (status) => async () => ({ status, json: {} });

const CASES = [
  { name: "happy path",                      cookie: GOOD_COOKIE, http: ok(OK_BODY),                       expect: "ok" },
  { name: "no cookies at all",               cookie: "",          secret: "",           http: ok(OK_BODY), expect: "missing-credential" },
  { name: "cookie jar throws, no fallback",  cookie: new Error("keychain denied"), secret: "", http: ok(OK_BODY), expect: "missing-credential" },
  { name: "cookie jar throws, secret saves", cookie: new Error("keychain denied"), secret: GOOD_COOKIE, http: ok(OK_BODY), expect: "ok" },
  { name: "cookie present, session absent",  cookie: "other=1",   secret: "",           http: ok(OK_BODY), expect: "missing-credential" },
  { name: "HTTP 401",                        cookie: GOOD_COOKIE, http: code(401),                         expect: "authentication-expired" },
  { name: "HTTP 403",                        cookie: GOOD_COOKIE, http: code(403),                         expect: "authentication-expired" },
  { name: "HTTP 429",                        cookie: GOOD_COOKIE, http: code(429),                         expect: "rate-limited" },
  { name: "HTTP 503",                        cookie: GOOD_COOKIE, http: code(503),                         expect: "provider-unavailable" },
  { name: "HTTP 418",                        cookie: GOOD_COOKIE, http: code(418),                         expect: "api-failure" },
  { name: "network error / timeout",         cookie: GOOD_COOKIE, http: async () => { throw new Error("timed out"); }, expect: "network-failure" },
  { name: "body is not an object",           cookie: GOOD_COOKIE, http: ok("nope"),                        expect: "parse-failure" },
  { name: "body is an array",                cookie: GOOD_COOKIE, http: ok([1, 2]),                        expect: "parse-failure" },
  { name: "usagePercent KEY ABSENT",         cookie: GOOD_COOKIE, http: ok({ nextResetTimestampUtc: OK_BODY.nextResetTimestampUtc }), expect: "parse-failure" },
  { name: "usagePercent null",               cookie: GOOD_COOKIE, http: ok({ ...OK_BODY, usagePercent: null }),   expect: "parse-failure" },
  { name: "usagePercent non-numeric",        cookie: GOOD_COOKIE, http: ok({ ...OK_BODY, usagePercent: "lots" }),  expect: "parse-failure" },
  { name: "usagePercent GENUINELY ZERO",     cookie: GOOD_COOKIE, http: ok({ ...OK_BODY, usagePercent: 0 }),       expect: "ok" },
  { name: "reset timestamp missing",         cookie: GOOD_COOKIE, http: ok({ usagePercent: 42 }),                  expect: "ok" },
  { name: "reset timestamp malformed",       cookie: GOOD_COOKIE, http: ok({ ...OK_BODY, nextResetTimestampUtc: "not-a-date" }), expect: "ok" },
];

new Function(readFileSync(PLUGIN, "utf8"))();
if (!provider) { console.error("plugin did not call defineProvider"); process.exit(1); }

let pass = 0, fail_ = 0;
for (const c of CASES) {
  const ctx = makeCtx({ cookie: c.cookie ?? "", secret: c.secret ?? "", http: c.http });
  let got, detail = "";
  try {
    const r = await provider.fetchUsage(ctx);
    got = "ok";
    detail = `usedPercent=${r.primary.usedPercent} resetsAt=${r.primary.resetsAt ? r.primary.resetsAt.toISOString() : "—"} plan="${r.identity.loginMethod}"`;
  } catch (e) {
    const m = String(e.message);
    got = m.startsWith(MARK) ? m.split(":")[1] : `UNCLASSIFIED(${m.slice(0, 40)})`;
    detail = m.startsWith(MARK) ? m.split(":").slice(3).join(":").slice(0, 88) : m.slice(0, 88);
  }
  const good = got === c.expect;
  good ? pass++ : fail_++;
  console.log(`${good ? "PASS" : "FAIL"}  ${c.name.padEnd(30)} -> ${got.padEnd(22)} ${detail}`);
  if (!good) console.log(`      expected: ${c.expect}`);
}
console.log(`\n${pass} passed, ${fail_} failed`);
process.exit(fail_ ? 1 : 0);
HARNESS

"${node_cmd[@]}" "$harness" "$plugin"
