#!/usr/bin/env bash
# OPS-266 paper desk executor: Stage-0 brakes, tailnet bind, no control plane.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
module="$repo_root/modules/paper-desk-executor"
nix_module="$module/default.nix"
host="$repo_root/hosts/hsb0/configuration.nix"
docs="$repo_root/hosts/hsb0/docs/IB-GATEWAY.md"

node --test "$module"/*.test.mjs

grep -Fq 'nixcfg.paperDeskExecutor.enable = true' "$host"
grep -Fq '../../modules/paper-desk-executor' "$host"
# The ${} is Nix interpolation in the module source, not a shell expansion.
# shellcheck disable=SC2016
grep -Fq 'IB_DESK_GATEWAY_PORT=${toString cfg.gatewayPort}' "$nix_module"
grep -Fq 'TRADING_MODE=paper' "$nix_module"
grep -Fq 'live port 4001 is refused' "$nix_module"
grep -Fq 'networking.firewall.interfaces.tailscale0.allowedTCPPorts' "$nix_module"
grep -Fq '100.64.0.6' "$nix_module"
grep -Fq '8470' "$nix_module"
grep -Fq '100.64.0.9' "$nix_module"
grep -Fq '100.64.0.14' "$nix_module"
grep -Fq 'User = "paper-desk-executor"' "$nix_module"
grep -Fq 'ProtectSystem = "strict"' "$nix_module"
grep -Fq 'NoNewPrivileges = true' "$nix_module"
grep -F -q -e '--cap-drop=ALL' "$nix_module"
grep -Fq 'barta.paper-desk-intent.v2' "$module/policy.mjs"
grep -Fq 'KEEP.includes' "$module/ib.mjs"
grep -Fq 'orderRef: intent.intentId' "$module/ib.mjs"
grep -Fq '## Paper desk executor' "$docs"
grep -Fq '/var/lib/paper-desk-executor/HALT' "$docs"
grep -Fq 'SXR8' "$docs"
grep -Fq 'TSLA' "$docs"

if grep -Fq '8470' "$host"; then
  printf 'T92 failed: port 8470 must not be added to the host-wide firewall list\n' >&2
  exit 1
fi
if grep -Fq 'globalCancel' "$module"/*.mjs; then
  printf 'T92 failed: executor must never use globalCancel\n' >&2
  exit 1
fi
if grep -Fq 'oc-workspace-shared' "$module"/*.mjs "$nix_module"; then
  printf 'T92 failed: GitHub control plane must stay out of the executor\n' >&2
  exit 1
fi
if grep -Eq 'age[.]secrets|githubToken|IB_DESK_GITHUB' "$nix_module"; then
  printf 'T92 failed: executor must not take a token or agenix secret\n' >&2
  exit 1
fi
if grep -Fq 'ConditionPathExists' "$nix_module"; then
  printf 'T92 failed: executor startup must not wait on a credential file\n' >&2
  exit 1
fi

printf 'T92 passed: paper desk executor brakes, tailnet bind and offline API tests are wired\n'
