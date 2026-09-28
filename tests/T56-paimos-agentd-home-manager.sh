#!/usr/bin/env bash
# T56 — NIX-584: classic paimos-agentd is retired; paimos is Aeon.
# paimos-classic (paimos-legacy CLI) stays only for pma until this evening.
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash %s is too old -- set -e does not abort on a failing [[ ]], so this test would FALSELY PASS. Run under bash 5: nix run nixpkgs#bash -- %s\n' \
    "${0##*/}" "$BASH_VERSION" "$0" >&2
  exit 2
fi

repo_root=$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  printf 'T56 failed: %s\n' "$*" >&2
  exit 1
}

[[ -e "$repo_root/pkgs/paimos-cli/default.nix" ]] || fail 'pkgs/paimos-cli must remain for pma until tonight'
[[ ! -e "$repo_root/modules/uzumaki/paimos-agentd.nix" ]] || fail 'paimos-agentd.nix must not return'

grep -Fq 'paimos-legacy' "$repo_root/flake.nix" || fail 'flake.nix must keep the paimos-legacy input for pma'
grep -Fq 'paimos-cli =' "$repo_root/flake.nix" || fail 'flake.nix must still package paimos-cli for pma'
grep -Fq 'paimos-classic' "$repo_root/modules/uzumaki/aeon.nix" ||
  fail 'aeon.nix must keep the paimos-classic wrapper for pma'
for f in \
  "$repo_root/flake.nix" \
  "$repo_root/pkgs/paimos-cli/default.nix" \
  "$repo_root/modules/uzumaki/aeon.nix" \
  "$repo_root/modules/uzumaki/macos-common.nix"; do
  grep -Fq 'NIX-584: kept only for pma until it moves to Aeon (evening 2026-09-28); remove in the follow-up' "$f" ||
    fail "$f must carry the NIX-584 evening-removal comment"
done

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

has_wrapper=$(cd "$repo_root" && nix eval --json '.#homeConfigurations."markus@mbp2607".config.home.packages' --apply 'ps: builtins.any (p: (p.name or "") == "paimos-classic") ps')
[[ "$has_wrapper" == "true" ]] || fail "paimos-classic must be installed on mbp2607, got $has_wrapper"

printf 'T56 passed: classic agentd retired; paimos is Aeon; paimos-classic remains for pma\n'
