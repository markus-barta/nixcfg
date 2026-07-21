#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
COMPOSE_DIR=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
SIDECAR_SMOKE="${SCRIPT_DIR}/../pharos-nonprod/run-sidecar-smoke.sh"
RETIRE_HOST="${SCRIPT_DIR}/../pharos-production/retire-host.sh"
RENDER_SIDECARS="${SCRIPT_DIR}/../pharos-production/render-sidecars.sh"
HOST=retirementsmoke
VOLUME_PREFIX=${JANUS_PHAROS_RETIREMENT_SMOKE_VOLUME_PREFIX:-"janus_pharos_retirement_smoke_$(date +%s)_$$"}
IMAGE=${JANUS_ENGINE_IMAGE:-}

for dependency in awk docker grep jq sha256sum; do
  command -v "$dependency" >/dev/null 2>&1 || {
    printf 'janus pharos retirement smoke missing dependency\n' >&2
    exit 1
  }
done

if [[ ! "$VOLUME_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]]; then
  printf 'janus pharos retirement smoke invalid volume prefix\n' >&2
  exit 1
fi

if [ -z "$IMAGE" ]; then
  IMAGE=$(
    awk '
      /^[[:space:]]+janus-engine-staged:/ { in_service = 1; next }
      in_service && /^    image:/ { print $2; exit }
      in_service && /^  [A-Za-z0-9_-]+:/ { exit }
    ' "${COMPOSE_DIR}/docker-compose.yml"
  )
fi
if [ -z "$IMAGE" ]; then
  printf 'janus pharos retirement smoke missing engine image\n' >&2
  exit 1
fi

AGE_VOLUME="${VOLUME_PREFIX}_age"
STORE_VOLUME="${VOLUME_PREFIX}_secrets"
PERMIT_VOLUME="${VOLUME_PREFIX}_permits"
OUT_VOLUME="${VOLUME_PREFIX}_out"
METADATA_VOLUME="${VOLUME_PREFIX}_metadata"
LIFECYCLE_VOLUME="${VOLUME_PREFIX}_lifecycle"
TMP_DIR=$(mktemp -d)

cleanup() {
  rm -r "$TMP_DIR"
  docker volume rm \
    "$AGE_VOLUME" \
    "$STORE_VOLUME" \
    "$PERMIT_VOLUME" \
    "$OUT_VOLUME" \
    "$METADATA_VOLUME" \
    "$LIFECYCLE_VOLUME" \
    >/dev/null 2>&1 || true
}
trap cleanup EXIT

provider_digest() {
  docker run --rm \
    -v "${STORE_VOLUME}:/var/lib/janus/secrets:ro" \
    --entrypoint sha256sum "$IMAGE" \
    "/var/lib/janus/secrets/pharos/${HOST}/PHAROS_BEACON_RETIREMENTSMOKE_TOKEN.age" |
    awk '{ print $1 }'
}

JANUS_ENGINE_IMAGE="$IMAGE" \
  JANUS_PHAROS_CONTRACT_DIR="$SCRIPT_DIR" \
  JANUS_PHAROS_CONTRACT_NAME=retirement-smoke \
  JANUS_PHAROS_SCOPE_ENVIRONMENT=retirement-smoke \
  JANUS_PHAROS_SMOKE_HOSTS="$HOST" \
  JANUS_PHAROS_SMOKE_ROOT="${TMP_DIR}/sidecar-state" \
  JANUS_PHAROS_SMOKE_VOLUME_PREFIX="$VOLUME_PREFIX" \
  "$SIDECAR_SMOKE" >"${TMP_DIR}/sidecar.out"
grep -Fq 'value_returned=false sidecars=validated permits_consumed=true' "${TMP_DIR}/sidecar.out"

before_provider=$(provider_digest)
[[ "$before_provider" =~ ^[0-9a-f]{64}$ ]]

JANUS_ENGINE_IMAGE="$IMAGE" \
  JANUS_PHAROS_CONTRACT_DIR="$SCRIPT_DIR" \
  JANUS_PHAROS_RETIREMENTS_FILE="${SCRIPT_DIR}/retired-hosts.json" \
  JANUS_PHAROS_VOLUME_PREFIX="$VOLUME_PREFIX" \
  JANUS_PHAROS_SCOPE=pharos/csb1/nonprod-retirement-smoke \
  JANUS_PHAROS_SCOPE_ENVIRONMENT=retirement-smoke \
  JANUS_PHAROS_LOCK_ROOT="${TMP_DIR}/locks" \
  JANUS_PHAROS_RETIREMENT_FIXTURE=1 \
  "$RETIRE_HOST" apply "$HOST" >"${TMP_DIR}/apply.out"
grep -Eq '^janusd-admin pharos-beacon retire host=retirementsmoke state=complete .* value_returned=false provider_deleted=false$' \
  "${TMP_DIR}/apply.out"

docker run --rm \
  -v "${OUT_VOLUME}:/run/janus/env:ro" \
  --entrypoint sh "$IMAGE" \
  -c 'test ! -e /run/janus/env/pharos/beacons/retirementsmoke.env
      test ! -e /run/janus/env/pharos/beacon-token-hashes/retirementsmoke.json'

after_provider=$(provider_digest)
[ "$before_provider" = "$after_provider" ]

docker run --rm \
  -v "${LIFECYCLE_VOLUME}:/var/lib/janus/lifecycle:ro" \
  --entrypoint sh "$IMAGE" \
  -c 'set -eu
      test -f /var/lib/janus/lifecycle/pharos-retirements/retirementsmoke.json
      test "$(find /var/lib/janus/lifecycle/tombstones -maxdepth 1 -type f | wc -l | tr -d " ")" = 1'

JANUS_ENGINE_IMAGE="$IMAGE" \
  JANUS_PHAROS_CONTRACT_DIR="$SCRIPT_DIR" \
  JANUS_PHAROS_RETIREMENTS_FILE="${SCRIPT_DIR}/retired-hosts.json" \
  JANUS_PHAROS_VOLUME_PREFIX="$VOLUME_PREFIX" \
  JANUS_PHAROS_SCOPE=pharos/csb1/nonprod-retirement-smoke \
  JANUS_PHAROS_SCOPE_ENVIRONMENT=retirement-smoke \
  JANUS_PHAROS_LOCK_ROOT="${TMP_DIR}/locks" \
  JANUS_PHAROS_RETIREMENT_FIXTURE=1 \
  "$RETIRE_HOST" reconcile "$HOST" >"${TMP_DIR}/reconcile.out"
grep -Eq '^janusd-admin pharos-beacon reconcile host=retirementsmoke state=complete .* value_returned=false provider_deleted=false$' \
  "${TMP_DIR}/reconcile.out"

JANUS_ENGINE_IMAGE="$IMAGE" \
  JANUS_PHAROS_CONTRACT_DIR="$SCRIPT_DIR" \
  JANUS_PHAROS_RETIREMENTS_FILE="${SCRIPT_DIR}/retired-hosts.json" \
  JANUS_PHAROS_VOLUME_PREFIX="$VOLUME_PREFIX" \
  JANUS_PHAROS_SCOPE=pharos/csb1/nonprod-retirement-smoke \
  JANUS_PHAROS_SCOPE_ENVIRONMENT=retirement-smoke \
  JANUS_PHAROS_LOCK_ROOT="${TMP_DIR}/locks" \
  JANUS_PHAROS_RETIREMENT_FIXTURE=1 \
  "$RETIRE_HOST" apply "$HOST" >"${TMP_DIR}/replay.out"
grep -Eq '^janusd-admin pharos-beacon retire host=retirementsmoke state=complete .* value_returned=false provider_deleted=false$' \
  "${TMP_DIR}/replay.out"

JANUS_ENGINE_IMAGE="$IMAGE" \
  JANUS_PHAROS_CONTRACT_DIR="$SCRIPT_DIR" \
  JANUS_PHAROS_RETIREMENTS_FILE="${SCRIPT_DIR}/retired-hosts.json" \
  JANUS_PHAROS_HOSTS="$HOST" \
  JANUS_PHAROS_VOLUME_PREFIX="$VOLUME_PREFIX" \
  JANUS_PHAROS_SCOPE=pharos/csb1/nonprod-retirement-smoke \
  JANUS_PHAROS_SCOPE_ENVIRONMENT=retirement-smoke \
  "$RENDER_SIDECARS" >"${TMP_DIR}/rerender.out"
grep -Fq 'sidecars rendered hosts=0 value_returned=false' "${TMP_DIR}/rerender.out"

docker run --rm \
  -v "${OUT_VOLUME}:/run/janus/env:ro" \
  --entrypoint sh "$IMAGE" \
  -c 'test ! -e /run/janus/env/pharos/beacons/retirementsmoke.env
      test ! -e /run/janus/env/pharos/beacon-token-hashes/retirementsmoke.json'
[ "$before_provider" = "$(provider_digest)" ]

printf 'ok: janus pharos retirement smoke passed host=%s state=complete replay=idempotent rerender=excluded value_returned=false provider_deleted=false\n' "$HOST"
