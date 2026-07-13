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
stage='input'
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
failure_gate_for_stage() {
  case "$1" in
  input) printf '%s\n' input ;;
  preflight) printf '%s\n' preflight ;;
  approval) printf '%s\n' approval ;;
  permit) printf '%s\n' permit ;;
  managed_run) printf '%s\n' managed_run ;;
  managed_run_contract | validation) printf '%s\n' managed_run_contract ;;
  review_binding) printf '%s\n' review_binding ;;
  all_host_eval | all_host_evaluation) printf '%s\n' all_host_evaluation ;;
  target_build) printf '%s\n' target_build ;;
  backup_readiness) printf '%s\n' backup_readiness ;;
  fresh_backup) printf '%s\n' fresh_backup ;;
  switch) printf '%s\n' switch ;;
  schedule_reboot | reboot_schedule) printf '%s\n' reboot_schedule ;;
  post_reboot_validation | reboot_timeout | boot_change) printf '%s\n' boot_change ;;
  system_identity) printf '%s\n' system_identity ;;
  revision_identity) printf '%s\n' revision_identity ;;
  kernel) printf '%s\n' kernel ;;
  rollback) printf '%s\n' rollback ;;
  storage) printf '%s\n' storage ;;
  failed_units) printf '%s\n' failed_units ;;
  required_services) printf '%s\n' required_services ;;
  heartbeat) printf '%s\n' heartbeat ;;
  *) printf '%s\n' managed_run ;;
  esac
}

on_error() {
  local status=$?
  local failure_gate
  trap - ERR
  failure_gate=$(failure_gate_for_stage "$stage")
  printf 'pharos_guarded_deploy=failed action=%s stage=%s failure_gate=%s value_returned=false\n' \
    "$action" "$stage" "$failure_gate" >&2
  exit "$status"
}
trap on_error ERR

request_file="$STATE_DIR/requests/$(date -u +%Y%m%dT%H%M%SZ)-$action.json"
jq -n \
  --arg host "$HOST" \
  --arg action "$action" \
  --arg ticket "$ticket" \
  --arg requested_at "$(date -u +%FT%TZ)" \
  '{schema:"inspr.pharos.guarded-deploy-request.v1",host:$host,action:$action,ticket:$ticket,requested_at:$requested_at,status:"requested",value_returned:false}' \
  >"$request_file"
chmod 0600 "$request_file"

stage='preflight'
"$JANUSD" run preflight --profile "$profile" -- >"$tmp/preflight.out" 2>"$tmp/preflight.err"
grep -q 'reason_code=ok value_returned=false' "$tmp/preflight.out"

stage='approval'
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

stage='permit'
"$JANUSD" approve permit \
  --approval "$approval_id" \
  --permit-ttl-seconds 240 \
  --revoke-approval \
  >"$tmp/permit.out" 2>"$tmp/permit.err"
permit_id=$(sed -n 's/.*permit_id=\([^ ]*\).*/\1/p' "$tmp/permit.out" | head -n1)
[[ "$permit_id" = use_* ]]

stage='managed_run'
run_status=0
if "$JANUSD" run --profile "$profile" --permit "$permit_id" -- \
  >"$tmp/run.out" 2>"$tmp/run.err"; then
  run_status=0
else
  run_status=$?
fi

if [ "$run_status" -ne 0 ] ||
  ! grep -Eq \
    '^janusd run completed exit_success=true exit_code=Some\(0\) reason_code=ok value_returned=false$' \
    "$tmp/run.err"; then
  runner_failure_gate='managed_run'
  runner_line=$(grep -E \
    '^pharos_system_update=failed( phase=(review|apply|resume))? failure_gate=(input|preflight|approval|permit|managed_run|managed_run_contract|review_binding|all_host_evaluation|target_build|backup_readiness|fresh_backup|switch|reboot_schedule|boot_change|system_identity|revision_identity|kernel|rollback|storage|failed_units|required_services|heartbeat) rollback=(not_required|succeeded|failed) value_returned=false$' \
    "$tmp/run.err" | tail -n1 || true)
  if [[ "$runner_line" =~ failure_gate=([a-z0-9_]+) ]]; then
    runner_failure_gate=${BASH_REMATCH[1]}
  else
    legacy_runner_line=$(grep -E \
      '^pharos_system_update=failed phase=(review|apply|resume) stage=[a-z0-9_]+ rollback=(not_required|succeeded|failed) value_returned=false$' \
      "$tmp/run.err" | tail -n1 || true)
    if [[ "$legacy_runner_line" =~ stage=([a-z0-9_]+) ]]; then
      runner_failure_gate=$(failure_gate_for_stage "${BASH_REMATCH[1]}")
    fi
  fi
  printf 'pharos_guarded_deploy=failed action=%s stage=managed_run failure_gate=%s value_returned=false\n' \
    "$action" "$runner_failure_gate" >&2
  exit 1
fi
stage='managed_run_contract'
grep -q 'value_returned=false' "$tmp/run.out"
cat "$tmp/run.out"
stage='completed'
printf 'host=%s action=%s status=completed ticket=%s review=recorded permit=consumed value_returned=false\n' \
  "$HOST" "$action" "$ticket"
