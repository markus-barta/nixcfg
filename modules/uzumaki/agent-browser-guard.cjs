// NIX-445 — accidental native-browser launch prevention for Node (CommonJS preload)
//
// WHAT THIS IS
//   A CommonJS module loaded via `NODE_OPTIONS=--require <this file>` into agent
//   CLI processes whose own sandbox cannot be wrapped (Cursor, and as
//   defence-in-depth elsewhere). It intercepts the four child-process APIs
//   Playwright and friends use to start a browser, and refuses before the
//   browser process is created.
//
// WHAT THIS IS NOT
//   NOT an OS security boundary. It is process-local, cooperative and trivially
//   avoidable: a direct shell/Python/Go/XPC launch, a scrubbed or overridden
//   NODE_OPTIONS, a re-required pristine child_process from a bundler cache, or
//   `exec`/`execSync` with a shell string that does not contain a denied path
//   all escape it. The Seatbelt guard (`inspr-agent-guard`) and the Codex native
//   permission profile are the actual boundaries; this closes the accidental
//   Node/Playwright path where neither can apply.
//
// PRIVACY
//   The refusal carries a fixed code and a fixed sentence. argv, URLs, headers
//   and environment are never read into the message, logged or re-thrown.
'use strict';

const child_process = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const util = require('node:util');

// Substituted at build time by lib/agent-browser-guard.nix. The placeholders sit
// inside string literals so this file stays valid JavaScript in the repo and can
// be linted, formatted and syntax-checked without a Nix build.
const DENY_PATHS = JSON.parse('@INSPR_DENY_PATHS@');
const DENY_BASENAMES = new Set(JSON.parse('@INSPR_DENY_BASENAMES@'));

const REFUSAL_CODE = 'INSPR_BROWSER_GUARD_REFUSED';
const REFUSAL_MESSAGE =
  'INSPR agent browser guard (NIX-445): native browser launch refused. ' +
  'Ask the controller for a verified browser-QA runner; a blocked launch is not a passed test. ' +
  'This is accidental-launch prevention inside Node, not an OS security boundary.';

// Bound the work done on every single spawn in the process.
const MAX_PATH_ENTRIES = 64;

const denied = DENY_PATHS.map((entry) =>
  entry.length > 1 && entry.endsWith(path.sep) ? entry.slice(0, -1) : entry,
);

function isDenied(resolved) {
  for (const entry of denied) {
    if (resolved === entry || resolved.startsWith(entry + path.sep)) return true;
  }
  return false;
}

function realpathSafe(candidate) {
  try {
    return fs.realpathSync(candidate);
  } catch {
    // Unresolvable (missing, permission, or a shell string): fall back to the
    // literal so a `.app` bundle prefix is still recognised.
    return candidate;
  }
}

// Returns a resolved path worth checking, or null when the call is clearly not
// a browser launch. Bare command names are only looked up when their basename
// is a known browser one, so ordinary spawns stay cheap.
function resolveTarget(file) {
  if (typeof file !== 'string' || file.length === 0) return null;
  if (file.includes(path.sep)) return realpathSafe(path.resolve(file));
  if (!DENY_BASENAMES.has(file)) return null;
  const entries = String(process.env.PATH || '')
    .split(path.delimiter)
    .slice(0, MAX_PATH_ENTRIES);
  for (const dir of entries) {
    if (!dir) continue;
    const candidate = path.join(dir, file);
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
    } catch {
      continue;
    }
    return realpathSafe(candidate);
  }
  return null;
}

function refusal() {
  const error = new Error(REFUSAL_MESSAGE);
  error.code = REFUSAL_CODE;
  return error;
}

function assertAllowed(file) {
  const resolved = resolveTarget(file);
  if (resolved !== null && isDenied(resolved)) throw refusal();
}

// Wrap in place. Arguments, options and callbacks of every non-browser call are
// forwarded untouched, so behaviour outside the deny list is unchanged.
for (const name of ['spawn', 'spawnSync', 'execFile', 'execFileSync']) {
  const original = child_process[name];
  if (typeof original !== 'function') continue;

  const guarded = function (file, ...rest) {
    assertAllowed(file);
    return original.call(this, file, ...rest);
  };
  Object.defineProperty(guarded, 'name', { value: name });
  Object.defineProperty(guarded, 'length', { value: original.length });

  // `util.promisify(execFile)` prefers this symbol. Copying the original as-is
  // would leave a bypass, so the promisified form is checked first and only
  // then delegates to the vendor implementation.
  const custom = original[util.promisify.custom];
  if (typeof custom === 'function') {
    guarded[util.promisify.custom] = function (file, ...rest) {
      assertAllowed(file);
      return custom.call(this, file, ...rest);
    };
  }

  child_process[name] = guarded;
}

module.exports = { REFUSAL_CODE };
