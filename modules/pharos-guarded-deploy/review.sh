#!/usr/bin/env bash
set -Eeuo pipefail

readonly HOST='@HOST@'
readonly JANUSD='@JANUSD@'
readonly STATE_DIR='/var/lib/pharos-guarded-deploy'
readonly PROFILE_MANIFEST='/etc/janus/pharos-deploy/managed-commands.toml'
readonly SECRET_MANIFEST='/etc/janus/pharos-deploy/secretspec.toml'
readonly METADATA='/etc/janus/pharos-deploy/metadata.toml'

action=${1:-}
ticket=${2:-}
case "$action" in
apply)
  profile='profile.@APPLY_SECRET_NAME@'
  secret_ref='@APPLY_SECRET_REF@'
  ;;
rollback)
  profile='profile.@ROLLBACK_SECRET_NAME@'
  secret_ref='@ROLLBACK_SECRET_REF@'
  ;;
update)
  profile='profile.@UPDATE_SECRET_NAME@'
  secret_ref='@UPDATE_SECRET_REF@'
  ;;
*)
  printf 'usage: sudo pharos-guarded-deploy apply|rollback|update TICKET\n' >&2
  exit 2
  ;;
esac
[[ "$ticket" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]] || {
  printf 'ticket must be a PPM issue key\n' >&2
  exit 2
}
[ "$(id -u)" -eq 0 ] || {
  printf 'pharos guarded deploy requires root\n' >&2
  exit 1
}

export JANUS_RUN_PROFILE_MANIFEST="$PROFILE_MANIFEST"
export JANUS_MANAGED_PROFILE_MANIFEST="$PROFILE_MANIFEST"
export JANUS_RUN_PERMIT_DIR="$STATE_DIR/permits"
export JANUS_APPROVAL_DIR="$STATE_DIR/approvals"
export JANUS_LIFECYCLE_EVIDENCE_DIR="$STATE_DIR/evidence"
export JANUS_RUN_EXECUTOR="janus-run@$HOST"
export JANUS_RUN_SCOPE="pharos/$HOST/production"
export JANUS_AGE_MANIFEST_FILE="$SECRET_MANIFEST"
export JANUS_AGE_METADATA_FILE="$METADATA"
export JANUS_AGE_PROFILE="$HOST"
export JANUS_AGE_STORE_DIR='/var/lib/janus/secrets'
export JANUS_AGE_IDENTITY_FILE='/etc/ssh/ssh_host_ed25519_key'
export JANUS_AGE_RECIPIENTS_FILE='/etc/ssh/ssh_host_ed25519_key.pub'

tmp=$(mktemp -d "$STATE_DIR/.review.XXXXXX")
chmod 0700 "$tmp"
cleanup() {
  find "$tmp" -type f -exec shred -u {} + 2>/dev/null || true
  rmdir "$tmp" 2>/dev/null || true
}
trap cleanup EXIT

request_file="$STATE_DIR/requests/$(date -u +%Y%m%dT%H%M%SZ)-$action.json"
jq -n \
  --arg host "$HOST" \
  --arg action "$action" \
  --arg ticket "$ticket" \
  --arg requested_at "$(date -u +%FT%TZ)" \
  '{schema:"inspr.pharos.guarded-deploy-request.v1",host:$host,action:$action,ticket:$ticket,requested_at:$requested_at,status:"requested",value_returned:false}' \
  >"$request_file"
chmod 0600 "$request_file"

"$JANUSD" run preflight --profile "$profile" -- >"$tmp/preflight.out" 2>"$tmp/preflight.err"
grep -q 'reason_code=ok value_returned=false' "$tmp/preflight.out"

"$JANUSD" approve issue \
  --secret-ref "$secret_ref" \
  --profile "$profile" \
  --purpose "Guarded Pharos $action for $HOST" \
  --reason "$ticket approved target-local $action" \
  --egress hook_guarded \
  --expires-in-seconds 300 \
  >"$tmp/approval.out" 2>"$tmp/approval.err"
approval_id=$(sed -n 's/.*approval_id=\([^ ]*\).*/\1/p' "$tmp/approval.out" | head -n1)
[[ "$approval_id" = appr_* ]]

"$JANUSD" approve permit \
  --approval "$approval_id" \
  --permit-ttl-seconds 240 \
  --revoke-approval \
  >"$tmp/permit.out" 2>"$tmp/permit.err"
permit_id=$(sed -n 's/.*permit_id=\([^ ]*\).*/\1/p' "$tmp/permit.out" | head -n1)
[[ "$permit_id" = use_* ]]

if ! "$JANUSD" run --profile "$profile" --permit "$permit_id" -- \
  >"$tmp/run.out" 2>"$tmp/run.err"; then
  printf 'host=%s action=%s status=failed ticket=%s review=recorded value_returned=false\n' \
    "$HOST" "$action" "$ticket" >&2
  exit 1
fi
grep -q 'value_returned=false' "$tmp/run.out"
grep -q 'reason_code=ok value_returned=false' "$tmp/run.err"
cat "$tmp/run.out"
printf 'host=%s action=%s status=completed ticket=%s review=recorded permit=consumed value_returned=false\n' \
  "$HOST" "$action" "$ticket"
