#!/usr/bin/env bash
# NIX-392 / NIX-415 / NIX-421 / NIX-426 / NIX-428 / NIX-437 / NIX-439 — mbp2607 must install
# the exact released Paimos CLI/agentd pair, run the owned-session daemon with an
# exact Claude SDK, publish durable status/control without putting its credential
# in the store, and declare owner-only Cursor argv once Pi remains unset.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  printf 'T56 failed: %s\n' "$*" >&2
  exit 1
}

python3 - "$repo_root/flake.lock" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1], encoding="utf-8"))["nodes"]["paimos"]
original = lock["original"]
locked = lock["locked"]
assert original == {
    "owner": "inspr-at",
    "repo": "paimos",
    "ref": "v26.09.09",
    "type": "github",
}, original
assert locked["rev"] == "afb87c190e5235a11a21d0d4eee821b8eff96729", locked
assert locked["narHash"] == "sha256-DFtJi2zBe9hRK6fIHncD1ABqkLovMjC9tqSh+b0LYF8=", locked
PY

package_version=$(cd "$repo_root" && nix eval --raw '.#packages.aarch64-darwin.paimos-cli.version')
[ "$package_version" = 26.09.09 ] || fail "Paimos package is not the canonical v26.09.09 release: $package_version"

deployment_version=$(
  python3 - "$repo_root/flake.nix" "$repo_root/hosts/csb1/docker/compose-spec.nix" <<'PY'
import re, sys

flake = open(sys.argv[1], encoding="utf-8").read()
compose = open(sys.argv[2], encoding="utf-8").read()
client = re.findall(r'github:inspr-at/paimos/v([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+\.[0-9]+)?)', flake)
server = re.findall(r'ghcr\.io/inspr-at/paimos:([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+\.[0-9]+)?)@(sha256:[0-9a-f]{64})', compose)
assert len(client) == 1, f"expected one Paimos client release pin, got {client!r}"
assert len(server) == 1, f"expected one PPM server release pin, got {server!r}"
assert client[0] == server[0][0], f"Paimos client/server release drift: {client[0]} != {server[0][0]}"
assert server[0][1] == "sha256:ecbee9edc565f4f8e6e6f7e31c0a1bc522ceb9a2351767aea9c1201d4b5d769d", server
print(server[0][0])
PY
)
[ "$package_version" = "$deployment_version" ] || fail "Paimos package/server release drift: $package_version != $deployment_version"

sdk_version=$(cd "$repo_root" && nix eval --raw '.#packages.aarch64-darwin.claude-agent-sdk.version')
[ "$sdk_version" = 0.3.251 ] || fail "Claude Agent SDK version drifted: $sdk_version"
sdk_out=$(cd "$repo_root" && nix eval --raw '.#packages.aarch64-darwin.claude-agent-sdk.outPath')
sdk_relative=$(cd "$repo_root" && nix eval --raw '.#packages.aarch64-darwin.claude-agent-sdk.sdkRelativePath')

agent_json=$(cd "$repo_root" && nix eval --json '.#homeConfigurations."markus@mbp2607".config.launchd.agents.paimos-agentd')
activation=$(cd "$repo_root" && nix eval --raw '.#homeConfigurations."markus@mbp2607".config.home.activation.paimosAgentdPrivateState.data')
accounts_activation=$(cd "$repo_root" && nix eval --raw '.#homeConfigurations."markus@mbp2607".config.home.activation.paimosAgentdCodexAccounts.data')
cursor_accounts_activation=$(
  cd "$repo_root" && nix eval --raw '.#homeConfigurations."markus@mbp2607".config.home.activation.paimosAgentdCursorAccounts.data'
)

python3 - "$agent_json" "$sdk_out" "$sdk_relative" <<'PY'
import hashlib, json, sys
agent = json.loads(sys.argv[1])
sdk_out = sys.argv[2]
sdk_relative = sys.argv[3]
assert agent["enable"] is True, agent
config = agent["config"]
args = config["ProgramArguments"]
assert args[0].endswith("/bin/paimos-agentd"), args
expected_pairs = {
    "--instance": "ppm",
    "--state-root": "/Users/markus/Library/Caches/paimos/agentd",
    "--report-host": "mbp2607",
    "--report-url": "https://pm.barta.cm",
    "--report-api-key-file": "/Users/markus/Library/Caches/paimos/agentd/report-api-key",
    "--lifecycle-config": "/Users/markus/Library/Application Support/paimos/agentd/lifecycle.json",
    "--codex-accounts": "/Users/markus/Library/Application Support/paimos/agentd/codex-accounts.json",
    "--cursor-accounts": "/Users/markus/Library/Application Support/paimos/agentd/cursor-accounts.json",
}
for flag, value in expected_pairs.items():
    index = args.index(flag)
    assert args[index + 1] == value, (flag, args)
    assert args.count(flag) == 1, (flag, args)
for flag in ("--pi-path", "--pi-accounts"):
    assert flag not in args, (flag, args)
# NIX-445 / D1: Claude is the dispatch controller here, so it runs on the
# env+preload route — a Seatbelt profile would be inherited by the Codex and
# Cursor workers it starts and would kill them on their own sandbox_apply.
# Cursor is launched through the env-only wrapper instead: it runs its own
# seatbelt helper, so it must never be nested inside another profile.
cursor_index = args.index("--cursor-path")
assert args.count("--cursor-path") == 1, args
cursor_path = args[cursor_index + 1]
assert cursor_path.startswith("/nix/store/"), args
assert cursor_path.endswith("-paimos-agentd-cursor/bin/paimos-agentd-cursor"), args
claude_index = args.index("--claude-path")
assert args.count("--claude-path") == 1, args
claude_path = args[claude_index + 1]
assert claude_path.startswith("/nix/store/"), args
assert claude_path.endswith("-paimos-agentd-claude/bin/paimos-agentd-claude"), args
codex_index = args.index("--codex-path")
assert args[codex_index + 1].startswith("/nix/store/"), args
assert args[codex_index + 1].endswith("-paimos-agentd-codex/bin/paimos-agentd-codex"), args
node_index = args.index("--node-path")
assert args[node_index + 1].startswith("/nix/store/"), args
assert args[node_index + 1].endswith("/bin/node"), args
sdk_index = args.index("--claude-sdk-path")
assert sdk_out.startswith("/nix/store/"), sdk_out
assert args[sdk_index + 1] == f"{sdk_out}/{sdk_relative}", args
paimos_index = args.index("--paimos-path")
assert args[paimos_index + 1].startswith("/nix/store/"), args
assert args[paimos_index + 1].endswith("/bin/paimos"), args
assert config["Label"] == "at.inspr.paimos-agentd", config
assert config["RunAtLoad"] is True and config["KeepAlive"] is True, config
assert config["ProcessType"] == "Background", config
instance_key = hashlib.sha256(b"ppm").hexdigest()[:32]
instance_dir = f"/Users/markus/Library/Caches/paimos/agentd/{instance_key}"
assert config["StandardOutPath"] == f"{instance_dir}/agentd.stdout.log", config
assert config["StandardErrorPath"] == f"{instance_dir}/agentd.stderr.log", config
assert config["Umask"] == 63, config
# NIX-445: the only plist environment permitted is the non-secret browser-harness
# redirect that points every agentd-started session at the refusal shim.
# Credentials must still never appear here.
env = config.get("EnvironmentVariables")
assert env is not None and set(env) == {
    "CHROME_PATH",
    "PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH",
    "PUPPETEER_EXECUTABLE_PATH",
    "INSPR_AGENT_BROWSER_GUARD",
}, config
assert env["INSPR_AGENT_BROWSER_GUARD"] == "env-only", config
for key in ("CHROME_PATH", "PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH", "PUPPETEER_EXECUTABLE_PATH"):
    assert env[key].startswith("/nix/store/"), config
    assert env[key].endswith("/bin/inspr-browser-guard-refuse"), config
PY

current_system=$(nix eval --impure --raw --expr builtins.currentSystem)
if [ "$current_system" = aarch64-darwin ]; then
  cd "$repo_root"
  nix build '.#packages.aarch64-darwin.claude-agent-sdk' --no-link
  [ -f "$sdk_out/$sdk_relative" ] || fail 'realised Claude Agent SDK path does not exist'

  codex_launcher=$(
    python3 - "$agent_json" <<'PY'
import json, sys
args = json.loads(sys.argv[1])["config"]["ProgramArguments"]
print(args[args.index("--codex-path") + 1])
PY
  )
  activation_package=$(nix build '.#homeConfigurations."markus@mbp2607".activationPackage' --no-link --print-out-paths)
  [ -x "$codex_launcher" ] || fail 'realised Codex launcher does not exist'
  grep -Fq '/nix/store/' "$codex_launcher" || fail 'Codex launcher does not pin its runtime in the Nix store'
  grep -Eq '^export PATH=/nix/store/[^/]+-nodejs-[^/]+/bin:/usr/bin:/bin:/usr/sbin:/sbin$' "$codex_launcher" || fail 'Codex launcher does not supply a deterministic Node PATH'
  grep -Fq '/Users/markus/.npm-global/bin/codex' "$codex_launcher" || fail 'Codex launcher does not exec the operator-authenticated CLI'
  # NIX-445: Codex keeps its own Seatbelt sandbox (macOS refuses nested profiles),
  # so it gets the browser-harness variables only — never a guard wrapper.
  grep -Fq 'PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=' "$codex_launcher" || fail 'Codex launcher does not carry the NIX-445 browser-harness variables'
  if grep -Fq 'sandbox-exec' "$codex_launcher"; then
    fail 'Codex launcher must not be wrapped in a nested Seatbelt profile'
  fi

  claude_launcher=$(
    python3 - "$agent_json" <<'PYCLAUDE'
import json, sys
args = json.loads(sys.argv[1])["config"]["ProgramArguments"]
print(args[args.index("--claude-path") + 1])
PYCLAUDE
  )
  [ -x "$claude_launcher" ] || fail 'realised Claude launcher does not exist'
  grep -Fq '/Users/markus/.npm-global/bin/claude' "$claude_launcher" || fail 'Claude launcher does not exec the operator-authenticated CLI'
  grep -Fq 'NODE_OPTIONS' "$claude_launcher" || fail 'Claude launcher does not carry the NIX-445 Node preload'
  if grep -Eq 'sandbox-exec|inspr-agent-guard' "$claude_launcher"; then
    fail 'the dispatch controller must not be Seatbelt-wrapped — it would kill the workers it dispatches'
  fi

  cursor_launcher=$(
    python3 - "$agent_json" <<'PYCURSOR'
import json, sys
args = json.loads(sys.argv[1])["config"]["ProgramArguments"]
print(args[args.index("--cursor-path") + 1])
PYCURSOR
  )
  [ -x "$cursor_launcher" ] || fail 'realised Cursor launcher does not exist'
  grep -Fq '/Users/markus/.local/share/cursor-agent/versions/2026.09.02-c22c1a3/cursor-agent' "$cursor_launcher" ||
    fail 'Cursor launcher does not exec the pinned operator CLI'
  grep -Fq 'NODE_OPTIONS' "$cursor_launcher" || fail 'Cursor launcher does not carry the NIX-445 Node preload'
  if grep -Eq 'sandbox-exec|inspr-agent-guard' "$cursor_launcher"; then
    fail 'Cursor must never be nested inside another Seatbelt profile'
  fi

  service_plist="$activation_package/LaunchAgents/at.inspr.paimos-agentd.plist"
  [ -f "$service_plist" ] || fail 'final Home Manager generation has no Paimos LaunchAgent'
  python3 - "$agent_json" "$service_plist" <<'PY'
import hashlib, json, os, plistlib, stat, sys

declared = json.loads(sys.argv[1])["config"]
with open(sys.argv[2], "rb") as handle:
    generated = plistlib.load(handle)

assert generated["Label"] == "at.inspr.paimos-agentd", generated
assert generated["ProgramArguments"] == declared["ProgramArguments"], generated
assert os.path.isabs(generated["ProgramArguments"][0]), generated
assert os.path.basename(generated["ProgramArguments"][0]) == "paimos-agentd", generated
assert generated["ProgramArguments"][1] == "serve", generated
assert generated["Umask"] == 63, generated
instance_key = hashlib.sha256(b"ppm").hexdigest()[:32]
instance_dir = f"/Users/markus/Library/Caches/paimos/agentd/{instance_key}"
assert generated["StandardOutPath"] == f"{instance_dir}/agentd.stdout.log", generated
assert generated["StandardErrorPath"] == f"{instance_dir}/agentd.stderr.log", generated
assert generated.get("Program") is None, generated
# NIX-445: the generated plist carries exactly the non-secret browser-harness
# redirect and nothing else.
assert generated.get("EnvironmentVariables") == declared["EnvironmentVariables"], generated
assert set(generated["EnvironmentVariables"]) == {
    "CHROME_PATH",
    "PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH",
    "PUPPETEER_EXECUTABLE_PATH",
    "INSPR_AGENT_BROWSER_GUARD",
}, generated
assert generated.get("UserName") is None, generated
info = os.stat(sys.argv[2])
assert stat.S_ISREG(info.st_mode) and info.st_mode & 0o022 == 0, oct(info.st_mode)
PY

  credential_installer=$(
    grep -Eo '/nix/store/[^[:space:]]+-paimos-agentd-install-report-credential' <<<"$activation" | head -n 1
  )
  [ -x "$credential_installer" ] || fail 'realised report credential installer does not exist'
  fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/nix415-report-credential.XXXXXX")
  chmod 0700 "$fixture_root"
  trap '/usr/bin/trash "$fixture_root"' EXIT
  printf '%s' 'PPMAPIKEY=fixture-key' >"$fixture_root/valid.env"
  chmod 0400 "$fixture_root/valid.env"
  "$credential_installer" "$fixture_root/valid.env" "$fixture_root/raw-key" PPMAPIKEY
  [ "$(/usr/bin/stat -f '%Lp' "$fixture_root/raw-key")" = 600 ] || fail 'report credential output is not mode 0600'
  [ "$(<"$fixture_root/raw-key")" = fixture-key ] || fail 'report credential output does not contain the exact raw value'

  for invalid in wrong-name newline empty; do
    chmod 0600 "$fixture_root/invalid.env" 2>/dev/null || true
    case "$invalid" in
    wrong-name) printf '%s' 'OTHER=fixture-key' >"$fixture_root/invalid.env" ;;
    newline) printf 'PPMAPIKEY=fixture-key\nSECOND=value' >"$fixture_root/invalid.env" ;;
    empty) printf '%s' 'PPMAPIKEY=' >"$fixture_root/invalid.env" ;;
    esac
    chmod 0400 "$fixture_root/invalid.env"
    if "$credential_installer" "$fixture_root/invalid.env" "$fixture_root/raw-key" PPMAPIKEY >/dev/null 2>&1; then
      fail "report credential installer accepted $invalid input"
    fi
    [ "$(<"$fixture_root/raw-key")" = fixture-key ] || fail "$invalid input changed the last valid credential"
  done
  chmod 0644 "$fixture_root/valid.env"
  if "$credential_installer" "$fixture_root/valid.env" "$fixture_root/raw-key" PPMAPIKEY >/dev/null 2>&1; then
    fail 'report credential installer accepted a group/world-readable source'
  fi
fi

grep -Fq 'install -d -m 0700' <<<"$activation" || fail 'private state/log directory mode is not declared'
grep -Fq 'install -m 0600 /dev/null' <<<"$activation" || fail 'private log-file mode is not declared'
grep -Fq '/Users/markus/Library/Caches/paimos/agentd/616c1af8cc7f4556975b7cbe50bce072/agentd.stdout.log' <<<"$activation" || fail 'stdout log is outside the canonical instance state directory'
grep -Fq '/Users/markus/Library/Caches/paimos/agentd/616c1af8cc7f4556975b7cbe50bce072/agentd.stderr.log' <<<"$activation" || fail 'stderr log is outside the canonical instance state directory'
grep -Fq '/Users/markus/Library/Application Support/paimos/agentd/codex-accounts.json' <<<"$accounts_activation" || fail 'Codex accounts activation is not the Home Manager home-directory registry path'
grep -Fq 'paimos-agentd Codex account registry must be an existing regular non-symlink file' <<<"$accounts_activation" || fail 'Codex accounts activation lost its owner-only file gate'
grep -Fq '/Users/markus/Library/Application Support/paimos/agentd/cursor-accounts.json' <<<"$cursor_accounts_activation" || fail 'Cursor accounts activation is not the Home Manager home-directory registry path'
grep -Fq 'paimos-agentd Cursor account registry must be an existing regular non-symlink file' <<<"$cursor_accounts_activation" || fail 'Cursor accounts activation lost its owner-only file gate'
grep -Fq '/Users/markus/.inspr/secrets/agents/PPMAPIKEY.env' <<<"$activation" || fail 'reporting source is not the existing activation-managed secret'
grep -Fq '/Users/markus/Library/Caches/paimos/agentd/report-api-key' <<<"$activation" || fail 'reporting destination is not private agentd state'
grep -Fq 'PPMAPIKEY' <<<"$activation" || fail 'reporting assignment name is not pinned'

printf 'T56 passed: mbp2607 pins Paimos 26.09.09 with authenticated private agentd reporting, lifecycle control, owner-only Codex accounts, and prepared Cursor argv\n'
