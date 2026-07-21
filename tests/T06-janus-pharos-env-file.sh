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
PROD_IMPORT="$REPO_ROOT/hosts/csb1/docker/janus/pharos-production/import-existing-agenix-beacons.sh"
PROD_RENDER="$REPO_ROOT/hosts/csb1/docker/janus/pharos-production/render-sidecars.sh"
NONPROD_RENDER="$REPO_ROOT/hosts/csb1/docker/janus/pharos-nonprod/run-sidecar-smoke.sh"
RETIRE_HOST="$REPO_ROOT/hosts/csb1/docker/janus/pharos-production/retire-host.sh"
PROVIDER_IMPORT="$REPO_ROOT/hosts/csb1/docker/janus/pharos-production/import-agenix-hetzner-provider.sh"
PROVIDER_RENDER="$REPO_ROOT/hosts/csb1/docker/janus/pharos-production/render-hetzner-provider.sh"
PROVIDER_SMOKE="$REPO_ROOT/hosts/csb1/docker/janus/pharos-provider-smoke/run.sh"
PROD_RUNTIME="$REPO_ROOT/hosts/csb1/docker/janus/pharos-production/runtime-lib.sh"
COMPOSE_FILE="$REPO_ROOT/hosts/csb1/docker/docker-compose.yml"
CSB1_CONFIG="$REPO_ROOT/hosts/csb1/configuration.nix"
SECRETS_DECLARATIONS="$REPO_ROOT/secrets/secrets.nix"
PROVIDER_AGENIX_ARTIFACT="$REPO_ROOT/secrets/csb1-hetzner-cloud-provider-env.age"
AGENIX_CATALOG="$REPO_ROOT/hosts/csb1/docker/janus/catalog/agenix-catalog.json"

bash -n "$PROD_IMPORT"
bash -n "$PROD_RENDER"
bash -n "$NONPROD_RENDER"
bash -n "$RETIRE_HOST"
bash -n "$PROVIDER_IMPORT"
bash -n "$PROVIDER_RENDER"
bash -n "$PROVIDER_SMOKE"

require_occurrences() {
  local expected_count=$1
  local expected_text=$2
  local file=$3
  local actual_count
  actual_count=$(grep -Fc -- "$expected_text" "$file" || true)
  if [ "$actual_count" -lt "$expected_count" ]; then
    echo "missing structured Janus scope wiring in ${file#"$REPO_ROOT"/}: $expected_text" >&2
    exit 1
  fi
}

for renderer in "$NONPROD_RENDER" "$PROD_RENDER" "$PROVIDER_RENDER"; do
  # shellcheck disable=SC2016
  require_occurrences 1 '-e "JANUS_WARDEN_SCOPE_ORGANIZATION=${SCOPE_ORGANIZATION}"' "$renderer"
  # shellcheck disable=SC2016
  require_occurrences 1 '-e "JANUS_WARDEN_SCOPE_PROJECT=${SCOPE_PROJECT}"' "$renderer"
  # shellcheck disable=SC2016
  require_occurrences 1 '-e "JANUS_WARDEN_SCOPE_REPOSITORY=${SCOPE_REPOSITORY}"' "$renderer"
  # shellcheck disable=SC2016
  require_occurrences 1 '-e "JANUS_WARDEN_SCOPE_ENVIRONMENT=${SCOPE_ENVIRONMENT}"' "$renderer"
  # shellcheck disable=SC2016
  require_occurrences 2 '-e "JANUS_SCOPE_ORGANIZATION=${SCOPE_ORGANIZATION}"' "$renderer"
  # shellcheck disable=SC2016
  require_occurrences 2 '-e "JANUS_SCOPE_PROJECT=${SCOPE_PROJECT}"' "$renderer"
  # shellcheck disable=SC2016
  require_occurrences 2 '-e "JANUS_SCOPE_REPOSITORY=${SCOPE_REPOSITORY}"' "$renderer"
  # shellcheck disable=SC2016
  require_occurrences 2 '-e "JANUS_SCOPE_ENVIRONMENT=${SCOPE_ENVIRONMENT}"' "$renderer"
done
# shellcheck disable=SC2016
require_occurrences 1 '-e "JANUS_SCOPE_ORGANIZATION=${SCOPE_ORGANIZATION}"' "$RETIRE_HOST"
# shellcheck disable=SC2016
require_occurrences 1 '-e "JANUS_SCOPE_PROJECT=${SCOPE_PROJECT}"' "$RETIRE_HOST"
# shellcheck disable=SC2016
require_occurrences 1 '-e "JANUS_SCOPE_REPOSITORY=${SCOPE_REPOSITORY}"' "$RETIRE_HOST"
# shellcheck disable=SC2016
require_occurrences 1 '-e "JANUS_SCOPE_ENVIRONMENT=${SCOPE_ENVIRONMENT}"' "$RETIRE_HOST"
require_occurrences 1 '      - JANUS_WARDEN_SCOPE_ORGANIZATION=inspr' "$COMPOSE_FILE"
require_occurrences 1 '      - JANUS_WARDEN_SCOPE_ENVIRONMENT=staged' "$COMPOSE_FILE"
require_occurrences 1 '      - JANUS_SCOPE_ORGANIZATION=inspr' "$COMPOSE_FILE"
require_occurrences 1 '      - JANUS_SCOPE_ENVIRONMENT=staged' "$COMPOSE_FILE"

if [ ! -s "$PROVIDER_AGENIX_ARTIFACT" ]; then
  echo "missing or empty encrypted Hetzner provider artifact" >&2
  exit 1
fi

python3 - \
  "$NONPROD_PROFILE" \
  "$NONPROD_SECRETSPEC" \
  "$PROD_PROFILE" \
  "$PROD_SECRETSPEC" \
  "$PROD_METADATA" \
  "$COMPOSE_FILE" \
  "$PROVIDER_IMPORT" \
  "$PROVIDER_RENDER" \
  "$PROD_RUNTIME" \
  "$CSB1_CONFIG" \
  "$SECRETS_DECLARATIONS" \
  "$AGENIX_CATALOG" \
  "$PROVIDER_SMOKE" <<'PY'
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
compose_path = pathlib.Path(sys.argv[6])
provider_import_path = pathlib.Path(sys.argv[7])
provider_render_path = pathlib.Path(sys.argv[8])
prod_runtime_path = pathlib.Path(sys.argv[9])
csb1_config_path = pathlib.Path(sys.argv[10])
secrets_declarations_path = pathlib.Path(sys.argv[11])
agenix_catalog_path = pathlib.Path(sys.argv[12])
provider_smoke_path = pathlib.Path(sys.argv[13])
hosts = ["csb0", "csb1", "dsc0", "gpc0", "hsb0", "hsb1", "hsb8", "hsb9"]

for path in [
    nonprod_profile_path,
    nonprod_secretspec_path,
    prod_profile_path,
    prod_secretspec_path,
    prod_metadata_path,
    compose_path,
    provider_import_path,
    provider_render_path,
    provider_smoke_path,
    prod_runtime_path,
    csb1_config_path,
    secrets_declarations_path,
    agenix_catalog_path,
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

def scoped_secret_ref(*, project: str, environment: str, name: str) -> str:
    canonical = b""
    for component in ("janus-scope-v1", "inspr", project, "nixcfg", environment):
        encoded = component.encode()
        canonical += len(encoded).to_bytes(8, "big") + encoded
    canonical += b"\0\0"
    scope_ref = "scp_" + hashlib.sha256(canonical).hexdigest()[:40]
    digest = hashlib.sha256(
        b"janus-secret-ref-v2\0" + scope_ref.encode() + b"\0" + name.encode()
    ).hexdigest()
    return "sec_" + digest[:20]

def validate_registration(profile: dict) -> None:
    env_files = profile.get("env_files", [])
    by_id = {entry["id"]: entry for entry in env_files}
    registration = by_id.get("profile.PHAROS_NONPROD_REGISTRATION")
    if not registration:
        raise SystemExit("missing Pharos nonprod registration profile")
    expected_registration = {
        "secret_ref": scoped_secret_ref(
            project="pharos",
            environment="pharos-nonprod",
            name="PHAROS_NONPROD_REGISTRATION",
        ),
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
    scope_environment: str,
    reload: str,
    validations: list[str],
    supports_dual_value: bool,
    blast_radius_prefix: str,
    extra_profiles: set[str] | None = None,
) -> None:
    profile = nix_from_toml(profile_path)
    secretspec = nix_from_toml(secretspec_path)

    if secretspec.get("project", {}).get("name") != "pharos":
        raise SystemExit(f"{label} secretspec project name mismatch")
    expected_profiles = set(hosts) | (extra_profiles or set())
    if set(secretspec.get("profiles", {}).keys()) != expected_profiles:
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
        ref = scoped_secret_ref(
            project="pharos",
            environment=scope_environment,
            name=secret_name,
        )
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
            "format": "pharos-beacon-token-generation-v2",
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
    scope_environment="pharos-nonprod",
    reload="none",
    validations=["pharos-beacon-token-sidecar-preflight"],
    supports_dual_value=False,
    blast_radius_prefix="non-production Pharos beacon token for",
    extra_profiles=set(),
)
validate_beacon_contract(
    label="production",
    profile_path=prod_profile_path,
    secretspec_path=prod_secretspec_path,
    environment="production",
    scope_environment="production",
    reload="none",
    validations=["pharos-beacon-token-sidecar-preflight", "pharos-report-janus-mode-smoke"],
    supports_dual_value=False,
    blast_radius_prefix="production Pharos beacon token for",
    extra_profiles={"hetzner-cloud"},
)

prod_profile = nix_from_toml(prod_profile_path)
prod_secretspec = nix_from_toml(prod_secretspec_path)
provider_secret_name = "PHAROS_HCLOUD_API_TOKEN"
provider_profile_id = f"profile.{provider_secret_name}"
provider_ref = scoped_secret_ref(
    project="pharos",
    environment="production",
    name=provider_secret_name,
)
provider_entries = {
    entry["id"]: entry for entry in prod_profile.get("env_files", [])
}
provider = provider_entries.get(provider_profile_id)
if not provider:
    raise SystemExit("missing production Hetzner provider env-file profile")
expect_subset(
    provider,
    {
        "secret_ref": provider_ref,
        "executor": "janus-run@csb1",
        "destination": "pharos-provider-hetzner-cloud",
        "env": provider_secret_name,
        "output": "/run/janus/env/pharos/providers/hetzner-cloud.env",
    },
    "production Hetzner provider",
)
expect_subset(
    provider.get("consumer", {}),
    {
        "consumer_ref": "consumer.pharos_provider_hetzner_cloud",
        "kind": "service",
        "owner": "pharos",
        "environment": "production",
        "reload": "none",
        "validation": [
            "pharos-provider-credential-preflight",
            "pharos-provider-read-only-test",
        ],
        "supports_dual_value": False,
        "blast_radius": "production Pharos Hetzner Cloud provider access",
    },
    "production Hetzner provider consumer",
)
provider_secrets = prod_secretspec.get("profiles", {}).get("hetzner-cloud", {})
if provider_secrets.get(provider_secret_name, {}).get("required") is not True:
    raise SystemExit("production Hetzner provider secretspec entry is not required")

prod_metadata = nix_from_toml(prod_metadata_path)
defaults = prod_metadata.get("defaults", {})
if defaults.get("owner") != "pharos" or defaults.get("classification") != "high_value":
    raise SystemExit("production metadata defaults mismatch")

compose_text = compose_path.read_text(encoding="utf-8")
if "PHAROS_BEACON_TOKEN_HASH_DIR=/run/janus/env/pharos/beacon-token-hashes" not in compose_text:
    raise SystemExit("pharosd compose hash-dir env does not match Janus production output")
if "PHAROS_BEACON_TOKEN_MODE=janus" not in compose_text:
    raise SystemExit("pharosd compose must run in Janus-only token mode")
if "PHAROS_BEACON_TOKEN_MODE=dual" in compose_text:
    raise SystemExit("pharosd compose must not keep dual token mode after PHAROS-40 cutover")
if "janus_pharos_production_out:/run/janus/env:ro" not in compose_text:
    raise SystemExit("pharosd compose must mount Janus output at /run/janus/env")
if "janus_pharos_production_out:/run/janus/env/pharos:ro" in compose_text:
    raise SystemExit("pharosd compose has an extra nested pharos path in Janus mount")
if "PHAROS_HCLOUD_API_TOKEN_ENV_FILE=/run/janus/env/pharos/providers/hetzner-cloud.env" not in compose_text:
    raise SystemExit("pharosd Hetzner credential must use the Janus env-file boundary")
if "PHAROS_HCLOUD_PROJECT_LABEL=Pharos production" not in compose_text:
    raise SystemExit("pharosd Hetzner project label must identify the attended production scope")
if "PHAROS_HCLOUD_EXECUTE=0" not in compose_text:
    raise SystemExit("pharosd Hetzner execution must remain disabled during PHAROS-146 preflight")
if "PHAROS_HCLOUD_EXECUTE=1" in compose_text:
    raise SystemExit("pharosd Hetzner execution must not be enabled before attended approval")

provider_import_text = provider_import_path.read_text(encoding="utf-8")
provider_render_text = provider_render_path.read_text(encoding="utf-8")
prod_runtime_text = prod_runtime_path.read_text(encoding="utf-8")
csb1_config_text = csb1_config_path.read_text(encoding="utf-8")
secrets_declarations_text = secrets_declarations_path.read_text(encoding="utf-8")
agenix_catalog = json.loads(agenix_catalog_path.read_text(encoding="utf-8"))
provider_output = "/run/janus/env/pharos/providers/hetzner-cloud.env"
agenix_source = "/run/agenix/csb1-hetzner-cloud-provider-env"

if provider_output not in provider_render_text:
    raise SystemExit("production Hetzner renderer does not target the consumer path")
if "JANUS_WARDEN_AGE_PROFILE=${AGE_PROFILE}" not in provider_render_text:
    raise SystemExit("production Hetzner renderer does not bind the reviewed age profile")
if "value_returned=false" not in provider_render_text:
    raise SystemExit("production Hetzner renderer lacks value-free result evidence")
if "chmod 0600 \"$output\"" not in provider_render_text:
    raise SystemExit("production Hetzner renderer does not enforce mode 600")
if "JANUS_PHAROS_PROVIDER_CONSUMER_UID:-10001" not in provider_render_text:
    raise SystemExit("production Hetzner renderer lacks the reviewed Pharos uid")
if "PROVIDER_OUT_VOLUME" not in provider_render_text:
    raise SystemExit("production Hetzner renderer lacks an isolated output volume")
if "janus_pharos_prepare_provider_runtime" not in provider_render_text:
    raise SystemExit("production Hetzner renderer does not use the isolated runtime preparer")
if "janus_pharos_prepare_provider_mountpoint" not in provider_render_text:
    raise SystemExit("production Hetzner renderer does not prepare its nested read-only mountpoint")
if 'janus_pharos_prepare_runtime "$IMAGE"' in provider_render_text:
    raise SystemExit("production Hetzner renderer must not re-own shared beacon volumes")
if "--network none" not in provider_render_text:
    raise SystemExit("production Hetzner renderer does not deny secret-bearing network access")
if provider_render_text.index("env-file preflight") > provider_render_text.index("request_use"):
    raise SystemExit("production Hetzner renderer must preflight before issuing a permit")
if "janus_pharos_production_provider_out:/run/janus/env/pharos/providers:ro" not in compose_text:
    raise SystemExit("pharosd does not mount the isolated provider output read-only")
if "JANUS_PHAROS_PROVIDER_OUT_VOLUME:-janus_pharos_production_provider_out" not in compose_text:
    raise SystemExit("compose does not declare the reviewed external provider output volume")
provider_runtime_body = prod_runtime_text.split(
    "janus_pharos_prepare_provider_runtime()", 1
)[1].split("janus_pharos_prepare_provider_mountpoint()", 1)[0]
if "/run/janus/env" in provider_runtime_body:
    raise SystemExit("provider runtime preparer must not re-own shared beacon output")
if 'if ! first_entry=$(find "$mountpoint"' not in prod_runtime_text:
    raise SystemExit("provider mountpoint preparer must reject hidden shared-volume content")

if agenix_source not in provider_import_text:
    raise SystemExit("production Hetzner importer does not use the reviewed agenix source")
if "set +x" not in provider_import_text or "value_returned=false" not in provider_import_text:
    raise SystemExit("production Hetzner importer lacks value-output protections")
if "printf '%s' \"$PHAROS_HCLOUD_API_TOKEN\" | age" not in provider_import_text:
    if "printf '%s' \"$provider_token\" | age" not in provider_import_text:
        raise SystemExit("production Hetzner importer does not re-encrypt only the provider token")
if 'source "$SOURCE_FILE"' in provider_import_text or "set -a" in provider_import_text:
    raise SystemExit("production Hetzner importer must parse the enrollment file as data")
if "--network none" not in provider_import_text:
    raise SystemExit("production Hetzner importer does not isolate secret-bearing containers")
if agenix_source in compose_text:
    raise SystemExit("pharosd must not mount the root-only agenix enrollment source")

if "age.secrets.csb1-pharos-hetzner-cloud-provider-env" in csb1_config_text:
    raise SystemExit("stale Hetzner agenix declaration name")
if "age.secrets.csb1-hetzner-cloud-provider-env" not in csb1_config_text:
    raise SystemExit("missing csb1 Hetzner agenix declaration")
for fragment in [
    'path = "/run/agenix/csb1-hetzner-cloud-provider-env";',
    'owner = "root";',
    'group = "root";',
    'mode = "0400";',
]:
    if fragment not in csb1_config_text:
        raise SystemExit(f"csb1 Hetzner agenix declaration missing {fragment}")
if '"csb1-hetzner-cloud-provider-env.age".publicKeys = markus ++ csb1;' not in secrets_declarations_text:
    raise SystemExit("missing Hetzner agenix recipient declaration")

catalog_by_id = {entry["id"]: entry for entry in agenix_catalog}
catalog_provider = catalog_by_id.get("csb1-hetzner-cloud-provider-env")
if not catalog_provider:
    raise SystemExit("missing Janus catalog descriptor for the Hetzner provider credential")
expect_subset(
    catalog_provider,
    {
        "display_name": "Hetzner Cloud API token for Pharos",
        "provider": "agenix",
        "classification": "high",
        "owner": "platform",
        "scope": "csb1",
        "source": "secrets/csb1-hetzner-cloud-provider-env.age",
        "rotation_days": 180,
        "lifecycle": "active",
        "status": "managed",
        "use_enabled": True,
        "consumer_count": 1,
        "egress_mode": "connector-required",
        "tags": ["pharos", "provider", "hetzner"],
    },
    "Hetzner agenix catalog descriptor",
)
PY

echo "ok: Pharos Janus env-file and sidecar profiles are value-free"
