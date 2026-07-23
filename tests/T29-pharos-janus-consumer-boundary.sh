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
COMPOSE="$REPO_ROOT/hosts/csb1/docker/docker-compose.yml"
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

python3 - \
  "$RUNTIME" \
  "$PROD_RENDER" \
  "$NONPROD_RENDER" \
  "$RETIRE_HOST" \
  "$PROVIDER_RENDER" \
  "$COMPOSE" \
  "$JUSTFILE" <<'PY'
import pathlib
import sys

runtime_path = pathlib.Path(sys.argv[1])
prod_render_path = pathlib.Path(sys.argv[2])
nonprod_render_path = pathlib.Path(sys.argv[3])
retire_path = pathlib.Path(sys.argv[4])
provider_render_path = pathlib.Path(sys.argv[5])
compose_path = pathlib.Path(sys.argv[6])
justfile_path = pathlib.Path(sys.argv[7])

runtime = runtime_path.read_text(encoding="utf-8")
prod_render = prod_render_path.read_text(encoding="utf-8")
nonprod_render = nonprod_render_path.read_text(encoding="utf-8")
retire = retire_path.read_text(encoding="utf-8")
provider_render = provider_render_path.read_text(encoding="utf-8")
compose = compose_path.read_text(encoding="utf-8")
justfile = justfile_path.read_text(encoding="utf-8")

required_runtime = [
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

compose_required = [
    '    user: "10001:999"',
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
PY

echo "ok: Pharos reads only the validated Janus hash projection as its declared non-root identity"
