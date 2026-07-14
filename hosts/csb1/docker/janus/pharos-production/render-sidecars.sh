#!/usr/bin/env bash
set -Eeuo pipefail

on_error() {
  local status=$?
  local line=${1:-unknown}
  printf 'janus pharos production render failed near line %s status=%s\n' "$line" "$status" >&2
}
trap 'on_error "$LINENO"' ERR

DEFAULT_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_DIR=$(cd -- "${JANUS_PHAROS_CONTRACT_DIR:-$DEFAULT_SCRIPT_DIR}" && pwd)
COMPOSE_DIR=$(cd -- "${DEFAULT_SCRIPT_DIR}/../.." && pwd)
RETIREMENTS_FILE=${JANUS_PHAROS_RETIREMENTS_FILE:-${SCRIPT_DIR}/retired-hosts.json}
IMAGE=${JANUS_ENGINE_IMAGE:-}
VOLUME_PREFIX=${JANUS_PHAROS_VOLUME_PREFIX:-janus_pharos_production}
RUN_SCOPE=${JANUS_PHAROS_SCOPE:-pharos/csb1/production}
HOSTS_TEXT=${JANUS_PHAROS_HOSTS:-"csb0 csb1 dsc0 gpc0 hsb0 hsb1 hsb8 hsb9"}
PREPARE_ONLY=${JANUS_PHAROS_PREPARE_ONLY:-0}

# shellcheck disable=SC1091
source "${DEFAULT_SCRIPT_DIR}/runtime-lib.sh"

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

require_command age-keygen
require_command awk
require_command docker
require_command jq
require_command sed
require_command sha256sum

validate_identifier JANUS_PHAROS_VOLUME_PREFIX "$VOLUME_PREFIX"

jq -e '
  ((keys | sort) == ["retirements", "schema", "version"])
  and .schema == "inspr.pharos.janus-retirements.v1"
  and .version == 1
  and (.retirements | type == "array")
  and all(.retirements[];
    ((keys | sort) == [
      "credential_retirement_required",
      "disposition",
      "host",
      "server_deletion",
      "successor"
    ])
    and (.host | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$"))
    and (.disposition == "destroyed" or .disposition == "unmanaged" or .disposition == "rebuilt")
    and (.successor == null or (.successor | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$")))
    and .credential_retirement_required == true
    and .server_deletion == false
  )
' "$RETIREMENTS_FILE" >/dev/null || {
  printf 'janus pharos production render failed: invalid retirement intent\n' >&2
  exit 1
}

ACTIVE_HOSTS=()
for host in "${HOSTS[@]}"; do
  validate_identifier host "$host"
  if jq -e --arg host "$host" '.retirements[] | select(.host == $host)' \
    "$RETIREMENTS_FILE" >/dev/null; then
    continue
  fi
  ACTIVE_HOSTS+=("$host")
done
HOSTS=("${ACTIVE_HOSTS[@]}")

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
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

docker pull "$IMAGE" >/dev/null
janus_pharos_prepare_runtime "$IMAGE" "$SCRIPT_DIR" "$VOLUME_PREFIX"
AGE_VOLUME=$JANUS_PHAROS_AGE_VOLUME
STORE_VOLUME=$JANUS_PHAROS_STORE_VOLUME
PERMIT_VOLUME=$JANUS_PHAROS_PERMIT_VOLUME
OUT_VOLUME=$JANUS_PHAROS_OUT_VOLUME
METADATA_VOLUME=$JANUS_PHAROS_METADATA_VOLUME
container_uid=$JANUS_PHAROS_CONTAINER_UID
container_gid=$JANUS_PHAROS_CONTAINER_GID

if ! docker run --rm \
  -v "${AGE_VOLUME}:/run/janus/age" \
  --entrypoint sh "$IMAGE" \
  -c 'test -s /run/janus/age/identity && test -s /run/janus/age/recipient.pub'; then
  key_dir="${TMP_DIR}/age"
  mkdir -p "$key_dir"
  age-keygen -o "${key_dir}/identity" >"${key_dir}/age-keygen.out" 2>&1
  sed -n 's/^Public key: //p' "${key_dir}/age-keygen.out" | head -n1 >"${key_dir}/recipient.pub"
  sed -n 's/.*\(AGE-SECRET-KEY-[A-Z0-9]*\).*/\1/p' "${key_dir}/identity" |
    head -n1 >"${key_dir}/identity.plain"
  mv "${key_dir}/identity.plain" "${key_dir}/identity"
  if [ ! -s "${key_dir}/recipient.pub" ]; then
    printf 'failed to generate production age recipient\n' >&2
    exit 1
  fi
  if [ ! -s "${key_dir}/identity" ]; then
    printf 'failed to generate production age identity\n' >&2
    exit 1
  fi
  tar -C "$key_dir" -cf - identity recipient.pub |
    docker run -i --rm --user 0 \
      -v "${AGE_VOLUME}:/run/janus/age" \
      --entrypoint sh "$IMAGE" \
      -c '
set -eu
uid=$1
gid=$2
tmp=$(mktemp -d)
trap "rm -rf \"$tmp\"" EXIT
tar -C "$tmp" -xf -
install -o "$uid" -g "$gid" -m 0400 "$tmp/identity" /run/janus/age/identity
install -o "$uid" -g "$gid" -m 0444 "$tmp/recipient.pub" /run/janus/age/recipient.pub
' sh "$container_uid" "$container_gid"
fi

if [ "$PREPARE_ONLY" = "1" ]; then
  printf 'ok: janus pharos production runtime prepared volume_prefix=%s value_returned=false\n' "$VOLUME_PREFIX"
  exit 0
fi

docker run --rm \
  -v "${PERMIT_VOLUME}:/run/janus/permits" \
  --entrypoint sh "$IMAGE" \
  -c 'find /run/janus/permits -maxdepth 1 -type f \( -name "use_*.json" -o -name ".use_*.claim" \) -delete'

secret_ref_for() {
  secret_name=$1
  digest=$(printf 'pharos\0%s' "$secret_name" | sha256sum | awk '{ print $1 }')
  printf 'sec_%s\n' "${digest:0:20}"
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
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"janus-pharos-production-render","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"request_use","arguments":{"secret_ref":"${secret_ref}","profile_id":"${profile_id}","purpose":"PHAROS-100 production beacon sidecar render for ${host}"}}}
EOF

  docker run -i --rm \
    -e JANUS_PERMIT_DIR=/run/janus/permits \
    -e JANUS_WARDEN_PERMIT_DIR=/run/janus/permits \
    -e JANUS_WARDEN_BACKEND=age \
    -e "JANUS_WARDEN_DESTINATION=pharos-beacon-${host}" \
    -e JANUS_WARDEN_EXECUTOR=janus-run@csb1 \
    -e "JANUS_WARDEN_SCOPE=${RUN_SCOPE}" \
    -e JANUS_WARDEN_AGE_MANIFEST_FILE=/etc/janus/secretspec.toml \
    -e JANUS_WARDEN_AGE_METADATA_FILE=/var/lib/janus/metadata/metadata.toml \
    -e "JANUS_WARDEN_AGE_PROFILE=${host}" \
    -e JANUS_WARDEN_AGE_STORE_DIR=/var/lib/janus/secrets \
    -e JANUS_WARDEN_AGE_IDENTITY_FILE=/run/janus/age/identity \
    -e JANUS_WARDEN_AGE_RECIPIENTS_FILE=/run/janus/age/recipient.pub \
    -v "${SCRIPT_DIR}/secretspec.toml:/etc/janus/secretspec.toml:ro" \
    -v "${METADATA_VOLUME}:/var/lib/janus/metadata" \
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
    printf 'janus pharos production render failed: Warden did not issue permit for %s\n' "$host" >&2
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
    -e JANUS_RUN_PROFILE_MANIFEST=/etc/janus/managed-env-files.toml \
    -v "${SCRIPT_DIR}/managed-env-files.toml:/etc/janus/managed-env-files.toml:ro" \
    -v "${OUT_VOLUME}:/run/janus/env" \
    --entrypoint janusd "$IMAGE" \
    env-file preflight --profile "$profile_id" \
    >"$preflight_out" 2>"$preflight_err"; then
    printf 'janus pharos production render failed: env-file preflight failed for %s\n' "$host" >&2
    sed -n '1,80p' "$preflight_out" >&2
    sed -n '1,120p' "$preflight_err" >&2
    exit 1
  fi

  if ! docker run --rm \
    -e JANUS_RUN_PROFILE_MANIFEST=/etc/janus/managed-env-files.toml \
    -e JANUS_RUN_PERMIT_DIR=/run/janus/permits \
    -e JANUS_RUN_EXECUTOR=janus-run@csb1 \
    -e "JANUS_RUN_SCOPE=${RUN_SCOPE}" \
    -e JANUS_AGE_MANIFEST_FILE=/etc/janus/secretspec.toml \
    -e JANUS_AGE_METADATA_FILE=/var/lib/janus/metadata/metadata.toml \
    -e "JANUS_AGE_PROFILE=${host}" \
    -e JANUS_AGE_STORE_DIR=/var/lib/janus/secrets \
    -e JANUS_AGE_IDENTITY_FILE=/run/janus/age/identity \
    -e JANUS_AGE_RECIPIENTS_FILE=/run/janus/age/recipient.pub \
    -v "${SCRIPT_DIR}/managed-env-files.toml:/etc/janus/managed-env-files.toml:ro" \
    -v "${SCRIPT_DIR}/secretspec.toml:/etc/janus/secretspec.toml:ro" \
    -v "${METADATA_VOLUME}:/var/lib/janus/metadata" \
    -v "${AGE_VOLUME}:/run/janus/age:ro" \
    -v "${STORE_VOLUME}:/var/lib/janus/secrets" \
    -v "${PERMIT_VOLUME}:/run/janus/permits" \
    -v "${OUT_VOLUME}:/run/janus/env" \
    --entrypoint janusd "$IMAGE" \
    env-file --profile "$profile_id" --permit "$permit" \
    >"$run_out" 2>"$run_err"; then
    printf 'janus pharos production render failed: env-file render failed for %s\n' "$host" >&2
    sed -n '1,80p' "$run_out" >&2
    sed -n '1,120p' "$run_err" >&2
    exit 1
  fi

  if ! grep -q 'value_returned=false' "$run_out"; then
    printf 'janus pharos production render failed: env-file output missing value_returned=false for %s\n' "$host" >&2
    sed -n '1,80p' "$run_out" >&2
    sed -n '1,80p' "$run_err" >&2
    exit 1
  fi
  if ! grep -q 'hash_format=pharos-beacon-token-hashes-v1' "$run_out"; then
    printf 'janus pharos production render failed: env-file output missing sidecar format for %s\n' "$host" >&2
    sed -n '1,80p' "$run_out" >&2
    exit 1
  fi
}

relax_sidecar_permissions() {
  docker run --rm --user 0 \
    -v "${OUT_VOLUME}:/run/janus/env" \
    --entrypoint sh "$IMAGE" \
    -c '
set -eu
chmod 0750 /run/janus/env/pharos /run/janus/env/pharos/beacon-token-hashes
for host do
  chmod 0600 "/run/janus/env/pharos/beacons/${host}.env"
  chmod 0640 "/run/janus/env/pharos/beacon-token-hashes/${host}.json"
done
' sh "${HOSTS[@]}"
}

validate_outputs() {
  host=$1
  sidecar_file="${TMP_DIR}/${host}.sidecar.json"
  mode_file="${TMP_DIR}/${host}.modes"

  docker run --rm \
    -v "${OUT_VOLUME}:/run/janus/env:ro" \
    --entrypoint sh "$IMAGE" \
    -c '
set -eu
host=$1
cat "/run/janus/env/pharos/beacon-token-hashes/${host}.json"
' sh "$host" >"$sidecar_file"

  jq -e \
    --arg host "$host" \
    '.schema == "inspr.pharos.beacon-token-hashes.v1"
      and (.hosts | length == 1)
      and .hosts[0].name == $host
      and (.hosts[0].token_sha256 | test("^[0-9a-f]{64}$"))' \
    "$sidecar_file" >/dev/null

  docker run --rm \
    -v "${OUT_VOLUME}:/run/janus/env:ro" \
    --entrypoint sh "$IMAGE" \
    -c '
set -eu
host=$1
stat -c "%a %n" \
  "/run/janus/env/pharos/beacons/${host}.env" \
  "/run/janus/env/pharos/beacon-token-hashes/${host}.json"
' sh "$host" >"$mode_file"

  if [ "$(awk 'NR == 1 { print $1 }' "$mode_file")" != "600" ]; then
    printf 'janus pharos production render failed: env file is not mode 600 for %s\n' "$host" >&2
    exit 1
  fi
  if [ "$(awk 'NR == 2 { print $1 }' "$mode_file")" != "640" ]; then
    printf 'janus pharos production render failed: sidecar file is not mode 640 for %s\n' "$host" >&2
    exit 1
  fi
}

for host in "${HOSTS[@]}"; do
  upper=${host^^}
  secret_name="PHAROS_BEACON_${upper}_TOKEN"
  secret_ref=$(secret_ref_for "$secret_name")
  permit=$(run_warden_permit "$host" "$secret_name" "$secret_ref")
  render_env_file "$host" "$secret_name" "$permit"
done

relax_sidecar_permissions

for host in "${HOSTS[@]}"; do
  validate_outputs "$host"
done

remaining_permits=$(
  docker run --rm \
    -v "${PERMIT_VOLUME}:/run/janus/permits:ro" \
    --entrypoint sh "$IMAGE" \
    -c 'find /run/janus/permits -maxdepth 1 -type f | wc -l | tr -d " "'
)
if [ "$remaining_permits" != "0" ]; then
  printf 'janus pharos production render failed: permit registry not empty after run (%s files)\n' "$remaining_permits" >&2
  exit 1
fi

printf 'ok: janus pharos production sidecars rendered hosts=%s value_returned=false sidecars=validated permits_consumed=true volume_prefix=%s\n' \
  "${#HOSTS[@]}" "$VOLUME_PREFIX"
