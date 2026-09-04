#!/usr/bin/env bash
# NIX-392 / NIX-415 / NIX-421 / NIX-426 — mbp2607 must install the exact released Paimos
# CLI/agentd pair, run the owned-session daemon with an exact Claude SDK, and
# publish durable status/control without putting its credential in the store.
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
    "ref": "v26.09.04",
    "type": "github",
}, original
assert locked["rev"] == "94f108eef6dba471a3852860a7615af5d7ec0f8c", locked
PY

package_version=$(cd "$repo_root" && nix eval --raw '.#packages.aarch64-darwin.paimos-cli.version')
[ "$package_version" = 26.09.04 ] || fail "Paimos package is not the canonical v26.09.04 release: $package_version"

deployment_version=$(
  python3 - "$repo_root/flake.nix" "$repo_root/hosts/csb1/docker/compose-spec.nix" <<'PY'
import re, sys

flake = open(sys.argv[1], encoding="utf-8").read()
compose = open(sys.argv[2], encoding="utf-8").read()
client = re.findall(r'github:inspr-at/paimos/v([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?)', flake)
server = re.findall(r'ghcr\.io/inspr-at/paimos:([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?)@sha256:[0-9a-f]{64}', compose)
assert len(client) == 1, f"expected one Paimos client release pin, got {client!r}"
assert len(server) == 1, f"expected one PPM server release pin, got {server!r}"
assert client[0] == server[0], f"Paimos client/server release drift: {client[0]} != {server[0]}"
print(server[0])
PY
)
[ "$package_version" = "$deployment_version" ] || fail "Paimos package/server release drift: $package_version != $deployment_version"

sdk_version=$(cd "$repo_root" && nix eval --raw '.#packages.aarch64-darwin.claude-agent-sdk.version')
[ "$sdk_version" = 0.3.251 ] || fail "Claude Agent SDK version drifted: $sdk_version"
sdk_out=$(cd "$repo_root" && nix eval --raw '.#packages.aarch64-darwin.claude-agent-sdk.outPath')
sdk_relative=$(cd "$repo_root" && nix eval --raw '.#packages.aarch64-darwin.claude-agent-sdk.sdkRelativePath')

agent_json=$(cd "$repo_root" && nix eval --json '.#homeConfigurations."markus@mbp2607".config.launchd.agents.paimos-agentd')
activation=$(cd "$repo_root" && nix eval --raw '.#homeConfigurations."markus@mbp2607".config.home.activation.paimosAgentdPrivateState.data')

python3 - "$agent_json" "$sdk_out" "$sdk_relative" <<'PY'
import json, sys
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
    "--claude-path": "/Users/markus/.npm-global/bin/claude",
    "--report-host": "mbp2607",
    "--report-url": "https://pm.barta.cm",
    "--report-api-key-file": "/Users/markus/Library/Caches/paimos/agentd/report-api-key",
}
for flag, value in expected_pairs.items():
    index = args.index(flag)
    assert args[index + 1] == value, (flag, args)
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
assert config["StandardOutPath"] == "/Users/markus/Library/Logs/paimos-agentd/stdout.log", config
assert config["StandardErrorPath"] == "/Users/markus/Library/Logs/paimos-agentd/stderr.log", config
assert config.get("EnvironmentVariables") is None, config
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
  nix build '.#homeConfigurations."markus@mbp2607".activationPackage' --no-link
  [ -x "$codex_launcher" ] || fail 'realised Codex launcher does not exist'
  grep -Fq '/nix/store/' "$codex_launcher" || fail 'Codex launcher does not pin its runtime in the Nix store'
  grep -Eq '^export PATH=/nix/store/[^/]+-nodejs-[^/]+/bin:/usr/bin:/bin:/usr/sbin:/sbin$' "$codex_launcher" || fail 'Codex launcher does not supply a deterministic Node PATH'
  grep -Fq '/Users/markus/.npm-global/bin/codex' "$codex_launcher" || fail 'Codex launcher does not exec the operator-authenticated CLI'

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
grep -Fq '/Users/markus/.inspr/secrets/agents/PPMAPIKEY.env' <<<"$activation" || fail 'reporting source is not the existing activation-managed secret'
grep -Fq '/Users/markus/Library/Caches/paimos/agentd/report-api-key' <<<"$activation" || fail 'reporting destination is not private agentd state'
grep -Fq 'PPMAPIKEY' <<<"$activation" || fail 'reporting assignment name is not pinned'

printf 'T56 passed: mbp2607 pins Paimos 26.09.04 with authenticated private agentd reporting\n'
