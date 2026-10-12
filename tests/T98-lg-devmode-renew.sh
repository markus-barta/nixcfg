#!/usr/bin/env bash
# OPS-309: offline renewal/notification contract and evaluated hsb0 wiring.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  discover -s "${repo}/tests" -p 'test_lg_devmode_renew.py' -v
nix-instantiate --parse "${repo}/hosts/hsb0/lg-devmode-renew.nix" >/dev/null
nix-instantiate --eval --strict --json "${repo}/tests/lg-devmode-renew-eval.nix" --arg config null |
  python3 -c 'import json, sys; checks = json.load(sys.stdin); failed = [k for k, v in checks.items() if v is not True]; assert not failed, failed; print("OPS-309 hsb0 module evaluation: OK")'
