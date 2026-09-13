#!/usr/bin/env bash
set -Eeuo pipefail
set +x

readonly REFERENCE_ROOT='@OPERATION_REFERENCE_ROOT@'
readonly EXPECTED_SCOPE_REF='@OPERATION_SCOPE_REF@'
readonly EXPECTED_DOMAIN_SERVICE='@OPERATION_DOMAIN_SERVICE@'
readonly EXPECTED_AUDIENCE_FINGERPRINT='@OPERATION_AUDIENCE_FINGERPRINT@'
readonly EXPECTED_RELEASE_DIGEST='@OPERATION_RELEASE_DIGEST@'

fail() {
  printf 'pharos_guarded_operation_reference=failed reason=%s value_returned=false\n' "$1" >&2
  exit 1
}

validate_directory() {
  local path=$1
  [ -d "$path" ] && [ ! -L "$path" ] || fail reference_directory_invalid
  [ "$(stat -c '%u:%g' "$path")" = '0:0' ] || fail reference_directory_owner_invalid
  [ "$(stat -c '%a' "$path")" = '700' ] || fail reference_directory_mode_invalid
}

[ "$(id -u)" -eq 0 ] || fail root_required
[ -n "$REFERENCE_ROOT" ] || fail reference_contract_unconfigured
validate_directory "$REFERENCE_ROOT"
validate_directory "$REFERENCE_ROOT/incoming"
validate_directory "$REFERENCE_ROOT/consumed"

kind=${1:-}
step=${2:-}
case "$kind:$step" in
bootstrap:bootstrap-security-admin | bootstrap:reviewed-security-admin | bootstrap:reviewed-operator | bootstrap:reviewed-approver)
  [ "$#" -eq 3 ] || fail invocation_invalid
  source_reference=$3
  [[ "$source_reference" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]] || fail source_reference_invalid
  [ "${#source_reference}" -le 32 ] || fail source_reference_invalid
  workflow_dir="$REFERENCE_ROOT/incoming/role-bootstrap"
  validate_directory "$workflow_dir"
  bundle_dir="$workflow_dir/$source_reference"
  lineage="inspr397-guarded-role-bootstrap-v1|source=$source_reference|step=$step"
  conflict_domain='role_binding'
  duty='grant_role'
  ;;
action:approval | action:execute)
  [ "$#" -eq 7 ] || fail invocation_invalid
  action=$3
  ticket=$4
  lease_id=$5
  phase=$6
  host=$7
  [[ "$action" =~ ^(apply|rollback|update)$ ]] || fail action_invalid
  [[ "$ticket" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]] || fail ticket_invalid
  [ "${#ticket}" -le 32 ] || fail ticket_invalid
  [[ "$lease_id" =~ ^[a-z0-9][a-z0-9._-]{0,159}$ ]] || fail lease_id_invalid
  [[ "$phase" =~ ^(review|apply|resume)$ ]] || fail phase_invalid
  [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || fail host_invalid
  workflow_dir="$REFERENCE_ROOT/incoming/actions"
  validate_directory "$workflow_dir"
  lease_dir="$workflow_dir/$lease_id"
  validate_directory "$lease_dir"
  phase_dir="$lease_dir/$phase"
  validate_directory "$phase_dir"
  bundle_dir="$phase_dir/$action"
  lineage="inspr397-guarded-action-v1|id=$lease_id|host=$host|ticket=$ticket|phase=$phase|action=$action"
  conflict_domain='use_request'
  if [ "$step" = approval ]; then duty='approve_use'; else duty='execute_use'; fi
  ;;
*) fail invocation_invalid ;;
esac

validate_directory "$bundle_dir"
reference_file="$bundle_dir/$step.json"
[ -f "$reference_file" ] && [ ! -L "$reference_file" ] || fail reference_missing
[ "$(stat -c '%u:%g' "$reference_file")" = '0:0' ] || fail reference_owner_invalid
[ "$(stat -c '%a' "$reference_file")" = '600' ] || fail reference_mode_invalid
[ "$(stat -c '%h' "$reference_file")" = '1' ] || fail reference_link_invalid
[ "$(stat -c '%s' "$reference_file")" -le 65536 ] || fail reference_size_invalid

expected_operation_ref=$(python3 - "$conflict_domain" "$lineage" <<'PY'
import hashlib
import struct
import sys

hasher = hashlib.sha256()
for field in ("janus-operation-ref-v1", sys.argv[1], sys.argv[2]):
    raw = field.encode("utf-8")
    hasher.update(struct.pack(">Q", len(raw)))
    hasher.update(raw)
print("opr_" + hasher.hexdigest()[:32])
PY
) || fail operation_ref_derivation_failed

now=$(date -u +%s)
jq -e \
  --arg domain_service "$EXPECTED_DOMAIN_SERVICE" \
  --arg operation_ref "$expected_operation_ref" \
  --arg scope_ref "$EXPECTED_SCOPE_REF" \
  --arg conflict_domain "$conflict_domain" \
  --arg duty "$duty" \
  --arg audience_fingerprint "$EXPECTED_AUDIENCE_FINGERPRINT" \
  --arg release_digest "$EXPECTED_RELEASE_DIGEST" \
  --argjson now "$now" '
    (keys | sort) == [
      "audience_fingerprint", "conflict_domain", "domain_service",
      "duty", "expires_at_unix_secs", "issued_at_unix_secs", "nonce_ref",
      "operation_ref", "policy_revision", "release_digest", "schema_version",
      "scope_ref", "signature", "state_revision"
    ]
    and .schema_version == 1
    and .domain_service == $domain_service
    and .operation_ref == $operation_ref
    and .scope_ref == $scope_ref
    and .conflict_domain == $conflict_domain
    and .duty == $duty
    and (.state_revision | type == "number" and floor == . and . > 0)
    and (.policy_revision | type == "string" and length > 0
      and (sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "")) == .)
    and (.issued_at_unix_secs | type == "number" and floor == . and . <= $now)
    and (.expires_at_unix_secs | type == "number" and floor == . and . > $now)
    and (.expires_at_unix_secs > .issued_at_unix_secs)
    and ((.expires_at_unix_secs - .issued_at_unix_secs) <= 300)
    and (.nonce_ref | type == "string" and test("^nce_[0-9a-f]{24}$"))
    and .audience_fingerprint == $audience_fingerprint
    and .release_digest == $release_digest
    and (.signature | type == "string" and test("^[0-9a-f]{128}$"))
  ' "$reference_file" >/dev/null || fail reference_context_invalid

nonce_ref=$(jq -er '.nonce_ref' "$reference_file") || fail reference_context_invalid
claim_dir="$REFERENCE_ROOT/consumed/$nonce_ref"
mkdir -m 0700 "$claim_dir" 2>/dev/null || fail reference_reused
claimed_file="$claim_dir/reference.json"
source_identity=$(stat -c '%d:%i' "$reference_file") || fail reference_identity_invalid
if ! mv "$reference_file" "$claimed_file"; then
  rmdir "$claim_dir" 2>/dev/null || true
  fail reference_consume_failed
fi
[ "$(stat -c '%d:%i' "$claimed_file")" = "$source_identity" ] || fail reference_identity_changed
[ "$(stat -c '%u:%g' "$claimed_file")" = '0:0' ] || fail reference_owner_invalid
[ "$(stat -c '%a' "$claimed_file")" = '600' ] || fail reference_mode_invalid
[ "$(stat -c '%h' "$claimed_file")" = '1' ] || fail reference_link_invalid

printf '%s\n' "$claimed_file"
