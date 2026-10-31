#!/usr/bin/env bash
# OPS-496: fake hubs + script behavior + scoped/full NixOS evaluation; no builds.
# Requires Python 3, Node 18+ and Bash 5; no browser or live devices.
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 5 ]; then
  printf 'T117 requires bash 5\n' >&2
  exit 2
fi

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
  discover -s "${repo}/tests" -p 'test_aqara_nightlight.py' -v
node --test "${repo}/tests/test_aqara_nightlight_ui.cjs"
nix-instantiate --parse "${repo}/hosts/hsb1/aqara-nightlight.nix" >/dev/null
grep -Fq './aqara-nightlight.nix # OPS-496:' "${repo}/hosts/hsb1/configuration.nix"

PYTHONDONTWRITEBYTECODE=1 python3 - "$repo" "$mode" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

repo = Path(sys.argv[1])

def evaluate(arguments):
    # NIX_REMOTE may point to an isolated writable eval store in a sandbox.
    # Neither this nor the full-flake branch builds a derivation.
    result = subprocess.run(
        ["nix", "eval", "--offline", "--no-write-lock-file", "--json", *arguments],
        cwd=repo, text=True, capture_output=True,
    )
    if result.returncode:
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)
    return json.loads(result.stdout)

def verify(result):
    service = result["service"]
    unit = service["serviceConfig"]
    assert unit["ExecStart"].endswith("-aqara-nightlight.py")
    assert "/bin/python3 " in unit["ExecStart"]
    assert unit["DynamicUser"] is True
    assert unit["StateDirectory"] == "aqara-nightlight"
    assert unit["StateDirectoryMode"] == "0700"
    assert unit["ProtectSystem"] == "strict"
    assert unit["IPAddressDeny"] == "any"
    allowed = set(unit["IPAddressAllow"])
    assert allowed == {"127.0.0.0/8", "::1/128", "192.168.1.0/24", "100.64.0.0/10",
                       "192.168.1.106/32", "192.168.1.108/32"}
    assert set(unit["RestrictAddressFamilies"]) == {"AF_INET", "AF_INET6"}
    for option in ("PrivateTmp", "PrivateDevices", "ProtectHome", "ProtectKernelTunables",
                   "ProtectKernelModules", "ProtectControlGroups", "NoNewPrivileges",
                   "LockPersonality", "RestrictRealtime", "RestrictSUIDSGID"):
        assert unit[option] is True, option
    assert service["environment"]["AQARA_LISTEN_ADDRESSES"] == "127.0.0.1,192.168.1.101,100.64.0.7"
    assert service["environment"]["AQARA_PORT"] == "8765"
    assert service["environment"]["AQARA_PAGE_FILE"].endswith("-aqara-nightlight-page.html")
    assert "network-online.target" in service["wants"]
    assert "tailscaled.service" in service["after"]
    assert service["wantedBy"] == ["multi-user.target"]
    assert result["firewall"]["enable"] is False
    assert 8765 in result["firewall"]["allowedTCPPorts"]
    assert "IPAddressDeny=any" in result["unit"]
    for peer in allowed:
        assert peer in result["unit"], peer
    assert result["miioVersion"] == "0.5.12", "review private MiIOProtocol ID API on version change"

source = os.environ.get("AQARA_TEST_NIXPKGS")
arguments = '{ nixpkgs = builtins.toPath ' + json.dumps(source) + '; }' if source else '{}'
result = evaluate(["--impure", "--expr", "import ./tests/aqara-nightlight-eval.nix " + arguments])
verify(result)
print("T117: real NixOS unit + hsb1 firewall declaration evaluated (scoped); python-miio " + result["miioVersion"])

if sys.argv[2] == "--module-only":
    print("T117: full hsb1 flake evaluation explicitly omitted (--module-only); still required before release")
else:
    projection = '''system: {
      service = {
        inherit (system.config.systemd.services.aqara-nightlight)
          serviceConfig environment wants after wantedBy;
      };
      unit = system.config.systemd.units."aqara-nightlight.service".text;
      firewall = { inherit (system.config.networking.firewall) enable allowedTCPPorts; };
      miioVersion = system.pkgs.python3Packages.python-miio.version;
    }'''
    verify(evaluate([str(repo) + "#nixosConfigurations.hsb1", "--apply", projection]))
    print("T117: full hsb1 unit/firewall evaluation passed")
PY
