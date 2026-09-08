#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal ${...}/$0 in single quotes is intentional:
# these are grep patterns for Nix interpolations and the text of generated scripts.
# NIX-445 — macOS agent browser-launch guard.
#
# Proves the mechanism with HARMLESS FAKE executables only. No browser, no
# Chromium, no Playwright is ever invoked by this test, and nothing outside the
# temporary directory is touched.
#
# What it asserts:
#   1. pure eval — profile/launcher/refusal text and their input validation
#   2. wiring   — hosts and paimos-agentd consume the guard as designed
#   3. no drift — the human (NIX-288) browser path stays exactly as it was
#   4. runtime  — a fake "browser" is denied directly, through a symlink and as
#                 a Node grandchild, while ordinary commands still run; and the
#                 documented macOS nesting limit still holds
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

fail() {
  printf 'T72 failed: %s\n' "$*" >&2
  exit 1
}

contains() {
  case "$1" in
  *"$2"*) ;;
  *) fail "$3" ;;
  esac
}

guard_eval() {
  nix eval --impure --raw --expr "
    let
      flake = builtins.getFlake (toString ./.);
      lib = flake.inputs.nixpkgs.lib;
      guard = import ./lib/agent-browser-guard.nix { inherit lib; };
    in
    $1
  "
}

# ── 1. Pure evaluation ───────────────────────────────────────────────────────
profile=$(guard_eval 'guard.mkProfileText { }')
contains "$profile" '(allow default)' 'profile must keep the session otherwise unrestricted'
contains "$profile" '(deny process-exec* (subpath "/Applications/Google Chrome.app"))' \
  'profile must deny exec of the NIX-288 Chrome bundle'
contains "$profile" '(deny process-exec* (subpath "/System/Cryptexes/App/System/Applications/Safari.app"))' \
  'profile must deny the RESOLVED Safari path — /Applications/Safari.app is a symlink Seatbelt never matches'
contains "$profile" '(deny lsopen)' 'profile must deny LaunchServices launches by default'

no_lsopen=$(guard_eval 'guard.mkProfileText { denyLaunchServices = false; }')
case "$no_lsopen" in
*'(deny lsopen)'*) fail 'denyLaunchServices = false must drop the lsopen rule' ;;
esac

# Profile injection and unresolvable paths must not be representable.
for bad in 'relative/path' '/tmp/quote"break' '/tmp/dollar$sub'; do
  if guard_eval "guard.mkProfileText { browserBundles = [ ''$bad'' ]; }" >/dev/null 2>&1; then
    fail "unsafe browser bundle path accepted: $bad"
  fi
done

guard_text=$(guard_eval 'guard.mkGuardText { profilePath = "/nix/store/fake.sb"; refusalPath = "/nix/store/fake-refuse"; }')
contains "$guard_text" 'exec /usr/bin/sandbox-exec -f /nix/store/fake.sb' \
  'guard must exec the CLI under the Seatbelt profile'
contains "$guard_text" 'exit 69' 'guard must fail closed when sandbox-exec is missing'
contains "$guard_text" 'PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=' \
  'guard must redirect the harness browser variable to the refusal shim'

env_only=$(guard_eval 'guard.mkEnvOnlyExports "/nix/store/fake-refuse"')
contains "$env_only" 'export PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/nix/store/fake-refuse' \
  'env-only layer must point Playwright at the refusal shim'
contains "$env_only" 'export INSPR_AGENT_BROWSER_GUARD=env-only' \
  'env-only layer must announce itself as env-only, not as a boundary'
case "$env_only" in
*sandbox-exec*) fail 'env-only layer must not apply a Seatbelt profile' ;;
esac

refusal_text=$(guard_eval 'guard.mkRefusalText { }')
case "$refusal_text" in
*'$*'* | *'$0'*) fail 'refusal must not echo argv — URLs and headers can be private' ;;
esac

codex_profile=$(guard_eval 'guard.mkCodexPermissionsToml { profileName = "inspr-browser-guard"; denyPaths = [ "/Applications/Google Chrome.app" ]; }')
contains "$codex_profile" '[permissions.inspr-browser-guard]' 'Codex profile must declare the named permission profile'
contains "$codex_profile" 'extends = ":workspace"' 'Codex profile must extend, never replace, the account workspace policy'
contains "$codex_profile" '"/Applications/Google Chrome.app" = "deny"' 'Codex profile must deny the browser bundle'

codex_requirements=$(guard_eval 'guard.mkCodexRequirementsToml { profileName = "inspr-browser-guard"; denyPaths = [ "/Applications/Google Chrome.app" ]; }')
contains "$codex_requirements" 'default_permissions = "inspr-browser-guard"' 'managed requirements must set the default permission profile'
contains "$codex_requirements" '[allowed_permission_profiles]' 'managed requirements must allow-list the guarded profile'
# Vendor managed-configuration docs require a BOOLEAN allow-list value. An
# invalid managed config can stop Codex starting at all, so parse and type-check
# it here rather than discovering it on a privileged install.
printf '%s' "$codex_requirements" >"${TMPDIR:-/tmp}/t72-requirements.toml"
python3 - "${TMPDIR:-/tmp}/t72-requirements.toml" <<'PYTOML' || exit 1
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    doc = tomllib.load(handle)
name = doc.get("default_permissions")
if name != "inspr-browser-guard":
    print(f"T72 failed: default_permissions is {name!r}", file=sys.stderr); sys.exit(1)
allowed = doc.get("allowed_permission_profiles")
if not isinstance(allowed, dict) or name not in allowed:
    print(f"T72 failed: allow-list missing the profile: {allowed!r}", file=sys.stderr); sys.exit(1)
if not isinstance(allowed[name], bool) or allowed[name] is not True:
    print(f"T72 failed: allowed_permission_profiles.{name} must be the boolean true, got {allowed[name]!r}", file=sys.stderr)
    sys.exit(1)
profile = doc.get("permissions", {}).get(name, {})
if profile.get("extends") != ":workspace":
    print(f"T72 failed: profile must extend the workspace baseline: {profile!r}", file=sys.stderr); sys.exit(1)
denies = profile.get("filesystem", {})
if denies.get("/Applications/Google Chrome.app") != "deny":
    print(f"T72 failed: Chrome bundle is not denied: {denies!r}", file=sys.stderr); sys.exit(1)
PYTOML
rm -f "${TMPDIR:-/tmp}/t72-requirements.toml"

# The deny list must carry the self-test anchor, so the managed installer can
# prove enforcement with a fake executable instead of with a browser.
probe_path=$(guard_eval 'guard.codexProbePath')
case "$probe_path" in
/private/*) ;;
*) fail "probe anchor must be an absolute resolved path: $probe_path" ;;
esac
grep -Fq 'guardLib.codexProbePath' modules/uzumaki/agent-browser-guard.nix ||
  fail 'the module must add the probe anchor to the Codex deny list'
anchored=$(guard_eval "guard.mkCodexRequirementsToml { profileName = ''inspr-browser-guard''; denyPaths = [ ''$probe_path'' ]; }")
contains "$anchored" "\"$probe_path\" = \"deny\"" 'probe anchor must render as a deny rule'

installer=$(guard_eval 'guard.mkManagedInstallerText { requirementsPath = "/nix/store/x-req.toml"; profileName = "inspr-browser-guard"; codexBinary = "/tmp/codex"; }')
contains "$installer" 'exit 77' 'installer must refuse to run without root and without SUDO_USER'
contains "$installer" 'SUDO_USER' 'installer must run its verification as the operator, never as root'
contains "$installer" '--replace-existing' 'installer must refuse to clobber a foreign managed config by default'
contains "$installer" 'pre-inspr-nix445' 'installer must back up an adopted config'
contains "$installer" 'refusing to touch' 'rollback must be checksum-guarded to our own file'
contains "$installer" 'sandbox_mode=danger-full-access' 'installer must prove the legacy sandbox override cannot escape'
contains "$installer" '-P :workspace' 'installer must prove a built-in profile is rejected once managed'
contains "$installer" 'rolling back' 'installer must roll back on verification failure'
case "$installer" in
*'Google Chrome.app/Contents/MacOS'*) fail 'installer must never execute or name a real browser binary' ;;
esac

contains "$codex_requirements" '"/Applications/Google Chrome.app" = "deny"' 'managed requirements must carry the deny definitions'

# ── 2. Wiring ────────────────────────────────────────────────────────────────
grep -Fq './agent-browser-guard.nix' modules/uzumaki/home-manager.nix ||
  fail 'uzumaki home-manager.nix must import the guard module'
grep -Fq 'agentBrowserGuard = {' hosts/mbp2607/home.nix ||
  fail 'mbp2607 must enable the guard explicitly'
grep -Fq 'browserGuard = {' hosts/mbp2607/home.nix ||
  fail 'mbp2607 must enable the agentd browser guard explicitly'
grep -Fq 'shadowedPrograms = {' hosts/mbp2607/home.nix ||
  fail 'mbp2607 must wire the real CLI names through the guard, not only *-guarded aliases'
for cli in claude grok pi; do
  grep -Eq "^ *$cli = " hosts/mbp2607/home.nix ||
    fail "mbp2607 must shadow the real $cli entry point"
done
# Codex, cursor-agent and its `agent` symlink each apply their own Seatbelt
# profile; wrapping any of them would break the sandbox they already have. They
# may appear under envOnlyPrograms — only shadowedPrograms is a Seatbelt wrap.
python3 - <<'PYSHADOW' || exit 1
import re, sys
src = open("hosts/mbp2607/home.nix", encoding="utf-8").read()
block = re.search(r"shadowedPrograms = \{(.*?)\n *\};", src, re.S)
if not block:
    print("T72 failed: shadowedPrograms block not found", file=sys.stderr); sys.exit(1)
for unwrappable in ("codex", "cursor-agent", "agent"):
    if re.search(rf"^\s*{re.escape(unwrappable)}\s*=", block.group(1), re.M):
        print(f"T72 failed: {unwrappable} must never be Seatbelt-wrapped", file=sys.stderr); sys.exit(1)
PYSHADOW
grep -Fq 'cursor-agent' modules/uzumaki/agent-browser-guard.nix ||
  fail 'the module must state the Cursor limitation explicitly'
grep -Fq 'fish_add_path --prepend --move ${shadowBin}/bin' modules/uzumaki/agent-browser-guard.nix ||
  fail 'guarded launchers must be placed ahead of ~/.npm-global/bin in fish'
grep -Fq 'guardPrefix' hosts/mbp2607/pi-local.nix ||
  fail 'the declarative Pi launchers must run under the guard'
grep -Fq '${guardEnvExports}' modules/uzumaki/paimos-agentd.nix ||
  fail 'the agentd Codex launcher must carry the env-only guard layer'
grep -Fq 'EnvironmentVariables = browserGuard.launchdEnvironment' modules/uzumaki/paimos-agentd.nix ||
  fail 'agentd-owned sessions must inherit the harness variables from the plist'

# Codex must stay out of the sandbox-wrapped set: macOS cannot nest profiles,
# so wrapping it would break its own inner sandbox (proved in section 4).
python3 - <<'PY' || exit 1
import re, sys
src = open("modules/uzumaki/paimos-agentd.nix", encoding="utf-8").read()
enum = re.search(r"sandboxedClis = lib\.mkOption \{\s*type = lib\.types\.listOf \(\s*lib\.types\.enum \[(.*?)\]", src, re.S)
if not enum:
    print("T72 failed: sandboxedClis enum not found", file=sys.stderr); sys.exit(1)
for name in ("codex", "cursor"):
    if name in enum.group(1):
        print(f"T72 failed: {name} must not be sandbox-wrappable", file=sys.stderr); sys.exit(1)
PY

# ── 3. The ordinary human browser path is untouched ──────────────────────────
grep -Fq 'chromiumAppPath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";' \
  modules/uzumaki/macos-common.nix ||
  fail 'NIX-288 native Chrome export must stay unchanged for human sessions'
grep -Fq 'macosCommon.playwrightSessionVars' hosts/mbp2607/home.nix ||
  fail 'mbp2607 must keep the NIX-288 session variable for human shells'
# Comments may discuss these; actual assignments must not exist.
if grep -Eq '^[^#;]*home\.sessionVariables[[:space:]]*=' modules/uzumaki/agent-browser-guard.nix; then
  fail 'the guard must not set home.sessionVariables — that would change human shells'
fi
if grep -Eq '^[^#;]*(google-chrome|commonCasks)' modules/uzumaki/agent-browser-guard.nix; then
  fail 'the guard must not manage the Chrome cask or the Brewfile baseline'
fi
if grep -Eq '^[^#;]*home\.sessionVariables[[:space:]]*=' modules/uzumaki/paimos-agentd.nix; then
  fail 'agentd wiring must not set home.sessionVariables'
fi

# ── 4. Runtime proof (Darwin only), fake executables only ────────────────────
if [ "$(uname -s)" != Darwin ]; then
  printf 'agent_browser_guard=passed scope=eval-only reason=not-darwin\n'
  exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/nix445-t72.XXXXXX")
# Seatbelt matches RESOLVED paths: /tmp is a symlink to /private/tmp, and a
# profile written against the unresolved path silently denies nothing.
work=$(cd "$work" && pwd -P)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

mkdir -p "$work/FakeBrowser.app/Contents/MacOS"
fake="$work/FakeBrowser.app/Contents/MacOS/FakeBrowser"
printf '#!/bin/sh\necho FAKE_BROWSER_LAUNCHED > "$0.marker"\necho FAKE_BROWSER_LAUNCHED\n' >"$fake"
chmod +x "$fake"
ln -s "$fake" "$work/fake-symlink"

# Baseline: without the guard the fake browser runs. Anything else means the
# later denials would prove nothing.
[ "$("$fake")" = FAKE_BROWSER_LAUNCHED ] || fail 'fake browser does not run unguarded — test is meaningless'
rm -f "$fake.marker" # the marker from the baseline run; from here on it means a leak

guard_eval "guard.mkProfileText { browserBundles = [ ''$work/FakeBrowser.app'' ]; }" >"$work/guard.sb"
refusal="$work/refuse"
{
  printf '#!/usr/bin/env bash\n'
  guard_eval 'guard.mkRefusalText { }'
} >"$refusal"
chmod +x "$refusal"
launcher="$work/guard"
{
  printf '#!/usr/bin/env bash\n'
  guard_eval "guard.mkGuardText { profilePath = ''$work/guard.sb''; refusalPath = ''$refusal''; }"
} >"$launcher"
chmod +x "$launcher"

denied() {
  local label=$1
  shift
  local out
  if out=$("$@" 2>&1); then
    fail "$label: expected denial, got success: $out"
  fi
  case "$out" in
  *FAKE_BROWSER_LAUNCHED*) fail "$label: the fake browser ran anyway" ;;
  *'not permitted'* | *EPERM*) ;;
  *) fail "$label: denial did not come from the sandbox: $out" ;;
  esac
}

denied 'direct exec' /usr/bin/sandbox-exec -f "$work/guard.sb" "$fake"
denied 'shell child' /usr/bin/sandbox-exec -f "$work/guard.sb" /bin/sh -c "'$fake'"
denied 'symlinked exec' /usr/bin/sandbox-exec -f "$work/guard.sb" /bin/sh -c "'$work/fake-symlink'"

# Indirect Node grandchild — the actual Playwright shape from the incident.
node=$(command -v node || true)
[ -x "$node" ] || fail 'node not found; the Playwright-shaped grandchild case cannot be proved'
cat >"$work/spawn.mjs" <<'JS'
import { spawnSync } from "node:child_process";
const r = spawnSync(process.argv[2], [], { encoding: "utf8" });
console.log(JSON.stringify({ status: r.status, error: r.error ? String(r.error) : null, stdout: (r.stdout || "").trim() }));
JS
grandchild=$(/usr/bin/sandbox-exec -f "$work/guard.sb" "$node" "$work/spawn.mjs" "$fake")
contains "$grandchild" 'EPERM' 'Node grandchild must be denied by the inherited sandbox'
case "$grandchild" in
*FAKE_BROWSER_LAUNCHED*) fail 'Node grandchild launched the fake browser' ;;
esac

# Ordinary work must be unaffected.
[ "$(/usr/bin/sandbox-exec -f "$work/guard.sb" /bin/echo ORDINARY_OK)" = ORDINARY_OK ] ||
  fail 'ordinary commands must still run inside the guard'
[ "$("$launcher" /bin/echo LAUNCHER_OK)" = LAUNCHER_OK ] ||
  fail 'the guard launcher must run ordinary programs'
denied 'guard launcher' "$launcher" "$fake"

# The launcher redirects only the browser-harness variables.
harness=$("$launcher" /bin/sh -c 'printf "%s\n" "$PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH" "$INSPR_AGENT_BROWSER_GUARD"')
[ "$harness" = "$refusal
sandbox" ] || fail "guard launcher must redirect the harness variables (got: $harness)"

# Bad input fails closed rather than running unguarded.
set +e
"$launcher" relative-program >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 64 ] || fail "guard launcher must reject a non-absolute program (rc=$rc)"

# The refusal shim explains the supported path and never reports success.
set +e
refusal_out=$("$refusal" --headless https://example.invalid 2>&1)
refusal_rc=$?
set -e
[ "$refusal_rc" -eq 78 ] || fail "refusal shim must exit non-zero (rc=$refusal_rc)"
contains "$refusal_out" 'native browser launch refused' 'refusal must be stable and explicit'
contains "$refusal_out" 'controller-owned or remote' 'refusal must name the supported browser-QA path'
contains "$refusal_out" 'NOT a passed browser test' 'refusal must forbid reporting a pass'

# Documented macOS limit, asserted so it cannot rot silently: a process under a
# profile containing any deny cannot apply a second profile. This is why Codex
# (which sandboxes every command itself) is env-only rather than wrapped.
nest_out=$(/usr/bin/sandbox-exec -f "$work/guard.sb" /usr/bin/sandbox-exec -p '(version 1)(allow default)' /bin/echo NESTED 2>&1 || true)
contains "$nest_out" 'sandbox_apply' \
  'macOS nesting limit changed — re-evaluate whether Codex can now be sandbox-wrapped'

# Codex applies its own Seatbelt profile per command and therefore cannot be
# wrapped (asserted above). Its native permission profile expresses the same deny
# — prove that with the same fake bundle, in an isolated CODEX_HOME, using only
# the local sandbox subcommand (no model, no account, no network).
codex_bin=$(command -v codex || true)
if [ -x "$codex_bin" ]; then
  mkdir -p "$work/codex-home" "$work/codex-ws"
  {
    guard_eval "guard.mkCodexPermissionsToml { profileName = ''inspr-browser-guard''; denyPaths = [ ''$work/FakeBrowser.app'' ]; }"
  } >"$work/codex-home/config.toml"

  codex_denied=$(CODEX_HOME="$work/codex-home" "$codex_bin" sandbox -P inspr-browser-guard -C "$work/codex-ws" -- \
    /bin/sh -c "'$fake'" 2>&1 || true)
  case "$codex_denied" in
  *FAKE_BROWSER_LAUNCHED*) fail 'Codex native profile did not stop the fake browser' ;;
  *'not permitted'*) ;;
  *) fail "Codex native profile denial not observed: $codex_denied" ;;
  esac

  codex_indirect=$(CODEX_HOME="$work/codex-home" "$codex_bin" sandbox -P inspr-browser-guard -C "$work/codex-ws" -- \
    "$node" "$work/spawn.mjs" "$fake" 2>&1 || true)
  case "$codex_indirect" in
  *FAKE_BROWSER_LAUNCHED*) fail 'Codex native profile did not stop the Node grandchild' ;;
  esac
  contains "$codex_indirect" '"status":126' 'Codex native profile must deny the indirect Node spawn'

  # The profile must EXTEND the account policy, not narrow ordinary work away.
  codex_ok=$(CODEX_HOME="$work/codex-home" "$codex_bin" sandbox -P inspr-browser-guard -C "$work/codex-ws" -- \
    /bin/sh -c 'echo ORDINARY_OK; touch ./guard-write-probe && echo WRITE_OK' 2>&1 || true)
  contains "$codex_ok" 'ORDINARY_OK' 'Codex guarded profile must still run ordinary commands'
  contains "$codex_ok" 'WRITE_OK' 'Codex guarded profile must keep the existing workspace write policy'
  codex_scope=codex-native
else
  codex_scope=codex-absent
fi

[ -e "$fake.marker" ] && fail 'a fake browser actually executed during this test'

printf 'agent_browser_guard=passed scope=eval+runtime fake_browser_launches=0 codex=%s\n' "$codex_scope"
