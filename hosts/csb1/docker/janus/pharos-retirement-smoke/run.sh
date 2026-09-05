#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
COMPOSE_DIR=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
SIDECAR_SMOKE="${SCRIPT_DIR}/../pharos-nonprod/run-sidecar-smoke.sh"
RETIRE_HOST="${SCRIPT_DIR}/../pharos-production/retire-host.sh"
RENDER_SIDECARS="${SCRIPT_DIR}/../pharos-production/render-sidecars.sh"
HOST=retirementsmoke
ACTIVE_HOST=retirementactive
VOLUME_PREFIX=${JANUS_PHAROS_RETIREMENT_SMOKE_VOLUME_PREFIX:-"janus_pharos_retirement_smoke_$(date +%s)_$$"}
IMAGE=${JANUS_ENGINE_IMAGE:-}
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../runtime-image-policy.sh"

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
      /^    janus-engine-staged = {/ { in_service = 1; next }
      in_service && /^      image = "/ { gsub(/^      image = "|";$/, ""); print; exit }
      in_service && /^    };/ { exit }
    ' "${COMPOSE_DIR}/compose-spec.nix"
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
HASH_OUT_VOLUME="${VOLUME_PREFIX}_hash_out"
METADATA_VOLUME="${VOLUME_PREFIX}_metadata"
LIFECYCLE_VOLUME="${VOLUME_PREFIX}_lifecycle"
TMP_DIR=$(mktemp -d)
DETACHED_CONTRACT_DIR="${TMP_DIR}/detached-contract"
mkdir -p "${TMP_DIR}/retirement-authority-state"
chmod 0700 "${TMP_DIR}/retirement-authority-state"

cleanup() {
  rm -r "$TMP_DIR"
  docker volume rm \
    "$AGE_VOLUME" \
    "$STORE_VOLUME" \
    "$PERMIT_VOLUME" \
    "$OUT_VOLUME" \
    "$HASH_OUT_VOLUME" \
    "$METADATA_VOLUME" \
    "$LIFECYCLE_VOLUME" \
    >/dev/null 2>&1 || true
}
trap cleanup EXIT

provider_digest() {
  docker run --rm \
    -v "${STORE_VOLUME}:/var/lib/janus/secrets:ro" \
    --entrypoint sha256sum "$JANUS_VOLUME_HELPER_IMAGE" \
    "/var/lib/janus/secrets/pharos/${HOST}/PHAROS_BEACON_RETIREMENTSMOKE_TOKEN.age" |
    awk '{ print $1 }'
}

JANUS_ENGINE_IMAGE="$IMAGE" \
  JANUS_PHAROS_CONTRACT_DIR="$SCRIPT_DIR" \
  JANUS_PHAROS_CONTRACT_NAME=retirement-smoke \
  JANUS_PHAROS_SCOPE_ENVIRONMENT=retirement-smoke \
  JANUS_PHAROS_SMOKE_HOSTS="$HOST $ACTIVE_HOST" \
  JANUS_PHAROS_SMOKE_ROOT="${TMP_DIR}/sidecar-state" \
  JANUS_PHAROS_SMOKE_VOLUME_PREFIX="$VOLUME_PREFIX" \
  JANUS_PHAROS_SMOKE_AUTHORITY_CONTRACT_DIR="${SCRIPT_DIR}/../pharos-production" \
  JANUS_PHAROS_SMOKE_AUTHORITY_HOST_ROOT="${TMP_DIR}/sidecar-authority-state" \
  JANUS_PHAROS_SMOKE_IDENTITYD_COMPOSE_PROJECT="$VOLUME_PREFIX" \
  "$SIDECAR_SMOKE" >"${TMP_DIR}/sidecar.out"
grep -Fq 'value_returned=false sidecars=validated consumer_projection=validated permits_consumed=true' \
  "${TMP_DIR}/sidecar.out"

# Repeat against the same private and projection volumes. This proves a normal
# rerender can restage Janus ownership without breaking the Pharos projection.
JANUS_ENGINE_IMAGE="$IMAGE" \
  JANUS_PHAROS_CONTRACT_DIR="$SCRIPT_DIR" \
  JANUS_PHAROS_CONTRACT_NAME=retirement-smoke \
  JANUS_PHAROS_SCOPE_ENVIRONMENT=retirement-smoke \
  JANUS_PHAROS_SMOKE_HOSTS="$HOST $ACTIVE_HOST" \
  JANUS_PHAROS_SMOKE_ROOT="${TMP_DIR}/sidecar-state" \
  JANUS_PHAROS_SMOKE_VOLUME_PREFIX="$VOLUME_PREFIX" \
  JANUS_PHAROS_SMOKE_AUTHORITY_CONTRACT_DIR="${SCRIPT_DIR}/../pharos-production" \
  JANUS_PHAROS_SMOKE_AUTHORITY_HOST_ROOT="${TMP_DIR}/sidecar-authority-state" \
  JANUS_PHAROS_SMOKE_IDENTITYD_COMPOSE_PROJECT="$VOLUME_PREFIX" \
  "$SIDECAR_SMOKE" >"${TMP_DIR}/sidecar-rerender.out"
grep -Fq 'value_returned=false sidecars=validated consumer_projection=validated permits_consumed=true' \
  "${TMP_DIR}/sidecar-rerender.out"

docker run --rm --network none --user 10001:999 \
  -v "${OUT_VOLUME}:/private:ro" \
  -v "${HASH_OUT_VOLUME}:/projection:ro" \
  --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
  -c '
set -eu
test ! -r /private/pharos/beacon-token-hashes/current
test -r /projection/current
IFS= read -r generation </projection/current
printf "%s" "$generation" | grep -Eq "^[0-9a-f]{64}$"
test -r "/projection/generation-${generation}.json"
'

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
  JANUS_PHAROS_AUTHORITY_HOST_ROOT="${TMP_DIR}/retirement-authority-state" \
  JANUS_PHAROS_IDENTITYD_COMPOSE_PROJECT="$VOLUME_PREFIX" \
  "$RETIRE_HOST" apply "$HOST" >"${TMP_DIR}/apply.out"
grep -Eq '^janusd-admin pharos-beacon retire host=retirementsmoke state=complete .* value_returned=false provider_deleted=false$' \
  "${TMP_DIR}/apply.out"

docker run --rm \
  -v "${OUT_VOLUME}:/run/janus/env:ro" \
  --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
  -c 'test ! -e /run/janus/env/pharos/beacons/retirementsmoke.env
      test ! -e /run/janus/env/pharos/beacon-token-hashes/retirementsmoke.json'

docker run --rm --network none --user 10001:999 \
  -v "${HASH_OUT_VOLUME}:/projection:ro" \
  --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
  -c '
set -eu
IFS= read -r generation </projection/current
generation_file="/projection/generation-${generation}.json"
test -r "$generation_file"
! grep -q "\"name\":\"retirementsmoke\"" "$generation_file"
'

after_provider=$(provider_digest)
[ "$before_provider" = "$after_provider" ]

docker run --rm \
  -v "${LIFECYCLE_VOLUME}:/var/lib/janus/lifecycle:ro" \
  --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
  -c 'set -eu
      test -f /var/lib/janus/lifecycle/pharos-retirements/retirementsmoke.json
      test "$(find /var/lib/janus/lifecycle/tombstones -maxdepth 1 -type f | wc -l | tr -d " ")" = 1'

# Retirement must have materialized the destroyed lifecycle entry before the
# detach operation can prove it removed anything. Keep both checks fail-closed:
# a missing or unreadable metadata file is a failure, not evidence of absence.
docker run --rm \
  -v "${METADATA_VOLUME}:/var/lib/janus/metadata:ro" \
  --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
  -c 'set -eu
      test -r /var/lib/janus/metadata/metadata.toml
      grep -Fq "name = \"PHAROS_BEACON_RETIREMENTSMOKE_TOKEN\"" /var/lib/janus/metadata/metadata.toml
      grep -Fq "lifecycle = \"destroyed\"" /var/lib/janus/metadata/metadata.toml'

JANUS_ENGINE_IMAGE="$IMAGE" \
  JANUS_PHAROS_CONTRACT_DIR="$SCRIPT_DIR" \
  JANUS_PHAROS_RETIREMENTS_FILE="${SCRIPT_DIR}/retired-hosts.json" \
  JANUS_PHAROS_VOLUME_PREFIX="$VOLUME_PREFIX" \
  JANUS_PHAROS_SCOPE=pharos/csb1/nonprod-retirement-smoke \
  JANUS_PHAROS_SCOPE_ENVIRONMENT=retirement-smoke \
  JANUS_PHAROS_LOCK_ROOT="${TMP_DIR}/locks" \
  JANUS_PHAROS_RETIREMENT_FIXTURE=1 \
  JANUS_PHAROS_AUTHORITY_HOST_ROOT="${TMP_DIR}/retirement-authority-state" \
  JANUS_PHAROS_IDENTITYD_COMPOSE_PROJECT="$VOLUME_PREFIX" \
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
  JANUS_PHAROS_AUTHORITY_HOST_ROOT="${TMP_DIR}/retirement-authority-state" \
  JANUS_PHAROS_IDENTITYD_COMPOSE_PROJECT="$VOLUME_PREFIX" \
  "$RETIRE_HOST" apply "$HOST" >"${TMP_DIR}/replay.out"
grep -Eq '^janusd-admin pharos-beacon retire host=retirementsmoke state=complete .* value_returned=false provider_deleted=false$' \
  "${TMP_DIR}/replay.out"

mkdir -p "$DETACHED_CONTRACT_DIR"
cp \
  "${SCRIPT_DIR}/managed-env-files.toml" \
  "${SCRIPT_DIR}/metadata.toml" \
  "${SCRIPT_DIR}/retired-hosts.json" \
  "${SCRIPT_DIR}/runtime-role-authorization-fixture.sh" \
  "$DETACHED_CONTRACT_DIR/"
cp -R "${SCRIPT_DIR}/../pharos-production/authority" "$DETACHED_CONTRACT_DIR/"
cat >"${DETACHED_CONTRACT_DIR}/secretspec.toml" <<'EOF'
[project]
name = "pharos"
revision = "1.0"

[profiles.retirementactive]
PHAROS_BEACON_RETIREMENTACTIVE_TOKEN = { description = "Isolated active peer for the retirement smoke", required = true }
EOF

JANUS_ENGINE_IMAGE="$IMAGE" \
  JANUS_PHAROS_CONTRACT_DIR="$DETACHED_CONTRACT_DIR" \
  JANUS_PHAROS_RETIREMENTS_FILE="${DETACHED_CONTRACT_DIR}/retired-hosts.json" \
  JANUS_PHAROS_VOLUME_PREFIX="$VOLUME_PREFIX" \
  JANUS_PHAROS_SCOPE=pharos/csb1/nonprod-retirement-smoke \
  JANUS_PHAROS_SCOPE_ENVIRONMENT=retirement-smoke \
  JANUS_PHAROS_LOCK_ROOT="${TMP_DIR}/locks" \
  JANUS_PHAROS_RETIREMENT_FIXTURE=1 \
  JANUS_PHAROS_AUTHORITY_HOST_ROOT="${TMP_DIR}/retirement-authority-state" \
  JANUS_PHAROS_IDENTITYD_COMPOSE_PROJECT="$VOLUME_PREFIX" \
  "$RETIRE_HOST" detach "$HOST" >"${TMP_DIR}/detach.out"
grep -Eq '^janusd-admin pharos-beacon detach-metadata host=retirementsmoke state=complete .* metadata_detached=true value_returned=false provider_deleted=false$' \
  "${TMP_DIR}/detach.out"

JANUS_ENGINE_IMAGE="$IMAGE" \
  JANUS_PHAROS_CONTRACT_DIR="$DETACHED_CONTRACT_DIR" \
  JANUS_PHAROS_RETIREMENTS_FILE="${DETACHED_CONTRACT_DIR}/retired-hosts.json" \
  JANUS_PHAROS_VOLUME_PREFIX="$VOLUME_PREFIX" \
  JANUS_PHAROS_SCOPE=pharos/csb1/nonprod-retirement-smoke \
  JANUS_PHAROS_SCOPE_ENVIRONMENT=retirement-smoke \
  JANUS_PHAROS_LOCK_ROOT="${TMP_DIR}/locks" \
  JANUS_PHAROS_RETIREMENT_FIXTURE=1 \
  JANUS_PHAROS_AUTHORITY_HOST_ROOT="${TMP_DIR}/retirement-authority-state" \
  JANUS_PHAROS_IDENTITYD_COMPOSE_PROJECT="$VOLUME_PREFIX" \
  "$RETIRE_HOST" detach "$HOST" >"${TMP_DIR}/detach-replay.out"
grep -Eq '^janusd-admin pharos-beacon detach-metadata host=retirementsmoke state=complete .* metadata_detached=false value_returned=false provider_deleted=false$' \
  "${TMP_DIR}/detach-replay.out"

docker run --rm \
  -v "${METADATA_VOLUME}:/var/lib/janus/metadata:ro" \
  --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
  -c 'set -eu
      test -r /var/lib/janus/metadata/metadata.toml
      if grep -q PHAROS_BEACON_RETIREMENTSMOKE_TOKEN /var/lib/janus/metadata/metadata.toml; then
        exit 1
      fi'

mkdir -p "${TMP_DIR}/authority-state"
chmod 0700 "${TMP_DIR}/authority-state"

JANUS_ENGINE_IMAGE="$IMAGE" \
  JANUS_PHAROS_CONTRACT_DIR="$DETACHED_CONTRACT_DIR" \
  JANUS_PHAROS_RETIREMENTS_FILE="${DETACHED_CONTRACT_DIR}/retired-hosts.json" \
  JANUS_PHAROS_HOSTS="$HOST $ACTIVE_HOST" \
  JANUS_PHAROS_VOLUME_PREFIX="$VOLUME_PREFIX" \
  JANUS_PHAROS_SCOPE=pharos/csb1/nonprod-retirement-smoke \
  JANUS_PHAROS_SCOPE_ENVIRONMENT=retirement-smoke \
  JANUS_PHAROS_RETIREMENT_FIXTURE=1 \
  JANUS_PHAROS_AUTHORITY_HOST_ROOT="${TMP_DIR}/authority-state" \
  JANUS_PHAROS_IDENTITYD_COMPOSE_PROJECT="$VOLUME_PREFIX" \
  JANUS_PHAROS_ROLE_AUTHORIZATION_CONTRACT="${DETACHED_CONTRACT_DIR}/runtime-role-authorization-fixture.sh" \
  JANUS_PHAROS_LOCK_FILE="${TMP_DIR}/render.lock" \
  "$RENDER_SIDECARS" >"${TMP_DIR}/rerender.out"
grep -Fq 'sidecars rendered hosts=1 value_returned=false' "${TMP_DIR}/rerender.out"

docker run --rm \
  -v "${OUT_VOLUME}:/run/janus/env:ro" \
  --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
  -c 'test ! -e /run/janus/env/pharos/beacons/retirementsmoke.env
      test ! -e /run/janus/env/pharos/beacon-token-hashes/retirementsmoke.json
      test -r /run/janus/env/pharos/beacons/retirementactive.env
      test -r /run/janus/env/pharos/beacon-token-hashes/retirementactive.json'
docker run --rm --network none --user 10001:999 \
  -v "${HASH_OUT_VOLUME}:/projection:ro" \
  --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
  -c '
set -eu
IFS= read -r generation </projection/current
generation_file="/projection/generation-${generation}.json"
test -r "$generation_file"
cat "$generation_file"
' >"${TMP_DIR}/rerender-generation.json"
jq -e --arg active_host "$ACTIVE_HOST" --arg retired_host "$HOST" '
  .schema == "inspr.pharos.beacon-token-generation.v2"
  and (.hosts | length) == 1
  and .hosts[0].name == $active_host
  and all(.hosts[]; .name != $retired_host)
' "${TMP_DIR}/rerender-generation.json" >/dev/null
[ "$before_provider" = "$(provider_digest)" ]

printf 'ok: janus pharos retirement smoke passed host=%s state=complete replay=idempotent rerender=excluded value_returned=false provider_deleted=false\n' "$HOST"
