#!/usr/bin/env bash
# T06-janus-pharos-env-file.sh
# Description: Validate Janus env-file profiles for Pharos beacon token handoff.
# Related PPM issues: PHAROS-40, PHAROS-94, JANUS-261

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NONPROD_PROFILE="$REPO_ROOT/hosts/csb1/docker/janus/pharos-nonprod/managed-env-files.toml"
NONPROD_SECRETSPEC="$REPO_ROOT/hosts/csb1/docker/janus/pharos-nonprod/secretspec.toml"
PROD_PROFILE="$REPO_ROOT/hosts/csb1/docker/janus/pharos-production/managed-env-files.toml"
PROD_SECRETSPEC="$REPO_ROOT/hosts/csb1/docker/janus/pharos-production/secretspec.toml"
PROD_METADATA="$REPO_ROOT/hosts/csb1/docker/janus/pharos-production/metadata.toml"

python3 - "$NONPROD_PROFILE" "$NONPROD_SECRETSPEC" "$PROD_PROFILE" "$PROD_SECRETSPEC" "$PROD_METADATA" <<'PY'
import hashlib
import json
import pathlib
import re
import subprocess
import sys

nonprod_profile_path = pathlib.Path(sys.argv[1])
nonprod_secretspec_path = pathlib.Path(sys.argv[2])
prod_profile_path = pathlib.Path(sys.argv[3])
prod_secretspec_path = pathlib.Path(sys.argv[4])
prod_metadata_path = pathlib.Path(sys.argv[5])
hosts = ["csb0", "csb1", "gpc0", "hsb0", "hsb1", "hsb8", "hsb9"]

for path in [
    nonprod_profile_path,
    nonprod_secretspec_path,
    prod_profile_path,
    prod_secretspec_path,
    prod_metadata_path,
]:
    text = path.read_text(encoding="utf-8")
    if re.search(r"Bearer |BEGIN |PRIVATE KEY|pharos_[0-9A-Fa-f]{16,}", text):
        raise SystemExit(f"{path.name} contains a forbidden secret-shaped literal")

def nix_from_toml(path: pathlib.Path) -> dict:
    expr = f'builtins.fromTOML (builtins.readFile "{path}")'
    completed = subprocess.run(
        ["nix", "eval", "--impure", "--json", "--expr", expr],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    )
    return json.loads(completed.stdout)

def expect_subset(actual: dict, expected: dict, label: str) -> None:
    for key, value in expected.items():
        if actual.get(key) != value:
            raise SystemExit(f"{label} {key} mismatch")

def validate_registration(profile: dict) -> None:
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
    expect_subset(registration, expected_registration, "registration")
    if not re.fullmatch(r"sec_[A-Za-z0-9_]+", registration.get("secret_ref", "")):
        raise SystemExit("registration secret_ref must be opaque")

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
    expect_subset(registration.get("consumer", {}), expected_consumer, "registration consumer")

def validate_beacon_contract(
    *,
    label: str,
    profile_path: pathlib.Path,
    secretspec_path: pathlib.Path,
    environment: str,
    reload: str,
    validations: list[str],
    supports_dual_value: bool,
    blast_radius_prefix: str,
) -> None:
    profile = nix_from_toml(profile_path)
    secretspec = nix_from_toml(secretspec_path)

    if secretspec.get("project", {}).get("name") != "pharos":
        raise SystemExit(f"{label} secretspec project name mismatch")
    if set(secretspec.get("profiles", {}).keys()) != set(hosts):
        raise SystemExit(f"{label} secretspec host coverage mismatch")

    env_files = profile.get("env_files", [])
    by_id = {entry["id"]: entry for entry in env_files}
    beacon_entries = [entry for entry in env_files if entry["id"].startswith("profile.PHAROS_BEACON_")]
    if len(beacon_entries) != len(hosts):
        raise SystemExit(f"{label} unexpected number of Pharos beacon env-file profiles")

    for host in hosts:
        upper = host.upper()
        secret_name = f"PHAROS_BEACON_{upper}_TOKEN"
        host_secrets = secretspec.get("profiles", {}).get(host, {})
        if secret_name not in host_secrets:
            raise SystemExit(f"{label} missing secretspec entry for {host}")
        ref = "sec_" + hashlib.sha256(b"pharos\0" + secret_name.encode()).hexdigest()[:20]
        profile_id = f"profile.PHAROS_BEACON_{upper}_TOKEN"
        entry = by_id.get(profile_id)
        if not entry:
            raise SystemExit(f"{label} missing env-file profile for {host}")
        expected_entry = {
            "secret_ref": ref,
            "executor": "janus-run@csb1",
            "destination": f"pharos-beacon-{host}",
            "env": "PHAROS_TOKEN",
            "output": f"/run/janus/env/pharos/beacons/{host}.env",
        }
        expect_subset(entry, expected_entry, f"{label} {profile_id}")

        expected_sidecar = {
            "format": "pharos-beacon-token-hashes-v1",
            "subject": host,
            "output": f"/run/janus/env/pharos/beacon-token-hashes/{host}.json",
        }
        expect_subset(entry.get("hash_sidecar", {}), expected_sidecar, f"{label} {profile_id} hash_sidecar")

        expected_consumer = {
            "consumer_ref": f"consumer.pharos_beacon_{host}",
            "kind": "service",
            "owner": "pharos",
            "environment": environment,
            "reload": reload,
            "validation": validations,
            "supports_dual_value": supports_dual_value,
            "blast_radius": f"{blast_radius_prefix} {host}",
        }
        expect_subset(entry.get("consumer", {}), expected_consumer, f"{label} {profile_id} consumer")

nonprod_profile = nix_from_toml(nonprod_profile_path)
validate_registration(nonprod_profile)
validate_beacon_contract(
    label="nonprod",
    profile_path=nonprod_profile_path,
    secretspec_path=nonprod_secretspec_path,
    environment="nonprod",
    reload="none",
    validations=["pharos-beacon-token-sidecar-preflight"],
    supports_dual_value=False,
    blast_radius_prefix="non-production Pharos beacon token for",
)
validate_beacon_contract(
    label="production",
    profile_path=prod_profile_path,
    secretspec_path=prod_secretspec_path,
    environment="production",
    reload="none",
    validations=["pharos-beacon-token-sidecar-preflight", "pharos-report-dual-mode-smoke"],
    supports_dual_value=True,
    blast_radius_prefix="production Pharos beacon token for",
)

prod_metadata = nix_from_toml(prod_metadata_path)
defaults = prod_metadata.get("defaults", {})
if defaults.get("owner") != "pharos" or defaults.get("classification") != "high_value":
    raise SystemExit("production metadata defaults mismatch")
PY

echo "ok: Pharos Janus env-file and sidecar profiles are value-free"
