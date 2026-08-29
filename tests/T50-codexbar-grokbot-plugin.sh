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

// --- snapshot schema validator ------------------------------------------
// Mirrors CodexBar's own "Invalid provider plugin snapshot: ..." rules, taken
// verbatim from the app binary's validation strings. A plugin can fetch the
// right number and still be rejected wholesale for a malformed container —
// which is exactly what shipped once: `details` was built as a flat array of
// {label,value} rows instead of an array of {title,rows} SECTIONS, and the
// provider showed "details[0].rows must be an array" instead of the usage.
function validateSnapshot(s) {
  const errs = [];
  if (!s || typeof s !== "object" || Array.isArray(s)) {
    return ["fetchUsage must resolve to an object"];
  }
  const isObj = (v) => v && typeof v === "object" && !Array.isArray(v);

  for (const key of ["primary", "secondary", "tertiary"]) {
    if (s[key] === undefined) continue;
    if (!isObj(s[key])) { errs.push(`${key} must be an object`); continue; }
    const p = s[key];
    if (typeof p.usedPercent !== "number" || !Number.isFinite(p.usedPercent)) {
      errs.push(`${key}.usedPercent must be a finite number`);
    }
    if (p.windowMinutes !== undefined && typeof p.windowMinutes !== "number") {
      errs.push(`${key}.windowMinutes must be a number`);
    }
    if (p.resetsAt !== undefined && !(p.resetsAt instanceof Date)) {
      errs.push(`${key}.resetsAt must be a Date`);
    }
    if (p.resetDescription !== undefined && typeof p.resetDescription !== "string") {
      errs.push(`${key}.resetDescription must be a string`);
    }
  }

  if (s.identity !== undefined && !isObj(s.identity)) errs.push("identity must be an object");
  if (s.cost !== undefined && !isObj(s.cost)) errs.push("cost must be an object");
  if (s.costUsage !== undefined) {
    if (!isObj(s.costUsage)) errs.push("costUsage must be an object");
    else if (s.costUsage.entries !== undefined && !Array.isArray(s.costUsage.entries)) {
      errs.push("costUsage.entries must be an array");
    }
  }
  if (s.extraWindows !== undefined && !Array.isArray(s.extraWindows)) {
    errs.push("extraWindows must be an array");
  }

  if (s.details !== undefined) {
    if (!Array.isArray(s.details)) {
      errs.push("details must be an array");
    } else {
      s.details.forEach((section, i) => {
        if (!isObj(section)) { errs.push(`details[${i}] must be an object`); return; }
        if (!Array.isArray(section.rows)) { errs.push(`details[${i}].rows must be an array`); return; }
        section.rows.forEach((row, j) => {
          if (!isObj(row)) { errs.push(`details[${i}].rows[${j}] must be an object`); return; }
          if (typeof row.label !== "string") errs.push(`details[${i}].rows[${j}].label must be a string`);
          if (typeof row.value !== "string") errs.push(`details[${i}].rows[${j}].value must be a string`);
        });
        if (section.chart !== undefined) {
          if (!isObj(section.chart)) errs.push(`details[${i}].chart must be an object`);
          else if (!Array.isArray(section.chart.points)) errs.push(`details[${i}].chart.points must be an array`);
        }
      });
    }
  }

  const hasWindow = ["primary", "secondary", "tertiary"].some((k) => s[k] !== undefined);
  const hasDetailSection = Array.isArray(s.details) && s.details.length > 0;
  if (!hasWindow && !s.cost && !hasDetailSection && !s.identity) {
    errs.push("snapshot must contain at least one rate window, cost, detail section, or identity field");
  }
  return errs;
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
  { name: "details section populated",       cookie: GOOD_COOKIE, http: ok({ ...OK_BODY, hasAvailableUsage: false }),            expect: "ok" },
  { name: "no detail rows at all",           cookie: GOOD_COOKIE, http: ok({ usagePercent: 5 }),                                 expect: "ok" },
];

new Function(readFileSync(PLUGIN, "utf8"))();
if (!provider) { console.error("plugin did not call defineProvider"); process.exit(1); }

let pass = 0, fail_ = 0;
for (const c of CASES) {
  const ctx = makeCtx({ cookie: c.cookie ?? "", secret: c.secret ?? "", http: c.http });
  let got, detail = "";
  try {
    const r = await provider.fetchUsage(ctx);
    const schemaErrs = validateSnapshot(r);
    if (schemaErrs.length > 0) {
      got = "SCHEMA-INVALID";
      detail = schemaErrs.join("; ").slice(0, 88);
    } else {
      got = "ok";
      detail = `usedPercent=${r.primary.usedPercent} resetsAt=${r.primary.resetsAt ? r.primary.resetsAt.toISOString() : "—"} plan="${r.identity.loginMethod}" details=${r.details ? r.details.length + " section(s)" : "none"}`;
    }
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
