#!/usr/bin/env bash
# NIX-445 — Node child-process preload: accidental browser-launch prevention.
#
# Deterministic, fake executables only. No browser, Chromium or Playwright is
# invoked; the "browser" is a shell script in a temp dir that writes a marker
# file, so a leak is provable rather than assumed.
#
# Scope asserted here is exactly what the preload claims: the four child-process
# APIs plus the promisified execFile, in this process and in Node children that
# inherit NODE_OPTIONS. It is not an OS boundary and this test does not pretend
# otherwise.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

fail() {
  printf 'T73 failed: %s\n' "$*" >&2
  exit 1
}

node=$(command -v node || true)
[ -x "$node" ] || fail 'node not found'

work=$(mktemp -d "${TMPDIR:-/tmp}/nix445-t73.XXXXXX")
work=$(cd "$work" && pwd -P) # Seatbelt/realpath parity: /tmp is a symlink
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/FakeBrowser.app/Contents/MacOS" "$work/allowed"
fake="$work/FakeBrowser.app/Contents/MacOS/FakeBrowser"
printf '#!/bin/sh\ntouch "%s.marker"\necho FAKE_BROWSER_LAUNCHED\n' "$fake" >"$fake"
chmod +x "$fake"
ln -s "$fake" "$work/fake-symlink"

allowed="$work/allowed/ordinary"
printf '#!/bin/sh\ntouch "%s.marker"\necho ORDINARY_RAN\n' "$allowed" >"$allowed"
chmod +x "$allowed"

preload="$work/preload.cjs"
nix eval --impure --raw --expr "
  let
    flake = builtins.getFlake (toString ./.);
    lib = flake.inputs.nixpkgs.lib;
    guard = import ./lib/agent-browser-guard.nix { inherit lib; };
  in
  guard.mkPreloadText { denyPaths = [ ''$work/FakeBrowser.app'' ]; }
" >"$preload"
node --check "$preload" || fail 'rendered preload is not valid JavaScript'

cat >"$work/probe.mjs" <<'JS'
import cp from "node:child_process";
import util from "node:util";

const denied = process.argv[2];
const symlinked = process.argv[3];
const allowed = process.argv[4];
const results = {};

// A URL-shaped argument: it must never appear in a refusal message.
const secretish = ["--headless", "https://private.example/secret?token=abc"];

const record = async (name, fn) => {
  try {
    const value = await fn();
    results[name] = { blocked: false, value: String(value ?? "").trim() };
  } catch (error) {
    results[name] = {
      blocked: true,
      code: error.code,
      leaked: String(error.message).includes("token=abc") || String(error.message).includes(denied),
    };
  }
};

await record("spawn", () => {
  const child = cp.spawn(denied, secretish);
  return `pid:${child.pid}`;
});
await record("spawnSync", () => {
  const r = cp.spawnSync(denied, secretish, { encoding: "utf8" });
  return r.stdout;
});
await record("execFile", () => new Promise((resolve, reject) => {
  cp.execFile(denied, secretish, (err, stdout) => (err ? reject(err) : resolve(stdout)));
}));
await record("execFileSync", () => cp.execFileSync(denied, secretish, { encoding: "utf8" }));
await record("execFilePromisified", () => util.promisify(cp.execFile)(denied, secretish).then((r) => r.stdout));
await record("symlink", () => cp.spawnSync(symlinked, [], { encoding: "utf8" }).stdout);

// Controls: an ordinary executable and a system binary must be untouched, with
// arguments, options and callbacks preserved.
await record("allowedSpawnSync", () => cp.spawnSync(allowed, ["x"], { encoding: "utf8" }).stdout);
await record("allowedTrue", () => String(cp.spawnSync("/usr/bin/true").status));
await record("allowedCallback", () => new Promise((resolve, reject) => {
  cp.execFile("/bin/echo", ["CALLBACK_OK"], (err, stdout) => (err ? reject(err) : resolve(stdout)));
}));

// Playwright shape: a Node grandchild that inherits NODE_OPTIONS and spawns the
// browser itself.
await record("nodeGrandchild", () => {
  const r = cp.spawnSync(process.execPath, ["-e", `require("child_process").spawnSync(${JSON.stringify(denied)})`], {
    encoding: "utf8",
  });
  return `${r.status}:${(r.stderr || "").includes("INSPR_BROWSER_GUARD_REFUSED") ? "refused" : "unrefused"}`;
});

console.log(JSON.stringify(results));
JS

out=$(NODE_OPTIONS="--require $preload" "$node" "$work/probe.mjs" "$fake" "$work/fake-symlink" "$allowed")

python3 - "$out" <<'PY' || exit 1
import json, sys
r = json.loads(sys.argv[1])
blocked = ["spawn", "spawnSync", "execFile", "execFileSync", "execFilePromisified", "symlink"]
for name in blocked:
    entry = r.get(name, {})
    if not entry.get("blocked"):
        print(f"T73 failed: {name} was not blocked: {entry}", file=sys.stderr); sys.exit(1)
    if entry.get("code") != "INSPR_BROWSER_GUARD_REFUSED":
        print(f"T73 failed: {name} refusal code is {entry.get('code')!r}", file=sys.stderr); sys.exit(1)
    if entry.get("leaked"):
        print(f"T73 failed: {name} refusal leaked argv or a URL", file=sys.stderr); sys.exit(1)
for name, expected in (("allowedSpawnSync", "ORDINARY_RAN"), ("allowedTrue", "0"), ("allowedCallback", "CALLBACK_OK")):
    entry = r.get(name, {})
    if entry.get("blocked") or entry.get("value") != expected:
        print(f"T73 failed: control {name} broke: {entry}", file=sys.stderr); sys.exit(1)
grandchild = r.get("nodeGrandchild", {})
if grandchild.get("blocked") or not grandchild.get("value", "").endswith(":refused"):
    print(f"T73 failed: Playwright-shaped Node grandchild was not refused: {grandchild}", file=sys.stderr); sys.exit(1)
PY

[ -e "$fake.marker" ] && fail 'the fake browser actually executed'
[ -e "$allowed.marker" ] || fail 'the allowed control never ran — the test proves nothing'

# The NODE_OPTIONS snippet must add the preload once and keep what was there.
snippet=$(nix eval --impure --raw --expr "
  let
    flake = builtins.getFlake (toString ./.);
    lib = flake.inputs.nixpkgs.lib;
    guard = import ./lib/agent-browser-guard.nix { inherit lib; };
  in
  guard.mkPreloadEnvExports ''$preload''
")
merged=$(NODE_OPTIONS="--max-old-space-size=2048" /bin/sh -c "$snippet"'; printf "%s" "$NODE_OPTIONS"')
case "$merged" in
"--max-old-space-size=2048 --require $preload") ;;
*) fail "existing NODE_OPTIONS not preserved: $merged" ;;
esac
twice=$(NODE_OPTIONS="--require $preload" /bin/sh -c "$snippet"'; printf "%s" "$NODE_OPTIONS"')
[ "$twice" = "--require $preload" ] || fail "preload added twice: $twice"

# Wiring: Cursor is env-only everywhere, never Seatbelt-wrapped.
grep -Fq 'envOnlyPrograms = {' hosts/mbp2607/home.nix ||
  fail 'mbp2607 must wire the Cursor names as env-only launchers'
for name in cursor-agent agent; do
  grep -Eq "^ *$name = " hosts/mbp2607/home.nix ||
    fail "mbp2607 must wire the real $name entry point"
done
grep -Fq 'envOnlyCliPath "cursor"' modules/uzumaki/paimos-agentd.nix ||
  fail 'the agentd Cursor path must use the env-only launcher'

printf 'agent_browser_guard_preload=passed apis=6 controls=3 fake_browser_launches=0\n'
