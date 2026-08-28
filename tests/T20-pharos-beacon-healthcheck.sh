#!/usr/bin/env bash
# T20-pharos-beacon-healthcheck.sh
# Description: Keep every active beacon on the image's report-freshness probe.
# Related PPM issues: PHAROS-204, NIX-390

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mutation_host=""
if [[ "${1:-}" == "--inject-disabled-healthcheck=csb0" ]]; then
  mutation_host="csb0"
elif [[ $# -ne 0 ]]; then
  printf 'pharos_beacon_healthcheck=failed reason=invalid_argument\n' >&2
  exit 1
fi
compose_files=(
  "${repo_root}/hosts/csb0/docker/compose-spec.nix"
  "${repo_root}/hosts/csb1/docker/compose-spec.nix"
  "${repo_root}/hosts/hsb0/docker/compose-spec.nix"
  "${repo_root}/hosts/hsb1/docker/compose-spec.nix"
  "${repo_root}/hosts/hsb8/docker/compose-spec.nix"
  "${repo_root}/hosts/hsb9/docker/compose-spec.nix"
)

python3 - "$mutation_host" "${compose_files[@]}" <<'PY'
import pathlib
import re
import sys

mutation_host = sys.argv[1]
paths = [pathlib.Path(value) for value in sys.argv[2:]]
expected_hosts = ("csb0", "csb1", "hsb0", "hsb1", "hsb8", "hsb9")
actual_hosts = tuple(path.parts[-3] for path in paths)
if actual_hosts != expected_hosts:
    raise SystemExit(
        f"active beacon inventory mismatch: expected={expected_hosts} actual={actual_hosts}"
    )


def service_block(compose: str, host: str, name: str) -> str:
    match = re.search(
        rf"^    {re.escape(name)} = \{{\n(?P<body>.*?)^    \}};$",
        compose,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        raise SystemExit(f"missing compose service: host={host} service={name}")
    return match.group("body")


def has_healthcheck_override(beacon: str) -> bool:
    return re.search(r"^      healthcheck\s*=", beacon, re.MULTILINE) is not None


for path, host in zip(paths, expected_hosts):
    compose = path.read_text(encoding="utf-8")
    beacon = service_block(compose, host, "pharos-beacon")
    if mutation_host == host:
        beacon += "      healthcheck = {\n        disable = true;\n      };\n"

    if beacon.count('"PHAROS_URL=http://100.64.0.4:8088"') != 1:
        raise SystemExit(f"beacon must retain the reviewed report endpoint: host={host}")
    if beacon.count('"PHAROS_INTERVAL=60"') != 1:
        raise SystemExit(f"beacon must retain the reviewed health cadence: host={host}")
    if 'network_mode = "host";' not in beacon:
        raise SystemExit(f"beacon must retain host networking: host={host}")
    if has_healthcheck_override(beacon):
        raise SystemExit(
            "pharos_beacon_healthcheck=failed "
            f"reason=beacon_healthcheck_overridden host={host}"
        )

control_plane = paths[1].read_text(encoding="utf-8")
server = service_block(control_plane, "csb1", "pharosd")

for binding in [
    '"127.0.0.1:8088:8080"',
    '"100.64.0.4:8088:8080"',
]:
    if server.count(binding) != 1:
        raise SystemExit(f"pharosd must expose exactly one reviewed listener: {binding}")

print(f"pharos_beacon_healthcheck_contract=passed beacons={len(paths)}")
PY

if [[ -z "$mutation_host" ]]; then
  mutation_output=""
  if mutation_output=$(bash "$0" --inject-disabled-healthcheck=csb0 2>&1); then
    printf 'pharos_beacon_healthcheck=failed reason=mutation_accepted host=csb0\n' >&2
    exit 1
  fi

  expected='pharos_beacon_healthcheck=failed reason=beacon_healthcheck_overridden host=csb0'
  if [[ "$mutation_output" != *"$expected"* ]]; then
    printf 'pharos_beacon_healthcheck=failed reason=mutation_wrong_verdict host=csb0\n' >&2
    exit 1
  fi

  printf 'pharos_beacon_healthcheck_mutation=passed host=csb0\n'
fi
