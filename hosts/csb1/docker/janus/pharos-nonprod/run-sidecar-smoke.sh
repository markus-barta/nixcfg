#!/usr/bin/env bash
set -Eeuo pipefail

on_error() {
  local status=$?
  local line=${1:-unknown}
  printf 'janus pharos sidecar smoke failed near line %s status=%s\n' "$line" "$status" >&2
}
trap 'on_error "$LINENO"' ERR

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
COMPOSE_DIR=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
IMAGE=${JANUS_ENGINE_IMAGE:-}
SMOKE_ROOT=${JANUS_PHAROS_SMOKE_ROOT:-"${XDG_STATE_HOME:-${HOME}/.local/state}/janus-pharos-sidecar-smoke"}
VOLUME_PREFIX=${JANUS_PHAROS_SMOKE_VOLUME_PREFIX:-janus_pharos_sidecar_smoke}
HOSTS=(csb0 csb1 gpc0 hsb0 hsb1 hsb8 hsb9)

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

validate_identifier JANUS_PHAROS_SMOKE_VOLUME_PREFIX "$VOLUME_PREFIX"

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

umask 077
AGE_VOLUME="${VOLUME_PREFIX}_age"
STORE_VOLUME="${VOLUME_PREFIX}_secrets"
PERMIT_VOLUME="${VOLUME_PREFIX}_permits"
OUT_VOLUME="${VOLUME_PREFIX}_out"
TMP_DIR=$(mktemp -d)
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$SMOKE_ROOT"
chmod 0700 "$SMOKE_ROOT"

docker pull "$IMAGE" >/dev/null

container_uid=$(docker run --rm --entrypoint id "$IMAGE" -u)
container_gid=$(docker run --rm --entrypoint id "$IMAGE" -g)
if [ "$container_uid" = "0" ]; then
  printf 'janus pharos sidecar smoke failed: image default user is root\n' >&2
  exit 1
fi

docker volume create "$AGE_VOLUME" >/dev/null
docker volume create "$STORE_VOLUME" >/dev/null
docker volume create "$PERMIT_VOLUME" >/dev/null
docker volume create "$OUT_VOLUME" >/dev/null

docker run --rm --user 0 \
  -v "${AGE_VOLUME}:/run/janus/age" \
  -v "${STORE_VOLUME}:/var/lib/janus/secrets" \
  -v "${PERMIT_VOLUME}:/run/janus/permits" \
  -v "${OUT_VOLUME}:/run/janus/env/pharos" \
  --entrypoint sh "$IMAGE" \
  -s -- "$container_uid" "$container_gid" <<'EOF'
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
EOF

if ! docker run --rm \
  -v "${AGE_VOLUME}:/run/janus/age" \
  --entrypoint sh "$IMAGE" \
  -c 'test -s /run/janus/age/identity && test -s /run/janus/age/recipient.pub'; then
  keygen_out=$(age-keygen 2>&1)
  recipient=$(printf '%s\n' "$keygen_out" | sed -n 's/^Public key: //p' | head -n1)
  identity=$(printf '%s\n' "$keygen_out" | sed -n 's/.*\(AGE-SECRET-KEY-[A-Z0-9]*\).*/\1/p' | head -n1)
  if [ -z "$recipient" ] || [ -z "$identity" ]; then
    printf 'failed to generate non-prod age identity\n' >&2
    exit 1
  fi
  printf '%s\n%s\n' "$identity" "$recipient" |
    docker run -i --rm \
      -v "${AGE_VOLUME}:/run/janus/age" \
      --entrypoint sh "$IMAGE" \
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
    --entrypoint cat "$IMAGE" /run/janus/age/recipient.pub |
    tr -d '\r\n'
)
printf '%s\n' "$recipient" >"${SMOKE_ROOT}/recipient.pub"

docker run --rm \
  -v "${PERMIT_VOLUME}:/run/janus/permits" \
  --entrypoint sh "$IMAGE" \
  -c 'find /run/janus/permits -maxdepth 1 -type f \( -name "use_*.json" -o -name ".use_*.claim" \) -delete'

secret_ref_for() {
  secret_name=$1
  digest=$(printf 'pharos\0%s' "$secret_name" | sha256sum | awk '{ print $1 }')
  printf 'sec_%s\n' "${digest:0:20}"
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

  docker run --rm \
    -v "${STORE_VOLUME}:/var/lib/janus/secrets" \
    -v "${encrypted_file}:/tmp/input.age:ro" \
    --entrypoint sh "$IMAGE" \
    -s -- "$host" "$secret_name" <<'EOF'
set -eu
host=$1
secret_name=$2
dir="/var/lib/janus/secrets/pharos/${host}"
tmp="${dir}/.${secret_name}.age.tmp"
mkdir -p "$dir"
cat /tmp/input.age >"$tmp"
chmod 0400 "$tmp"
mv "$tmp" "${dir}/${secret_name}.age"
EOF
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
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"request_use","arguments":{"secret_ref":"${secret_ref}","profile_id":"${profile_id}","purpose":"Pharos non-prod beacon sidecar smoke for ${host}"}}}
EOF

  docker run -i --rm \
    -e JANUS_PERMIT_DIR=/run/janus/permits \
    -e JANUS_WARDEN_PERMIT_DIR=/run/janus/permits \
    -e JANUS_WARDEN_BACKEND=age \
    -e "JANUS_WARDEN_DESTINATION=pharos-beacon-${host}" \
    -e JANUS_WARDEN_EXECUTOR=janus-run@csb1 \
    -e JANUS_WARDEN_SCOPE=pharos/csb1/nonprod \
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

  docker run --rm \
    -e JANUS_RUN_PROFILE_MANIFEST=/etc/janus/managed-env-files.toml \
    -v "${SCRIPT_DIR}/managed-env-files.toml:/etc/janus/managed-env-files.toml:ro" \
    -v "${OUT_VOLUME}:/run/janus/env/pharos" \
    --entrypoint janusd "$IMAGE" \
    env-file preflight --profile "$profile_id" \
    >"$preflight_out" 2>"$preflight_err"

  docker run --rm \
    -e JANUS_RUN_PROFILE_MANIFEST=/etc/janus/managed-env-files.toml \
    -e JANUS_RUN_PERMIT_DIR=/run/janus/permits \
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
    -v "${OUT_VOLUME}:/run/janus/env/pharos" \
    --entrypoint janusd "$IMAGE" \
    env-file --profile "$profile_id" --permit "$permit" \
    >"$run_out" 2>"$run_err"

  if ! grep -q 'value_returned=false' "$run_out"; then
    printf 'janus pharos sidecar smoke failed: env-file output missing value_returned=false for %s\n' "$host" >&2
    sed -n '1,80p' "$run_out" >&2
    sed -n '1,80p' "$run_err" >&2
    exit 1
  fi
  if ! grep -q 'hash_format=pharos-beacon-token-hashes-v1' "$run_out"; then
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
    -v "${OUT_VOLUME}:/run/janus/env/pharos:ro" \
    --entrypoint sh "$IMAGE" \
    -s -- "$host" >"$sidecar_file" <<'EOF'
set -eu
host=$1
cat "/run/janus/env/pharos/beacon-token-hashes/${host}.json"
EOF

  jq -e \
    --arg host "$host" \
    --arg expected_hash "$expected_hash" \
    '.schema == "inspr.pharos.beacon-token-hashes.v1"
      and (.hosts | length == 1)
      and .hosts[0].name == $host
      and .hosts[0].token_sha256 == $expected_hash' \
    "$sidecar_file" >/dev/null

  docker run --rm \
    -v "${OUT_VOLUME}:/run/janus/env/pharos:ro" \
    --entrypoint sh "$IMAGE" \
    -s -- "$host" >"$mode_file" <<'EOF'
set -eu
host=$1
stat -c '%a %n' \
  "/run/janus/env/pharos/beacons/${host}.env" \
  "/run/janus/env/pharos/beacon-token-hashes/${host}.json"
EOF

  if [ "$(awk 'NR == 1 { print $1 }' "$mode_file")" != "600" ]; then
    printf 'janus pharos sidecar smoke failed: env file is not mode 600 for %s\n' "$host" >&2
    exit 1
  fi
  if [ "$(awk 'NR == 2 { print $1 }' "$mode_file")" != "600" ]; then
    printf 'janus pharos sidecar smoke failed: sidecar file is not mode 600 for %s\n' "$host" >&2
    exit 1
  fi
}

for host in "${HOSTS[@]}"; do
  upper=${host^^}
  secret_name="PHAROS_BEACON_${upper}_TOKEN"
  secret_ref=$(secret_ref_for "$secret_name")
  seed_secret "$host" "$secret_name"
  permit=$(run_warden_permit "$host" "$secret_name" "$secret_ref")
  render_env_file "$host" "$secret_name" "$permit"
  validate_outputs "$host"
done

remaining_permits=$(
  docker run --rm \
    -v "${PERMIT_VOLUME}:/run/janus/permits:ro" \
    --entrypoint sh "$IMAGE" \
    -c 'find /run/janus/permits -maxdepth 1 -type f | wc -l | tr -d " "'
)
if [ "$remaining_permits" != "0" ]; then
  printf 'janus pharos sidecar smoke failed: permit registry not empty after run (%s files)\n' "$remaining_permits" >&2
  exit 1
fi

printf 'ok: janus pharos sidecar smoke passed hosts=%s value_returned=false sidecars=validated permits_consumed=true volumes=%s,%s,%s,%s\n' \
  "${#HOSTS[@]}" "$AGE_VOLUME" "$STORE_VOLUME" "$PERMIT_VOLUME" "$OUT_VOLUME"
