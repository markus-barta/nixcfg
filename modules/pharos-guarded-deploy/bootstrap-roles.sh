#!/usr/bin/env bash
set -Eeuo pipefail
set +x

readonly JANUSD_ADMIN='@JANUSD_ADMIN@'
readonly SCOPE_ORGANIZATION='@SCOPE_ORGANIZATION@'
readonly SCOPE_PROJECT='@SCOPE_PROJECT@'
readonly SCOPE_REPOSITORY='@SCOPE_REPOSITORY@'
readonly SCOPE_ENVIRONMENT='@SCOPE_ENVIRONMENT@'
readonly ROLE_BINDINGS_ROOT='@ROLE_BINDINGS_ROOT@'
readonly ROLE_AUDIT_FILE='@ROLE_AUDIT_FILE@'
readonly ROLE_POLICY_FILE='@ROLE_POLICY_FILE@'
readonly BOOTSTRAP_PRINCIPAL='@BOOTSTRAP_PRINCIPAL@'
readonly SECURITY_ADMIN_PRINCIPAL='@SECURITY_ADMIN_PRINCIPAL@'
readonly USE_PRINCIPAL='@USE_PRINCIPAL@'
readonly ADMIN_PRINCIPAL='@ADMIN_PRINCIPAL@'
readonly SOURCE_REFERENCE='@SOURCE_REFERENCE@'
readonly BINDING_TTL_SECONDS='@BINDING_TTL_SECONDS@'

fail() {
  printf 'pharos_guarded_roles=failed reason=%s value_returned=false\n' "$1" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || fail root_required
[ -d "$ROLE_BINDINGS_ROOT" ] && [ ! -L "$ROLE_BINDINGS_ROOT" ] || fail bindings_root_invalid
[ "$(stat -c '%u:%g' "$ROLE_BINDINGS_ROOT")" = '0:0' ] || fail bindings_root_owner_invalid
[ "$(stat -c '%a' "$ROLE_BINDINGS_ROOT")" = '700' ] || fail bindings_root_mode_invalid
[ -f "$ROLE_AUDIT_FILE" ] && [ ! -L "$ROLE_AUDIT_FILE" ] || fail audit_file_invalid
[ "$(stat -c '%u:%g' "$ROLE_AUDIT_FILE")" = '0:0' ] || fail audit_file_owner_invalid
[ "$(stat -c '%a' "$ROLE_AUDIT_FILE")" = '600' ] || fail audit_file_mode_invalid
[ -z "$(find "$ROLE_BINDINGS_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ] || fail registry_not_empty

export JANUS_ROLE_AUTHORIZATION_MODE='enforced'
export JANUS_ROLE_BINDINGS_ROOT="$ROLE_BINDINGS_ROOT"
export JANUS_ROLE_AUDIT_FILE="$ROLE_AUDIT_FILE"
export JANUS_SCOPE_ORGANIZATION="$SCOPE_ORGANIZATION"
export JANUS_SCOPE_PROJECT="$SCOPE_PROJECT"
export JANUS_SCOPE_REPOSITORY="$SCOPE_REPOSITORY"
export JANUS_SCOPE_ENVIRONMENT="$SCOPE_ENVIRONMENT"
if [ -n "$ROLE_POLICY_FILE" ]; then
  export JANUS_ROLE_POLICY_FILE="$ROLE_POLICY_FILE"
else
  unset JANUS_ROLE_POLICY_FILE
fi

tmp=$(mktemp -d "${ROLE_BINDINGS_ROOT%/*}/.role-bootstrap.XXXXXX")
chmod 0700 "$tmp"
cleanup() {
  find "$tmp" -type f -exec shred -u {} + 2>/dev/null || true
  rmdir "$tmp" 2>/dev/null || true
}
trap cleanup EXIT

run_admin() {
  local principal=$1
  shift
  JANUS_RELEASE_EXECUTOR="$principal" "$JANUSD_ADMIN" "$@"
}

JANUS_ROLE_BOOTSTRAP_ACK='bootstrap-role-authorization' \
  run_admin "$BOOTSTRAP_PRINCIPAL" role-binding issue --bootstrap \
  --role security_admin \
  --expires-in-seconds 900 \
  --source-reference "$SOURCE_REFERENCE" \
  --reason initial-reviewed-role-bootstrap >"$tmp/bootstrap.json"
bootstrap_id=$(jq -er '.binding_id | select(test("^rbd_[A-Za-z0-9_-]+$"))' "$tmp/bootstrap.json") ||
  fail bootstrap_output_invalid
scope_ref=$(jq -er '.scope_ref | select(test("^scp_[0-9a-f]{40}$"))' "$tmp/bootstrap.json") ||
  fail bootstrap_output_invalid
jq -e '
  .role == "security_admin"
  and .source_kind == "unsafe_bootstrap"
  and .status == "active"
  and .value_returned == false
' "$tmp/bootstrap.json" >/dev/null || fail bootstrap_output_invalid

issue_binding() {
  local grantor=$1
  local principal=$2
  local role=$3
  local reason=$4
  local output=$5
  run_admin "$grantor" role-binding issue \
    --principal-binding "executor:${principal}|scope:${scope_ref}" \
    --role "$role" \
    --expires-in-seconds "$BINDING_TTL_SECONDS" \
    --source-reference "$SOURCE_REFERENCE" \
    --reason "$reason" >"$output"
  jq -e --arg role "$role" '
    .role == $role
    and .status == "active"
    and .value_returned == false
  ' "$output" >/dev/null || fail binding_output_invalid
}

issue_binding "$BOOTSTRAP_PRINCIPAL" "$SECURITY_ADMIN_PRINCIPAL" security_admin \
  reviewed-security-administration "$tmp/security-admin.json"
issue_binding "$SECURITY_ADMIN_PRINCIPAL" "$USE_PRINCIPAL" operator \
  reviewed-guarded-use "$tmp/operator.json"
issue_binding "$SECURITY_ADMIN_PRINCIPAL" "$ADMIN_PRINCIPAL" approver \
  reviewed-guarded-approval "$tmp/approver.json"
run_admin "$SECURITY_ADMIN_PRINCIPAL" role-binding revoke \
  --binding "$bootstrap_id" \
  --reason bootstrap-replaced-by-reviewed-bindings >"$tmp/revoke.json"

run_admin "$SECURITY_ADMIN_PRINCIPAL" role-binding list >"$tmp/status.json"
jq -e '
  .value_returned == false
  and ([.bindings[] | select(.source_kind == "unsafe_bootstrap" and .status == "revoked")] | length) == 1
  and ([.bindings[] | select(.source_kind == "local_reviewed" and .status == "active" and .role == "security_admin")] | length) == 1
  and ([.bindings[] | select(.source_kind == "local_reviewed" and .status == "active" and .role == "operator")] | length) == 1
  and ([.bindings[] | select(.source_kind == "local_reviewed" and .status == "active" and .role == "approver")] | length) == 1
' "$tmp/status.json" >/dev/null || fail status_contract_invalid

printf 'pharos_guarded_roles=ready scope=%s/%s/%s/%s source_reference=%s value_returned=false\n' \
  "$SCOPE_ORGANIZATION" "$SCOPE_PROJECT" "$SCOPE_REPOSITORY" "$SCOPE_ENVIRONMENT" \
  "$SOURCE_REFERENCE"
