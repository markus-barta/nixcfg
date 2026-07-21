#!/usr/bin/env bash
# T20-pharos-beacon-healthcheck.sh
# Description: Keep the beacon container's inherited readiness probe truthful.
# Related PPM issues: PHAROS-162, PHAROS-174

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose="${repo_root}/hosts/csb1/docker/docker-compose.yml"

python3 - "${compose}" <<'PY'
import pathlib
import re
import sys

compose = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")

def service_block(name: str) -> str:
    match = re.search(
        rf"^  {re.escape(name)}:\n(?P<body>.*?)(?=^  [A-Za-z0-9_.-]+:\n|\Z)",
        compose,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        raise SystemExit(f"missing compose service: {name}")
    return match.group("body")

server = service_block("pharosd")
beacon = service_block("pharos-beacon")

for binding in [
    '- "127.0.0.1:8088:8080"',
    '- "100.64.0.4:8088:8080"',
]:
    if server.count(binding) != 1:
        raise SystemExit(f"pharosd must expose exactly one reviewed listener: {binding}")

if beacon.count("- PHAROS_ADDR=0.0.0.0:8088") != 1:
    raise SystemExit("beacon healthcheck must target the local-only Pharos listener")
if beacon.count("- PHAROS_URL=http://100.64.0.4:8088") != 1:
    raise SystemExit("beacon reports must retain the reviewed tailnet endpoint")
if "network_mode: host" not in beacon:
    raise SystemExit("beacon must retain host networking for the local readiness probe")
if "healthcheck:\n      disable: true" in beacon:
    raise SystemExit("beacon must not suppress its inherited healthcheck")

print("pharos_beacon_healthcheck_contract=passed")
PY
