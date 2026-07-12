#!/usr/bin/env bash
set -Eeuo pipefail

readonly HOST='@HOST@'
readonly PHAROS_URL='@PHAROS_URL@'
readonly STATE_DIR='@STATE_DIR@'
readonly GUARDED_DEPLOY='@GUARDED_DEPLOY@'
readonly REQUEST_FILE="$STATE_DIR/active-agent-request.json"

[ "$(id -u)" -eq 0 ]
[[ "$PHAROS_URL" =~ ^http://[0-9.]+:[0-9]+$ ]]
[[ -n "${PHAROS_TOKEN:-}" ]]
[[ "$PHAROS_TOKEN" =~ ^[A-Za-z0-9._~+/=-]{16,512}$ ]]

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

jq -n --arg host "$HOST" '{host:$host}' >"$claim_request"
if ! claim_code=$(curl_json POST /agent/actions/claim "$claim_request" "$claim_response"); then
  printf 'pharos_action_agent=deferred reason=claim_unreachable\n' >&2
  exit 1
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
  exit 1
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
mkdir -p "$action_dir"
chmod 0700 "$action_dir"

request_tmp="${REQUEST_FILE}.tmp"
jq -S '{schema,version,id,host,ticket,phase}' "$claim_response" >"$request_tmp"
chmod 0600 "$request_tmp"
mv "$request_tmp" "$REQUEST_FILE"

runner_status=0
if "$GUARDED_DEPLOY" update "$ticket" >"$run_dir/runner.out" 2>"$run_dir/runner.err"; then
  runner_status=0
else
  runner_status=$?
fi

if ! jq -e --arg host "$HOST" --arg phase "$phase" '
  .schema == "inspr.pharos.host-action-agent-result.v1"
  and .version == 1
  and .host == $host
  and .phase == $phase
  and (.outcome == "succeeded" or .outcome == "rebooting" or .outcome == "failed")
  and ((.plan == null) or (.plan | type == "object"))
  and ((.result == null) or (.result | type == "object"))
  and (keys | sort == ["host", "outcome", "phase", "plan", "result", "schema", "version"])
' "$result_file" >/dev/null 2>&1; then
  jq -n --arg host "$HOST" --arg phase "$phase" '
    {
      schema:"inspr.pharos.host-action-agent-result.v1",
      version:1,
      host:$host,
      phase:$phase,
      outcome:"failed",
      plan:null,
      result:null
    }
  ' >"$result_file"
  chmod 0600 "$result_file"
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
  exit 1
fi

shred -u "$REQUEST_FILE" 2>/dev/null || true
printf 'pharos_action_agent=reported phase=%s outcome=%s runner_ok=%s\n' \
  "$phase" "$outcome" "$([ "$runner_status" -eq 0 ] && printf true || printf false)"
