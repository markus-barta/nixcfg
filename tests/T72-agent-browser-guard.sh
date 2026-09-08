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
/etc/codex/*) ;;
*) fail "the root-written probe anchor must live in the root-owned managed directory, got: $probe_path" ;;
esac
preload_probe=$(guard_eval 'guard.defaultPreloadProbeRelative')
case "$preload_probe" in
/*) fail "the unprivileged anchor must be home-relative, got: $preload_probe" ;;
esac
grep -Fq 'guardLib.codexProbePath' modules/uzumaki/agent-browser-guard.nix ||
  fail 'the module must add the probe anchor to the Codex deny list'
grep -Fq 'cfg.preloadProbePath' modules/uzumaki/agent-browser-guard.nix ||
  fail 'the module must keep a separate unprivileged anchor for the preload proof'
anchored=$(guard_eval "guard.mkCodexRequirementsToml { profileName = ''inspr-browser-guard''; denyPaths = [ ''$probe_path'' ]; }")
contains "$anchored" "\"$probe_path\" = \"deny\"" 'probe anchor must render as a deny rule'

installer=$(guard_eval 'guard.mkManagedInstallerText { requirementsPath = "/nix/store/x-req.toml"; profileName = "inspr-browser-guard"; fullProfileName = "inspr-browser-guard-full"; readOnlyProfileName = "inspr-browser-guard-readonly"; codexBinary = "/tmp/codex"; }')
contains "$installer" 'SUDO_USER' 'installer must run its verification as the operator, never as root'
contains "$installer" '--replace-existing' 'installer must refuse to clobber a foreign managed config by default'
contains "$installer" 'pre-inspr-nix445' 'installer must back up an adopted config'
contains "$installer" 'refusing to touch' 'rollback must be checksum-guarded to our own file'
contains "$installer" 'sandbox_mode=danger-full-access' 'installer must prove the legacy sandbox override cannot escape'
contains "$installer" '-P :workspace' 'installer must prove a built-in profile is rejected once managed'
contains "$installer" 'guarded full profile' 'installer must verify the guarded full-access profile still denies the probe'
contains "$installer" 'FULL_WRITE_OK' 'installer must verify guarded-full keeps outside-workspace write'
contains "$installer" 'guarded read-only profile' 'installer must verify that read-only stays read-only'
contains "$installer" 'READONLY_WROTE' 'installer must fail if the workspace default broadened a read-only caller'
contains "$installer" 'include-managed-config' 'every proof must resolve managed policy explicitly'
contains "$installer" 'NOT proved here' 'installer must narrow its claim to the sandbox proof path'
case "$installer" in
*'sandbox -C '*) fail 'installer must not treat a flagless codex sandbox run as a managed-policy proof' ;;
esac
contains "$installer" 'adopted_foreign_identical' 'installer must not claim an identical config it did not install'
case "$installer" in
*'Google Chrome.app/Contents/MacOS'*) fail 'installer must never execute or name a real browser binary' ;;
esac

# B1 — no fixed name in a world-writable directory, and fail closed on symlinks.
case "$installer" in
*'/private/var/tmp'* | *' /var/tmp'* | *'"/tmp'*) fail 'installer must not write a fixed name into a world-writable directory' ;;
esac
contains "$installer" 'is a symlink' 'installer must fail closed on a symlinked target, directory or probe'
contains "$installer" 'is not owned by root' 'installer must verify the managed directory is root-owned'
contains "$installer" 'group- or world-writable' 'installer must refuse a pre-emptable managed directory'

# B2 — the install/verify window must be transactional, signals included.
contains "$installer" 'trap on_exit EXIT' 'installer must arm the rollback handler before any mutation'
contains "$installer" "trap 'exit 130' INT" 'installer must trap INT'
contains "$installer" "trap 'exit 143' TERM" 'installer must trap TERM'
contains "$installer" 'verified=1' 'installer must clear the rollback only after verification'
contains "$installer" 'unverified install' 'installer must roll back an unverified install'
owner_line=$(printf '%s\n' "$installer" | grep -n 'is not owned by root' | head -1 | cut -d: -f1)
installd_line=$(printf '%s\n' "$installer" | grep -n 'install -d ' | head -1 | cut -d: -f1)
[ -n "$owner_line" ] && [ -n "$installd_line" ] && [ "$owner_line" -lt "$installd_line" ] ||
  fail 'an existing managed directory must be validated before install -d could normalise it'
trap_line=$(printf '%s\n' "$installer" | grep -n 'trap on_exit EXIT' | head -1 | cut -d: -f1)
stamp_line=$(printf '%s\n' "$installer" | grep -n '>"\$STAMP"' | head -1 | cut -d: -f1)
mv_line=$(printf '%s\n' "$installer" | grep -n 'mv -f "\$tmp" "\$TARGET"' | head -1 | cut -d: -f1)
[ -n "$stamp_line" ] && [ -n "$mv_line" ] && [ "$stamp_line" -lt "$mv_line" ] ||
  fail 'the rollback stamp must exist before the target does'
[ -n "$trap_line" ] && [ "$trap_line" -lt "$mv_line" ] ||
  fail 'the rollback handler must be armed before the target is replaced'
intent_line=$(printf '%s\n' "$installer" | grep -n 'mutation_intent=1$' | head -1 | cut -d: -f1)
[ -n "$intent_line" ] && [ "$intent_line" -lt "$mv_line" ] ||
  fail 'mutation intent must be recorded before the rename, not after'

# Run the rendered installer in an isolated fixture — never /etc, never sudo.
fixture=$(mktemp -d "${TMPDIR:-/tmp}/t72-installer.XXXXXX")
fixture=$(cd "$fixture" && pwd -P)
printf '#!/usr/bin/env bash\n%s\n' "$installer" >"$fixture/installer.sh"
chmod +x "$fixture/installer.sh"
bash -n "$fixture/installer.sh" || fail 'rendered installer is not valid shell'
mkdir -p "$fixture/etc"
set +e
"$fixture/installer.sh" >"$fixture/out" 2>&1
rc=$?
set -e
[ "$rc" -eq 77 ] || fail "unprivileged installer must exit 77, got $rc"
grep -q 'must run as root' "$fixture/out" || fail 'unprivileged refusal must say why'
[ -z "$(ls -A "$fixture/etc")" ] || fail 'unprivileged installer wrote into the fixture'
set +e
"$fixture/installer.sh" --bogus >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 64 ] || fail "bad argument must exit 64, got $rc"

# Exercise the rollback guard itself in the fixture.
{
  printf '%s\n' "$installer" | sed -n '/^sha_of() {$/,/^}$/p'
  printf '%s\n' "$installer" | sed -n '/^restore() {$/,/^}$/p'
} >"$fixture/restore.sh"
grep -q '^restore() {' "$fixture/restore.sh" || fail 'could not extract the restore function'
grep -q '^sha_of() {' "$fixture/restore.sh" || fail 'could not extract the checksum helper'
restore_case() {
  rm -rf "$fixture/case"
  mkdir -p "$fixture/case"
  printf 'managed\n' >"$fixture/case/requirements.toml"
  case "$2" in
  ours) /usr/bin/shasum -a 256 "$fixture/case/requirements.toml" | cut -d' ' -f1 >"$fixture/case/requirements.toml.inspr-nix445.sha256" ;;
  stale) printf 'deadbeef\n' >"$fixture/case/requirements.toml.inspr-nix445.sha256" ;;
  esac
  [ "$3" = yes ] && printf 'previous\n' >"$fixture/case/requirements.toml.pre-inspr-nix445.20260101T000000Z"
  (
    TARGET=$fixture/case/requirements.toml
    STAMP=$TARGET.inspr-nix445.sha256
    SHASUM=/usr/bin/shasum
    adopted_foreign_identical=0
    new_sha=${5-}
    pre_stamp=${6-}
    export TARGET STAMP SHASUM adopted_foreign_identical new_sha pre_stamp
    # shellcheck source=/dev/null
    . "$fixture/restore.sh"
    restore
  ) >/dev/null 2>&1 || true
  case "$4" in
  removed) [ ! -e "$fixture/case/requirements.toml" ] || fail "restore($1) should have removed our own file" ;;
  kept) [ -e "$fixture/case/requirements.toml" ] || fail "restore($1) must not remove a file that is not ours" ;;
  restored) [ "$(cat "$fixture/case/requirements.toml")" = previous ] || fail "restore($1) should have restored the backup" ;;
  esac
}
restore_case 'no stamp' none no kept
restore_case 'stale stamp' stale no kept
restore_case 'ours, no backup' ours no removed
restore_case 'ours, with backup' ours yes restored
# Provenance boundaries: a target this run wrote is rolled back even without a
# usable stamp, and a target replaced by someone else after our write is not.
managed_sha=$(printf 'managed\n' | /usr/bin/shasum -a 256 | cut -d' ' -f1)
restore_case 'mid-transaction, ours by checksum' none no removed "$managed_sha"
restore_case 'mid-transaction, replaced under us' none no kept deadbeefdeadbeef

# The managed-directory mode check must reject GROUP write too: an existing
# root-owned /etc/codex can carry a non-wheel group, and a trailing-character
# glob would only ever have seen the "other" digit.
printf '%s\n' "$installer" | sed -n '/^mode_is_group_or_world_writable() {$/,/^}$/p' >"$fixture/mode.sh"
grep -q '^mode_is_group_or_world_writable() {' "$fixture/mode.sh" ||
  fail 'could not extract the directory-mode check'
mode_case() {
  local mode=$1 expect=$2 rc
  set +e
  bash -c ". '$fixture/mode.sh'; mode_is_group_or_world_writable '$mode'"
  rc=$?
  set -e
  case "$expect" in
  accept) [ "$rc" -ne 0 ] || fail "mode $mode must be accepted as a safe managed directory" ;;
  reject) [ "$rc" -eq 0 ] || fail "mode $mode is writable by group or others and must be rejected" ;;
  esac
}
mode_case 755 accept
mode_case 750 accept
mode_case 775 reject
mode_case 770 reject
mode_case 777 reject
rm -rf "$fixture"

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
empty = re.search(r"shadowedPrograms = \{ *\};", src)
block = "" if empty else None
if block is None:
    found = re.search(r"shadowedPrograms = \{(.*?)\n *\};", src, re.S)
    if not found:
        print("T72 failed: shadowedPrograms block not found", file=sys.stderr); sys.exit(1)
    block = found.group(1)
for unwrappable in ("codex", "cursor-agent", "agent"):
    if re.search(rf"^\s*{re.escape(unwrappable)}\s*=", block, re.M):
        print(f"T72 failed: {unwrappable} must never be Seatbelt-wrapped", file=sys.stderr); sys.exit(1)
# D1: the dispatch-capable entry points must be on the env+preload route, since a
# Seatbelt profile would kill the Codex/Cursor workers they dispatch.
env_only = re.search(r"envOnlyPrograms = \{(.*?)\n *\};", src, re.S)
if not env_only:
    print("T72 failed: envOnlyPrograms block not found", file=sys.stderr); sys.exit(1)
for required in ("claude", "grok", "pi", "cursor-agent", "agent"):
    if not re.search(rf"^\s*{re.escape(required)}\s*=", env_only.group(1), re.M):
        print(f"T72 failed: {required} must be wired on the env+preload route", file=sys.stderr); sys.exit(1)
PYSHADOW
grep -Fq 'cursor-agent' modules/uzumaki/agent-browser-guard.nix ||
  fail 'the module must state the Cursor limitation explicitly'
grep -Fq 'fish_add_path --prepend --move ${shadowBin}/bin' modules/uzumaki/agent-browser-guard.nix ||
  fail 'guarded launchers must be placed ahead of ~/.npm-global/bin in fish'
grep -Fq 'programs.zsh.envExtra' modules/uzumaki/agent-browser-guard.nix ||
  fail 'zsh coverage must go through .zshenv, which non-interactive `zsh -c` also reads'
grep -Fq 'INSPR_AGENT_BROWSER_GUARD-' modules/uzumaki/agent-browser-guard.nix ||
  fail 'the strict wrapper must be re-entrant inside an existing guard'
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

  # The guarded FULL profile keeps the authorized full-access workflows working —
  # the coordinator and the operator's own sessions launch with the bypass flag —
  # while still refusing the fake browser.
  codex_full=$(CODEX_HOME="$work/codex-home" "$codex_bin" sandbox -P inspr-browser-guard-full -C "$work/codex-ws" -- \
    /bin/sh -c "touch $work/outside-probe && echo FULL_WRITE_OK" 2>&1 || true)
  contains "$codex_full" 'FULL_WRITE_OK' 'guarded-full must keep outside-workspace write'
  codex_full_denied=$(CODEX_HOME="$work/codex-home" "$codex_bin" sandbox -P inspr-browser-guard-full -C "$work/codex-ws" -- \
    /bin/sh -c "'$fake'" 2>&1 || true)
  case "$codex_full_denied" in
  *FAKE_BROWSER_LAUNCHED*) fail 'guarded-full let the fake browser run' ;;
  *'not permitted'*) ;;
  *) fail "guarded-full produced no recognisable denial: $codex_full_denied" ;;
  esac

  # An explicit read-only selection must not be broadened to workspace-write.
  codex_ro=$(CODEX_HOME="$work/codex-home" "$codex_bin" sandbox -P inspr-browser-guard-readonly -C "$work/codex-ws" -- \
    /bin/sh -c 'touch ./readonly-probe && echo READONLY_WROTE' 2>&1 || true)
  case "$codex_ro" in
  *READONLY_WROTE*) fail 'guarded read-only was broadened to write' ;;
  esac
  codex_scope=codex-native
else
  codex_scope=codex-absent
fi

[ -e "$fake.marker" ] && fail 'a fake browser actually executed during this test'

printf 'agent_browser_guard=passed scope=eval+runtime fake_browser_launches=0 codex=%s\n' "$codex_scope"
