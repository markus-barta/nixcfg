#!/usr/bin/env bash
# OPS-384: pure module contract, no flake fetching, build, network or host access.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$repo_root" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
root = Path(sys.argv[1])
fixture = root / "tests/paper-desk-executor-eval.nix"
result = subprocess.run(["nix-instantiate", "--eval", "--strict", "--json",
                         "--expr", f"import {fixture} {{ tailnetContract = true; }}"],
                        text=True, capture_output=True)
assert result.returncode == 0, result.stderr
cfg = json.loads(result.stdout)
assert cfg["staticExecutor"] == ["100.64.0.14"]
assert cfg["staticMailbox"] == {"100.64.0.14": "ops"}
assert cfg["rules"] == [{"tag": "tag:paper-desk", "host": "grok-amy-box", "identity": "amy"}]
assert cfg["timer"]["timerConfig"]["OnUnitActiveSec"] == "30s"
assert cfg["sync"]["after"] == ["tailscaled.service", "firewall.service"]
assert cfg["sync"]["serviceConfig"]["User"] == "root"
assert cfg["sync"]["serviceConfig"]["LoadCredential"] == ["destinations.json:/fixture/notification-config"]
for name in ["tailscaled", "firewallService"]:
    assert "--no-block start tailnet-peer-sync.service" in cfg[name]["postStart"]
for name, port in [("executor", 8470), ("mailbox", 8471)]:
    service = cfg[name]
    assert "/run/tailnet-peers:/tailnet-peers:ro" in service["volumes"]
    assert service["user"] == "1000:1000"
    assert service["read_only"] is True
    assert service["cap_drop"] == ["ALL"]
    assert service["security_opt"] == ["no-new-privileges:true"]
    assert service["network_mode"] == "host"
    assert service["pids_limit"] == 64
    assert "ports" not in service
    assert all("docker.sock" not in mount and "tailscale" not in mount for mount in service["volumes"])
    assert any("PEERS_FILE=/tailnet-peers/peers.json" in item for item in service["environment"])
    assert any(f"_PORT={port}" in item for item in service["environment"])
assert "PAPER_DESK_ADMIN_ALLOW=[\"100.64.0.14\"]" in cfg["executor"]["environment"]
assert "PAPER_DESK_RESULTS_CAPTURE=false" in cfg["executor"]["environment"]
assert cfg["executor"]["mem_limit"] == "384m"
assert cfg["mailbox"]["mem_limit"] == "256m"
for prefix, port in [("paper-desk", 8470), ("agent-mailbox", 8471)]:
    assert f"-A {prefix}-peers -j {prefix}-dyn" in cfg["firewall"]
    assert f'-m comment --comment "tailnet-refused-{port}" -j DROP' in cfg["firewall"]
    assert "-m limit --limit 2/min --limit-burst 2 -j LOG" in cfg["firewall"]
    assert f"-s 100.64.0.14 -j RETURN" in cfg["firewall"]
    assert f"-I nixos-fw -j {prefix}-dyn-fw" in cfg["firewall"]
assert cfg["firewall"].rstrip().endswith("--no-block start tailnet-peer-sync.service")
for folder in ["modules/paper-desk-executor", "modules/agent-mailbox"]:
    source = (root / folder / "default.nix").read_text()
    assert source.index('cp ${./server.mjs} "$out/server.mjs"') < source.index("substituteInPlace")
    for path in (root / folder).rglob("*"):
        if path.is_file():
            text = path.read_text()
            assert all(pin not in text for pin in ["100.64.0.15", "100.64.0.10", "100.64.0.9"]), path
print("T106 passed: dynamic identity, read-only snapshots, timers/triggers, refusal alerts and unchanged container hardening")
PY
