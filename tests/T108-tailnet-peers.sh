#!/usr/bin/env bash
# OPS-384: pure module contract, no flake fetching, build, network or host access.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$repo_root" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
import tempfile
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
assert cfg["sync"]["serviceConfig"]["UMask"] == "0077"
assert "d /run/tailnet-peers 0710 root 1000 - -" in cfg["tmpfiles"]
assert "--notification-config /fixture/notification-config" in cfg["sync"]["serviceConfig"]["ExecStart"]
assert "LoadCredential" not in cfg["sync"]["serviceConfig"]
assert cfg["sync"]["wantedBy"] == ["tailscaled.service"]
assert cfg["serviceNames"] == ["tailnet-peer-sync"]
assert all(key not in cfg["sync"] for key in ["wants", "requires", "bindsTo", "partOf"])
for name, port in [("executor", 8470), ("mailbox", 8471)]:
    service = cfg[name]
    assert "/run/tailnet-peers:/run/tailnet-peers:ro" in service["volumes"]
    assert service["user"] == "1000:1000"
    assert service["read_only"] is True
    assert service["cap_drop"] == ["ALL"]
    assert service["security_opt"] == ["no-new-privileges:true"]
    assert service["network_mode"] == "host"
    assert service["pids_limit"] == 64
    assert "ports" not in service
    assert all("docker.sock" not in mount and "tailscale" not in mount for mount in service["volumes"])
    assert any("PEERS_FILE=/run/tailnet-peers/peers.json" in item for item in service["environment"])
    assert any(f"_PORT={port}" in item for item in service["environment"])
assert "PAPER_DESK_ADMIN_ALLOW=[\"100.64.0.14\"]" in cfg["executor"]["environment"]
assert "PAPER_DESK_RESULTS_CAPTURE=false" in cfg["executor"]["environment"]
assert cfg["executor"]["mem_limit"] == "384m"
assert cfg["mailbox"]["mem_limit"] == "256m"
assert 'AGENT_MAILBOX_DYNAMIC_IDENTITIES=["amy"]' in cfg["mailbox"]["environment"]
for prefix, port in [("paper-desk", 8470), ("agent-mailbox", 8471)]:
    rules = [line.strip() for line in cfg["firewall"].splitlines()
             if f"-A {prefix}-peers " in line]
    assert len(rules) == 5, rules
    assert rules[0].endswith("-s 100.64.0.14 -j RETURN"), rules
    assert rules[1].endswith(f"-j {prefix}-dyn"), rules
    assert "-m limit --limit 2/min --limit-burst 2 -j LOG" in rules[2], rules
    assert f'-m comment --comment "tailnet-refused-{port}" -j DROP' in rules[3], rules
    assert rules[4] == f"iptables -t raw -A {prefix}-peers -j DROP", rules
    assert f"-I nixos-fw -j {prefix}-dyn-fw" in cfg["firewall"]
assert cfg["firewall"].rstrip().endswith("--no-block start tailnet-peer-sync.service || true")
for script in [cfg["firewall"], cfg["firewallStop"]]:
    assert script.count("/fixture/coreutils/bin/mkdir -p /run/lock || true") == 2
    assert script.count('/fixture/util-linux/bin/flock -w 30 -x 9 || echo') == 2
    assert script.count(') 9>/run/lock/tailnet-peer-sync.lock || echo') == 2
    # Execute the rendered hooks under sh -e with injected mkdir, flock,
    # iptables and systemctl failures. No host firewall or /run writes.
    (root / "tests/.tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=root / "tests/.tmp") as temporary:
        lockdir = Path(temporary) / "lockdir"
        for missing in [False, True]:
            if not missing:
                lockdir.mkdir()
            safe = script.replace("/run/lock", str(lockdir))
            safe = safe.replace("/fixture/coreutils/bin/mkdir", "false")
            safe = safe.replace("/fixture/util-linux/bin/flock", "false")
            safe = safe.replace("/fixture/systemd/bin/systemctl", "false")
            safe = safe.replace("iptables", "false")
            checked = subprocess.run(["sh", "-e", "-c", safe + "\necho firewall-completed"],
                                     text=True, capture_output=True)
            assert checked.returncode == 0, checked.stderr
            assert "firewall-completed" in checked.stdout
            if not missing:
                (lockdir / "tailnet-peer-sync.lock").unlink()
                lockdir.rmdir()
source = (root / "modules/tailnet-peers/default.nix").read_text()
script = (root / "modules/tailnet-peers/sync.py").read_text()
# Tool paths are substituted into sync.py at build time; the settings JSON carries data only,
# so no configured value can reach subprocess argv (CodeQL py/command-line-injection).
assert source.index('cp ${./sync.py} "$out/sync.py"') < source.index('substituteInPlace "$out/sync.py"')
for placeholder, binary in [("@tailscale@", "${pkgs.tailscale}/bin/tailscale"),
                            ("@iptablesRestore@", "${config.networking.firewall.package}/bin/iptables-restore"),
                            ("@iptablesSave@", "${config.networking.firewall.package}/bin/iptables-save"),
                            ("@docker@", "${config.virtualisation.docker.package}/bin/docker")]:
    assert f"--replace-fail '{placeholder}' '{binary}'" in source, placeholder
    assert script.count(f'"{placeholder}"') == 1, placeholder
for key in ["tailscale", "restore", "save", "docker", "iptables"]:
    assert f"{key} = " not in source.split("builtins.toJSON", 1)[1].split("trigger =", 1)[0], key
assert 'cfg["tailscale"]' not in script and 'cfg["restore"]' not in script
assert 'cfg["save"]' not in script and 'cfg["docker"]' not in script
assert "require_tools()" in script.split("def main():", 1)[1].split("with open(", 1)[0]
for folder in ["modules/paper-desk-executor", "modules/agent-mailbox"]:
    source = (root / folder / "default.nix").read_text()
    assert source.index('cp ${./server.mjs} "$out/server.mjs"') < source.index("substituteInPlace")
    for path in (root / folder).rglob("*"):
        if path.is_file():
            text = path.read_text()
            assert all(pin not in text for pin in ["100.64.0.15", "100.64.0.10", "100.64.0.9"]), path
print("T108 passed: dynamic identity, read-only snapshots, timers/triggers, refusal alerts and unchanged container hardening")
PY
