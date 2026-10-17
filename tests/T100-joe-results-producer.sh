#!/usr/bin/env bash
# JOED-20: pure synthetic producer tests + module evaluation; never builds/SSH.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node "$repo_root/modules/joe-results-producer/verify-contracts.mjs"
node --test --test-concurrency=2 "$repo_root/modules/joe-results-producer/"*.test.mjs
python3 - "$repo_root" <<'PY'
import json
import subprocess
import sys
from pathlib import Path
repo = Path(sys.argv[1])
fixture = repo / "tests/joe-results-producer-eval.nix"
def evaluate(options):
    return subprocess.run(["nix-instantiate", "--eval", "--strict", "--json", "--expr", f"import {fixture} {options}"], capture_output=True, text=True)
enabled = evaluate("{}")
assert enabled.returncode == 0, enabled.stderr
value = json.loads(enabled.stdout)
assert value["capture"] is True
assert value["captureKeep"] == ["SXR8", "TSLA"]
service = value["services"]["joe-results-producer"]["serviceConfig"]
assert service["Environment"] == ["JOE_RESULTS_INGRESS_ORIGIN=https://ingress.example.invalid"]
assert service["User"] == service["Group"] == "1000"
assert service["ProtectSystem"] == "strict"
assert service["NoNewPrivileges"] and service["PrivateDevices"] and service["ProtectHome"]
assert service["IPAddressDeny"] == ["any"]
assert service["IPAddressAllow"] == ["127.0.0.1/32", "192.0.2.10/32"]
assert service["ReadWritePaths"] == ["/var/lib/joe-results-producer"]
assert "/var/lib/paper-desk-executor" in service["BindReadOnlyPaths"]
assert "/var/lib/joe-board-pusher" not in service["BindReadOnlyPaths"]
assert service["CapabilityBoundingSet"] == ""
assert service["SupplementaryGroups"] == []
assert service["SocketBindDeny"] == ["any"]
assert service["LoadCredential"] == ["joe-board-push-token:/run/agenix/joe-board-push-token"]
assert "-/run/agenix" in service["InaccessiblePaths"]
assert "-/run/secrets" in service["InaccessiblePaths"]
assert "time-sync.target" in value["services"]["joe-results-producer"]["after"]
disabled = evaluate("{ enable = false; }")
assert disabled.returncode == 0, disabled.stderr
assert json.loads(disabled.stdout) == {"capture": False, "captureKeep": [], "services": {}}
extended = evaluate('{ keepSymbols = [ "SXR8" "TSLA" "ACME" ]; }')
assert extended.returncode == 0, extended.stderr
assert json.loads(extended.stdout)["captureKeep"] == ["SXR8", "TSLA", "ACME"]
for options in ['{ endpoint = "http://ingress.example.invalid/joe/inbox/results"; }', '{ endpoint = "https://ingress.example.invalid/joe/inbox"; }', '{ endpoint = "https://ingress.example.invalid/joe/inbox/results?token=bad"; }', '{ ingressAddress = "any"; }', '{ ingressAddress = "999.0.0.1"; }', '{ keepSymbols = [ "TSLA" ]; }']:
    rejected = evaluate(options)
    assert rejected.returncode != 0, options
host = (repo / "hosts/hsb0/configuration.nix").read_text()
mixed_case = evaluate('{ ingressHost = "Ingress.example.invalid"; endpoint = "https://Ingress.example.invalid/joe/inbox/results"; }')
assert mixed_case.returncode != 0, "mixed-case ingressHost must fail evaluation"
assert "lowercase ingressHost" in mixed_case.stderr, mixed_case.stderr
assert 'nixcfg.joeResultsProducer.enable = false;' in host
assert '../../modules/joe-results-producer' in host
print("JOED-20 enabled/disabled Nix evaluation and sandbox assertions passed (no build)")
PY
