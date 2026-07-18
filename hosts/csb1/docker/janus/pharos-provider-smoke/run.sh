#!/usr/bin/env bash
set -Eeuo pipefail
set +x

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DOCKER_DIR=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
CONTRACT_DIR=$(cd -- "${SCRIPT_DIR}/../pharos-production" && pwd)
RENDER_SCRIPT="${CONTRACT_DIR}/render-hetzner-provider.sh"
VOLUME_PREFIX="janus_pharos_provider_smoke_$$"
PROVIDER_OUT_VOLUME="${VOLUME_PREFIX}_provider_out"
SHARED_OUT_VOLUME="${VOLUME_PREFIX}_out"
IMAGE=$(
  awk '
    /^[[:space:]]+janus-engine-staged:/ { in_service = 1; next }
    in_service && /^    image:/ { print $2; exit }
    in_service && /^  [A-Za-z0-9_-]+:/ { exit }
  ' "${DOCKER_DIR}/docker-compose.yml"
)

if [ "$(id -u)" != 0 ]; then
  printf 'run the isolated Pharos provider smoke as root on csb1\n' >&2
  exit 1
fi
if [ "$(hostname -s)" != csb1 ]; then
  printf 'refusing isolated Pharos provider smoke on the wrong host\n' >&2
  exit 1
fi
if [ -z "$IMAGE" ]; then
  printf 'could not resolve janus-engine-staged image from docker-compose.yml\n' >&2
  exit 1
fi

TMP_DIR=$(mktemp -d)
cleanup() {
  local status=$?
  local volume
  trap - EXIT
  rm -rf "$TMP_DIR"
  for volume in \
    "${VOLUME_PREFIX}_age" \
    "${VOLUME_PREFIX}_secrets" \
    "${VOLUME_PREFIX}_permits" \
    "${VOLUME_PREFIX}_out" \
    "${VOLUME_PREFIX}_metadata" \
    "${VOLUME_PREFIX}_lifecycle" \
    "${VOLUME_PREFIX}_provider_out" \
    "${VOLUME_PREFIX}_provider_permits"; do
    if docker volume inspect "$volume" >/dev/null 2>&1; then
      docker volume rm "$volume" >/dev/null 2>&1 || status=1
    fi
  done
  exit "$status"
}
trap cleanup EXIT

docker volume create "$SHARED_OUT_VOLUME" >/dev/null
shared_before="${TMP_DIR}/shared-before"
docker run --rm --network none --user 0 \
  -v "${SHARED_OUT_VOLUME}:/run/janus/env" \
  --entrypoint sh "$IMAGE" \
  -c '
set -eu
install -d -o 999 -g 999 -m 0750 /run/janus/env/pharos
install -d -o 4242 -g 4343 -m 0711 /run/janus/env/pharos/beacon-token-hashes
printf "%s" "provider-smoke-shared-output-sentinel" > \
  /run/janus/env/pharos/beacon-token-hashes/sentinel
chown 4242:4343 /run/janus/env/pharos/beacon-token-hashes/sentinel
chmod 0640 /run/janus/env/pharos/beacon-token-hashes/sentinel
stat -c "%a %u %g" /run/janus/env/pharos
stat -c "%a %u %g" /run/janus/env/pharos/beacon-token-hashes
stat -c "%a %u %g" /run/janus/env/pharos/beacon-token-hashes/sentinel
sha256sum /run/janus/env/pharos/beacon-token-hashes/sentinel
' >"$shared_before"

absent_mountpoint_out="${TMP_DIR}/absent-mountpoint.out"
if docker run --rm --network none --user 10001:999 \
  -v "${SHARED_OUT_VOLUME}:/run/janus/env:ro" \
  -v "${PROVIDER_OUT_VOLUME}:/run/janus/env/pharos/providers:ro" \
  --entrypoint sh "$IMAGE" \
  -c 'exit 0' >"$absent_mountpoint_out" 2>&1; then
  printf 'isolated Pharos provider smoke expected an absent nested mountpoint to fail\n' >&2
  exit 1
fi

JANUS_PHAROS_CONTRACT_DIR="$CONTRACT_DIR" \
  JANUS_PHAROS_VOLUME_PREFIX="$VOLUME_PREFIX" \
  JANUS_PHAROS_PREPARE_ONLY=1 \
  JANUS_ENGINE_IMAGE="$IMAGE" \
  bash "$RENDER_SCRIPT" >/dev/null

docker run --rm --network none --user 0 \
  -v "${SHARED_OUT_VOLUME}:/run/janus/env" \
  --entrypoint sh "$IMAGE" \
  -c 'printf "%s" "unexpected" > /run/janus/env/pharos/providers/unexpected'
mountpoint_failure_out="${TMP_DIR}/mountpoint-failure.out"
if JANUS_PHAROS_CONTRACT_DIR="$CONTRACT_DIR" \
  JANUS_PHAROS_VOLUME_PREFIX="$VOLUME_PREFIX" \
  JANUS_PHAROS_PREPARE_ONLY=1 \
  JANUS_ENGINE_IMAGE="$IMAGE" \
  bash "$RENDER_SCRIPT" >"$mountpoint_failure_out" 2>&1; then
  printf 'isolated Pharos provider smoke accepted a nonempty nested mountpoint\n' >&2
  exit 1
fi
docker run --rm --network none --user 0 \
  -v "${SHARED_OUT_VOLUME}:/run/janus/env" \
  --entrypoint sh "$IMAGE" \
  -c 'rm /run/janus/env/pharos/providers/unexpected'

docker run --rm --network none --user 0 \
  -v "${SHARED_OUT_VOLUME}:/run/janus/env" \
  --entrypoint sh "$IMAGE" \
  -c '
set -eu
rmdir /run/janus/env/pharos/providers
ln -s beacon-token-hashes /run/janus/env/pharos/providers
'
symlink_failure_out="${TMP_DIR}/symlink-failure.out"
if JANUS_PHAROS_CONTRACT_DIR="$CONTRACT_DIR" \
  JANUS_PHAROS_VOLUME_PREFIX="$VOLUME_PREFIX" \
  JANUS_PHAROS_PREPARE_ONLY=1 \
  JANUS_ENGINE_IMAGE="$IMAGE" \
  bash "$RENDER_SCRIPT" >"$symlink_failure_out" 2>&1; then
  printf 'isolated Pharos provider smoke accepted a symlink nested mountpoint\n' >&2
  exit 1
fi
docker run --rm --network none --user 0 \
  -v "${SHARED_OUT_VOLUME}:/run/janus/env" \
  --entrypoint sh "$IMAGE" \
  -c '
set -eu
test -L /run/janus/env/pharos/providers
rm /run/janus/env/pharos/providers
'
JANUS_PHAROS_CONTRACT_DIR="$CONTRACT_DIR" \
  JANUS_PHAROS_VOLUME_PREFIX="$VOLUME_PREFIX" \
  JANUS_PHAROS_PREPARE_ONLY=1 \
  JANUS_ENGINE_IMAGE="$IMAGE" \
  bash "$RENDER_SCRIPT" >/dev/null

AGE_VOLUME="${VOLUME_PREFIX}_age"
STORE_VOLUME="${VOLUME_PREFIX}_secrets"
recipient=$(
  docker run --rm --network none \
    -v "${AGE_VOLUME}:/run/janus/age:ro" \
    --entrypoint sh "$IMAGE" \
    -c 'test -s /run/janus/age/recipient.pub; cat /run/janus/age/recipient.pub'
)
container_uid=$(docker run --rm --network none --entrypoint id "$IMAGE" -u)
container_gid=$(docker run --rm --network none --entrypoint id "$IMAGE" -g)

fixture="pharos-provider-smoke-fixture-${VOLUME_PREFIX}"
fixture_sha=$(printf '%s' "$fixture" | sha256sum | awk '{ print $1 }')
encrypted_file="${TMP_DIR}/provider.age"
umask 077
printf '%s' "$fixture" | age -r "$recipient" -o "$encrypted_file"

docker run --rm --network none --user 0 \
  -v "${STORE_VOLUME}:/var/lib/janus/secrets" \
  -v "${encrypted_file}:/tmp/provider.age:ro" \
  --entrypoint sh "$IMAGE" \
  -c '
set -eu
uid=$1
gid=$2
dir=/var/lib/janus/secrets/pharos/hetzner-cloud
install -d -o "$uid" -g "$gid" -m 0700 "$dir"
install -o "$uid" -g "$gid" -m 0400 \
  /tmp/provider.age "$dir/PHAROS_HCLOUD_API_TOKEN.age"
' sh "$container_uid" "$container_gid"

render_out="${TMP_DIR}/render.out"
JANUS_PHAROS_CONTRACT_DIR="$CONTRACT_DIR" \
  JANUS_PHAROS_VOLUME_PREFIX="$VOLUME_PREFIX" \
  JANUS_ENGINE_IMAGE="$IMAGE" \
  bash "$RENDER_SCRIPT" >"$render_out"

grep -q 'value_returned=false' "$render_out"
grep -q 'hash_format=none' "$render_out"
grep -q 'permits_consumed=true' "$render_out"
if grep -Fq "$fixture" "$render_out"; then
  printf 'isolated Pharos provider smoke leaked its fixture value\n' >&2
  exit 1
fi

failure_contract="${TMP_DIR}/failure-contract"
mkdir -p "$failure_contract"
cp "${CONTRACT_DIR}/metadata.toml" "${failure_contract}/metadata.toml"
printf '%s\n' '[invalid-provider-manifest' >"${failure_contract}/managed-env-files.toml"
failure_out="${TMP_DIR}/failure.out"
if JANUS_PHAROS_CONTRACT_DIR="$failure_contract" \
  JANUS_PHAROS_VOLUME_PREFIX="$VOLUME_PREFIX" \
  JANUS_ENGINE_IMAGE="$IMAGE" \
  bash "$RENDER_SCRIPT" >"$failure_out" 2>&1; then
  printf 'isolated Pharos provider smoke expected the invalid preflight to fail\n' >&2
  exit 1
fi
if grep -Fq "$fixture" "$failure_out"; then
  printf 'isolated Pharos provider failure path leaked its fixture value\n' >&2
  exit 1
fi

docker run --rm --network none --user 0 \
  -v "${PROVIDER_OUT_VOLUME}:/run/janus/env/pharos/providers:ro" \
  --entrypoint sh "$IMAGE" \
  -c '
set -eu
expected_sha=$1
file=/run/janus/env/pharos/providers/hetzner-cloud.env
test -s "$file"
[ ! -L "$file" ]
[ "$(stat -c "%a" "$file")" = 600 ]
[ "$(stat -c "%u" "$file")" = 10001 ]
[ "$(stat -c "%a" /run/janus/env/pharos/providers)" = 700 ]
line=
IFS= read -r line <"$file"
case "$line" in
PHAROS_HCLOUD_API_TOKEN=*) value=${line#PHAROS_HCLOUD_API_TOKEN=} ;;
*) exit 1 ;;
esac
actual_sha=$(printf "%s" "$value" | sha256sum)
actual_sha=${actual_sha%% *}
[ "$actual_sha" = "$expected_sha" ]
' sh "$fixture_sha"

docker run --rm --network none --user 10001:999 \
  -v "${PROVIDER_OUT_VOLUME}:/run/janus/env/pharos/providers:ro" \
  --entrypoint sh "$IMAGE" \
  -c '
set -eu
expected_sha=$1
file=/run/janus/env/pharos/providers/hetzner-cloud.env
test -r "$file"
line=
IFS= read -r line <"$file"
case "$line" in
PHAROS_HCLOUD_API_TOKEN=*) value=${line#PHAROS_HCLOUD_API_TOKEN=} ;;
*) exit 1 ;;
esac
actual_sha=$(printf "%s" "$value" | sha256sum)
actual_sha=${actual_sha%% *}
[ "$actual_sha" = "$expected_sha" ]
' sh "$fixture_sha"

docker run --rm --network none --user 10002:10002 \
  -v "${PROVIDER_OUT_VOLUME}:/run/janus/env/pharos/providers:ro" \
  --entrypoint sh "$IMAGE" \
  -c 'test ! -r /run/janus/env/pharos/providers/hetzner-cloud.env'

shared_after="${TMP_DIR}/shared-after"
docker run --rm --network none --user 0 \
  -v "${SHARED_OUT_VOLUME}:/run/janus/env:ro" \
  --entrypoint sh "$IMAGE" \
  -c '
set -eu
stat -c "%a %u %g" /run/janus/env/pharos
stat -c "%a %u %g" /run/janus/env/pharos/beacon-token-hashes
stat -c "%a %u %g" /run/janus/env/pharos/beacon-token-hashes/sentinel
sha256sum /run/janus/env/pharos/beacon-token-hashes/sentinel
' >"$shared_after"
if ! cmp -s "$shared_before" "$shared_after"; then
  printf 'isolated Pharos provider smoke changed the shared beacon output volume\n' >&2
  exit 1
fi

docker run --rm --network none --user 0 \
  -v "${SHARED_OUT_VOLUME}:/run/janus/env:ro" \
  --entrypoint sh "$IMAGE" \
  -c '
set -eu
mountpoint=/run/janus/env/pharos/providers
test -d "$mountpoint"
[ ! -L "$mountpoint" ]
[ "$(stat -c "%a" "$mountpoint")" = 700 ]
first_entry=
if ! first_entry=$(find "$mountpoint" -mindepth 1 -maxdepth 1 -print -quit); then
  exit 1
fi
[ -z "$first_entry" ]
'

# Reproduce Compose's exact nested read-only mount topology. Docker refuses to
# start this container when the target is absent from the read-only parent.
docker run --rm --network none --user 10001:999 \
  -v "${SHARED_OUT_VOLUME}:/run/janus/env:ro" \
  -v "${PROVIDER_OUT_VOLUME}:/run/janus/env/pharos/providers:ro" \
  --entrypoint sh "$IMAGE" \
  -c 'test -r /run/janus/env/pharos/providers/hetzner-cloud.env'

fixture=
unset fixture fixture_sha recipient
printf 'ok: isolated Pharos Hetzner provider sidecar smoke passed value_returned=false network=none permits_consumed=true\n'
