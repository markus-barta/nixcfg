#!/usr/bin/env bash
# T56 — NIX-584: classic workstation Paimos (paimos-legacy CLI + paimos-agentd) is retired.
set -euo pipefail

repo_root=$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  printf 'T56 failed: %s\n' "$*" >&2
  exit 1
}

[[ ! -e "$repo_root/pkgs/paimos-cli/default.nix" ]] || fail 'pkgs/paimos-cli must not return'
[[ ! -e "$repo_root/modules/uzumaki/paimos-agentd.nix" ]] || fail 'paimos-agentd.nix must not return'

if grep -Fq 'paimos-legacy' "$repo_root/flake.nix"; then
  fail 'flake.nix still references paimos-legacy'
fi
if grep -Fq 'paimos-cli =' "$repo_root/flake.nix"; then
  fail 'flake.nix still packages paimos-cli'
fi

if grep -Fq 'paimos-classic' "$repo_root/modules/uzumaki/aeon.nix"; then
  fail 'classic paimos wrapper must not remain in aeon.nix'
fi
if grep -Fq './paimos-agentd.nix' "$repo_root/modules/uzumaki/home-manager.nix"; then
  fail 'home-manager.nix must not import paimos-agentd'
fi
if grep -Fq 'inspr.paimos-cli' "$repo_root/modules/shared/markus-defaults.nix" \
  "$repo_root/hosts/mbp2607/home.nix" "$repo_root/hosts/mbp2606/home.nix"; then
  fail 'inspr.paimos-cli must not remain in workstation defaults or homes'
fi
if grep -Fq 'paimosAgentd' "$repo_root/hosts/mbp2607/home.nix"; then
  fail 'mbp2607 must not enable classic paimosAgentd'
fi

# Live mbp2607: Aeon agentd stays; classic launchd agent is gone; paimos is Aeon.
aeon_json=$(cd "$repo_root" && nix eval --json '.#homeConfigurations."markus@mbp2607".config.launchd.agents.aeon-agentd')
python3 - "$aeon_json" <<'PY'
import json, sys
agent = json.loads(sys.argv[1])
assert agent.get("enable") is True, agent
config = agent["config"]
assert config["Label"] == "at.inspr.aeon-agentd", config
args = config["ProgramArguments"]
assert args[0].endswith("/bin/aeon-agentd"), args
assert args[1] == "serve", args
PY

has_classic=$(cd "$repo_root" && nix eval --json '.#homeConfigurations."markus@mbp2607".config.launchd.agents' --apply 'agents: agents ? paimos-agentd')
[[ "$has_classic" == "false" ]] || fail "classic paimos-agentd launchd agent is still present ($has_classic)"

alias_default=$(cd "$repo_root" && nix eval --json '.#homeConfigurations."markus@mbp2607".config.uzumaki.aeon.cli.paimosAlias')
[[ "$alias_default" == "true" ]] || fail "paimosAlias must default on, got $alias_default"

printf 'T56 passed: classic paimos-cli/agentd retired; aeon-agentd and paimos alias remain\n'
