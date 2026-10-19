#!/usr/bin/env bash
# JOED-43: pure service-spec evaluation; no builds, network or host operations.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$repo_root" <<'PY'
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
fixture = root / "tests/paper-desk-executor-eval.nix"

def evaluate(enabled):
    value = "true" if enabled else "false"
    result = subprocess.run(["nix-instantiate", "--eval", "--strict", "--json", "--expr",
        f"import {fixture} {{ tailnetContract = true; mailboxEnabled = {value}; }}"], text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)

enabled, disabled = evaluate(True), evaluate(False)
mount = "/run/agent-mailbox-local:/run/agent-mailbox-local:"
socket = "/run/agent-mailbox-local/sender/mailbox.sock"
assert mount + "ro" in enabled["executor"]["volumes"]
assert mount + "rw" in enabled["mailbox"]["volumes"]
assert f"PAPER_DESK_MAILBOX_SOCKET={socket}" in enabled["executor"]["environment"]
assert f"AGENT_MAILBOX_LOCAL_SOCKET={socket}" in enabled["mailbox"]["environment"]
identities = next(item.split("=", 1)[1] for item in enabled["mailbox"]["environment"] if item.startswith("AGENT_MAILBOX_IDENTITIES="))
assert json.loads(identities) == ["ops", "amy", "paper-desk-executor"]
assert "d /run/agent-mailbox-local 0750 root 1000 - -" in enabled["tmpfiles"]
assert "d /run/agent-mailbox-local/sender 0700 1000 1000 - -" in enabled["tmpfiles"]
assert disabled["mailbox"] is None
assert all("agent-mailbox-local" not in item for item in disabled["executor"]["volumes"])
assert all("MAILBOX_SOCKET" not in item for item in disabled["executor"]["environment"])
assert all("agent-mailbox-local" not in item for item in disabled["tmpfiles"])
assert enabled["staticExecutor"] == disabled["staticExecutor"] == ["100.64.0.14"]
assert enabled["staticMailbox"] == {"100.64.0.14": "ops"}
for service in [enabled["executor"], enabled["mailbox"], disabled["executor"]]:
    assert service["user"] == "1000:1000"
    assert service["read_only"] is True
    assert service["cap_drop"] == ["ALL"]
    assert service["network_mode"] == "host"
    assert "ports" not in service
    assert all("docker.sock" not in item for item in service["volumes"])
# Host composes exactly these module service specs; no extra socket consumer.
host = (root / "hosts/hsb0/configuration.nix").read_text()
assert 'services.paper-desk-executor = config.nixcfg.paperDeskExecutor.serviceSpec;' in host
assert 'services.agent-mailbox = config.nixcfg.agentMailbox.serviceSpec;' in host
consumers = [file for file in (root / "modules").rglob("*.nix") if "agent-mailbox-local:" in file.read_text()]
assert sorted(str(file.relative_to(root)) for file in consumers) == ["modules/agent-mailbox/default.nix", "modules/paper-desk-executor/default.nix"]
print("T110 passed: local send-only socket mounts, permissions, identity and mailbox-disabled fallback")
PY
