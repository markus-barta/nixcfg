#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
COMPOSE_DIR=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
IMAGE=${JANUS_ENGINE_IMAGE:-}
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../runtime-image-policy.sh"
SMOKE_ROOT=${JANUS_SMOKE_ROOT:-"${XDG_STATE_HOME:-${HOME}/.local/state}/janus-engine-smoke"}
VOLUME_PREFIX=${JANUS_SMOKE_VOLUME_PREFIX:-janus_engine_smoke}
COMPOSE_PROJECT=${JANUS_SMOKE_COMPOSE_PROJECT:-janus_engine_smoke}
SECRET_REF="sec_5b4032741aeaeb486a64"
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
require_command python3
require_command sed

# NIX-361: the long-running staged Warden holds the smoke volumes' audit log;
# a concurrent smoke dies with "audit log is already in use". Refuse loudly
# instead of failing deep inside the harness.
if [ "$(docker inspect --format '{{.State.Running}}' janus-engine-staged 2>/dev/null || true)" = "true" ]; then
  printf 'janus smoke refused: janus-engine-staged is running and holds the audit log (docker stop janus-engine-staged, then retry)\n' >&2
  exit 1
fi

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
    -f /etc/compose/csb1/docker-compose.yml \
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
      /^    janus-engine-staged = {/ { in_service = 1; next }
      in_service && /^      image = "/ { gsub(/^      image = "|";$/, ""); print; exit }
      in_service && /^    };/ { exit }
    ' "${COMPOSE_DIR}/compose-spec.nix"
  )
fi

if [ -z "$IMAGE" ]; then
  printf 'could not resolve janus-engine-staged image from compose-spec.nix\n' >&2
  exit 1
fi

umask 077
AGE_VOLUME="${VOLUME_PREFIX}_age"
STORE_VOLUME="${VOLUME_PREFIX}_secrets"
PERMIT_VOLUME="${VOLUME_PREFIX}_permits"
AUTHORITY_VOLUME="${VOLUME_PREFIX}_authority"
IDENTITYD_CONTAINER="${COMPOSE_PROJECT}-identityd"
SMOKE_NETWORK="${COMPOSE_PROJECT}_default"
export JANUS_SMOKE_AGE_VOLUME="$AGE_VOLUME"
export JANUS_SMOKE_STORE_VOLUME="$STORE_VOLUME"
export JANUS_SMOKE_PERMIT_VOLUME="$PERMIT_VOLUME"
TMP_DIR=$(mktemp -d)
cleanup() {
  docker rm -f "$IDENTITYD_CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
  if docker network inspect "$SMOKE_NETWORK" >/dev/null 2>&1; then
    network_containers=$(
      docker network inspect "$SMOKE_NETWORK" \
        --format '{{ len .Containers }}' 2>/dev/null || printf '1'
    )
    if [ "$network_containers" = "0" ]; then
      docker network rm "$SMOKE_NETWORK" >/dev/null 2>&1 || true
    fi
  fi
}
trap cleanup EXIT

mkdir -p "${SMOKE_ROOT}"
chmod 0700 "${SMOKE_ROOT}"

compose_config

docker pull "$IMAGE" >/dev/null

janus_assert_static_runtime_image "$IMAGE"
container_uid=$JANUS_RUNTIME_UID
container_gid=$JANUS_RUNTIME_GID

docker volume create "$AGE_VOLUME" >/dev/null
docker volume create "$STORE_VOLUME" >/dev/null
docker volume create "$PERMIT_VOLUME" >/dev/null

# New Docker volumes are root-owned until primed. Only this setup container
# runs as root; Warden and janusd still run as the image's default user.
docker run -i --rm --user 0 \
  -v "${AGE_VOLUME}:/run/janus/age" \
  -v "${STORE_VOLUME}:/var/lib/janus/secrets" \
  -v "${PERMIT_VOLUME}:/run/janus/permits" \
  --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
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
  --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
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
      --user "${container_uid}:${container_gid}" \
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

printf 'janus-nonprod-smoke-%s' "$(date +%s%N)" |
  age -r "$recipient" -o "${TMP_DIR}/JANUS_SMOKE.age"

docker run -i --rm \
  --user "${container_uid}:${container_gid}" \
  -v "${STORE_VOLUME}:/var/lib/janus/secrets" \
  --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
  -c '
    set -eu
    umask 077
    mkdir -p /var/lib/janus/secrets/janus/csb1
    rm -f /var/lib/janus/secrets/janus/csb1/JANUS_SMOKE.age
    cat >/var/lib/janus/secrets/janus/csb1/JANUS_SMOKE.age
    chmod 0400 /var/lib/janus/secrets/janus/csb1/JANUS_SMOKE.age
  ' <"${TMP_DIR}/JANUS_SMOKE.age"

# --- NIX-361: runtime accountability broker (JANUS-429) ---------------------
# Since rust-engine v0.1.22+ every Warden tool call and janusd-use command
# obtains a signed, value-free admission from janusd-identityd before role
# authorization runs; without a broker the engine denies with
# runtime_authority_denied. This stands up a smoke-scoped identityd sidecar
# (same hardened release image, no network, socket shared via a dedicated
# volume) in accountability_legacy posture — the upstream assurance-harness
# shape (janus scripts/with-runtime-authority.sh), containerized. The two
# manifests in ./authority/ are vendored tag-exact from the pinned release.
AUTHORITY_ROOT=/run/janus/authority
TRUST_DOMAIN="janus-nonprod-smoke"
RELEASE_DIGEST="${IMAGE##*@}"

docker volume create "$AUTHORITY_VOLUME" >/dev/null
docker rm -f "$IDENTITYD_CONTAINER" >/dev/null 2>&1 || true

docker run -i --rm --user 0 \
  -v "${AUTHORITY_VOLUME}:${AUTHORITY_ROOT}" \
  --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
  -s -- "$container_uid" "$container_gid" "$AUTHORITY_ROOT" <<'EOF'
set -eu
uid=$1
gid=$2
root=$3
mkdir -p "$root/registry" "$root/run" "$root/state" "$root/audit"
# identityd denies an occupied socket path; a leftover from a previous run
# must never look occupied.
rm -f "$root/run/identity.sock"
chown -R "${uid}:${gid}" "$root"
chmod 0700 "$root" "$root/registry" "$root/run" "$root/state" "$root/audit"
EOF

# Enroll the container runtime uid as the smoke's stable subject. The record
# is value-free; fingerprints follow the upstream length-prefixed framing.
python3 - "$container_uid" "$TRUST_DOMAIN" <<'PY' |
import hashlib
import json
import sys
import time

uid = int(sys.argv[1])
trust_domain = sys.argv[2]
subject = "act_11111111111111111111111111111111"

def fingerprint(domain: str, value: bytes) -> str:
    digest = hashlib.sha256()
    encoded = domain.encode()
    digest.update(len(encoded).to_bytes(8, "big"))
    digest.update(encoded)
    digest.update(len(value).to_bytes(8, "big"))
    digest.update(value)
    return "sha256:" + digest.hexdigest()

record = {
    "schema_version": 1,
    "subject_ref": subject,
    "subject_class": "human",
    "trust_adapter": "local_peer",
    "trust_domain_fingerprint": fingerprint("janus-identity-trust-domain-v1", trust_domain.encode()),
    "local_uid": uid,
    "enrolled_at_unix_secs": int(time.time()),
    "review_fingerprint": fingerprint("janus-subject-review-v1", b"nix-361-nonprod-smoke-review"),
}
print(json.dumps(record, separators=(",", ":")))
PY
  docker run -i --rm \
    --user "${container_uid}:${container_gid}" \
    -v "${AUTHORITY_VOLUME}:${AUTHORITY_ROOT}" \
    --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
    -c "
      set -eu
      umask 077
      cat >${AUTHORITY_ROOT}/registry/act_11111111111111111111111111111111.json
      chmod 0600 ${AUTHORITY_ROOT}/registry/act_11111111111111111111111111111111.json
    "

authority_env_flags=(
  -e "JANUS_SCOPE_ORGANIZATION=inspr"
  -e "JANUS_SCOPE_PROJECT=janus"
  -e "JANUS_SCOPE_REPOSITORY=nixcfg"
  -e "JANUS_SCOPE_ENVIRONMENT=staged"
  -e "JANUS_IDENTITY_SOCKET=${AUTHORITY_ROOT}/run/identity.sock"
  -e "JANUS_DUTY_SURFACE_MANIFEST=/etc/janus/authority/duty-surface-manifest-v1.json"
  -e "JANUS_ACCOUNTABILITY_POSTURE=accountability_legacy"
  -e "JANUS_RUNTIME_AUTHORITY_AUDIENCE=janus-runtime-nonprod-smoke"
  -e "JANUS_RUNTIME_AUTHORITY_VERIFYING_KEY_FILE=${AUTHORITY_ROOT}/state/runtime-authority.pub"
  -e "JANUS_RELEASE_DIGEST=${RELEASE_DIGEST}"
)

identityd_env_flags=(
  "${authority_env_flags[@]}"
  -e "JANUS_IDENTITY_REGISTRY_ROOT=${AUTHORITY_ROOT}/registry"
  -e "JANUS_IDENTITY_SIGNING_KEY_FILE=${AUTHORITY_ROOT}/state/identity-signing.key"
  -e "JANUS_IDENTITY_TRANSPORT_MANIFEST=/etc/janus/authority/transport-manifest-v1.json"
  -e "JANUS_IDENTITY_TRUST_DOMAIN=${TRUST_DOMAIN}"
  -e "JANUS_IDENTITY_AUDIENCE=janus-identity-nonprod-smoke"
  -e "JANUS_IDENTITY_ASSERTION_TTL_SECONDS=60"
  -e "JANUS_OPERATION_VERIFYING_KEY_FILE=${AUTHORITY_ROOT}/state/runtime-authority.pub"
  -e "JANUS_OPERATION_DOMAIN_SERVICE=${TRUST_DOMAIN}"
  -e "JANUS_OPERATION_AUDIENCE=janus-runtime-nonprod-smoke"
  -e "JANUS_RUNTIME_AUTHORITY_AUDIT_FILE=${AUTHORITY_ROOT}/audit/runtime-authority.jsonl"
)

docker run -d --name "$IDENTITYD_CONTAINER" \
  --user "${container_uid}:${container_gid}" \
  --read-only --network none --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --tmpfs "/tmp:rw,noexec,nosuid,nodev,size=16m,uid=${container_uid},gid=${container_gid},mode=0700" \
  -v "${AUTHORITY_VOLUME}:${AUTHORITY_ROOT}" \
  -v "${SCRIPT_DIR}/authority:/etc/janus/authority:ro" \
  "${identityd_env_flags[@]}" \
  --entrypoint /usr/local/bin/janusd-identityd \
  "$IMAGE" >/dev/null

identityd_ready=0
for _ in $(seq 1 100); do
  if docker run --rm -v "${AUTHORITY_VOLUME}:${AUTHORITY_ROOT}:ro" \
    --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
    -c "test -S ${AUTHORITY_ROOT}/run/identity.sock" 2>/dev/null; then
    identityd_ready=1
    break
  fi
  if [ "$(docker inspect --format '{{.State.Running}}' "$IDENTITYD_CONTAINER" 2>/dev/null)" != "true" ]; then
    break
  fi
  sleep 0.2
done
if [ "$identityd_ready" != "1" ]; then
  printf 'janus smoke failed: runtime authority broker did not come up\n' >&2
  docker logs "$IDENTITYD_CONTAINER" 2>&1 | sed -n '1,40p' >&2 || true
  exit 1
fi

compose_run_authorized() {
  compose_run \
    "${authority_env_flags[@]}" \
    -v "${AUTHORITY_VOLUME}:${AUTHORITY_ROOT}" \
    -v "${SCRIPT_DIR}/authority:/etc/janus/authority:ro" \
    "$@"
}
# --- end runtime accountability broker ---------------------------------------

cat >"${TMP_DIR}/mcp.jsonl" <<EOF
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"janus-smoke","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"request_use","arguments":{"secret_ref":"${SECRET_REF}","profile_id":"${PROFILE_ID}","purpose":"csb1 staged non-prod smoke"}}}
EOF

# The redirects below hide the Warden's own stderr; a nonzero exit must dump
# it instead of dying silently under set -e (NIX-361 diagnosis lesson).
warden_rc=0
compose_run_authorized -i \
  --entrypoint janus-warden \
  janus-engine-staged <"${TMP_DIR}/mcp.jsonl" \
  >"${TMP_DIR}/warden.out" 2>"${TMP_DIR}/warden.err" || warden_rc=$?
if [ "$warden_rc" != "0" ]; then
  printf 'janus smoke failed: Warden exited %s\n' "$warden_rc" >&2
  sed -n '1,80p' "${TMP_DIR}/warden.out" >&2
  sed -n '1,120p' "${TMP_DIR}/warden.err" >&2
  exit 1
fi

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

use_rc=0
compose_run_authorized \
  --entrypoint janusd-use \
  janus-engine-staged run --profile "${PROFILE_ID}" --permit "$permit" -- --help \
  >"${TMP_DIR}/run.out" 2>"${TMP_DIR}/run.err" || use_rc=$?
if [ "$use_rc" != "0" ] && ! grep -q 'reason_code=ok value_returned=false' "${TMP_DIR}/run.err"; then
  printf 'janus smoke failed: supervised consumer exited %s\n' "$use_rc" >&2
  sed -n '1,40p' "${TMP_DIR}/run.out" >&2
  sed -n '1,80p' "${TMP_DIR}/run.err" >&2
  exit 1
fi

if [ -s "${TMP_DIR}/run.out" ]; then
  printf 'janus smoke failed: supervised consumer returned unexpected stdout\n' >&2
  sed -n '1,40p' "${TMP_DIR}/run.out" >&2
  sed -n '1,80p' "${TMP_DIR}/run.err" >&2
  exit 1
fi
if grep -q 'janus-nonprod-smoke-' "${TMP_DIR}/run.out" "${TMP_DIR}/run.err"; then
  printf 'janus smoke failed: consumer output exposed fixture material\n' >&2
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
    --entrypoint sh "$JANUS_VOLUME_HELPER_IMAGE" \
    -c 'find /run/janus/permits -maxdepth 1 -type f | wc -l | tr -d " "'
)
if [ "$remaining_permits" != "0" ]; then
  printf 'janus smoke failed: permit registry not empty after run (%s files)\n' "$remaining_permits" >&2
  exit 1
fi

printf 'ok: janus non-prod permit smoke passed image=%s profile=%s user_uid=%s user_gid=%s value_returned=false output=suppressed permit_consumed=true volumes=%s,%s,%s\n' \
  "$IMAGE" "$PROFILE_ID" "$container_uid" "$container_gid" "$AGE_VOLUME" "$STORE_VOLUME" "$PERMIT_VOLUME"
