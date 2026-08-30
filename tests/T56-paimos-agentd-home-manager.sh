#!/usr/bin/env bash
# NIX-392 — mbp2607 must install the exact released Paimos CLI/agentd pair and
# run the owned-session daemon with an exact, operator-installed Claude SDK.
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
    "ref": "v5.21.0",
    "type": "github",
}, original
assert locked["rev"] == "ec235d7cd03a13d06a02727cf55bad7c29bd89c7", locked
PY

package_version=$(cd "$repo_root" && nix eval --raw '.#packages.aarch64-darwin.paimos-cli.version')
[ "$package_version" = 5.21.0 ] || fail "Paimos package is not the canonical v5.21.0 release: $package_version"

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
fi

grep -Fq 'install -d -m 0700' <<<"$activation" || fail 'private state/log directory mode is not declared'
grep -Fq 'install -m 0600 /dev/null' <<<"$activation" || fail 'private log-file mode is not declared'

printf 'T56 passed: mbp2607 pins Paimos 5.21.0, agentd, and Claude SDK 0.3.251 with private launchd state\n'
