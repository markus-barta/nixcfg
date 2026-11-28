#!/usr/bin/env bash
# OPS-705: entirely offline, bounded PATH-fake transactions; never a Nix build.
set -euo pipefail
started=$SECONDS
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
phase_started=$SECONDS
phase_done() {
  printf 'T125 phase %s: %s seconds\n' "$1" "$((SECONDS - phase_started))"
  phase_started=$SECONDS
}
python3 -B "$repo/tests/test_hausnetz_cd_adapter.py"
phase_done adapter-tests
python3 -B "$repo/tests/test_hausnetz_cd_adapter.py" --mutants
phase_done adapter-mutants
python3 -B "$repo/tests/test_hsb0_deploy_lock.py"
phase_done deploy-lock-tests
python3 -B "$repo/tests/test_hausnetz_cd.py"
phase_done transaction-cases
python3 -B "$repo/tests/test_hausnetz_cd.py" --mutants
phase_done transaction-mutants
python3 -B "$repo/tests/test_hausnetz_cd_mutant_pool.py"
phase_done mutant-pool-controls
for source in "$repo/modules/hausnetz-cd/default.nix" "$repo/hosts/mbp2607/hausnetz-cd.nix" "$repo/hosts/csb1/hausnetz-cd-alert.nix" "$repo/hosts/mbp2607/ci-vm.nix"; do
  nix-instantiate --parse "$source" >/dev/null
done
nix-instantiate --eval --strict --json "$repo/tests/hausnetz-cd-eval.nix" | python3 -c '
import json, sys
c = json.load(sys.stdin)
e, o = c["executorDefaults"], c["orchestratorDefaults"]
assert e["enable"] is False and e["allowLive"] is False
assert e["requireReadyz"] is True
assert not {"manifestPath", "versionUrl", "versionField", "healthUrl"}.intersection(e)
assert o["enable"] is False and o["mode"] == "dry-run"
assert "manifestPath" not in o and o["releaseTicket"] is None
assert o["alarmTicket"] is None
assert all(c["alarmTicketChecks"]["valid"]) and not any(c["alarmTicketChecks"]["invalid"])
assert c["homeAlarmTicket"] == "OPS-705" and c["homeReleaseTicket"] == "HNET-570"
assert o["alarmCommand"] == [] and o["secondaryTelegramCommand"]
assert o["acceptanceCommand"] == [] and o["acceptanceUrl"] == ""
assert o["acceptanceTimeout"] == 600 and o["attendedAckMinutes"] == 30
assert o["vmTestWaitTimeout"] == 1800
assert not {"agentsHost", "agentsPort"}.intersection(o)
assert o["mailboxRemoteFile"] == "/fixture/home/.config/inspr/mbx-remote"
assert o["localMailboxCommand"] == "/fixture/home/.local/bin/mbx"
assert c["hostSettings"] == {"enable": True, "allowLive": True}
h = c["homeSettings"]
assert h["enable"] is True and h["mode"] == "live"
assert h["acceptanceUrl"] == "http://192.168.1.99/"
assert h["acceptanceCommand"] == ["/fixture/runner/bin/hausnetz-cd-acceptance", "{trusted_rev}", "{url}", "{version}", "{caps_sha256}"]
live = json.loads(c["liveSettings"])
assert c["liveAgent"]["enable"] is True and live["enabled"] is True and live["mode"] == "live"
assert live["acceptance_command"] == h["acceptanceCommand"]
assert live["acceptance_url"] == json.loads(c["liveAdapterSettings"])["acceptance_url"] == h["acceptanceUrl"]
a = c["adapterRunner"]
aset = json.loads(a["settings"])
assert aset["cache_dir"] == "/fixture/home/.local/share/hausnetz-cd"
assert 0 < aset["timeout"] < aset["budget"] < o["acceptanceTimeout"]
assert aset["ci_vm"] == "/fixture/ci-vm/bin/ci-vm"
assert aset["colima"] == "colima/bin/colima"
assert {"colima", "git", "openssh", "coreutils", "python3"}.issubset(a["runtimeInputs"])
assert "COLIMA_HOME" in a["text"] and "PYTHONPATH" in a["text"]
assert "@CONFIG@" not in a["entrypoint"] and "@GUEST@" not in a["entrypoint"]
compile(a["entrypoint"], "adapter", "exec")
assert c["hostAssertion"] is True and c["otherHostAssertion"] is False
assert any(p.endswith("/modules/hausnetz-cd") for p in c["hostImports"])
assert any(p.endswith("/hosts/mbp2607/hausnetz-cd.nix") for p in c["homeImports"])
assert c["executorTmpfiles"] == ["d /var/lib/hausnetz-cd 0700 root root - -",
                                  "f /run/hsb0-deploy.lock 0644 root root -"]
assert c["agent"]["enable"] is False and c["agent"]["config"]["StartInterval"] == 120
executor = json.loads(c["executorRunner"]["settings"])
assert executor["allow_live"] is False and executor["lock_file"] == "/run/hsb0-deploy.lock"
assert executor["require_readyz"] is True
assert not {"manifest_path", "version_url", "version_field", "health_url"}.intersection(executor)
assert {"git", "selected-nix", "curl", "python3", "systemd", "util-linux"}.issubset(c["executorRunner"]["runtimeInputs"])
assert "nix" not in c["executorRunner"]["runtimeInputs"]
assert "exec python3 -B /fixture/hausnetz-cd-execute.py" in c["executorRunner"]["text"]
assert "CONFIG_FILE = " + json.dumps("/fixture/hausnetz-cd-executor.json") in c["executorRunner"]["entrypoint"]
orchestrator = json.loads(c["orchestratorRunner"]["settings"])
assert orchestrator["enabled"] is False and orchestrator["mode"] == "dry-run"
assert orchestrator["alarm_ticket"] is None and orchestrator["release_ticket"] is None
assert orchestrator["target"] == "mba@hsb0.lan"
assert orchestrator["acceptance_command"] == [] and orchestrator["acceptance_url"] == ""
assert orchestrator["acceptance_timeout"] == 600 and orchestrator["attended_ack_minutes"] == 30
assert orchestrator["vm_test_wait_timeout"] == 1800
assert "selected-nix" in c["orchestratorRunner"]["runtimeInputs"]
assert "gh" in c["orchestratorRunner"]["runtimeInputs"]
assert not {"agents_host", "agents_port"}.intersection(orchestrator)
assert orchestrator["mailbox_remote_file"] == o["mailboxRemoteFile"]
assert orchestrator["local_mailbox_command"] == o["localMailboxCommand"]
assert orchestrator["secondary_telegram_command"][-2:] == ["mba@csb1", "sudo -n /run/current-system/sw/bin/hausnetz-cd-alert"]
assert "exec python3 -B /fixture/hausnetz-cd-orchestrate.py" in c["orchestratorRunner"]["text"]
assert "CONFIG_FILE = " + json.dumps("/fixture/hausnetz-cd-orchestrator.json") in c["orchestratorRunner"]["entrypoint"]
for name in ("executorRunner", "orchestratorRunner"):
    assert "--config" not in c[name]["text"]
    assert "add_argument(" + json.dumps("--config") not in c[name]["entrypoint"]
    assert "@CONFIG@" not in c[name]["entrypoint"]
    compile(c[name]["entrypoint"], name, "exec")
print("T125 Nix module contracts: safe module defaults, live host opt-ins, packaged adapter, selected Nix passed")
'
phase_done nix-checks
printf 'T125 hausnetz CD: offline transactions and mutants passed\n'
printf 'T125 elapsed: %s seconds\n' "$((SECONDS - started))"
