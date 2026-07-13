#!/usr/bin/env bash
set -Eeuo pipefail

readonly HOST='@HOST@'
readonly PHAROS_URL='@PHAROS_URL@'
readonly STATE_DIR='@STATE_DIR@'
readonly GUARDED_DEPLOY='@GUARDED_DEPLOY@'
readonly BOOT_ID_FILE='@BOOT_ID_FILE@'
readonly REBOOT_TIMEOUT_SECONDS='@REBOOT_TIMEOUT_SECONDS@'
readonly REQUEST_FILE="$STATE_DIR/active-agent-request.json"

[ "$(id -u)" -eq 0 ]
[[ "$PHAROS_URL" =~ ^http://[0-9.]+:[0-9]+$ ]]
[[ -n "${PHAROS_TOKEN:-}" ]]
[[ "$PHAROS_TOKEN" =~ ^[A-Za-z0-9._~+/=-]{16,512}$ ]]
[[ "$REBOOT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]
[ "$REBOOT_TIMEOUT_SECONDS" -ge 120 ]
[ -r "$BOOT_ID_FILE" ]

mkdir -p "$STATE_DIR" "$STATE_DIR/actions" "$STATE_DIR/agent-runs"
chmod 0700 "$STATE_DIR" "$STATE_DIR/actions" "$STATE_DIR/agent-runs"
exec 9>"$STATE_DIR/action-agent.lock"
flock -n 9 || exit 0

run_dir=$(mktemp -d "$STATE_DIR/agent-runs/.run.XXXXXX")
auth_config="$run_dir/curl.conf"
claim_request="$run_dir/claim.json"
claim_response="$run_dir/claim-response.json"
result_request="$run_dir/result-request.json"
result_response="$run_dir/result-response.json"

cleanup() {
  find "$run_dir" -type f -exec shred -u {} + 2>/dev/null || true
  rmdir "$run_dir" 2>/dev/null || true
}
trap cleanup EXIT

printf 'header = "Authorization: Bearer %s"\n' "$PHAROS_TOKEN" >"$auth_config"
chmod 0600 "$auth_config"
unset PHAROS_TOKEN

reboot_wait_gate() {
  local candidate
  local pending=''
  local current_boot
  local previous_boot
  local deadline
  local switched_at
  local switched_epoch
  local now

  while IFS= read -r -d '' candidate; do
    if ! jq -e --arg host "$HOST" '
      .schema == "inspr.pharos.system-update-local.v1"
      and .version == 1
      and .host == $host
      and .ticket == "PHAROS-126"
      and .status == "rebooting"
      and (.boot_id_before | type == "string" and length > 0 and length <= 128)
      and ((.reboot_deadline_epoch == null) or (.reboot_deadline_epoch | type == "number" and floor == . and . > 0))
    ' "$candidate" >/dev/null 2>&1; then
      continue
    fi
    if [ -n "$pending" ]; then
      printf 'pharos_action_agent=blocked reason=ambiguous_reboot_state\n' >&2
      exit 1
    fi
    pending=$candidate
  done < <(find "$STATE_DIR/actions" -mindepth 2 -maxdepth 2 -name internal.json -type f -print0)

  [ -n "$pending" ] || return 0
  current_boot=$(tr -d '\r\n' <"$BOOT_ID_FILE")
  previous_boot=$(jq -r '.boot_id_before' "$pending")
  [ -n "$current_boot" ]
  if [ "$current_boot" != "$previous_boot" ]; then
    return 0
  fi

  deadline=$(jq -r '.reboot_deadline_epoch // 0' "$pending")
  if [ "$deadline" -le 0 ]; then
    switched_at=$(jq -r '.switched_at // empty' "$pending")
    if [ -z "$switched_at" ] || ! switched_epoch=$(date -u -d "$switched_at" +%s 2>/dev/null); then
      printf 'pharos_action_agent=blocked reason=invalid_reboot_state\n' >&2
      exit 1
    fi
    deadline=$((switched_epoch + REBOOT_TIMEOUT_SECONDS))
  fi
  now=$(date -u +%s)
  if [ "$now" -lt "$deadline" ]; then
    printf 'pharos_action_agent=deferred reason=waiting_for_reboot\n'
    exit 0
  fi

  printf 'pharos_action_agent=timeout reason=reboot_not_observed\n' >&2
}

reboot_wait_gate

curl_json() {
  local method=$1
  local path=$2
  local body=$3
  local response=$4

  curl --silent --show-error \
    --connect-timeout 10 \
    --max-time 30 \
    --config "$auth_config" \
    --request "$method" \
    --header 'Content-Type: application/json' \
    --data-binary "@$body" \
    --output "$response" \
    --write-out '%{http_code}' \
    "$PHAROS_URL$path"
}

failure_gate_for_runner_stage() {
  case "$1" in
  input) printf '%s\n' input ;;
  preflight | source) printf '%s\n' preflight ;;
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
  *) printf '%s\n' managed_run_contract ;;
  esac
}

result_file_identity() {
  local path=$1

  if stat -c '%d:%i:%Y:%s' "$path" 2>/dev/null; then
    return 0
  fi
  stat -f '%d:%i:%m:%z' "$path"
}

jq -n --arg host "$HOST" '{host:$host}' >"$claim_request"
if ! claim_code=$(curl_json POST /agent/actions/claim "$claim_request" "$claim_response"); then
  printf 'pharos_action_agent=deferred reason=claim_unreachable\n' >&2
  exit 0
fi

case "$claim_code" in
204)
  printf 'pharos_action_agent=idle\n'
  exit 0
  ;;
409)
  printf 'pharos_action_agent=blocked reason=fleet_failure_gate\n'
  exit 0
  ;;
200) ;;
*)
  printf 'pharos_action_agent=deferred reason=claim_rejected status=%s\n' "$claim_code" >&2
  exit 0
  ;;
esac

if ! jq -e --arg host "$HOST" '
  .schema == "inspr.pharos.host-action-lease.v1"
  and .version == 1
  and .host == $host
  and .ticket == "PHAROS-126"
  and (.phase == "review" or .phase == "apply" or .phase == "resume")
  and (.id | type == "string" and test("^[a-z0-9][a-z0-9._-]{0,159}$"))
  and (keys | sort == ["host", "id", "phase", "schema", "ticket", "version"])
' "$claim_response" >/dev/null; then
  printf 'pharos_action_agent=failed reason=invalid_lease\n' >&2
  exit 1
fi

action_id=$(jq -r '.id' "$claim_response")
phase=$(jq -r '.phase' "$claim_response")
ticket=$(jq -r '.ticket' "$claim_response")
action_dir="$STATE_DIR/actions/$action_id"
result_file="$action_dir/result.json"
invocation_file="$action_dir/last-invocation"
mkdir -p "$action_dir"
chmod 0700 "$action_dir"

request_tmp="${REQUEST_FILE}.tmp"
jq -S '{schema,version,id,host,ticket,phase}' "$claim_response" >"$request_tmp"
chmod 0600 "$request_tmp"
mv "$request_tmp" "$REQUEST_FILE"

result_before='absent'
if [ -e "$result_file" ]; then
  result_before=$(result_file_identity "$result_file")
fi
invocation_before='absent'
if [ -e "$invocation_file" ]; then
  invocation_before=$(result_file_identity "$invocation_file")
fi

runner_status=0
if "$GUARDED_DEPLOY" update "$ticket" >"$run_dir/runner.out" 2>"$run_dir/runner.err"; then
  runner_status=0
else
  runner_status=$?
fi

result_updated=false
if [ -e "$result_file" ]; then
  result_after=$(result_file_identity "$result_file")
  if [ "$result_after" != "$result_before" ]; then
    result_updated=true
  fi
fi
invocation_updated=false
if [ -e "$invocation_file" ]; then
  invocation_after=$(result_file_identity "$invocation_file")
  if [ "$invocation_after" != "$invocation_before" ]; then
    invocation_updated=true
  fi
fi
idempotent_result_reused=false
if [ "$invocation_updated" = true ] && grep -Fxq \
  "pharos_system_update=idempotent phase=$phase value_returned=false" \
  "$run_dir/runner.out"; then
  idempotent_result_reused=true
fi
result_fresh=false
if [ "$result_updated" = true ] || [ "$idempotent_result_reused" = true ]; then
  result_fresh=true
fi

runner_failure_gate=''
safe_runner_diagnostic=$(grep -E \
  '^pharos_guarded_deploy=failed action=update stage=(input|preflight|approval|permit|managed_run|managed_run_contract|validation) failure_gate=(input|preflight|approval|permit|managed_run|managed_run_contract|review_binding|all_host_evaluation|target_build|backup_readiness|fresh_backup|switch|reboot_schedule|boot_change|system_identity|revision_identity|kernel|rollback|storage|failed_units|required_services|heartbeat) value_returned=false$' \
  "$run_dir/runner.err" | tail -n1 || true)
if [[ "$safe_runner_diagnostic" =~ failure_gate=([a-z0-9_]+) ]]; then
  runner_failure_gate=${BASH_REMATCH[1]}
else
  safe_runner_diagnostic=$(grep -E \
    '^pharos_guarded_deploy=failed action=update stage=(input|preflight|approval|permit|managed_run|validation)( runner_stage=[a-z0-9_]+)? value_returned=false$' \
    "$run_dir/runner.err" | tail -n1 || true)
  if [[ "$safe_runner_diagnostic" =~ runner_stage=([a-z0-9_]+) ]]; then
    runner_failure_gate=$(failure_gate_for_runner_stage "${BASH_REMATCH[1]}")
  elif [[ "$safe_runner_diagnostic" =~ stage=([a-z0-9_]+) ]]; then
    runner_failure_gate=$(failure_gate_for_runner_stage "${BASH_REMATCH[1]}")
  fi
fi
if [ "$runner_status" -ne 0 ]; then
  if [ -n "$safe_runner_diagnostic" ]; then
    printf '%s\n' "$safe_runner_diagnostic" >&2
  fi
fi

result_valid=false
if [ "$result_fresh" = true ] && jq -e --arg host "$HOST" --arg phase "$phase" '
  .schema == "inspr.pharos.host-action-agent-result.v1"
  and .version == 1
  and .host == $host
  and .phase == $phase
  and (.outcome == "succeeded" or .outcome == "rebooting" or .outcome == "failed")
  and ((.plan == null) or (.plan | type == "object"))
  and ((.result == null) or (
    (.result | type == "object")
    and (.result.backup_validated | type == "boolean")
    and (.result.switch_passed | type == "boolean")
    and (.result.reboot_observed | type == "boolean")
    and (.result.kernel_verified | type == "boolean")
    and (.result.rollback_available | type == "boolean")
    and ((.result.failure_gate == null) or (
      .result.failure_gate | type == "string" and test("^(input|preflight|approval|permit|managed_run|managed_run_contract|review_binding|all_host_evaluation|target_build|backup_readiness|fresh_backup|switch|reboot_schedule|boot_change|system_identity|revision_identity|kernel|rollback|storage|failed_units|required_services|heartbeat)$")
    ))
    and ((.result.recovery_mode == null) or (
      .result.recovery_mode | type == "string" and test("^(exact_reviewed_system|trusted_descendant)$")
    ))
    and (((.result | keys) - ["backup_validated", "failure_gate", "kernel_verified", "reboot_observed", "recovery_mode", "rollback_available", "switch_passed"]) | length == 0)
  ))
  and (keys | sort == ["host", "outcome", "phase", "plan", "result", "schema", "version"])
' "$result_file" >/dev/null 2>&1; then
  result_valid=true
fi

if [ "$result_valid" = true ] && [ "$runner_status" -ne 0 ] &&
  [ "$(jq -r '.outcome' "$result_file")" != failed ]; then
  result_valid=false
fi

if [ "$result_valid" != true ] ||
  { [ "$(jq -r '.outcome // empty' "$result_file" 2>/dev/null || true)" = failed ] &&
    ! jq -e '.result != null and .result.failure_gate != null' "$result_file" >/dev/null 2>&1; }; then
  synthetic_failure_gate=${runner_failure_gate:-managed_run_contract}
  result_tmp="${result_file}.tmp"
  jq -n --arg host "$HOST" --arg phase "$phase" --arg failure_gate "$synthetic_failure_gate" '
    {
      schema:"inspr.pharos.host-action-agent-result.v1",
      version:1,
      host:$host,
      phase:$phase,
      outcome:"failed",
      plan:null,
      result:{
        backup_validated:false,
        switch_passed:false,
        reboot_observed:false,
        kernel_verified:false,
        rollback_available:false,
        failure_gate:$failure_gate,
        recovery_mode:null
      }
    }
  ' >"$result_tmp"
  chmod 0600 "$result_tmp"
  mv "$result_tmp" "$result_file"
fi

jq -n --arg host "$HOST" --slurpfile local "$result_file" '
  {
    host:$host,
    phase:$local[0].phase,
    outcome:$local[0].outcome,
    plan:$local[0].plan,
    result:$local[0].result
  }
' >"$result_request"

outcome=$(jq -r '.outcome' "$result_file")
attempts=1
if [ "$phase" = resume ] && [ "$outcome" = succeeded ]; then
  attempts=24
fi

accepted=false
for _ in $(seq 1 "$attempts"); do
  if result_code=$(curl_json POST "/agent/actions/$action_id/result" "$result_request" "$result_response"); then
    if [ "$result_code" = 200 ]; then
      accepted=true
      break
    fi
    if [ "$result_code" != 409 ] || [ "$attempts" -eq 1 ]; then
      break
    fi
  fi
  sleep 5
done

if [ "$accepted" != true ]; then
  printf 'pharos_action_agent=deferred phase=%s outcome=%s reason=result_not_accepted\n' \
    "$phase" "$outcome" >&2
  exit 0
fi

shred -u "$REQUEST_FILE" 2>/dev/null || true
printf 'pharos_action_agent=reported phase=%s outcome=%s runner_ok=%s\n' \
  "$phase" "$outcome" "$([ "$runner_status" -eq 0 ] && printf true || printf false)"
