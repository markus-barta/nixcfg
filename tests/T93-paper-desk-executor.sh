#!/usr/bin/env bash
# OPS-266 paper desk executor: Stage-0 brakes, tailnet bind, no control plane.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
module="$repo_root/modules/paper-desk-executor"
nix_module="$module/default.nix"
host="$repo_root/hosts/hsb0/configuration.nix"
docs="$repo_root/hosts/hsb0/docs/IB-GATEWAY.md"

node --test --test-concurrency=2 "$module"/*.test.mjs

# Pure module evaluation with inert packages, never a NixOS build on macOS.
python3 - "$repo_root" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

fixture = Path(sys.argv[1]) / "tests/paper-desk-executor-eval.nix"

def evaluate(options):
    return subprocess.run(
        ["nix-instantiate", "--eval", "--strict", "--json", "--expr", f"import {fixture} {options}"],
        capture_output=True, text=True,
    )

default = evaluate("{}")
assert default.returncode == 0, default.stderr
assert json.loads(default.stdout) == {"reconRetentionHours": 48, "resultsHealthPort": 8472, "retentionEnvironment": ["PAPER_DESK_RECON_RETENTION_HOURS=48"]}
for port in ["8471", "8470", "8473"]:
    result = evaluate("{ resultsHealthPort = " + port + "; }")
    assert result.returncode != 0, port
    assert "loopback port 8472" in result.stderr, result.stderr
for hours in ["16.0 / 60.0", "0.33333333", "72", "336"]:
    result = evaluate("{ reconRetentionHours = " + hours + "; }")
    assert result.returncode == 0, result.stderr
    value = json.loads(result.stdout)
    assert len(value["retentionEnvironment"]) == 1
    supplied = float(value["retentionEnvironment"][0].split("=", 1)[1])
    assert 16 / 60 <= supplied <= 336, value
for hours in ["0", "-1", "0.25", "0.26666665", "337"]:
    result = evaluate("{ reconRetentionHours = " + hours + "; }")
    assert result.returncode != 0, hours
    assert "reconRetentionHours must be between 16/60 and 336 hours" in result.stderr, result.stderr
result = evaluate('{ reconRetentionHours = "invalid"; }')
assert result.returncode != 0
assert "reconRetentionHours" in result.stderr
for options in ['{ clientIds.executor = 709; }', '{ clientIds.recon = 709; }', '{ ownershipClientIds.j = [ 709 ]; }', '{ marketDataClientId = 709; }', '{ bookClientId = 709; }']:
    rejected = evaluate(options)
    assert rejected.returncode != 0, options
    assert "client" in rejected.stderr.lower(), rejected.stderr
print("JOED-20 reserved FX client 709 rejects executor, recon, legacy, market and book collisions")
print("OPS-331 retention module evaluation passed: default, 4 valid overrides, 5 bounds failures, invalid type")
PY

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
grep -Fq '"100.64.0.15"' "$nix_module"
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
