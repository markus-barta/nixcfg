#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
production="$repo_root/hosts/csb1/docker/janus/pharos-production"
smoke="$repo_root/hosts/csb1/docker/janus/pharos-retirement-smoke"
compose="$repo_root/hosts/csb1/docker/docker-compose.yml"

bash -n "$production/runtime-lib.sh"
bash -n "$production/render-sidecars.sh"
bash -n "$production/retire-host.sh"
bash -n "$smoke/run.sh"

if "$production/retire-host.sh" reconcile '../invalid' >/dev/null 2>&1; then
  printf 'retirement helper accepted an invalid host\n' >&2
  exit 1
fi

grep -Fq 'JANUS_LIFECYCLE_TOMBSTONE_DIR=/var/lib/janus/lifecycle/tombstones' \
  "$production/retire-host.sh"
grep -Fq -- '--state-dir /var/lib/janus/lifecycle/pharos-retirements' \
  "$production/retire-host.sh"
grep -Fq 'JANUS_PHAROS_METADATA_VOLUME' "$production/runtime-lib.sh"
grep -Fq 'JANUS_PHAROS_LIFECYCLE_VOLUME' "$production/runtime-lib.sh"
grep -Fq '/var/lib/janus/metadata/baseline.toml' "$production/runtime-lib.sh"
grep -Fq 'RETIREMENTS_FILE' "$production/render-sidecars.sh"
grep -Fq 'METADATA_VOLUME' "$production/render-sidecars.sh"
grep -Fq 'fixture_uses_production_contract' "$production/retire-host.sh"
grep -Fq 'fixture_uses_production_volumes' "$production/retire-host.sh"
grep -Fq 'fixture_uses_production_scope' "$production/retire-host.sh"
grep -Fq 'pharos/csb1/nonprod-retirement-smoke' "$smoke/run.sh"

if grep -Eq -- '--(value|token|secret-ref|provider-delete|delete)([=[:space:]]|$)' \
  "$production/retire-host.sh"; then
  printf 'retirement helper exposes a forbidden value or provider control\n' >&2
  exit 1
fi
if grep -Fq '/etc/janus/metadata.toml:ro' "$production/render-sidecars.sh"; then
  printf 'production renderer still mounts immutable lifecycle metadata\n' >&2
  exit 1
fi

python3 - "$smoke" "$compose" <<'PY'
import hashlib
import json
import pathlib
import re
import subprocess
import sys

smoke = pathlib.Path(sys.argv[1])
compose = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
host = "retirementsmoke"
secret_name = "PHAROS_BEACON_RETIREMENTSMOKE_TOKEN"
expected_ref = "sec_" + hashlib.sha256(b"pharos\0" + secret_name.encode()).hexdigest()[:20]

def nix_from_toml(path: pathlib.Path) -> dict:
    expression = f'builtins.fromTOML (builtins.readFile "{path}")'
    completed = subprocess.run(
        ["nix", "eval", "--impure", "--json", "--expr", expression],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    )
    return json.loads(completed.stdout)

profiles = nix_from_toml(smoke / "managed-env-files.toml")["env_files"]
if len(profiles) != 1:
    raise SystemExit("retirement smoke must bind exactly one profile")
profile = profiles[0]
expected = {
    "id": "profile.PHAROS_BEACON_RETIREMENTSMOKE_TOKEN",
    "secret_ref": expected_ref,
    "destination": f"pharos-beacon-{host}",
    "env": "PHAROS_TOKEN",
    "output": f"/run/janus/env/pharos/beacons/{host}.env",
}
for key, value in expected.items():
    if profile.get(key) != value:
        raise SystemExit(f"retirement smoke profile {key} mismatch")
sidecar = profile.get("hash_sidecar", {})
if sidecar.get("subject") != host or sidecar.get("output") != f"/run/janus/env/pharos/beacon-token-hashes/{host}.json":
    raise SystemExit("retirement smoke sidecar mismatch")

secretspec = nix_from_toml(smoke / "secretspec.toml")
if secret_name not in secretspec.get("profiles", {}).get(host, {}):
    raise SystemExit("retirement smoke secret is not declared")

intent = json.loads((smoke / "retired-hosts.json").read_text(encoding="utf-8"))
if intent != {
    "retirements": [{
        "credential_retirement_required": True,
        "disposition": "destroyed",
        "host": host,
        "server_deletion": False,
        "successor": None,
    }],
    "schema": "inspr.pharos.janus-retirements.v1",
    "version": 1,
}:
    raise SystemExit("retirement smoke intent mismatch")

image_match = re.search(
    r"^\s+image: ghcr\.io/markus-barta/janus/janus-engine:(rust-engine-v[^@\s]+)@(sha256:[0-9a-f]{64})$",
    compose,
    re.MULTILINE,
)
if not image_match:
    raise SystemExit("Janus staged image is not release and digest pinned")
PY

printf 'janus_pharos_retirement_contract=passed\n'
