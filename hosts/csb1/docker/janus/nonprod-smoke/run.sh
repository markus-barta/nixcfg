#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
COMPOSE_DIR=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
IMAGE=${JANUS_ENGINE_IMAGE:-}
SMOKE_ROOT=${JANUS_SMOKE_ROOT:-"${XDG_STATE_HOME:-${HOME}/.local/state}/janus-engine-smoke"}
SECRET_REF="sec_9143cb19a04cc2dc154e"
PROFILE_ID="profile.JANUS_SMOKE"
DESTINATION="janus-engine-nonprod-smoke"
EXECUTOR="janus-run@csb1"
SCOPE="janus/csb1/staged"

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
AGE_DIR="${SMOKE_ROOT}/age"
STORE_DIR="${SMOKE_ROOT}/secrets"
PERMIT_DIR="${SMOKE_ROOT}/permits"
TMP_DIR=$(mktemp -d)
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "${AGE_DIR}" "${STORE_DIR}/janus/csb1" "${PERMIT_DIR}"
chmod 0700 "${SMOKE_ROOT}" "${AGE_DIR}" "${PERMIT_DIR}"
find "${PERMIT_DIR}" -maxdepth 1 -type f \( -name 'use_*.json' -o -name '.use_*.claim' \) -delete

if [ ! -s "${AGE_DIR}/identity" ] || [ ! -s "${AGE_DIR}/recipient.pub" ]; then
  keygen_out=$(age-keygen 2>&1)
  recipient=$(printf '%s\n' "$keygen_out" | sed -n 's/^Public key: //p' | head -n1)
  identity=$(printf '%s\n' "$keygen_out" | sed -n 's/.*\(AGE-SECRET-KEY-[A-Z0-9]*\).*/\1/p' | head -n1)
  if [ -z "$recipient" ] || [ -z "$identity" ]; then
    printf 'failed to generate non-prod age identity\n' >&2
    exit 1
  fi
  printf '%s\n' "$identity" >"${AGE_DIR}/identity"
  printf '%s\n' "$recipient" >"${AGE_DIR}/recipient.pub"
fi

recipient=$(cat "${AGE_DIR}/recipient.pub")
printf 'janus-nonprod-smoke-%s' "$(date +%s%N)" |
  age -r "$recipient" -o "${STORE_DIR}/janus/csb1/JANUS_SMOKE.age"

cat >"${TMP_DIR}/mcp.jsonl" <<EOF
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"janus-smoke","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"request_use","arguments":{"secret_ref":"${SECRET_REF}","profile_id":"${PROFILE_ID}","purpose":"csb1 staged non-prod smoke"}}}
EOF

docker pull "$IMAGE" >/dev/null
docker run -i --rm --user 0 \
  -e JANUS_WARDEN_BACKEND=age \
  -e JANUS_WARDEN_PERMIT_DIR=/run/janus/permits \
  -e JANUS_WARDEN_EXECUTOR="${EXECUTOR}" \
  -e JANUS_WARDEN_DESTINATION="${DESTINATION}" \
  -e JANUS_WARDEN_SCOPE="${SCOPE}" \
  -e JANUS_WARDEN_AGE_MANIFEST_FILE=/etc/janus/secretspec.toml \
  -e JANUS_WARDEN_AGE_PROFILE=csb1 \
  -e JANUS_WARDEN_AGE_STORE_DIR=/var/lib/janus/secrets \
  -e JANUS_WARDEN_AGE_IDENTITY_FILE=/run/janus/age/identity \
  -e JANUS_WARDEN_AGE_RECIPIENTS_FILE=/run/janus/age/recipient.pub \
  -v "${SCRIPT_DIR}/secretspec.toml:/etc/janus/secretspec.toml:ro" \
  -v "${STORE_DIR}:/var/lib/janus/secrets" \
  -v "${PERMIT_DIR}:/run/janus/permits" \
  -v "${AGE_DIR}/identity:/run/janus/age/identity:ro" \
  -v "${AGE_DIR}/recipient.pub:/run/janus/age/recipient.pub:ro" \
  --entrypoint janus-warden "$IMAGE" <"${TMP_DIR}/mcp.jsonl" \
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

docker run --rm --user 0 \
  -e JANUS_RUN_PERMIT_DIR=/run/janus/permits \
  -e JANUS_RUN_EXECUTOR="${EXECUTOR}" \
  -e JANUS_RUN_SCOPE="${SCOPE}" \
  -e JANUS_AGE_MANIFEST_FILE=/etc/janus/secretspec.toml \
  -e JANUS_AGE_PROFILE=csb1 \
  -e JANUS_AGE_STORE_DIR=/var/lib/janus/secrets \
  -e JANUS_AGE_IDENTITY_FILE=/run/janus/age/identity \
  -e JANUS_AGE_RECIPIENTS_FILE=/run/janus/age/recipient.pub \
  -e JANUS_RUN_PROFILE_MANIFEST=/etc/janus/managed-commands.toml \
  -v "${SCRIPT_DIR}/secretspec.toml:/etc/janus/secretspec.toml:ro" \
  -v "${SCRIPT_DIR}/managed-commands.toml:/etc/janus/managed-commands.toml:ro" \
  -v "${STORE_DIR}:/var/lib/janus/secrets" \
  -v "${PERMIT_DIR}:/run/janus/permits" \
  -v "${AGE_DIR}/identity:/run/janus/age/identity:ro" \
  -v "${AGE_DIR}/recipient.pub:/run/janus/age/recipient.pub:ro" \
  "$IMAGE" run --profile "${PROFILE_ID}" --permit "$permit" -- \
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

remaining_permits=$(find "${PERMIT_DIR}" -maxdepth 1 -type f | wc -l | tr -d ' ')
if [ "$remaining_permits" != "0" ]; then
  printf 'janus smoke failed: permit registry not empty after run (%s files)\n' "$remaining_permits" >&2
  exit 1
fi

printf 'ok: janus non-prod permit smoke passed image=%s profile=%s value_returned=false output=redacted permit_consumed=true\n' \
  "$IMAGE" "$PROFILE_ID"
