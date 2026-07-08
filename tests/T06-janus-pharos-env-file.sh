#!/usr/bin/env bash
# T06-janus-pharos-env-file.sh
# Description: Validate the staged Janus env-file profiles for Pharos nonprod.
# Related PPM issues: PHAROS-40, PHAROS-94, JANUS-261

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE="$REPO_ROOT/hosts/csb1/docker/janus/pharos-nonprod/managed-env-files.toml"
SECRETSPEC="$REPO_ROOT/hosts/csb1/docker/janus/pharos-nonprod/secretspec.toml"

python3 - "$PROFILE" "$SECRETSPEC" <<'PY'
import hashlib
import json
import pathlib
import re
import subprocess
import sys

profile_path = pathlib.Path(sys.argv[1])
secretspec_path = pathlib.Path(sys.argv[2])
profile_text = profile_path.read_text(encoding="utf-8")
secretspec_text = secretspec_path.read_text(encoding="utf-8")

for text, label in [(profile_text, "profile"), (secretspec_text, "secretspec")]:
    if re.search(r"Bearer |BEGIN |PRIVATE KEY|pharos_[0-9A-Fa-f]{16,}", text):
        raise SystemExit(f"{label} contains a forbidden secret-shaped literal")

def nix_from_toml(path: pathlib.Path) -> dict:
    expr = f'builtins.fromTOML (builtins.readFile "{path}")'
    completed = subprocess.run(
        ["nix", "eval", "--impure", "--json", "--expr", expr],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    )
    return json.loads(completed.stdout)

profile = nix_from_toml(profile_path)
secretspec = nix_from_toml(secretspec_path)

env_files = profile.get("env_files", [])
by_id = {entry["id"]: entry for entry in env_files}

registration = by_id.get("profile.PHAROS_NONPROD_REGISTRATION")
if not registration:
    raise SystemExit("missing Pharos nonprod registration profile")
expected_registration = {
    "executor": "janus-run@csb1",
    "destination": "pharos-nonprod",
    "env": "PHAROS_REGISTRATION_TOKEN",
    "output": "/run/janus/env/pharos/pharos.env",
}
for key, expected in expected_registration.items():
    if registration.get(key) != expected:
        raise SystemExit(f"registration {key} mismatch")
if not re.fullmatch(r"sec_[A-Za-z0-9_]+", registration.get("secret_ref", "")):
    raise SystemExit("registration secret_ref must be opaque")

consumer = registration.get("consumer", {})
expected_consumer = {
    "consumer_ref": "consumer.pharos_nonprod",
    "kind": "service",
    "owner": "pharos",
    "environment": "nonprod",
    "reload": "none",
    "validation": ["pharos-registration-preflight"],
    "supports_dual_value": False,
    "blast_radius": "non-production Pharos host registration only",
}
for key, expected in expected_consumer.items():
    if consumer.get(key) != expected:
        raise SystemExit(f"registration consumer {key} mismatch")

if secretspec.get("project", {}).get("name") != "pharos":
    raise SystemExit("Pharos secretspec project name mismatch")

hosts = ["csb0", "csb1", "gpc0", "hsb0", "hsb1", "hsb8", "hsb9"]
profiles = secretspec.get("profiles", {})
for host in hosts:
    upper = host.upper()
    secret_name = f"PHAROS_BEACON_{upper}_TOKEN"
    host_secrets = profiles.get(host, {})
    if secret_name not in host_secrets:
        raise SystemExit(f"missing secretspec entry for {host}")
    ref = "sec_" + hashlib.sha256(b"pharos\0" + secret_name.encode()).hexdigest()[:20]
    profile_id = f"profile.PHAROS_BEACON_{upper}_TOKEN"
    entry = by_id.get(profile_id)
    if not entry:
        raise SystemExit(f"missing env-file profile for {host}")
    expected_entry = {
        "secret_ref": ref,
        "executor": "janus-run@csb1",
        "destination": f"pharos-beacon-{host}",
        "env": "PHAROS_TOKEN",
        "output": f"/run/janus/env/pharos/beacons/{host}.env",
    }
    for key, expected in expected_entry.items():
        if entry.get(key) != expected:
            raise SystemExit(f"{profile_id} {key} mismatch")

    sidecar = entry.get("hash_sidecar", {})
    expected_sidecar = {
        "format": "pharos-beacon-token-hashes-v1",
        "subject": host,
        "output": f"/run/janus/env/pharos/beacon-token-hashes/{host}.json",
    }
    for key, expected in expected_sidecar.items():
        if sidecar.get(key) != expected:
            raise SystemExit(f"{profile_id} hash_sidecar {key} mismatch")

    consumer = entry.get("consumer", {})
    expected_consumer = {
        "consumer_ref": f"consumer.pharos_beacon_{host}",
        "kind": "service",
        "owner": "pharos",
        "environment": "nonprod",
        "reload": "none",
        "validation": ["pharos-beacon-token-sidecar-preflight"],
        "supports_dual_value": False,
        "blast_radius": f"non-production Pharos beacon token for {host}",
    }
    for key, expected in expected_consumer.items():
        if consumer.get(key) != expected:
            raise SystemExit(f"{profile_id} consumer {key} mismatch")

if len([entry for entry in env_files if entry["id"].startswith("profile.PHAROS_BEACON_")]) != len(hosts):
    raise SystemExit("unexpected number of Pharos beacon env-file profiles")
PY

echo "ok: staged Pharos Janus env-file and sidecar profiles are value-free"
