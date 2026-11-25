#!/usr/bin/env bash
# OPS-675: fixtures, must-fail content mutant and Nix evaluation; never build.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-full}"
case "$mode" in
full | --module-only) ;;
*)
  printf 'usage: %s [--module-only]\n' "$0" >&2
  exit 2
  ;;
esac

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  discover -s "${repo}/tests" -p 'test_hausvogt_health_watch.py' -v
PYTHONDONTWRITEBYTECODE=1 python3 "${repo}/tests/test_hausvogt_health_watch.py" --marker-mutant
PYTHONDONTWRITEBYTECODE=1 python3 "${repo}/tests/test_fleet_alerts_engine.py"
nix-instantiate --parse "${repo}/hosts/csb1/hausvogt-health-watch.nix" >/dev/null

PYTHONDONTWRITEBYTECODE=1 python3 - "$repo" "$mode" <<'PY'
import json
from pathlib import Path
import subprocess
import sys

repo = Path(sys.argv[1])

def verify(cfg, credential_source):
    service, timer = cfg["service"], cfg["timer"]
    unit = service["serviceConfig"]
    assert unit["Type"] == "oneshot"
    assert unit["ExecStart"].endswith("/checks.py")
    assert unit["StateDirectory"] == "hausvogt-health-watch"
    assert unit["StateDirectoryMode"] == "0700"
    assert unit["SuccessExitStatus"] == [0, 1]
    assert unit["DynamicUser"] is True
    assert unit["LoadCredential"] == ["notification-env:" + credential_source]
    assert "EnvironmentFile" not in unit
    assert not unit.get("SupplementaryGroups")
    assert unit["CapabilityBoundingSet"] == ""
    for key in ["PrivateTmp", "PrivateDevices", "ProtectHome", "ProtectKernelTunables", "ProtectKernelModules",
                "ProtectControlGroups", "NoNewPrivileges", "LockPersonality", "RestrictRealtime", "RestrictSUIDSGID"]:
        assert unit[key] is True, key
    assert unit["ProtectSystem"] == "strict"
    assert unit["RestrictAddressFamilies"] == ["AF_UNIX", "AF_INET", "AF_INET6"]
    assert unit["SystemCallArchitectures"] == "native"
    assert unit["TimeoutStartSec"] == "90"
    assert service["after"] == ["network-online.target"]
    assert service["wants"] == ["network-online.target"]
    assert timer["wantedBy"] == ["timers.target"]
    assert timer["timerConfig"] == {"OnBootSec": "2m", "OnUnitActiveSec": "5m",
                                    "RandomizedDelaySec": "30s", "Unit": "hausvogt-health-watch.service"}

result = subprocess.run(
    ["nix-instantiate", "--eval", "--strict", "--json", "./tests/hausvogt-health-watch-eval.nix"],
    cwd=repo, text=True, capture_output=True,
)
if result.returncode:
    sys.stderr.write(result.stderr)
    raise SystemExit(result.returncode)
verify(json.loads(result.stdout), "/fixture/notification-target")
print("csb1 imported Hausvogt watch module evaluation: ok")

if sys.argv[2] == "--module-only":
    print("Full csb1 flake evaluation explicitly omitted (--module-only).")
else:
    projection = '''system: {
      service = {
        inherit (system.config.systemd.services.hausvogt-health-watch) serviceConfig after wants;
      };
      timer = {
        inherit (system.config.systemd.timers.hausvogt-health-watch) timerConfig wantedBy;
      };
    }'''
    result = subprocess.run(
        ["nix", "eval", "--json", "--no-write-lock-file", str(repo) + "#nixosConfigurations.csb1",
         "--apply", projection], text=True, capture_output=True,
    )
    if result.returncode:
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)
    verify(json.loads(result.stdout), "/run/agenix/csb1-watchtower-env")
    print("Full csb1 Hausvogt watch service/timer evaluation: ok")
PY

if [ "$mode" = full ]; then
  echo "T124 ok"
else
  echo "T124 module-only checks ok; full flake evaluation remains required"
fi
