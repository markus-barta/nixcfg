#!/usr/bin/env bash
# OPS-307: fixtures + real engine + csb1 module/full-flake evaluation; never build.
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
  discover -s "${repo}/tests" -p 'test_aeon_watch_checks.py' -v
PYTHONDONTWRITEBYTECODE=1 python3 "${repo}/tests/test_fleet_alerts_engine.py"
nix-instantiate --parse "${repo}/hosts/csb1/aeon-watch.nix" >/dev/null

PYTHONDONTWRITEBYTECODE=1 python3 - "$repo" "$mode" <<'PY'
import json
from pathlib import Path
import subprocess
import sys

repo = Path(sys.argv[1])

def evaluate(expression, check=True):
    result = subprocess.run(
        ["nix-instantiate", "--eval", "--strict", "--json", "--expr", expression],
        cwd=repo, text=True, capture_output=True,
    )
    if check and result.returncode:
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)
    return result

def verify(cfg, credential_source):
    assert cfg["tenant"] == "0000a0e7000040008000000000000307"
    service, timer = cfg["service"], cfg["timer"]
    unit = service["serviceConfig"]
    assert unit["Type"] == "oneshot"
    assert unit["ExecStart"].endswith("/checks.py")
    assert unit["StateDirectory"] == "aeon-watch"
    assert unit["StateDirectoryMode"] == "0700"
    assert unit["SuccessExitStatus"] == [0, 1]
    assert unit["DynamicUser"] is True
    assert unit["SupplementaryGroups"] == ["docker"]
    assert unit["LoadCredential"] == ["notification-env:" + credential_source]
    assert "EnvironmentFile" not in unit
    assert unit["CapabilityBoundingSet"] == ""
    for key in ["PrivateTmp", "PrivateDevices", "ProtectHome", "ProtectKernelTunables", "ProtectKernelModules",
                "ProtectControlGroups", "NoNewPrivileges", "LockPersonality", "RestrictRealtime", "RestrictSUIDSGID"]:
        assert unit[key] is True, key
    assert unit["ProtectSystem"] == "strict"
    assert unit["RestrictAddressFamilies"] == ["AF_UNIX", "AF_INET", "AF_INET6"]
    assert unit["SystemCallArchitectures"] == "native"
    assert unit["TimeoutStartSec"] == "90"
    assert "docker.service" in service["after"]
    assert "network-online.target" in service["wants"]
    assert timer["wantedBy"] == ["timers.target"]
    assert timer["timerConfig"] == {"OnBootSec": "120s", "OnUnitActiveSec": "30s",
                                    "AccuracySec": "1s", "Unit": "aeon-watch.service"}

fixture = 'import ./tests/aeon-watch-eval.nix '
cfg = json.loads(evaluate(fixture + '{}').stdout)
verify(cfg, "/fixture/notification-target")
assert cfg["rendered"] == "/fixture/python3/bin/python3 /fixture/aeon-watch/checks.py"
override = "abcdef0123456789abcdef0123456789"
assert json.loads(evaluate(fixture + '{ probeTenant = "' + override + '"; }').stdout)["tenant"] == override
for invalid in ["", "bad", '"; invalid python', "5d32191b-252c-4ef4-a406-788316a5ccb7"]:
    result = evaluate(fixture + '{ probeTenant = ' + json.dumps(invalid) + '; }', check=False)
    assert result.returncode != 0, "unsafe tenant accepted"
print("csb1 imported aeon-watch module evaluation: ok")

if sys.argv[2] == "--module-only":
    print("Full csb1 flake evaluation explicitly omitted (--module-only).")
else:
    # Full NixOS configuration evaluation only: no derivations are built.
    projection = '''system: {
      tenant = system.config.aeonWatch.probeTenant;
      service = {
        inherit (system.config.systemd.services.aeon-watch) serviceConfig after wants;
      };
      timer = {
        inherit (system.config.systemd.timers.aeon-watch) timerConfig wantedBy;
      };
    }'''
    result = subprocess.run(
        ["nix", "eval", "--no-write-lock-file", "--json", str(repo) + "#nixosConfigurations.csb1",
         "--apply", projection], text=True, capture_output=True,
    )
    if result.returncode:
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)
    verify(json.loads(result.stdout), "/run/agenix/csb1-watchtower-env")
    print("Full csb1 aeon-watch service/timer evaluation: ok")
PY

if [ "$mode" = full ]; then
  echo "T96 ok"
else
  echo "T96 module-only checks ok; full flake evaluation remains required"
fi
