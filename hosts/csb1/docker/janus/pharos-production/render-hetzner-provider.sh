#!/usr/bin/env bash
set -Eeuo pipefail
set +x

on_error() {
  local status=$?
  local line=${1:-unknown}
  printf 'janus pharos Hetzner provider render failed near line %s status=%s\n' "$line" "$status" >&2
}
trap 'on_error "$LINENO"' ERR

DEFAULT_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_DIR=$(cd -- "${JANUS_PHAROS_CONTRACT_DIR:-$DEFAULT_SCRIPT_DIR}" && pwd)
COMPOSE_DIR=$(cd -- "${DEFAULT_SCRIPT_DIR}/../.." && pwd)
IMAGE=${JANUS_ENGINE_IMAGE:-}
VOLUME_PREFIX=${JANUS_PHAROS_VOLUME_PREFIX:-janus_pharos_production}
SHARED_OUT_VOLUME=${VOLUME_PREFIX}_out
PROVIDER_OUT_VOLUME=${JANUS_PHAROS_PROVIDER_OUT_VOLUME:-${VOLUME_PREFIX}_provider_out}
PROVIDER_PERMIT_VOLUME=${JANUS_PHAROS_PROVIDER_PERMIT_VOLUME:-${VOLUME_PREFIX}_provider_permits}
RUN_SCOPE=${JANUS_PHAROS_SCOPE:-pharos/csb1/production}
SCOPE_ORGANIZATION=${JANUS_PHAROS_SCOPE_ORGANIZATION:-inspr}
SCOPE_PROJECT=${JANUS_PHAROS_SCOPE_PROJECT:-pharos}
SCOPE_REPOSITORY=${JANUS_PHAROS_SCOPE_REPOSITORY:-nixcfg}
SCOPE_ENVIRONMENT=${JANUS_PHAROS_SCOPE_ENVIRONMENT:-production}
PREPARE_ONLY=${JANUS_PHAROS_PREPARE_ONLY:-0}
EXPECTED_HOST=${JANUS_PHAROS_PROVIDER_HOST:-csb1}
LOCK_FILE=${JANUS_PHAROS_PROVIDER_LOCK_FILE:-/run/lock/janus-pharos-hetzner-provider.lock}
CONSUMER_UID=${JANUS_PHAROS_PROVIDER_CONSUMER_UID:-10001}
CONSUMER_GID=${JANUS_PHAROS_PROVIDER_CONSUMER_GID:-999}
AGE_PROFILE=hetzner-cloud
PROFILE_ID=profile.PHAROS_HCLOUD_API_TOKEN
DESTINATION=pharos-provider-hetzner-cloud
OUTPUT_FILE=/run/janus/env/pharos/providers/hetzner-cloud.env

# shellcheck disable=SC1091
source "${DEFAULT_SCRIPT_DIR}/runtime-lib.sh"

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

validate_numeric_id() {
  local name=$1
  local value=$2
  case "$value" in
  "" | *[!0-9]*)
    printf 'invalid %s\n' "$name" >&2
    exit 1
    ;;
  esac
  if [ "$value" = 0 ]; then
    printf '%s must be non-root\n' "$name" >&2
    exit 1
  fi
}

require_command awk
require_command docker
require_command flock
require_command grep
require_command hostname
require_command id
require_command jq
require_command sed

validate_identifier JANUS_PHAROS_VOLUME_PREFIX "$VOLUME_PREFIX"
validate_identifier JANUS_PHAROS_PROVIDER_OUT_VOLUME "$PROVIDER_OUT_VOLUME"
validate_identifier JANUS_PHAROS_PROVIDER_PERMIT_VOLUME "$PROVIDER_PERMIT_VOLUME"
validate_identifier JANUS_PHAROS_PROVIDER_HOST "$EXPECTED_HOST"
validate_identifier JANUS_PHAROS_SCOPE_ORGANIZATION "$SCOPE_ORGANIZATION"
validate_identifier JANUS_PHAROS_SCOPE_PROJECT "$SCOPE_PROJECT"
validate_identifier JANUS_PHAROS_SCOPE_REPOSITORY "$SCOPE_REPOSITORY"
validate_identifier JANUS_PHAROS_SCOPE_ENVIRONMENT "$SCOPE_ENVIRONMENT"
validate_numeric_id JANUS_PHAROS_PROVIDER_CONSUMER_UID "$CONSUMER_UID"
validate_numeric_id JANUS_PHAROS_PROVIDER_CONSUMER_GID "$CONSUMER_GID"

if [ "$(id -u)" != 0 ]; then
  printf 'run the Hetzner provider renderer as root on csb1\n' >&2
  exit 1
fi
if [ "$(hostname -s)" != "$EXPECTED_HOST" ]; then
  printf 'refusing Hetzner provider render on the wrong host\n' >&2
  exit 1
fi

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  printf 'another Hetzner provider render is already running\n' >&2
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

TMP_DIR=$(mktemp -d)
provider_ownership_staged=0
provider_permit_ready=0

restore_provider_ownership() {
  docker run --rm --network none --user 0 \
    -v "${PROVIDER_OUT_VOLUME}:/run/janus/env/pharos/providers" \
    --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
    -c '
set -eu
uid=$1
gid=$2
output=$3
[ ! -L "$output" ]
chown "$uid:$gid" /run/janus/env/pharos/providers
chmod 0700 /run/janus/env/pharos/providers
if [ -f "$output" ]; then
  chown "$uid:$gid" "$output"
  chmod 0600 "$output"
fi
' sh "$CONSUMER_UID" "$CONSUMER_GID" "$OUTPUT_FILE" >/dev/null
}

purge_provider_permits() {
  docker run --rm --network none \
    -v "${PROVIDER_PERMIT_VOLUME}:/run/janus/permits" \
    --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
    -c 'find /run/janus/permits -maxdepth 1 -type f \( -name "use_*.json" -o -name ".use_*.claim" \) -delete' \
    >/dev/null
}

cleanup() {
  local status=$?
  trap - EXIT
  if [ "$provider_ownership_staged" = 1 ]; then
    if ! restore_provider_ownership; then
      printf 'janus pharos Hetzner provider render failed to restore consumer ownership\n' >&2
      status=1
    fi
  fi
  if [ "$provider_permit_ready" = 1 ]; then
    if ! purge_provider_permits; then
      printf 'janus pharos Hetzner provider render failed to purge provider permits\n' >&2
      status=1
    fi
  fi
  rm -rf "$TMP_DIR"
  exit "$status"
}
trap cleanup EXIT

docker pull "$IMAGE" >/dev/null
janus_pharos_prepare_provider_runtime "$IMAGE" "$SCRIPT_DIR" "$VOLUME_PREFIX"
AGE_VOLUME=$JANUS_PHAROS_AGE_VOLUME
STORE_VOLUME=$JANUS_PHAROS_STORE_VOLUME
METADATA_VOLUME=$JANUS_PHAROS_METADATA_VOLUME
container_uid=$JANUS_PHAROS_CONTAINER_UID
container_gid=$JANUS_PHAROS_CONTAINER_GID

janus_pharos_prepare_provider_mountpoint "$IMAGE" "$SHARED_OUT_VOLUME"

janus_pharos_prepare_age_identity \
  "$IMAGE" "$AGE_VOLUME" "$container_uid" "$container_gid"

docker volume create "$PROVIDER_OUT_VOLUME" >/dev/null
docker volume create "$PROVIDER_PERMIT_VOLUME" >/dev/null
provider_permit_ready=1

restore_provider_ownership

docker run --rm --network none --user 0 \
  -v "${PROVIDER_PERMIT_VOLUME}:/run/janus/permits" \
  --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
  -c '
set -eu
uid=$1
gid=$2
chown -R "$uid:$gid" /run/janus/permits
chmod 0700 /run/janus/permits
' sh "$container_uid" "$container_gid"

if [ "$PREPARE_ONLY" = 1 ]; then
  printf 'ok: janus pharos Hetzner provider runtime prepared volume_prefix=%s provider_volume=%s value_returned=false\n' \
    "$VOLUME_PREFIX" "$PROVIDER_OUT_VOLUME"
  exit 0
fi

provider_ownership_staged=1
docker run --rm --network none --user 0 \
  -v "${PROVIDER_OUT_VOLUME}:/run/janus/env/pharos/providers" \
  --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
  -c '
set -eu
uid=$1
gid=$2
output=$3
[ ! -L "$output" ]
if [ -e "$output" ]; then
  test -f "$output"
  chown "$uid:$gid" "$output"
  chmod 0600 "$output"
fi
chown "$uid:$gid" /run/janus/env/pharos/providers
chmod 0700 /run/janus/env/pharos/providers
' sh "$container_uid" "$container_gid" "$OUTPUT_FILE"

preflight_out="${TMP_DIR}/provider.preflight.out"
preflight_err="${TMP_DIR}/provider.preflight.err"
if ! docker run --rm --network none \
  -e JANUS_PRODUCT_MODE=self_hosted \
  -e JANUS_ROLE_AUTHORIZATION_MODE=unsafe_disabled_dev \
  -e JANUS_RUN_PROFILE_MANIFEST=/etc/janus/managed-env-files.toml \
  -e "JANUS_SCOPE_ORGANIZATION=${SCOPE_ORGANIZATION}" \
  -e "JANUS_SCOPE_PROJECT=${SCOPE_PROJECT}" \
  -e "JANUS_SCOPE_REPOSITORY=${SCOPE_REPOSITORY}" \
  -e "JANUS_SCOPE_ENVIRONMENT=${SCOPE_ENVIRONMENT}" \
  -v "${SCRIPT_DIR}/managed-env-files.toml:/etc/janus/managed-env-files.toml:ro" \
  -v "${PROVIDER_OUT_VOLUME}:/run/janus/env/pharos/providers" \
  --entrypoint janusd-use "$IMAGE" \
  env-file preflight --profile "$PROFILE_ID" \
  >"$preflight_out" 2>"$preflight_err"; then
  printf 'janus pharos Hetzner provider render failed: env-file preflight failed\n' >&2
  sed -n '1,80p' "$preflight_out" >&2
  sed -n '1,120p' "$preflight_err" >&2
  exit 1
fi

purge_provider_permits

secret_ref=$(
  awk -v profile_id="$PROFILE_ID" '
    $0 == "id = \"" profile_id "\"" { found = 1; next }
    found && /^secret_ref = "/ {
      sub(/^secret_ref = "/, "")
      sub(/".*$/, "")
      print
      exit
    }
    found && /^\[\[env_files\]\]/ { exit }
  ' "${SCRIPT_DIR}/managed-env-files.toml"
)
if [ -z "$secret_ref" ]; then
  printf 'janus pharos Hetzner provider render failed: missing reviewed secret ref\n' >&2
  exit 1
fi
request_file="${TMP_DIR}/provider.request.jsonl"
warden_out="${TMP_DIR}/provider.warden.out"
warden_err="${TMP_DIR}/provider.warden.err"

cat >"$request_file" <<EOF
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"janus-pharos-provider-render","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"request_use","arguments":{"secret_ref":"${secret_ref}","profile_id":"${PROFILE_ID}","purpose":"PHAROS-151 production Hetzner provider sidecar render"}}}
EOF

docker run -i --rm --network none \
  -e JANUS_PRODUCT_MODE=self_hosted \
  -e JANUS_ROLE_AUTHORIZATION_MODE=unsafe_disabled_dev \
  -e JANUS_PERMIT_DIR=/run/janus/permits \
  -e JANUS_WARDEN_PERMIT_DIR=/run/janus/permits \
  -e JANUS_WARDEN_BACKEND=age \
  -e "JANUS_WARDEN_DESTINATION=${DESTINATION}" \
  -e JANUS_WARDEN_EXECUTOR=janus-run@csb1 \
  -e "JANUS_WARDEN_SCOPE=${RUN_SCOPE}" \
  -e "JANUS_WARDEN_SCOPE_ORGANIZATION=${SCOPE_ORGANIZATION}" \
  -e "JANUS_WARDEN_SCOPE_PROJECT=${SCOPE_PROJECT}" \
  -e "JANUS_WARDEN_SCOPE_REPOSITORY=${SCOPE_REPOSITORY}" \
  -e "JANUS_WARDEN_SCOPE_ENVIRONMENT=${SCOPE_ENVIRONMENT}" \
  -e JANUS_WARDEN_AGE_MANIFEST_FILE=/etc/janus/secretspec.toml \
  -e JANUS_WARDEN_AGE_METADATA_FILE=/var/lib/janus/metadata/metadata.toml \
  -e "JANUS_WARDEN_AGE_PROFILE=${AGE_PROFILE}" \
  -e JANUS_WARDEN_AGE_STORE_DIR=/var/lib/janus/secrets \
  -e JANUS_WARDEN_AGE_IDENTITY_FILE=/run/janus/age/identity \
  -e JANUS_WARDEN_AGE_RECIPIENTS_FILE=/run/janus/age/recipient.pub \
  -v "${SCRIPT_DIR}/secretspec.toml:/etc/janus/secretspec.toml:ro" \
  -v "${METADATA_VOLUME}:/var/lib/janus/metadata" \
  -v "${AGE_VOLUME}:/run/janus/age:ro" \
  -v "${STORE_VOLUME}:/var/lib/janus/secrets" \
  -v "${PROVIDER_PERMIT_VOLUME}:/run/janus/permits" \
  --entrypoint janus-warden "$IMAGE" \
  <"$request_file" >"$warden_out" 2>"$warden_err"

permit=$(
  jq -r 'select(.id==2) | .result.structuredContent.result.permit_id // empty' \
    <"$warden_out" | head -n1
)
if [ -z "$permit" ]; then
  printf 'janus pharos Hetzner provider render failed: Warden did not issue a permit\n' >&2
  sed -n '1,80p' "$warden_out" >&2
  sed -n '1,120p' "$warden_err" >&2
  exit 1
fi

run_out="${TMP_DIR}/provider.env-file.out"
run_err="${TMP_DIR}/provider.env-file.err"
if ! docker run --rm --network none \
  -e JANUS_PRODUCT_MODE=self_hosted \
  -e JANUS_ROLE_AUTHORIZATION_MODE=unsafe_disabled_dev \
  -e JANUS_RUN_PROFILE_MANIFEST=/etc/janus/managed-env-files.toml \
  -e JANUS_RUN_PERMIT_DIR=/run/janus/permits \
  -e JANUS_RUN_EXECUTOR=janus-run@csb1 \
  -e "JANUS_RUN_SCOPE=${RUN_SCOPE}" \
  -e "JANUS_SCOPE_ORGANIZATION=${SCOPE_ORGANIZATION}" \
  -e "JANUS_SCOPE_PROJECT=${SCOPE_PROJECT}" \
  -e "JANUS_SCOPE_REPOSITORY=${SCOPE_REPOSITORY}" \
  -e "JANUS_SCOPE_ENVIRONMENT=${SCOPE_ENVIRONMENT}" \
  -e JANUS_AGE_MANIFEST_FILE=/etc/janus/secretspec.toml \
  -e JANUS_AGE_METADATA_FILE=/var/lib/janus/metadata/metadata.toml \
  -e "JANUS_AGE_PROFILE=${AGE_PROFILE}" \
  -e JANUS_AGE_STORE_DIR=/var/lib/janus/secrets \
  -e JANUS_AGE_IDENTITY_FILE=/run/janus/age/identity \
  -e JANUS_AGE_RECIPIENTS_FILE=/run/janus/age/recipient.pub \
  -v "${SCRIPT_DIR}/managed-env-files.toml:/etc/janus/managed-env-files.toml:ro" \
  -v "${SCRIPT_DIR}/secretspec.toml:/etc/janus/secretspec.toml:ro" \
  -v "${METADATA_VOLUME}:/var/lib/janus/metadata" \
  -v "${AGE_VOLUME}:/run/janus/age:ro" \
  -v "${STORE_VOLUME}:/var/lib/janus/secrets" \
  -v "${PROVIDER_PERMIT_VOLUME}:/run/janus/permits" \
  -v "${PROVIDER_OUT_VOLUME}:/run/janus/env/pharos/providers" \
  --entrypoint janusd-use "$IMAGE" \
  env-file --profile "$PROFILE_ID" --permit "$permit" \
  >"$run_out" 2>"$run_err"; then
  printf 'janus pharos Hetzner provider render failed: env-file render failed\n' >&2
  sed -n '1,80p' "$run_out" >&2
  sed -n '1,120p' "$run_err" >&2
  exit 1
fi

if ! grep -q 'value_returned=false' "$run_out"; then
  printf 'janus pharos Hetzner provider render failed: output missing value_returned=false\n' >&2
  sed -n '1,80p' "$run_out" >&2
  exit 1
fi
if ! grep -q 'hash_format=none' "$run_out"; then
  printf 'janus pharos Hetzner provider render failed: output did not preserve the no-hash contract\n' >&2
  sed -n '1,80p' "$run_out" >&2
  exit 1
fi

restore_provider_ownership
provider_ownership_staged=0

mode_file="${TMP_DIR}/provider.mode"
docker run --rm --network none --user 0 \
  -v "${PROVIDER_OUT_VOLUME}:/run/janus/env/pharos/providers:ro" \
  --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
  -c '
set -eu
output=$1
test -s "$output"
[ ! -L "$output" ]
stat -c "%a" "$output"
stat -c "%u" "$output"
stat -c "%g" "$output"
stat -c "%a" /run/janus/env/pharos/providers
' sh "$OUTPUT_FILE" >"$mode_file"

if [ "$(sed -n '1p' "$mode_file")" != 600 ]; then
  printf 'janus pharos Hetzner provider render failed: env file is not mode 600\n' >&2
  exit 1
fi
if [ "$(sed -n '2p' "$mode_file")" != "$CONSUMER_UID" ]; then
  printf 'janus pharos Hetzner provider render failed: env file owner mismatch\n' >&2
  exit 1
fi
if [ "$(sed -n '3p' "$mode_file")" != "$CONSUMER_GID" ]; then
  printf 'janus pharos Hetzner provider render failed: env file group mismatch\n' >&2
  exit 1
fi
if [ "$(sed -n '4p' "$mode_file")" != 700 ]; then
  printf 'janus pharos Hetzner provider render failed: provider volume root is not mode 700\n' >&2
  exit 1
fi

remaining_permits=$(
  docker run --rm --network none \
    -v "${PROVIDER_PERMIT_VOLUME}:/run/janus/permits:ro" \
    --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
    -c 'find /run/janus/permits -maxdepth 1 -type f | wc -l | tr -d " "'
)
if [ "$remaining_permits" != 0 ]; then
  printf 'janus pharos Hetzner provider render failed: permit registry not empty after run\n' >&2
  exit 1
fi

printf 'ok: janus pharos Hetzner provider sidecar rendered value_returned=false hash_format=none mode=600 permits_consumed=true provider_volume=%s\n' \
  "$PROVIDER_OUT_VOLUME"
