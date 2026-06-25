#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
COMPOSE_DIR=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
IMAGE=${JANUS_ENGINE_IMAGE:-}
SMOKE_ROOT=${JANUS_SMOKE_ROOT:-"${XDG_STATE_HOME:-${HOME}/.local/state}/janus-engine-smoke"}
VOLUME_PREFIX=${JANUS_SMOKE_VOLUME_PREFIX:-janus_engine_smoke}
COMPOSE_PROJECT=${JANUS_SMOKE_COMPOSE_PROJECT:-janus_engine_smoke}
SECRET_REF="sec_9143cb19a04cc2dc154e"
PROFILE_ID="profile.JANUS_SMOKE"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

require_command age
require_command age-keygen
require_command awk
require_command docker
require_command jq
require_command sed

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

validate_compose_project() {
  name=$1
  value=$2
  case "$value" in
  "" | [!a-z0-9]* | *[!a-z0-9_-]*)
    printf 'invalid %s: %s\n' "$name" "$value" >&2
    exit 1
    ;;
  esac
}

validate_identifier JANUS_SMOKE_VOLUME_PREFIX "$VOLUME_PREFIX"
validate_compose_project JANUS_SMOKE_COMPOSE_PROJECT "$COMPOSE_PROJECT"

if [ "$COMPOSE_PROJECT" = "csb1" ]; then
  printf 'janus smoke refused: JANUS_SMOKE_COMPOSE_PROJECT must not be the live csb1 project\n' >&2
  exit 1
fi

docker_compose_safe() {
  for arg in "$@"; do
    case "$arg" in
    down | rm | restart | stop | start | up | kill | pause | unpause | --remove-orphans)
      printf 'janus smoke refused unsafe docker compose argument: %s\n' "$arg" >&2
      exit 1
      ;;
    esac
  done

  docker compose \
    --project-name "$COMPOSE_PROJECT" \
    --project-directory "$COMPOSE_DIR" \
    -f "${COMPOSE_DIR}/docker-compose.yml" \
    "$@"
}

compose_config() {
  docker_compose_safe --profile janus-engine-staged config --quiet --no-env-resolution
}

compose_run() {
  docker_compose_safe --profile janus-engine-staged run --rm --no-deps "$@"
}

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
export JANUS_SMOKE_AGE_VOLUME="$AGE_VOLUME"
export JANUS_SMOKE_STORE_VOLUME="$STORE_VOLUME"
export JANUS_SMOKE_PERMIT_VOLUME="$PERMIT_VOLUME"
TMP_DIR=$(mktemp -d)
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "${SMOKE_ROOT}"
chmod 0700 "${SMOKE_ROOT}"

compose_config

docker pull "$IMAGE" >/dev/null

container_uid=$(docker run --rm --entrypoint id "$IMAGE" -u)
container_gid=$(docker run --rm --entrypoint id "$IMAGE" -g)
if [ "$container_uid" = "0" ]; then
  printf 'janus smoke failed: image default user is root\n' >&2
  exit 1
fi

docker volume create "$AGE_VOLUME" >/dev/null
docker volume create "$STORE_VOLUME" >/dev/null
docker volume create "$PERMIT_VOLUME" >/dev/null

# New Docker volumes are root-owned until primed. Only this setup container
# runs as root; Warden and janusd still run as the image's default user.
docker run --rm --user 0 \
  -v "${AGE_VOLUME}:/run/janus/age" \
  -v "${STORE_VOLUME}:/var/lib/janus/secrets" \
  -v "${PERMIT_VOLUME}:/run/janus/permits" \
  --entrypoint sh "$IMAGE" \
  -s -- "$container_uid" "$container_gid" <<'EOF'
set -eu
uid=$1
gid=$2
mkdir -p /run/janus/age /run/janus/permits /var/lib/janus/secrets
chown -R "${uid}:${gid}" /run/janus/age /run/janus/permits /var/lib/janus/secrets
EOF

cat >"${SMOKE_ROOT}/volumes.env" <<EOF
JANUS_ENGINE_IMAGE=${IMAGE}
JANUS_SMOKE_VOLUME_PREFIX=${VOLUME_PREFIX}
JANUS_SMOKE_COMPOSE_PROJECT=${COMPOSE_PROJECT}
JANUS_SMOKE_AGE_VOLUME=${AGE_VOLUME}
JANUS_SMOKE_STORE_VOLUME=${STORE_VOLUME}
JANUS_SMOKE_PERMIT_VOLUME=${PERMIT_VOLUME}
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

printf 'janus-nonprod-smoke-%s' "$(date +%s%N)" |
  age -r "$recipient" -o "${TMP_DIR}/JANUS_SMOKE.age"

docker run -i --rm \
  -v "${STORE_VOLUME}:/var/lib/janus/secrets" \
  --entrypoint sh "$IMAGE" \
  -c '
    set -eu
    umask 077
    mkdir -p /var/lib/janus/secrets/janus/csb1
    rm -f /var/lib/janus/secrets/janus/csb1/JANUS_SMOKE.age
    cat >/var/lib/janus/secrets/janus/csb1/JANUS_SMOKE.age
    chmod 0400 /var/lib/janus/secrets/janus/csb1/JANUS_SMOKE.age
  ' <"${TMP_DIR}/JANUS_SMOKE.age"

cat >"${TMP_DIR}/mcp.jsonl" <<EOF
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"janus-smoke","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"request_use","arguments":{"secret_ref":"${SECRET_REF}","profile_id":"${PROFILE_ID}","purpose":"csb1 staged non-prod smoke"}}}
EOF

compose_run -i \
  --entrypoint janus-warden \
  janus-engine-staged <"${TMP_DIR}/mcp.jsonl" \
  >"${TMP_DIR}/warden.out" 2>"${TMP_DIR}/warden.err"

permit=$(
  jq -r 'select(.id==2) | .result.structuredContent.result.permit_id // empty' \
    <"${TMP_DIR}/warden.out" | head -n1
)
if [ -z "$permit" ]; then
  printf 'janus smoke failed: Warden did not issue a permit\n' >&2
  sed -n '1,80p' "${TMP_DIR}/warden.out" >&2
  sed -n '1,120p' "${TMP_DIR}/warden.err" >&2
  exit 1
fi

compose_run \
  janus-engine-staged run --profile "${PROFILE_ID}" --permit "$permit" -- \
  -c "printf 'smoke:%s' \"\$JANUS_SECRET_SMOKE\"" \
  >"${TMP_DIR}/run.out" 2>"${TMP_DIR}/run.err"

if ! grep -qx 'smoke:\[REDACTED\]' "${TMP_DIR}/run.out"; then
  printf 'janus smoke failed: expected redacted stdout\n' >&2
  sed -n '1,40p' "${TMP_DIR}/run.out" >&2
  sed -n '1,80p' "${TMP_DIR}/run.err" >&2
  exit 1
fi

if ! grep -q 'reason_code=ok value_returned=false' "${TMP_DIR}/run.err"; then
  printf 'janus smoke failed: expected ok value-free run evidence\n' >&2
  sed -n '1,80p' "${TMP_DIR}/run.err" >&2
  exit 1
fi

remaining_permits=$(
  docker run --rm \
    -v "${PERMIT_VOLUME}:/run/janus/permits:ro" \
    --entrypoint sh "$IMAGE" \
    -c 'find /run/janus/permits -maxdepth 1 -type f | wc -l | tr -d " "'
)
if [ "$remaining_permits" != "0" ]; then
  printf 'janus smoke failed: permit registry not empty after run (%s files)\n' "$remaining_permits" >&2
  exit 1
fi

printf 'ok: janus non-prod permit smoke passed image=%s profile=%s user_uid=%s user_gid=%s value_returned=false output=redacted permit_consumed=true volumes=%s,%s,%s\n' \
  "$IMAGE" "$PROFILE_ID" "$container_uid" "$container_gid" "$AGE_VOLUME" "$STORE_VOLUME" "$PERMIT_VOLUME"
