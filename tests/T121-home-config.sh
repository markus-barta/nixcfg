#!/usr/bin/env bash
# OPS-158: real scanner/Git fixtures, must-fail mutants, scoped + full host eval.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-full}"
case "$mode" in
full | --module-only | --local-only) ;;
*)
  printf 'usage: %s [--module-only|--local-only]\n' "$0" >&2
  exit 2
  ;;
esac

export PYTHONDONTWRITEBYTECODE=1
python3 "${repo}/tests/test_home_config.py"
python3 "${repo}/tests/test_home_config.py" --mutants
nix-instantiate --parse "${repo}/hosts/hsb1/home-config.nix" >/dev/null
nix-instantiate --parse "${repo}/tests/home-config-eval.nix" >/dev/null

if [ "$mode" = "--local-only" ]; then
  printf 'T121: fixtures and mutants passed; scoped/full evaluation explicitly omitted (required before release)\n'
  exit 0
fi

python3 - "$repo" "$mode" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

repo = Path(sys.argv[1])
source = os.environ.get("HOME_CONFIG_TEST_NIXPKGS")


def evaluate(full_host):
    expression = "import ./tests/home-config-eval.nix { fullHost = " + ("true" if full_host else "false") + ";"
    if source:
        expression += " nixpkgs = builtins.toPath " + json.dumps(source) + ";"
    expression += " }"
    result = subprocess.run(["nix", "eval", "--offline", "--no-write-lock-file", "--option", "allow-import-from-derivation", "false",
                             "--impure", "--json", "--expr", expression],
                            cwd=repo, capture_output=True, text=True)
    if result.returncode:
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)
    return json.loads(result.stdout)


def verify(result):
    unit = result["service"]["serviceConfig"]
    destination = "/home/mba/home-config"
    nr = "/home/mba/docker/mounts/nodered/data"
    ha = "/home/mba/docker/mounts/homeassistant"
    assert unit["Type"] == "oneshot"
    assert unit["User"] == "root" and unit["Group"] == "home-config"
    assert unit["UMask"] == "0027" and unit["RuntimeDirectoryMode"] == "0700"
    assert unit["ProtectHome"] == "read-only" and unit["ProtectSystem"] == "strict"
    assert set(unit["ReadWritePaths"]) == {destination, "/run/hsb1-home-config"}
    assert set(unit["ReadOnlyPaths"]) == {nr, ha}
    assert unit["PrivateNetwork"] is True and unit["IPAddressDeny"] == "any"
    assert unit["RestrictAddressFamilies"] == ["AF_UNIX"]
    assert unit["CapabilityBoundingSet"] == ["CAP_DAC_READ_SEARCH"]
    assert unit["Nice"] == 19 and unit["IOSchedulingClass"] == "idle"
    assert unit["TimeoutStartSec"] == "10min"
    assert result["service"]["restartIfChanged"] is False
    assert "systemd-tmpfiles-setup.service" in result["service"]["after"]
    assert unit["ExecStart"].endswith("/bin/hsb1-home-config")
    assert set(result["service"]["mounts"]) == {destination, nr, ha}
    assert not any("docker" in name or "compose" in name for name in result["service"]["wants"])
    paths = set(result["pathConfig"]["PathChanged"])
    for name in (nr, nr + "/flows.json", nr + "/settings.js", ha, ha + "/configuration.yaml", ha + "/automations.yaml"):
        assert name in paths, name
    assert ha + "/.storage" not in paths, "unrelated storage writes must not trigger snapshots"
    assert destination not in paths
    assert result["pathConfig"]["Unit"] == "hsb1-home-config.service"
    assert result["timerConfig"]["OnBootSec"] == "2min"
    assert result["timerConfig"]["OnUnitInactiveSec"] == "15min"
    assert result["timerConfig"]["Unit"] == "hsb1-home-config.service"
    assert "mba" in result["readers"]
    assert "[safe]" in result["readerConfig"] and "directory = " + json.dumps(destination) in result["readerConfig"]
    assert "d " + destination + " 2750 root home-config - -" in result["tmpfiles"]
    gc = result["maintenance"]["serviceConfig"]
    assert gc["ExecStart"].endswith("/bin/hsb1-home-config --gc")
    assert gc["TimeoutStartSec"] == "30min" and gc["PrivateNetwork"] is True
    assert gc["ProtectSystem"] == "strict" and gc["ProtectHome"] == "read-only"
    assert gc["Group"] == "home-config" and gc["UMask"] == "0027"
    assert gc["CapabilityBoundingSet"] == []
    assert {nr, ha} <= set(gc["InaccessiblePaths"])
    assert result["maintenance"]["restartIfChanged"] is False
    assert result["maintenance"]["timerConfig"]["OnCalendar"] == "weekly"
    assert result["maintenance"]["timerConfig"]["Persistent"] is True
    witness = result["witness"]["serviceConfig"]
    assert witness["StateDirectory"] == "home-config-watch"
    assert witness["ProtectHome"] == "read-only" and witness["ProtectSystem"] == "strict"
    assert witness["SuccessExitStatus"] == [0, 1] and witness["TimeoutStartSec"] == "60"
    assert result["witness"]["timerConfig"]["OnUnitActiveSec"] == "10min"
    assert result["sources"]["script"].endswith("home-config-snapshot.py")
    assert result["sources"]["scanner"].endswith("home-config-gitleaks.toml")
    assert "/home:/backup/home:ro" in result["backup"]["volumes"]
    assert "/backup/home /backup/root /backup/etc" in result["backup"]["script"]
    assert "home-config" not in result["backup"]["script"], "new backup exclusion must be reviewed"
    for marker in ("ProtectSystem=strict", "ProtectHome=read-only", "PrivateNetwork=true", "Nice=19", "IOSchedulingClass=idle"):
        assert marker in result["units"]["service"], marker
    assert "PathChanged=" + nr + "/flows.json" in result["units"]["path"]
    assert "OnUnitInactiveSec=15min" in result["units"]["timer"]
    assert "X-RestartIfChanged=false" in result["units"]["service"]
    assert "systemd-tmpfiles-setup.service" in next(line for line in result["units"]["service"].splitlines() if line.startswith("After="))
    assert "TimeoutStartSec=30min" in result["units"]["gc"]
    assert "OnCalendar=weekly" in result["units"]["gcTimer"]
    assert "StateDirectory=home-config-watch" in result["units"]["witness"]
    assert "OnUnitActiveSec=10min" in result["units"]["witnessTimer"]


verify(evaluate(False))
print("T121: real scoped NixOS module, rendered units and restic coverage evaluated")
if sys.argv[2] == "--module-only":
    print("T121: full hsb1 evaluation explicitly omitted (required before release)")
else:
    verify(evaluate(True))
    print("T121: full hsb1 module/units/backup contract evaluated")
PY
