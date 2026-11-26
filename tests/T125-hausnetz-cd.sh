#!/usr/bin/env bash
# OPS-705: entirely offline, bounded PATH-fake transactions; never a Nix build.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 -B "$repo/tests/test_hausnetz_cd.py"
python3 -B "$repo/tests/test_hausnetz_cd.py" --mutants
for source in "$repo/modules/hausnetz-cd/default.nix" "$repo/hosts/mbp2607/hausnetz-cd.nix"; do
  nix-instantiate --parse "$source" >/dev/null
done
nix-instantiate --eval --strict --json "$repo/tests/hausnetz-cd-eval.nix" | python3 -c '
import json, sys
c = json.load(sys.stdin)
e, o = c["executorDefaults"], c["orchestratorDefaults"]
assert e["enable"] is False and e["allowLive"] is False
assert e["manifestPath"] is None and e["versionUrl"] is None and e["versionField"] is None
assert o["enable"] is False and o["mode"] == "dry-run"
assert o["manifestPath"] is None and o["releaseTicket"] is None
assert o["alarmCommand"] == [] and o["secondaryTelegramCommand"] == []
assert c["hostSettings"] == {"enable": True, "allowLive": False}
assert c["hostAssertion"] is True and c["otherHostAssertion"] is False
assert any(p.endswith("/modules/hausnetz-cd") for p in c["hostImports"])
assert any(p.endswith("/hosts/mbp2607/hausnetz-cd.nix") for p in c["homeImports"])
assert c["executorTmpfiles"] == ["d /var/lib/hausnetz-cd 0700 root root - -"]
assert c["agent"]["enable"] is False and c["agent"]["config"]["StartInterval"] == 120
executor = json.loads(c["executorRunner"]["text"].split("--config ", 1)[1])
assert executor["allow_live"] is False and executor["lock_file"] == "/run/hsb0-deploy.lock"
assert executor["manifest_path"] is None and executor["version_url"] is None
assert executor["version_field"] is None and executor["health_url"] is None
assert {"git", "nix", "curl", "python3", "systemd", "util-linux"}.issubset(c["executorRunner"]["runtimeInputs"])
assert "exec python3 -B /nix/store/" in c["executorRunner"]["text"]
orchestrator = json.loads(c["orchestratorRunner"]["text"].split("--config ", 1)[1])
assert orchestrator["enabled"] is False and orchestrator["mode"] == "dry-run"
assert orchestrator["target"] == "mba@hsb0.lan"
assert "exec python3 -B /nix/store/" in c["orchestratorRunner"]["text"]
print("T125 Nix module contracts: disabled timer, dry-run host and unset HNET-570 inputs passed")
'
printf 'T125 hausnetz CD: offline transactions and mutants passed\n'
