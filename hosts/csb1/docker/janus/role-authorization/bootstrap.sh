#!/usr/bin/env bash
set -Eeuo pipefail
set +x

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
COMPOSE_SPEC=${JANUS_ROLE_COMPOSE_SPEC:-${SCRIPT_DIR}/../../compose-spec.nix}
ROLE_CONTAINER_ROOT=/var/lib/janus/role-authorization
IMAGE=${JANUS_ENGINE_IMAGE:-}
SOURCE_REFERENCE=${JANUS_ROLE_SOURCE_REFERENCE:-NIX-345}
DURABLE_TTL_SECONDS=31622400
mode=${1:-bootstrap}
posture=${2:-production}

fail() {
  printf 'janus_role_bootstrap=failed reason=%s value_returned=false\n' "$1" >&2
  exit 1
}

case "$mode" in
bootstrap | status) ;;
*) fail invalid_mode ;;
esac

case "$posture" in
production)
  PRODUCT_MODE=production
  SCOPE_PROJECT=pharos
  SCOPE_ENVIRONMENT=production
  BOOTSTRAP_ACTOR=janus-role-bootstrap@csb1
  SECURITY_ADMIN_ACTOR=janus-security-admin@csb1
  SECURITY_REVIEWER_ACTOR=janus-security-reviewer@csb1
  EXPECTED_REVIEWED=6
  EXPECTED_OPERATORS=2
  EXPECTED_OWNERS=2
  ;;
staged)
  PRODUCT_MODE=self_hosted
  SCOPE_PROJECT=janus
  SCOPE_ENVIRONMENT=staged
  BOOTSTRAP_ACTOR=janus-role-bootstrap-staged@csb1
  SECURITY_ADMIN_ACTOR=janus-security-admin-staged@csb1
  SECURITY_REVIEWER_ACTOR=janus-security-reviewer-staged@csb1
  EXPECTED_REVIEWED=3
  EXPECTED_OPERATORS=1
  EXPECTED_OWNERS=0
  ;;
*) fail invalid_posture ;;
esac
ROLE_HOST_ROOT=${JANUS_ROLE_HOST_ROOT:-/var/lib/janus-role-authorization-csb1/${posture}}

for dependency in awk docker find jq stat; do
  command -v "$dependency" >/dev/null 2>&1 || fail missing_dependency
done

[ "$(id -u)" = 0 ] || fail root_required
[ -f "$COMPOSE_SPEC" ] || fail compose_spec_missing

if [ -z "$IMAGE" ]; then
  IMAGE=$(
    awk '
      /^    janus-managed-transactiond = \{/ { inside = 1; next }
      inside && /^      image = "/ {
        gsub(/^      image = "|";$/, "")
        print
        exit
      }
      inside && /^    \};$/ { exit }
    ' "$COMPOSE_SPEC"
  )
fi
[[ "$IMAGE" =~ ^ghcr\.io/inspr-at/janus/janus-engine:rust-engine-v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]] ||
  fail image_pin_invalid

for path in "$ROLE_HOST_ROOT" "$ROLE_HOST_ROOT/bindings"; do
  [ -d "$path" ] && [ ! -L "$path" ] || fail role_directory_invalid
  [ "$(stat -c %u:%g "$path")" = "65532:65532" ] || fail role_directory_owner_invalid
  [ "$(stat -c %a "$path")" = "700" ] || fail role_directory_mode_invalid
done
[ -f "$ROLE_HOST_ROOT/audit.jsonl" ] && [ ! -L "$ROLE_HOST_ROOT/audit.jsonl" ] ||
  fail role_audit_invalid
[ "$(stat -c %u:%g "$ROLE_HOST_ROOT/audit.jsonl")" = "65532:65532" ] ||
  fail role_audit_owner_invalid
[ "$(stat -c %a "$ROLE_HOST_ROOT/audit.jsonl")" = "600" ] ||
  fail role_audit_mode_invalid
run_admin() {
  local actor=$1
  shift

  # NIX-377: production posture requires runtime authority socket for janusd-admin
  local -a authority_env=()
  if [ "$posture" = "production" ]; then
    local identity_root=/var/lib/janus-identity-csb1/production
    local identity_socket="${identity_root}/run/identity.sock"
    local release_digest="${IMAGE##*@}"
    authority_env=(
      -e "JANUS_IDENTITY_SOCKET=${identity_socket}"
      -e "JANUS_DUTY_SURFACE_MANIFEST=/etc/janus/pharos-production-authority/duty-surface-manifest-v1.json"
      -e "JANUS_ACCOUNTABILITY_POSTURE=identity_shadow_only"
      -e "JANUS_RUNTIME_AUTHORITY_AUDIENCE=janus-runtime-pharos-production"
      -e "JANUS_RUNTIME_AUTHORITY_VERIFYING_KEY_FILE=${identity_root}/state/runtime-authority.pub"
      -e "JANUS_RELEASE_DIGEST=${release_digest}"
      -v "${identity_root}:/var/lib/janus/identity:ro"
      -v /etc/janus/pharos-production-authority:/etc/janus/pharos-production-authority:ro
    )
  fi

  docker run --rm --network none --read-only \
    --user 65532:65532 \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    -e "JANUS_PRODUCT_MODE=${PRODUCT_MODE}" \
    -e JANUS_ROLE_AUTHORIZATION_MODE=enforced \
    -e JANUS_ROLE_BINDINGS_ROOT=${ROLE_CONTAINER_ROOT}/bindings \
    -e JANUS_ROLE_AUDIT_FILE=${ROLE_CONTAINER_ROOT}/audit.jsonl \
    -e "JANUS_RELEASE_EXECUTOR=${actor}" \
    -e JANUS_SCOPE_ORGANIZATION=inspr \
    -e "JANUS_SCOPE_PROJECT=${SCOPE_PROJECT}" \
    -e JANUS_SCOPE_REPOSITORY=nixcfg \
    -e "JANUS_SCOPE_ENVIRONMENT=${SCOPE_ENVIRONMENT}" \
    -v "${ROLE_HOST_ROOT}:${ROLE_CONTAINER_ROOT}" \
    "${authority_env[@]}" \
    --entrypoint /usr/local/bin/janusd-admin \
    "$IMAGE" "$@"
}

if [ "$mode" = status ]; then
  run_admin "$SECURITY_ADMIN_ACTOR" role-binding list
  exit
fi

[ -z "$(find "$ROLE_HOST_ROOT/bindings" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
  fail registry_not_empty

bootstrap_output=$(
  JANUS_ROLE_BOOTSTRAP_ACK=bootstrap-role-authorization \
    docker run --rm --network none --read-only \
    --user 65532:65532 \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    -e "JANUS_PRODUCT_MODE=${PRODUCT_MODE}" \
    -e JANUS_ROLE_AUTHORIZATION_MODE=enforced \
    -e JANUS_ROLE_BOOTSTRAP_ACK \
    -e JANUS_ROLE_BINDINGS_ROOT=${ROLE_CONTAINER_ROOT}/bindings \
    -e JANUS_ROLE_AUDIT_FILE=${ROLE_CONTAINER_ROOT}/audit.jsonl \
    -e "JANUS_RELEASE_EXECUTOR=${BOOTSTRAP_ACTOR}" \
    -e JANUS_SCOPE_ORGANIZATION=inspr \
    -e "JANUS_SCOPE_PROJECT=${SCOPE_PROJECT}" \
    -e JANUS_SCOPE_REPOSITORY=nixcfg \
    -e "JANUS_SCOPE_ENVIRONMENT=${SCOPE_ENVIRONMENT}" \
    -v "${ROLE_HOST_ROOT}:${ROLE_CONTAINER_ROOT}" \
    --entrypoint /usr/local/bin/janusd-admin \
    "$IMAGE" role-binding issue --bootstrap \
    --role security_admin \
    --expires-in-seconds 900 \
    --source-reference "$SOURCE_REFERENCE" \
    --reason initial-role-authorization-bootstrap
) || fail bootstrap_denied

bootstrap_id=$(jq -er '.binding_id | select(test("^rbd_[A-Za-z0-9_-]+$"))' <<<"$bootstrap_output") ||
  fail bootstrap_output_invalid
scope_ref=$(jq -er '.scope_ref | select(test("^scp_[0-9a-f]{40}$"))' <<<"$bootstrap_output") ||
  fail bootstrap_output_invalid
jq -e '
  .role == "security_admin"
  and .source_kind == "unsafe_bootstrap"
  and .status == "active"
  and .value_returned == false
' <<<"$bootstrap_output" >/dev/null || fail bootstrap_output_invalid
printf '%s\n' "$bootstrap_output"

issue_binding() {
  local actor=$1
  local principal=$2
  local role=$3
  local reason=$4
  run_admin "$actor" role-binding issue \
    --principal-binding "executor:${principal}|scope:${scope_ref}" \
    --role "$role" \
    --expires-in-seconds "$DURABLE_TTL_SECONDS" \
    --source-reference "$SOURCE_REFERENCE" \
    --reason "$reason"
}

# The short-lived bootstrap identity creates one reviewed durable admin. That
# distinct identity then owns every remaining grant and closes the bootstrap.
issue_binding "$BOOTSTRAP_ACTOR" "$SECURITY_ADMIN_ACTOR" security_admin reviewed-security-admin
issue_binding "$BOOTSTRAP_ACTOR" "$SECURITY_REVIEWER_ACTOR" security_admin reviewed-security-reviewer
if [ "$posture" = production ]; then
  issue_binding "$SECURITY_ADMIN_ACTOR" janus-run@csb1 operator production-approved-use
  issue_binding "$SECURITY_ADMIN_ACTOR" pharos-managed-use@csb1 operator managed-provisioning-use
  issue_binding "$SECURITY_ADMIN_ACTOR" pharos-managed@csb1 owner managed-provisioning-lifecycle
  issue_binding "$SECURITY_ADMIN_ACTOR" janus-pharos-retirement@csb1 owner reviewed-retirement-lifecycle
else
  issue_binding "$SECURITY_ADMIN_ACTOR" janus-run@csb1 operator staged-approved-use
fi
run_admin "$SECURITY_ADMIN_ACTOR" role-binding revoke \
  --binding "$bootstrap_id" \
  --reason bootstrap-replaced-by-reviewed-bindings

status_output=$(run_admin "$SECURITY_ADMIN_ACTOR" role-binding list) ||
  fail status_denied
jq -e \
  --argjson reviewed "$EXPECTED_REVIEWED" \
  --argjson operators "$EXPECTED_OPERATORS" \
  --argjson owners "$EXPECTED_OWNERS" '
  .value_returned == false
  and ([.bindings[] | select(.source_kind == "unsafe_bootstrap" and .status == "revoked")] | length) == 1
  and ([.bindings[] | select(.source_kind == "local_reviewed" and .status == "active")] | length) == $reviewed
  and ([.bindings[] | select(.role == "security_admin" and .status == "active")] | length) == 2
  and ([.bindings[] | select(.role == "operator" and .status == "active")] | length) == $operators
  and ([.bindings[] | select(.role == "owner" and .status == "active")] | length) == $owners
' <<<"$status_output" >/dev/null || fail status_contract_invalid
printf '%s\n' "$status_output"

if run_admin janus-unauthorized@csb1 role-binding list >/dev/null 2>&1; then
  fail unauthorized_actor_allowed
fi
printf 'janus_role_bootstrap=ready posture=%s source_reference=%s value_returned=false\n' \
  "$posture" "$SOURCE_REFERENCE"
