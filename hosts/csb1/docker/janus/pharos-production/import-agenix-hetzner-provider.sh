#!/usr/bin/env bash
set -Eeuo pipefail
set +x

on_error() {
  local status=$?
  local line=${1:-unknown}
  printf 'janus pharos Hetzner provider import failed near line %s status=%s\n' "$line" "$status" >&2
}
trap 'on_error "$LINENO"' ERR

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
COMPOSE_DIR=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
RENDER_SCRIPT=${JANUS_PHAROS_PROVIDER_RENDER_SCRIPT:-${SCRIPT_DIR}/render-hetzner-provider.sh}
SOURCE_FILE=${JANUS_PHAROS_PROVIDER_AGENIX_FILE:-/run/agenix/csb1-hetzner-cloud-provider-env}
EXPECTED_HOST=${JANUS_PHAROS_PROVIDER_HOST:-csb1}
VOLUME_PREFIX=${JANUS_PHAROS_VOLUME_PREFIX:-janus_pharos_production}
IMAGE=${JANUS_ENGINE_IMAGE:-}
SECRET_NAME=PHAROS_HCLOUD_API_TOKEN
AGE_PROFILE=hetzner-cloud

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

validate_identifier() {
  local name=$1
  local value=$2
  case "$value" in
  "" | *[!A-Za-z0-9_.-]*)
    printf 'invalid %s: %s\n' "$name" "$value" >&2
    exit 1
    ;;
  esac
}

require_command age
require_command awk
require_command docker
require_command hostname
require_command stat

validate_identifier JANUS_PHAROS_VOLUME_PREFIX "$VOLUME_PREFIX"
validate_identifier JANUS_PHAROS_PROVIDER_HOST "$EXPECTED_HOST"

if [ "$(id -u)" != 0 ]; then
  printf 'run the Hetzner provider import as root on csb1\n' >&2
  exit 1
fi
if [ "$(hostname -s)" != "$EXPECTED_HOST" ]; then
  printf 'refusing Hetzner provider import on the wrong host\n' >&2
  exit 1
fi
if [ ! -f "$SOURCE_FILE" ]; then
  printf 'the reviewed agenix source is not materialized\n' >&2
  exit 1
fi
if [ "$(stat -Lc '%u' "$SOURCE_FILE")" != 0 ] ||
  [ "$(stat -Lc '%g' "$SOURCE_FILE")" != 0 ] ||
  [ "$(stat -Lc '%a' "$SOURCE_FILE")" != 400 ]; then
  printf 'the reviewed agenix source must be root:root mode 400\n' >&2
  exit 1
fi
if [ ! -s "$SOURCE_FILE" ]; then
  printf 'the reviewed agenix source is empty\n' >&2
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
  printf 'could not resolve janus-engine-staged image from docker-compose.yml\n' >&2
  exit 1
fi

JANUS_PHAROS_PREPARE_ONLY=1 \
  JANUS_PHAROS_VOLUME_PREFIX="$VOLUME_PREFIX" \
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
if [ -z "$recipient" ]; then
  printf 'production Janus recipient is empty\n' >&2
  exit 1
fi

container_uid=$(docker run --rm --network none --entrypoint id "$IMAGE" -u)
container_gid=$(docker run --rm --network none --entrypoint id "$IMAGE" -g)
if [ "$container_uid" = 0 ]; then
  printf 'refusing to import into a root-owned Janus runtime\n' >&2
  exit 1
fi

TMP_DIR=$(mktemp -d)
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
encrypted_file="${TMP_DIR}/provider.age"

provider_token=
provider_key_count=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
  PHAROS_HCLOUD_API_TOKEN=*)
    if [ "$provider_key_count" != 0 ]; then
      printf 'the agenix source defines the provider token more than once\n' >&2
      exit 1
    fi
    provider_token=${line#PHAROS_HCLOUD_API_TOKEN=}
    provider_key_count=1
    ;;
  *)
    printf 'the agenix source must contain exactly one provider token assignment\n' >&2
    exit 1
    ;;
  esac
done <"$SOURCE_FILE"

if [ "$provider_key_count" != 1 ] || [ -z "$provider_token" ]; then
  printf 'the agenix source does not define a nonempty provider token\n' >&2
  exit 1
fi

umask 077
printf '%s' "$provider_token" | age -r "$recipient" -o "$encrypted_file"
provider_token=
unset provider_token line

if [ ! -s "$encrypted_file" ]; then
  printf 'provider re-encryption did not produce an artifact\n' >&2
  exit 1
fi

docker run --rm --network none --user 0 \
  -v "${STORE_VOLUME}:/var/lib/janus/secrets" \
  -v "${encrypted_file}:/tmp/provider.age:ro" \
  --entrypoint sh "$IMAGE" \
  -c '
set -eu
profile=$1
secret_name=$2
uid=$3
gid=$4
dir="/var/lib/janus/secrets/pharos/${profile}"
tmp="${dir}/.${secret_name}.age.tmp"
install -d -o "$uid" -g "$gid" -m 0700 "$dir"
install -o "$uid" -g "$gid" -m 0400 /tmp/provider.age "$tmp"
mv "$tmp" "${dir}/${secret_name}.age"
' sh "$AGE_PROFILE" "$SECRET_NAME" "$container_uid" "$container_gid"

JANUS_PHAROS_VOLUME_PREFIX="$VOLUME_PREFIX" \
  JANUS_ENGINE_IMAGE="$IMAGE" \
  bash "$RENDER_SCRIPT"

printf 'ok: imported agenix Hetzner provider credential into Janus value_returned=false source_retained=true\n'
