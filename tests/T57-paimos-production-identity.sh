#!/usr/bin/env bash
# NIX-396 — csb1 must stage the Paimos production identity firewall before
# a release can make the PAI-856 startup guard mandatory.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compose="$repo_root/hosts/csb1/docker/compose-spec.nix"

fail() {
  printf 'T57 failed: %s\n' "$*" >&2
  exit 1
}

nix-instantiate --parse "$compose" >/dev/null
ppm_environment=$(nix eval --impure --json --expr "(import $compose).services.ppm.environment")

PYTHONDONTWRITEBYTECODE=1 python3 - "$ppm_environment" <<'PY'
import json
import sys

environment = json.loads(sys.argv[1])
expected = {
    "PAIMOS_ENV": "production",
    "PAIMOS_DEPLOYMENT_INSTANCE": "ppm",
    "PAIMOS_AGENT_BUS_INSTANCE": "ppm",
}

values = {}
for item in environment:
    key, separator, value = item.partition("=")
    if separator and key in expected:
        values.setdefault(key, []).append(value)

for key, value in expected.items():
    actual = values.get(key, [])
    assert actual == [value], f"{key} must occur exactly once as {value!r}, got {actual!r}"

assert not any(item.startswith("PAIMOS_INSTANCE=") for item in environment), (
    "the server deployment identity must not reuse the CLI's PAIMOS_INSTANCE selector"
)
PY

printf 'T57 passed: csb1 PPM renders one matching production, deployment, and Agent Intercom identity\n'
