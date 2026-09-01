#!/usr/bin/env bash
# T29-pharos-janus-consumer-boundary.sh
# Description: Enforce the private Janus producer and Pharos hash projection boundary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME="$REPO_ROOT/hosts/csb1/docker/janus/pharos-production/runtime-lib.sh"
PROD_RENDER="$REPO_ROOT/hosts/csb1/docker/janus/pharos-production/render-sidecars.sh"
NONPROD_RENDER="$REPO_ROOT/hosts/csb1/docker/janus/pharos-nonprod/run-sidecar-smoke.sh"
RETIRE_HOST="$REPO_ROOT/hosts/csb1/docker/janus/pharos-production/retire-host.sh"
PROVIDER_RENDER="$REPO_ROOT/hosts/csb1/docker/janus/pharos-production/render-hetzner-provider.sh"
PROVIDER_SMOKE="$REPO_ROOT/hosts/csb1/docker/janus/pharos-provider-smoke/run.sh"
RETIREMENT_SMOKE="$REPO_ROOT/hosts/csb1/docker/janus/pharos-retirement-smoke/run.sh"
COMPOSE="$REPO_ROOT/hosts/csb1/docker/compose-spec.nix"
CSB1_CONFIG="$REPO_ROOT/hosts/csb1/configuration.nix"
JUSTFILE="$REPO_ROOT/justfile"

for script in \
  "$RUNTIME" \
  "$PROD_RENDER" \
  "$NONPROD_RENDER" \
  "$RETIRE_HOST" \
  "$PROVIDER_RENDER" \
  "$PROVIDER_SMOKE" \
  "$RETIREMENT_SMOKE"; do
  bash -n "$script"
done

authority_fixture=$(mktemp -d)
cleanup_authority_fixture() {
  chmod 0700 "$authority_fixture/restricted" 2>/dev/null || true
  rmdir \
    "$authority_fixture/restricted/production" \
    "$authority_fixture/restricted" \
    "$authority_fixture/accessible/production" \
    "$authority_fixture/accessible" \
    "$authority_fixture" 2>/dev/null || true
}
trap cleanup_authority_fixture EXIT
mkdir -p \
  "$authority_fixture/accessible/production" \
  "$authority_fixture/restricted/production"
chmod 0700 \
  "$authority_fixture/accessible" \
  "$authority_fixture/accessible/production" \
  "$authority_fixture/restricted" \
  "$authority_fixture/restricted/production"

authority_preflight() {
  bash -c 'source "$1"; janus_pharos_production_authority_root_preflight "$2"' \
    bash "$RUNTIME" "$1"
}

authority_preflight "$authority_fixture/accessible/production"
python3 - "$authority_fixture/accessible/production" <<'PY'
import os
import stat
import sys

mode = stat.S_IMODE(os.stat(sys.argv[1]).st_mode)
if mode != 0o700:
    raise SystemExit(f"authority preflight changed restrictive mode to {mode:o}")
PY

chmod 000 "$authority_fixture/restricted"
if permission_error=$(authority_preflight "$authority_fixture/restricted/production" 2>&1); then
  printf 'authority preflight accepted an untraversable custody parent\n' >&2
  exit 1
fi
printf '%s\n' "$permission_error" | grep -Fq 'permission denied' || {
  printf 'authority preflight did not distinguish permission denial\n' >&2
  exit 1
}
chmod 0700 "$authority_fixture/restricted"

if missing_error=$(authority_preflight "$authority_fixture/accessible/missing" 2>&1); then
  printf 'authority preflight accepted a missing custody root\n' >&2
  exit 1
fi
printf '%s\n' "$missing_error" | grep -Fq 'is missing' || {
  printf 'authority preflight did not distinguish a missing root\n' >&2
  exit 1
}

python3 - \
  "$RUNTIME" \
  "$PROD_RENDER" \
  "$NONPROD_RENDER" \
  "$RETIRE_HOST" \
  "$PROVIDER_RENDER" \
  "$COMPOSE" \
  "$CSB1_CONFIG" \
  "$JUSTFILE" <<'PY'
import pathlib
import sys

runtime_path = pathlib.Path(sys.argv[1])
prod_render_path = pathlib.Path(sys.argv[2])
nonprod_render_path = pathlib.Path(sys.argv[3])
retire_path = pathlib.Path(sys.argv[4])
provider_render_path = pathlib.Path(sys.argv[5])
compose_path = pathlib.Path(sys.argv[6])
csb1_config_path = pathlib.Path(sys.argv[7])
justfile_path = pathlib.Path(sys.argv[8])

runtime = runtime_path.read_text(encoding="utf-8")
prod_render = prod_render_path.read_text(encoding="utf-8")
nonprod_render = nonprod_render_path.read_text(encoding="utf-8")
retire = retire_path.read_text(encoding="utf-8")
provider_render = provider_render_path.read_text(encoding="utf-8")
compose = compose_path.read_text(encoding="utf-8")
csb1_config = csb1_config_path.read_text(encoding="utf-8")
justfile = justfile_path.read_text(encoding="utf-8")

required_runtime = [
    "janus_pharos_production_authority_root_preflight()",
    "janus_pharos_load_consumer_identity()",
    "janus_pharos_publish_hash_projection()",
    "config \\",
    "--no-env-resolution",
    "--no-path-resolution",
    '.services.pharosd.user',
    '[[ ! "$configured_user" =~ ^[1-9][0-9]*:[1-9][0-9]*$ ]]',
    '[ "$source_volume" != "$projection_volume" ]',
    '-v "${source_volume}:/source:ro"',
    '-v "${projection_volume}:/projection"',
    "--network none --user 0",
    'source_root=/source/pharos/beacon-token-hashes',
    'generation_target="$projection_root/generation-${generation}.json"',
    'mv "$current_tmp" "$projection_root/current"',
    'chmod 0750 "$projection_root"',
    'chmod 0640 {} +',
    '--network none --user "${consumer_uid}:${consumer_gid}"',
    'cat "$generation_file" >/dev/null',
]
for fragment in required_runtime:
    if fragment not in runtime:
        raise SystemExit(f"runtime consumer boundary missing {fragment!r}")

for writer_name, writer in [
    ("production renderer", prod_render),
    ("non-production smoke", nonprod_render),
    ("retirement", retire),
]:
    if "janus_pharos_publish_hash_projection" not in writer:
        raise SystemExit(f"{writer_name} does not publish through the consumer projection")
    if "relax_sidecar_permissions" in writer:
        raise SystemExit(f"{writer_name} retains the unsafe shared-volume chmod handoff")

for renderer_name, renderer in [
    ("production renderer", prod_render),
    ("non-production smoke", nonprod_render),
    ("provider renderer", provider_render),
]:
    if "janus_pharos_load_consumer_identity" not in renderer:
        raise SystemExit(f"{renderer_name} does not use the declared Pharos identity")

if "janus_pharos_prepare_age_identity" not in nonprod_render:
    raise SystemExit("non-production smoke does not use the shared identity owner contract")
if "keygen_out=" in nonprod_render:
    raise SystemExit("non-production smoke retains a duplicate root-owned identity generator")

compose_required = [
    '      user = "10001:992";',
    "PHAROS_BEACON_TOKEN_HASH_DIR=/run/pharos/beacon-token-hashes",
    "PHAROS_HCLOUD_API_TOKEN_ENV_FILE=/run/pharos/providers/hetzner-cloud.env",
    "janus_pharos_production_hash_out:/run/pharos/beacon-token-hashes:ro",
    "janus_pharos_production_provider_out:/run/pharos/providers:ro",
    "JANUS_PHAROS_HASH_OUT_VOLUME:-janus_pharos_production_hash_out",
]
for fragment in compose_required:
    if fragment not in compose:
        raise SystemExit(f"compose consumer boundary missing {fragment!r}")

compose_forbidden = [
    "janus_pharos_production_out:/run/janus/env:ro",
    "janus_pharos_prepare_provider_mountpoint",
]
for fragment in compose_forbidden:
    if fragment in compose:
        raise SystemExit(f"compose consumer boundary retains {fragment!r}")

if "janus_pharos_prepare_provider_mountpoint" in runtime + provider_render:
    raise SystemExit("obsolete nested provider mountpoint remains")

if "PROJECTION_ONLY=${JANUS_PHAROS_PROJECTION_ONLY:-0}" not in prod_render:
    raise SystemExit("production renderer lacks the no-downtime projection-only migration")
if "janus-pharos-production-seed-projection:" not in justfile:
    raise SystemExit("justfile lacks the reviewed projection seed operation")
for rule in (
    '"d /var/lib/janus-identity-csb1 0700 65532 65532 -"',
    '"d /var/lib/janus-identity-csb1/production 0700 65532 65532 -"',
):
    if rule not in csb1_config:
        raise SystemExit(f"production authority ownership drifted from {rule}")
expected_render_recipe = """janus-pharos-production-render:
    cd hosts/csb1/docker && sudo -- ./janus/pharos-production/render-sidecars.sh"""
if expected_render_recipe not in justfile:
    raise SystemExit("production render recipe does not cross the documented root custody boundary")
PY

echo "ok: Pharos reads only the validated Janus hash projection as its declared non-root identity"
