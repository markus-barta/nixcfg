#!/usr/bin/env bash
# T20-pharos-beacon-healthcheck.sh
# Description: Keep every active beacon on the image's report-freshness probe.
# Related PPM issues: PHAROS-204, NIX-390

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mutation_host=""
mutation_shape=""
if [[ "${1:-}" == "--inject-disabled-healthcheck=csb0" ]]; then
  mutation_host="csb0"
  mutation_shape="nested"
elif [[ "${1:-}" == "--inject-dotted-disabled-healthcheck=csb0" ]]; then
  mutation_host="csb0"
  mutation_shape="dotted"
elif [[ "${1:-}" == "--inject-quoted-disabled-healthcheck=csb0" ]]; then
  mutation_host="csb0"
  mutation_shape="quoted"
elif [[ "${1:-}" == "--inject-extra-beacon-host" ]]; then
  mutation_shape="inventory"
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

python3 - "$mutation_host" "$mutation_shape" "$repo_root" "${compose_files[@]}" <<'PY'
import pathlib
import re
import sys

mutation_host = sys.argv[1]
mutation_shape = sys.argv[2]
repo_root = pathlib.Path(sys.argv[3])
paths = [pathlib.Path(value) for value in sys.argv[4:]]
expected_hosts = ("csb0", "csb1", "hsb0", "hsb1", "hsb8", "hsb9")
actual_hosts = tuple(path.parts[-3] for path in paths)
if actual_hosts != expected_hosts:
    raise SystemExit(
        f"active beacon inventory mismatch: expected={expected_hosts} actual={actual_hosts}"
    )

discovered_hosts = tuple(
    path.parts[-3]
    for path in sorted(
        repo_root.glob("hosts/*/docker/compose-spec.nix"),
        key=lambda candidate: candidate.parts[-3],
    )
    if re.search(
        r"^    pharos-beacon = \{\n",
        path.read_text(encoding="utf-8"),
        re.MULTILINE,
    )
)
if mutation_shape == "inventory":
    discovered_hosts += ("zz-extra",)
if discovered_hosts != expected_hosts:
    raise SystemExit(
        "active beacon discovery mismatch: "
        f"expected={expected_hosts} actual={discovered_hosts}"
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
    return (
        re.search(
            r'^      (?:"healthcheck"|healthcheck)(?:\s*=|\.)',
            beacon,
            re.MULTILINE,
        )
        is not None
    )


for path, host in zip(paths, expected_hosts):
    compose = path.read_text(encoding="utf-8")
    beacon = service_block(compose, host, "pharos-beacon")
    if mutation_host == host:
        if mutation_shape == "nested":
            beacon += "      healthcheck = {\n        disable = true;\n      };\n"
        elif mutation_shape == "dotted":
            beacon += "      healthcheck.disable = true;\n"
        elif mutation_shape == "quoted":
            beacon += '      "healthcheck" = {\n        disable = true;\n      };\n'
        else:
            raise SystemExit(f"unsupported mutation shape: {mutation_shape}")

    if beacon.count('"PHAROS_URL=http://100.64.0.4:8088"') != 1:
        raise SystemExit(f"beacon must retain the reviewed report endpoint: host={host}")
    if beacon.count('"PHAROS_INTERVAL=60"') != 1:
        raise SystemExit(f"beacon must retain the reviewed health cadence: host={host}")
    if beacon.count('"PHAROS_PREFERENCES_FILE=/etc/pharos/host-preferences.json"') != 1:
        raise SystemExit(f"beacon must load canonical host preferences: host={host}")
    if beacon.count(
        '"/run/pharos-preferences:/etc/pharos:ro"'
    ) != 1:
        raise SystemExit(f"beacon must mount canonical host preferences read-only: host={host}")
    if "/etc/pharos/host-preferences.json:/etc/pharos/host-preferences.json" in beacon:
        raise SystemExit(f"beacon must not pin the preferences generation inode: host={host}")
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

if [[ -z "$mutation_shape" ]]; then
  for mutation in \
    --inject-disabled-healthcheck=csb0 \
    --inject-dotted-disabled-healthcheck=csb0 \
    --inject-quoted-disabled-healthcheck=csb0; do
    mutation_output=""
    if mutation_output=$(bash "$0" "$mutation" 2>&1); then
      printf 'pharos_beacon_healthcheck=failed reason=mutation_accepted mutation=%s\n' \
        "$mutation" >&2
      exit 1
    fi

    expected='pharos_beacon_healthcheck=failed reason=beacon_healthcheck_overridden host=csb0'
    if [[ "$mutation_output" != *"$expected"* ]]; then
      printf 'pharos_beacon_healthcheck=failed reason=mutation_wrong_verdict mutation=%s\n' \
        "$mutation" >&2
      exit 1
    fi

    printf 'pharos_beacon_healthcheck_mutation=passed mutation=%s\n' "$mutation"
  done

  inventory_output=""
  if inventory_output=$(bash "$0" --inject-extra-beacon-host 2>&1); then
    printf 'pharos_beacon_healthcheck=failed reason=inventory_mutation_accepted\n' >&2
    exit 1
  fi
  if [[ "$inventory_output" != *"active beacon discovery mismatch"* ]]; then
    printf 'pharos_beacon_healthcheck=failed reason=inventory_mutation_wrong_verdict\n' >&2
    exit 1
  fi
  printf 'pharos_beacon_healthcheck_inventory_mutation=passed\n'
fi
