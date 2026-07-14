#!/usr/bin/env bash
set -Eeuo pipefail

readonly OWNER='@OWNER@'
readonly PHAROS_URL='@PHAROS_URL@'
readonly STATE_DIR='@STATE_DIR@'
readonly REPO_PATH='@REPO_PATH@'
readonly RETIRE_HELPER='@RETIRE_HELPER@'
readonly PENDING_RESULT="$STATE_DIR/pending-result.json"

[ "$(id -u)" -eq 0 ]
[[ "$OWNER" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]
[[ "$PHAROS_URL" =~ ^http://[0-9.]+:[0-9]+$ ]]
[[ "$REPO_PATH" =~ ^/[A-Za-z0-9._/-]+$ ]]
[[ "$RETIRE_HELPER" == "$REPO_PATH"/* ]]
[[ -n "${PHAROS_TOKEN:-}" ]]
[[ "$PHAROS_TOKEN" =~ ^[A-Za-z0-9._~+/=-]{16,512}$ ]]

mkdir -p "$STATE_DIR" "$STATE_DIR/runs"
chmod 0700 "$STATE_DIR" "$STATE_DIR/runs"
exec 9>"$STATE_DIR/executor.lock"
flock -n 9 || exit 0

run_dir=$(mktemp -d "$STATE_DIR/runs/.run.XXXXXX")
auth_config="$run_dir/curl.conf"
claim_request="$run_dir/claim.json"
claim_response="$run_dir/claim-response.json"
result_request="$run_dir/result.json"
result_response="$run_dir/result-response.json"

cleanup() {
  find "$run_dir" -type f -exec shred -u {} + 2>/dev/null || true
  rmdir "$run_dir" 2>/dev/null || true
}
trap cleanup EXIT

printf 'header = "Authorization: Bearer %s"\n' "$PHAROS_TOKEN" >"$auth_config"
chmod 0600 "$auth_config"
unset PHAROS_TOKEN

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

valid_pending_result() {
  jq -e --arg owner "$OWNER" '
    .schema == "inspr.pharos.retirement-executor-result.v1"
    and .version == 1
    and .owner == $owner
    and .ticket == "PHAROS-127"
    and (.id | type == "string" and test("^[a-z0-9][a-z0-9._-]{0,159}$"))
    and (.host | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$"))
    and .host != $owner
    and (
      (.outcome == "succeeded" and .reason == null)
      or
      (.outcome == "failed" and (
        .reason == "checkout_not_ready"
        or .reason == "retirement_contract_invalid"
        or .reason == "janus_unavailable"
        or .reason == "janus_rejected"
        or .reason == "result_contract_invalid"
      ))
    )
    and (keys | sort == ["host", "id", "outcome", "owner", "reason", "schema", "ticket", "version"])
  ' "$PENDING_RESULT" >/dev/null 2>&1
}

report_pending_result() {
  local action_id
  local outcome
  local result_code

  [ -f "$PENDING_RESULT" ] && [ ! -L "$PENDING_RESULT" ] || {
    printf 'pharos_retirement_executor=blocked reason=invalid_pending_result\n' >&2
    return 1
  }
  valid_pending_result || {
    printf 'pharos_retirement_executor=blocked reason=invalid_pending_result\n' >&2
    return 1
  }

  action_id=$(jq -r '.id' "$PENDING_RESULT")
  outcome=$(jq -r '.outcome' "$PENDING_RESULT")
  jq '{owner,host,outcome} + if .reason == null then {} else {reason} end' \
    "$PENDING_RESULT" >"$result_request"

  if ! result_code=$(curl_json POST "/agent/retirements/$action_id/result" \
    "$result_request" "$result_response"); then
    printf 'pharos_retirement_executor=deferred reason=result_unreachable\n' >&2
    return 0
  fi
  if [ "$result_code" != 204 ]; then
    printf 'pharos_retirement_executor=deferred reason=result_rejected status=%s\n' \
      "$result_code" >&2
    return 0
  fi

  shred -u "$PENDING_RESULT"
  printf 'pharos_retirement_executor=reported outcome=%s\n' "$outcome"
}

if [ -e "$PENDING_RESULT" ]; then
  report_pending_result
  exit $?
fi

jq -n --arg owner "$OWNER" '{owner:$owner}' >"$claim_request"
if ! claim_code=$(curl_json POST /agent/retirements/claim "$claim_request" "$claim_response"); then
  printf 'pharos_retirement_executor=deferred reason=claim_unreachable\n' >&2
  exit 0
fi

case "$claim_code" in
204)
  printf 'pharos_retirement_executor=idle\n'
  exit 0
  ;;
200) ;;
*)
  printf 'pharos_retirement_executor=deferred reason=claim_rejected status=%s\n' \
    "$claim_code" >&2
  exit 0
  ;;
esac

if ! jq -e --arg owner "$OWNER" '
  .schema == "inspr.pharos.retirement-agent-lease.v1"
  and .version == 1
  and .ticket == "PHAROS-127"
  and (.id | type == "string" and test("^[a-z0-9][a-z0-9._-]{0,159}$"))
  and (.host | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$"))
  and .host != $owner
  and (keys | sort == ["host", "id", "schema", "ticket", "version"])
' "$claim_response" >/dev/null; then
  printf 'pharos_retirement_executor=blocked reason=invalid_lease\n' >&2
  exit 1
fi

action_id=$(jq -r '.id' "$claim_response")
target_host=$(jq -r '.host' "$claim_response")
outcome=failed
reason=janus_unavailable

export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.directory
export GIT_CONFIG_VALUE_0="$REPO_PATH"

if ! git -C "$REPO_PATH" fetch --quiet --prune origin \
  >"$run_dir/fetch.out" 2>"$run_dir/fetch.err"; then
  reason=checkout_not_ready
elif [ ! -x "$RETIRE_HELPER" ]; then
  reason=checkout_not_ready
elif "$RETIRE_HELPER" apply "$target_host" \
  >"$run_dir/retire.out" 2>"$run_dir/retire.err"; then
  outcome=succeeded
  reason=''
else
  safe_failure=$(grep -E \
    '^janus_pharos_retirement=failed reason=[a-z0-9_]+ value_returned=false provider_deleted=false$' \
    "$run_dir/retire.err" | tail -n1 || true)
  failure_code=''
  if [[ "$safe_failure" =~ reason=([a-z0-9_]+) ]]; then
    failure_code=${BASH_REMATCH[1]}
  fi
  case "$failure_code" in
  checkout_not_main | checkout_not_clean | checkout_not_reviewed)
    reason=checkout_not_ready
    ;;
  engine_rejected_retirement)
    reason=janus_rejected
    ;;
  invalid_engine_result)
    reason=result_contract_invalid
    ;;
  invalid_mode | invalid_host | invalid_volume_prefix | invalid_retention | \
    missing_contract | missing_intent | invalid_intent | host_not_uniquely_retired | \
    unreviewed_contract_path | unreviewed_intent_path | fixture_uses_production_contract | \
    fixture_intent_mismatch | fixture_uses_production_volumes | fixture_uses_production_scope)
    reason=retirement_contract_invalid
    ;;
  missing_dependency | missing_engine_image | retirement_in_progress | runtime_identity_missing | '')
    reason=janus_unavailable
    ;;
  *)
    reason=result_contract_invalid
    ;;
  esac
fi

pending_tmp=$(mktemp "$STATE_DIR/.pending-result.XXXXXX")
jq -n \
  --arg id "$action_id" \
  --arg owner "$OWNER" \
  --arg host "$target_host" \
  --arg outcome "$outcome" \
  --arg reason "$reason" '
  {
    schema:"inspr.pharos.retirement-executor-result.v1",
    version:1,
    id:$id,
    owner:$owner,
    host:$host,
    ticket:"PHAROS-127",
    outcome:$outcome,
    reason:(if $reason == "" then null else $reason end)
  }
' >"$pending_tmp"
chmod 0600 "$pending_tmp"
mv "$pending_tmp" "$PENDING_RESULT"

report_pending_result
