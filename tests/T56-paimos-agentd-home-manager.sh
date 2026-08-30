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

agent_json=$(cd "$repo_root" && nix eval --json '.#homeConfigurations."markus@mbp2607".config.launchd.agents.paimos-agentd')
activation=$(cd "$repo_root" && nix eval --raw '.#homeConfigurations."markus@mbp2607".config.home.activation.paimosAgentdPrivateState.data')

python3 - "$agent_json" <<'PY'
import json, sys
agent = json.loads(sys.argv[1])
assert agent["enable"] is True, agent
config = agent["config"]
args = config["ProgramArguments"]
assert args[0].endswith("/bin/paimos-agentd"), args
expected_pairs = {
    "--instance": "ppm",
    "--state-root": "/Users/markus/Library/Caches/paimos/agentd",
    "--codex-path": "/Users/markus/.npm-global/bin/codex",
    "--claude-path": "/Users/markus/.npm-global/bin/claude",
}
for flag, value in expected_pairs.items():
    index = args.index(flag)
    assert args[index + 1] == value, (flag, args)
node_index = args.index("--node-path")
assert args[node_index + 1].endswith("/bin/node"), args
sdk_index = args.index("--claude-sdk-path")
assert args[sdk_index + 1].endswith("/lib/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs"), args
assert config["Label"] == "at.inspr.paimos-agentd", config
assert config["RunAtLoad"] is True and config["KeepAlive"] is True, config
assert config["ProcessType"] == "Background", config
assert config["StandardOutPath"] == "/Users/markus/Library/Logs/paimos-agentd/stdout.log", config
assert config["StandardErrorPath"] == "/Users/markus/Library/Logs/paimos-agentd/stderr.log", config
assert config.get("EnvironmentVariables") is None, config
PY

grep -Fq 'install -d -m 0700' <<<"$activation" || fail 'private state/log directory mode is not declared'
grep -Fq 'install -m 0600 /dev/null' <<<"$activation" || fail 'private log-file mode is not declared'

printf 'T56 passed: mbp2607 pins Paimos 5.21.0, agentd, and Claude SDK 0.3.251 with private launchd state\n'
