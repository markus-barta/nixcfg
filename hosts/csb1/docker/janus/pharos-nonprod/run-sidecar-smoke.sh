#!/usr/bin/env bash
set -Eeuo pipefail

on_error() {
  local status=$?
  local line=${1:-unknown}
  printf 'janus pharos sidecar smoke failed near line %s status=%s\n' "$line" "$status" >&2
}
trap 'on_error "$LINENO"' ERR

DEFAULT_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_DIR=$(cd -- "${JANUS_PHAROS_CONTRACT_DIR:-$DEFAULT_SCRIPT_DIR}" && pwd)
CONTRACT_NAME=${JANUS_PHAROS_CONTRACT_NAME:-$(basename "$SCRIPT_DIR")}
COMPOSE_DIR=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
IMAGE=${JANUS_ENGINE_IMAGE:-}
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../pharos-production/runtime-lib.sh"
SMOKE_ROOT=${JANUS_PHAROS_SMOKE_ROOT:-"${XDG_STATE_HOME:-${HOME}/.local/state}/janus-pharos-sidecar-smoke/${CONTRACT_NAME}"}
VOLUME_PREFIX=${JANUS_PHAROS_SMOKE_VOLUME_PREFIX:-janus_pharos_sidecar_smoke_${CONTRACT_NAME}}
RUN_SCOPE=${JANUS_PHAROS_SMOKE_SCOPE:-pharos/csb1/${CONTRACT_NAME}}
SCOPE_ORGANIZATION=${JANUS_PHAROS_SCOPE_ORGANIZATION:-inspr}
SCOPE_PROJECT=${JANUS_PHAROS_SCOPE_PROJECT:-pharos}
SCOPE_REPOSITORY=${JANUS_PHAROS_SCOPE_REPOSITORY:-nixcfg}
SCOPE_ENVIRONMENT=${JANUS_PHAROS_SCOPE_ENVIRONMENT:-${CONTRACT_NAME}}
HOSTS_TEXT=${JANUS_PHAROS_SMOKE_HOSTS:-"csb0 csb1 dsc0 gpc0 hsb0 hsb1 hsb8 hsb9"}

read -r -a HOSTS <<<"$HOSTS_TEXT"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

validate_identifier() {
  name=$1
  value=$2
  case "$value" in
  "" | *[!A-Za-z0-9_.-]*)
    printf 'invalid %s: %s\n' "$name" "$value" >&2
    exit 1
    ;;
  esac
}

require_command age
require_command age-keygen
require_command awk
require_command docker
require_command jq
require_command python3
require_command sed
require_command sha256sum
require_command tr

validate_identifier JANUS_PHAROS_SMOKE_VOLUME_PREFIX "$VOLUME_PREFIX"
validate_identifier JANUS_PHAROS_SCOPE_ORGANIZATION "$SCOPE_ORGANIZATION"
validate_identifier JANUS_PHAROS_SCOPE_PROJECT "$SCOPE_PROJECT"
validate_identifier JANUS_PHAROS_SCOPE_REPOSITORY "$SCOPE_REPOSITORY"
validate_identifier JANUS_PHAROS_SCOPE_ENVIRONMENT "$SCOPE_ENVIRONMENT"
if [ "${#HOSTS[@]}" -eq 0 ]; then
  printf 'janus pharos sidecar smoke failed: no hosts requested\n' >&2
  exit 1
fi
for host in "${HOSTS[@]}"; do
  validate_identifier host "$host"
done

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

janus_pharos_load_consumer_identity "$COMPOSE_DIR"
consumer_uid=$JANUS_PHAROS_CONSUMER_UID
consumer_gid=$JANUS_PHAROS_CONSUMER_GID

umask 077
AGE_VOLUME="${VOLUME_PREFIX}_age"
STORE_VOLUME="${VOLUME_PREFIX}_secrets"
PERMIT_VOLUME="${VOLUME_PREFIX}_permits"
OUT_VOLUME="${VOLUME_PREFIX}_out"
HASH_OUT_VOLUME="${VOLUME_PREFIX}_hash_out"
TMP_DIR=$(mktemp -d)
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$SMOKE_ROOT"
chmod 0700 "$SMOKE_ROOT"

docker pull "$IMAGE" >/dev/null

janus_assert_static_runtime_image "$IMAGE"
container_uid=$JANUS_RUNTIME_UID
container_gid=$JANUS_RUNTIME_GID

docker volume create "$AGE_VOLUME" >/dev/null
docker volume create "$STORE_VOLUME" >/dev/null
docker volume create "$PERMIT_VOLUME" >/dev/null
docker volume create "$OUT_VOLUME" >/dev/null
docker volume create "$HASH_OUT_VOLUME" >/dev/null

docker run --rm --user 0 \
  -v "${AGE_VOLUME}:/run/janus/age" \
  -v "${STORE_VOLUME}:/var/lib/janus/secrets" \
  -v "${PERMIT_VOLUME}:/run/janus/permits" \
  -v "${OUT_VOLUME}:/run/janus/env" \
  --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
  -c '
set -eu
uid=$1
gid=$2
mkdir -p \
  /run/janus/age \
  /run/janus/permits \
  /run/janus/env/pharos/beacons \
  /run/janus/env/pharos/beacon-token-hashes \
  /var/lib/janus/secrets/pharos
chown -R "${uid}:${gid}" \
  /run/janus/age \
  /run/janus/permits \
  /run/janus/env/pharos \
  /var/lib/janus/secrets
chmod 0700 \
  /run/janus/age \
  /run/janus/permits \
  /run/janus/env/pharos \
  /run/janus/env/pharos/beacons \
  /run/janus/env/pharos/beacon-token-hashes \
  /var/lib/janus/secrets \
  /var/lib/janus/secrets/pharos
find /run/janus/env/pharos/beacon-token-hashes -maxdepth 1 -type f -exec chmod 0600 {} +
' sh "$container_uid" "$container_gid"

if ! docker run --rm \
  -v "${AGE_VOLUME}:/run/janus/age" \
  --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
  -c 'test -s /run/janus/age/identity && test -s /run/janus/age/recipient.pub'; then
  keygen_out=$(age-keygen 2>&1)
  recipient=$(printf '%s\n' "$keygen_out" | sed -n 's/^Public key: //p' | head -n1)
  identity=$(printf '%s\n' "$keygen_out" | sed -n 's/.*\(AGE-SECRET-KEY-[A-Z0-9]*\).*/\1/p' | head -n1)
  if [ -z "$recipient" ] || [ -z "$identity" ]; then
    printf 'failed to generate smoke age identity\n' >&2
    exit 1
  fi
  printf '%s\n%s\n' "$identity" "$recipient" |
    docker run -i --rm \
      -v "${AGE_VOLUME}:/run/janus/age" \
      --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
      -c '
        set -eu
        umask 077
        IFS= read -r identity
        IFS= read -r recipient
        printf "%s\n" "$identity" >/run/janus/age/identity
        printf "%s\n" "$recipient" >/run/janus/age/recipient.pub
        chmod 0400 /run/janus/age/identity
        chmod 0444 /run/janus/age/recipient.pub
      '
fi

recipient=$(
  docker run --rm \
    -v "${AGE_VOLUME}:/run/janus/age:ro" \
    --entrypoint cat "$JANUS_VOLUME_HELPER_IMAGE" /run/janus/age/recipient.pub |
    tr -d '\r\n'
)
printf '%s\n' "$recipient" >"${SMOKE_ROOT}/recipient.pub"

docker run --rm \
  -v "${PERMIT_VOLUME}:/run/janus/permits" \
  --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
  -c 'find /run/janus/permits -maxdepth 1 -type f \( -name "use_*.json" -o -name ".use_*.claim" \) -delete'

secret_ref_for() {
  secret_name=$1
  profile_id="profile.${secret_name}"
  secret_ref=$(
    awk -v profile_id="$profile_id" '
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
    printf 'janus pharos sidecar smoke failed: missing reviewed secret ref for %s\n' "$profile_id" >&2
    return 1
  fi
  printf '%s\n' "$secret_ref"
}

seed_secret() {
  host=$1
  secret_name=$2
  token_file="${TMP_DIR}/${host}.token"
  hash_file="${TMP_DIR}/${host}.sha256"
  encrypted_file="${TMP_DIR}/${host}.age"

  printf 'janus-pharos-sidecar-smoke-%s-%s' "$host" "$(date +%s%N)" >"$token_file"
  sha256sum "$token_file" | awk '{ print $1 }' >"$hash_file"
  age -r "$recipient" -o "$encrypted_file" <"$token_file"

  docker run -i --rm --user 0 \
    -v "${STORE_VOLUME}:/var/lib/janus/secrets" \
    --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
    -c '
set -eu
host=$1
secret_name=$2
uid=$3
gid=$4
dir="/var/lib/janus/secrets/pharos/${host}"
tmp="${dir}/.${secret_name}.age.tmp"
mkdir -p "$dir"
chown "${uid}:${gid}" "$dir"
chmod 0700 "$dir"
cat >"$tmp"
chown "${uid}:${gid}" "$tmp"
chmod 0400 "$tmp"
mv "$tmp" "${dir}/${secret_name}.age"
' sh "$host" "$secret_name" "$container_uid" "$container_gid" <"$encrypted_file"
}

run_warden_permit() {
  host=$1
  secret_name=$2
  secret_ref=$3
  profile_id="profile.${secret_name}"
  request_file="${TMP_DIR}/${host}.request.jsonl"
  warden_out="${TMP_DIR}/${host}.warden.out"
  warden_err="${TMP_DIR}/${host}.warden.err"

  cat >"$request_file" <<EOF
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"janus-pharos-sidecar-smoke","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"request_use","arguments":{"secret_ref":"${secret_ref}","profile_id":"${profile_id}","purpose":"Pharos ${CONTRACT_NAME} beacon sidecar smoke for ${host}"}}}
EOF

  docker run -i --rm \
    -e JANUS_PRODUCT_MODE=self_hosted \
    -e JANUS_ROLE_AUTHORIZATION_MODE=unsafe_disabled_dev \
    -e JANUS_PERMIT_DIR=/run/janus/permits \
    -e JANUS_WARDEN_PERMIT_DIR=/run/janus/permits \
    -e JANUS_WARDEN_BACKEND=age \
    -e "JANUS_WARDEN_DESTINATION=pharos-beacon-${host}" \
    -e JANUS_WARDEN_EXECUTOR=janus-run@csb1 \
    -e "JANUS_WARDEN_SCOPE=${RUN_SCOPE}" \
    -e "JANUS_WARDEN_SCOPE_ORGANIZATION=${SCOPE_ORGANIZATION}" \
    -e "JANUS_WARDEN_SCOPE_PROJECT=${SCOPE_PROJECT}" \
    -e "JANUS_WARDEN_SCOPE_REPOSITORY=${SCOPE_REPOSITORY}" \
    -e "JANUS_WARDEN_SCOPE_ENVIRONMENT=${SCOPE_ENVIRONMENT}" \
    -e JANUS_WARDEN_AGE_MANIFEST_FILE=/etc/janus/secretspec.toml \
    -e JANUS_WARDEN_AGE_METADATA_FILE=/etc/janus/metadata.toml \
    -e "JANUS_WARDEN_AGE_PROFILE=${host}" \
    -e JANUS_WARDEN_AGE_STORE_DIR=/var/lib/janus/secrets \
    -e JANUS_WARDEN_AGE_IDENTITY_FILE=/run/janus/age/identity \
    -e JANUS_WARDEN_AGE_RECIPIENTS_FILE=/run/janus/age/recipient.pub \
    -v "${SCRIPT_DIR}/secretspec.toml:/etc/janus/secretspec.toml:ro" \
    -v "${SCRIPT_DIR}/metadata.toml:/etc/janus/metadata.toml:ro" \
    -v "${AGE_VOLUME}:/run/janus/age:ro" \
    -v "${STORE_VOLUME}:/var/lib/janus/secrets" \
    -v "${PERMIT_VOLUME}:/run/janus/permits" \
    --entrypoint janus-warden "$IMAGE" \
    <"$request_file" >"$warden_out" 2>"$warden_err"

  permit=$(
    jq -r 'select(.id==2) | .result.structuredContent.result.permit_id // empty' \
      <"$warden_out" | head -n1
  )
  if [ -z "$permit" ]; then
    printf 'janus pharos sidecar smoke failed: Warden did not issue permit for %s\n' "$host" >&2
    sed -n '1,80p' "$warden_out" >&2
    sed -n '1,120p' "$warden_err" >&2
    exit 1
  fi
  printf '%s\n' "$permit"
}

render_env_file() {
  host=$1
  secret_name=$2
  permit=$3
  profile_id="profile.${secret_name}"
  preflight_out="${TMP_DIR}/${host}.preflight.out"
  preflight_err="${TMP_DIR}/${host}.preflight.err"
  run_out="${TMP_DIR}/${host}.env-file.out"
  run_err="${TMP_DIR}/${host}.env-file.err"

  if ! docker run --rm \
    -e JANUS_PRODUCT_MODE=self_hosted \
    -e JANUS_ROLE_AUTHORIZATION_MODE=unsafe_disabled_dev \
    -e JANUS_RUN_PROFILE_MANIFEST=/etc/janus/managed-env-files.toml \
    -e "JANUS_SCOPE_ORGANIZATION=${SCOPE_ORGANIZATION}" \
    -e "JANUS_SCOPE_PROJECT=${SCOPE_PROJECT}" \
    -e "JANUS_SCOPE_REPOSITORY=${SCOPE_REPOSITORY}" \
    -e "JANUS_SCOPE_ENVIRONMENT=${SCOPE_ENVIRONMENT}" \
    -v "${SCRIPT_DIR}/managed-env-files.toml:/etc/janus/managed-env-files.toml:ro" \
    -v "${OUT_VOLUME}:/run/janus/env" \
    --entrypoint janusd-use "$IMAGE" \
    env-file preflight --profile "$profile_id" \
    >"$preflight_out" 2>"$preflight_err"; then
    printf 'janus pharos sidecar smoke failed: env-file preflight failed for %s\n' "$host" >&2
    sed -n '1,80p' "$preflight_out" >&2
    sed -n '1,120p' "$preflight_err" >&2
    exit 1
  fi

  if ! docker run --rm \
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
    -e JANUS_AGE_METADATA_FILE=/etc/janus/metadata.toml \
    -e "JANUS_AGE_PROFILE=${host}" \
    -e JANUS_AGE_STORE_DIR=/var/lib/janus/secrets \
    -e JANUS_AGE_IDENTITY_FILE=/run/janus/age/identity \
    -e JANUS_AGE_RECIPIENTS_FILE=/run/janus/age/recipient.pub \
    -v "${SCRIPT_DIR}/managed-env-files.toml:/etc/janus/managed-env-files.toml:ro" \
    -v "${SCRIPT_DIR}/secretspec.toml:/etc/janus/secretspec.toml:ro" \
    -v "${SCRIPT_DIR}/metadata.toml:/etc/janus/metadata.toml:ro" \
    -v "${AGE_VOLUME}:/run/janus/age:ro" \
    -v "${STORE_VOLUME}:/var/lib/janus/secrets" \
    -v "${PERMIT_VOLUME}:/run/janus/permits" \
    -v "${OUT_VOLUME}:/run/janus/env" \
    --entrypoint janusd-use "$IMAGE" \
    env-file --profile "$profile_id" --permit "$permit" \
    >"$run_out" 2>"$run_err"; then
    printf 'janus pharos sidecar smoke failed: env-file render failed for %s\n' "$host" >&2
    sed -n '1,80p' "$run_out" >&2
    sed -n '1,120p' "$run_err" >&2
    exit 1
  fi

  if ! grep -q 'value_returned=false' "$run_out"; then
    printf 'janus pharos sidecar smoke failed: env-file output missing value_returned=false for %s\n' "$host" >&2
    sed -n '1,80p' "$run_out" >&2
    sed -n '1,80p' "$run_err" >&2
    exit 1
  fi
  if ! grep -q 'hash_format=pharos-beacon-token-generation-v2' "$run_out"; then
    printf 'janus pharos sidecar smoke failed: env-file output missing sidecar format for %s\n' "$host" >&2
    sed -n '1,80p' "$run_out" >&2
    exit 1
  fi
}

validate_outputs() {
  host=$1
  expected_hash=$(<"${TMP_DIR}/${host}.sha256")
  sidecar_file="${TMP_DIR}/${host}.sidecar.json"
  mode_file="${TMP_DIR}/${host}.modes"

  docker run --rm \
    -v "${OUT_VOLUME}:/run/janus/env:ro" \
    --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
    -c '
set -eu
host=$1
cat "/run/janus/env/pharos/beacon-token-hashes/${host}.json"
' sh "$host" >"$sidecar_file"

  jq -e \
    --arg host "$host" \
    --arg expected_hash "$expected_hash" \
    '.schema == "inspr.pharos.beacon-token-entry.v2"
      and .host.name == $host
      and .host.token_sha256 == $expected_hash' \
    "$sidecar_file" >/dev/null

  docker run --rm \
    -v "${OUT_VOLUME}:/run/janus/env:ro" \
    --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
    -c '
set -eu
host=$1
stat -c "%a %n" \
  "/run/janus/env/pharos/beacons/${host}.env" \
  "/run/janus/env/pharos/beacon-token-hashes/${host}.json"
' sh "$host" >"$mode_file"

  if [ "$(awk 'NR == 1 { print $1 }' "$mode_file")" != "600" ]; then
    printf 'janus pharos sidecar smoke failed: env file is not mode 600 for %s\n' "$host" >&2
    exit 1
  fi
  if [ "$(awk 'NR == 2 { print $1 }' "$mode_file")" != "600" ]; then
    printf 'janus pharos sidecar smoke failed: private sidecar file is not mode 600 for %s\n' "$host" >&2
    exit 1
  fi
}

validate_generation() {
  local generation_file="${TMP_DIR}/generation.id"
  local payload_file="${TMP_DIR}/generation.json"
  local mode_file="${TMP_DIR}/generation.modes"
  local generation

  docker run --rm \
    -v "${OUT_VOLUME}:/run/janus/env:ro" \
    --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
    -c '
set -eu
root=/run/janus/env/pharos/beacon-token-hashes
IFS= read -r generation <"${root}/current"
printf "%s" "$generation" | grep -Eq "^[0-9a-f]{64}$"
printf "%s\n" "$generation"
' >"$generation_file"

  IFS= read -r generation <"$generation_file"
  docker run --rm \
    -v "${OUT_VOLUME}:/run/janus/env:ro" \
    --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
    -c 'set -eu; cat "/run/janus/env/pharos/beacon-token-hashes/generation-${1}.json"' sh "$generation" \
    >"$payload_file"
  docker run --rm \
    -v "${OUT_VOLUME}:/run/janus/env:ro" \
    --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
    -c 'set -eu; root=/run/janus/env/pharos/beacon-token-hashes; stat -c %a "${root}/current" "${root}/generation-${1}.json"' sh "$generation" \
    >"$mode_file"

  jq -e --arg generation "$generation" --argjson expected_count "${#HOSTS[@]}" \
    '.schema == "inspr.pharos.beacon-token-generation.v2"
      and .generation == $generation
      and (.hosts | length) == $expected_count
      and ([.hosts[].name] | unique | length) == $expected_count
      and all(.hosts[]; (.name | test("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$")) and (.token_sha256 | test("^[0-9a-f]{64}$")))' \
    "$payload_file" >/dev/null
  [ "$(awk 'NR == 1 { print $1 }' "$mode_file")" = 600 ]
  [ "$(awk 'NR == 2 { print $1 }' "$mode_file")" = 600 ]
}

for host in "${HOSTS[@]}"; do
  upper=$(printf '%s' "$host" | tr '[:lower:]' '[:upper:]')
  secret_name="PHAROS_BEACON_${upper}_TOKEN"
  secret_ref=$(secret_ref_for "$secret_name")
  seed_secret "$host" "$secret_name"
  permit=$(run_warden_permit "$host" "$secret_name" "$secret_ref")
  render_env_file "$host" "$secret_name" "$permit"
done

for host in "${HOSTS[@]}"; do
  validate_outputs "$host"
done
validate_generation
janus_pharos_publish_hash_projection \
  "$OUT_VOLUME" "$HASH_OUT_VOLUME" "$consumer_uid" "$consumer_gid"

remaining_permits=$(
  docker run --rm \
    -v "${PERMIT_VOLUME}:/run/janus/permits:ro" \
    --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
    -c 'find /run/janus/permits -maxdepth 1 -type f | wc -l | tr -d " "'
)
if [ "$remaining_permits" != "0" ]; then
  printf 'janus pharos sidecar smoke failed: permit registry not empty after run (%s files)\n' "$remaining_permits" >&2
  exit 1
fi

printf 'ok: janus pharos sidecar smoke passed contract=%s hosts=%s value_returned=false sidecars=validated consumer_projection=validated permits_consumed=true volumes=%s,%s,%s,%s,%s\n' \
  "$CONTRACT_NAME" "${#HOSTS[@]}" "$AGE_VOLUME" "$STORE_VOLUME" "$PERMIT_VOLUME" "$OUT_VOLUME" "$HASH_OUT_VOLUME"
