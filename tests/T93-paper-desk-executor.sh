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
grep -Fq 'peerRules "-I"' "$nix_module"
# shellcheck disable=SC2016
grep -Fq -- '-i tailscale0 -s ${peer}' "$nix_module"
grep -Fq '100.64.0.6' "$nix_module"
grep -Fq '8470' "$nix_module"
grep -Fq '"100.64.0.10"' "$nix_module"
# OPS-266 2026-10-07: the pre-rebuild Amy-box address is no longer admitted.
if grep -Fq '"100.64.0.9"' "$nix_module"; then exit 1; fi
grep -Fq '100.64.0.14' "$nix_module"
grep -Fq 'user = "1000:1000"' "$nix_module"
grep -Fq 'read_only = true' "$nix_module"
grep -Fq 'no-new-privileges:true' "$nix_module"
grep -Fq 'cap_drop = [ "ALL" ]' "$nix_module"
grep -Fq 'services.paper-desk-executor = config.nixcfg.paperDeskExecutor.serviceSpec' "$host"
grep -Fq '0700 1000 1000' "$nix_module"
grep -Fq 'extraGroups = lib.mkForce [ ]' "$nix_module"
if grep -Eq 'extraGroups.*docker|SupplementaryGroups.*docker|docker[.]sock|--user=0:0' "$nix_module"; then
  printf 'T93 failed: executor identity must not grant Docker or root access\n' >&2
  exit 1
fi
grep -Fq 'barta.paper-desk-intent.v2' "$module/policy.mjs"
grep -Fq 'KEEP.includes' "$module/ib.mjs"
grep -Fq 'orderRef: intent.orderRef' "$module/ib.mjs"
grep -Fq '## Paper desk executor' "$docs"
grep -Fq '/var/lib/paper-desk-executor/HALT' "$docs"
grep -Fq 'SXR8' "$docs"
grep -Fq 'TSLA' "$docs"

if grep -Fq '8470' "$host"; then
  printf 'T93 failed: port 8470 must not be added to the host-wide firewall list\n' >&2
  exit 1
fi
if grep -Fq 'globalCancel' "$module"/*.mjs; then
  printf 'T93 failed: executor must never use globalCancel\n' >&2
  exit 1
fi
if grep -Fq 'oc-workspace-shared' "$module"/*.mjs "$nix_module"; then
  printf 'T93 failed: GitHub control plane must stay out of the executor\n' >&2
  exit 1
fi
if grep -Eq 'age[.]secrets|githubToken|IB_DESK_GITHUB' "$nix_module"; then
  printf 'T93 failed: executor must not take a token or agenix secret\n' >&2
  exit 1
fi
if grep -Fq 'ConditionPathExists' "$nix_module"; then
  printf 'T93 failed: executor startup must not wait on a credential file\n' >&2
  exit 1
fi

printf 'T93 passed: paper desk executor brakes, tailnet bind and offline API tests are wired\n'
