#!/usr/bin/env bash
set -euo pipefail

CONTAINER=${JANUS_ENGINE_CONTAINER:-janus-engine-staged}
SECRET_REF=${JANUS_SMOKE_SECRET_REF:-sec_5b4032741aeaeb486a64}
RAW_SECRET_NAME=${JANUS_SMOKE_RAW_SECRET_NAME:-JANUS_SMOKE}
PROFILE_ID=${JANUS_SMOKE_PROFILE_ID:-profile.JANUS_SMOKE}
FORBIDDEN_VALUE_PREFIX=${JANUS_SMOKE_FORBIDDEN_VALUE_PREFIX:-janus-nonprod-smoke-}
HEALTH_WAIT_SECONDS=${JANUS_MCP_HEALTH_WAIT_SECONDS:-30}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

require_command docker
require_command grep
require_command jq
require_command mktemp
require_command paste
require_command sort

status=$(docker inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)
if [ "$status" != "running" ]; then
  printf 'janus negative MCP smoke failed: %s is not running (status=%s)\n' "$CONTAINER" "${status:-missing}" >&2
  exit 1
fi

elapsed=0
while :; do
  health=$(
    docker inspect \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
      "$CONTAINER"
  )
  if [ "$health" = "healthy" ]; then
    break
  fi
  if [ "$elapsed" -ge "$HEALTH_WAIT_SECONDS" ]; then
    printf 'janus negative MCP smoke failed: %s is not healthy after %ss (health=%s)\n' \
      "$CONTAINER" "$HEALTH_WAIT_SECONDS" "$health" >&2
    exit 1
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

network_mode=$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$CONTAINER")
ports=$(docker inspect --format '{{json .NetworkSettings.Ports}}' "$CONTAINER")
traefik=$(docker inspect --format '{{index .Config.Labels "traefik.enable"}}' "$CONTAINER")

if [ "$network_mode" != "none" ] || [ "$ports" != "{}" ] || [ "$traefik" != "false" ]; then
  printf 'janus negative MCP smoke failed: expected internal-only container, got network_mode=%s ports=%s traefik=%s\n' \
    "$network_mode" "$ports" "$traefik" >&2
  exit 1
fi

tmp_dir=$(mktemp -d)
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

cat >"${tmp_dir}/catalog.jsonl" <<EOF
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"janus-engine-negative-smoke","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
EOF

run_case() {
  case_id=$1
  case_name=$2
  tool_name=$3
  arguments=$4
  request_file="${tmp_dir}/${case_name}.jsonl"
  output_file="${tmp_dir}/${case_name}.out"
  error_file="${tmp_dir}/${case_name}.err"

  cat >"$request_file" <<EOF
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"janus-engine-negative-smoke-${case_name}","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
{"jsonrpc":"2.0","id":${case_id},"method":"tools/call","params":{"name":"${tool_name}","arguments":${arguments}}}
EOF
  docker exec -i "$CONTAINER" janus-warden <"$request_file" >"$output_file" 2>"$error_file"
}

docker exec -i "$CONTAINER" janus-warden \
  <"${tmp_dir}/catalog.jsonl" \
  >"${tmp_dir}/catalog.out" \
  2>"${tmp_dir}/catalog.err"
run_case 3 resolve resolve_secret "{\"secret_ref\":\"${SECRET_REF}\"}"
run_case 4 reveal reveal "{\"secret_ref\":\"${SECRET_REF}\"}"
run_case 5 raw_describe describe_secret "{\"secret_ref\":\"${RAW_SECRET_NAME}\"}"
run_case 6 raw_request request_use "{\"secret_ref\":\"${RAW_SECRET_NAME}\",\"profile_id\":\"${PROFILE_ID}\",\"purpose\":\"negative raw secret name smoke\"}"
run_case 7 caller_override request_use "{\"secret_ref\":\"${SECRET_REF}\",\"profile_id\":\"${PROFILE_ID}\",\"purpose\":\"negative caller override smoke\",\"destination\":\"attacker.example\",\"executor\":\"unapproved\",\"ttl_seconds\":9999}"

cat "${tmp_dir}/catalog.out" "${tmp_dir}"/resolve.out "${tmp_dir}"/reveal.out \
  "${tmp_dir}"/raw_describe.out "${tmp_dir}"/raw_request.out \
  "${tmp_dir}"/caller_override.out >"${tmp_dir}/mcp.out"
cat "${tmp_dir}/catalog.err" "${tmp_dir}"/resolve.err "${tmp_dir}"/reveal.err \
  "${tmp_dir}"/raw_describe.err "${tmp_dir}"/raw_request.err \
  "${tmp_dir}"/caller_override.err >"${tmp_dir}/mcp.err"

if grep -q "$FORBIDDEN_VALUE_PREFIX" "${tmp_dir}/mcp.out" "${tmp_dir}/mcp.err"; then
  printf 'janus negative MCP smoke failed: transcript exposed fixture value prefix\n' >&2
  exit 1
fi

if jq -e 'select(.id >= 3 and .id <= 7) | tostring | test("use_[A-Za-z0-9_]+|permit_id")' \
  <"${tmp_dir}/mcp.out" >/dev/null; then
  printf 'janus negative MCP smoke failed: a negative response contained a permit id\n' >&2
  exit 1
fi

jq -e 'select(.id == 1) | .result.serverInfo.name == "janus-warden"' \
  <"${tmp_dir}/mcp.out" >/dev/null

tools=$(
  jq -r 'select(.id == 2) | .result.tools[].name' <"${tmp_dir}/mcp.out" |
    sort |
    paste -sd, -
)
if [ "$tools" != "describe_secret,health,list_secrets,request_use" ]; then
  printf 'janus negative MCP smoke failed: unexpected tool catalog: %s\n' "$tools" >&2
  exit 1
fi

if jq -e 'select(.id == 2) | .result.tools[].name | select(. == "resolve_secret" or . == "reveal")' \
  <"${tmp_dir}/mcp.out" >/dev/null; then
  printf 'janus negative MCP smoke failed: raw resolve/reveal tools were advertised\n' >&2
  exit 1
fi

assert_denial() {
  id=$1
  reason_code=$2

  jq -e --argjson id "$id" --arg reason_code "$reason_code" '
    select(.id == $id)
    | .result.isError == true
      and .result.structuredContent.ok == false
      and .result.structuredContent.value_returned == false
      and .result.structuredContent.error.reason_code == $reason_code
  ' <"${tmp_dir}/mcp.out" >/dev/null || {
    printf 'janus negative MCP smoke failed: id=%s did not return %s\n' "$id" "$reason_code" >&2
    sed -n '1,120p' "${tmp_dir}/mcp.out" >&2
    sed -n '1,120p' "${tmp_dir}/mcp.err" >&2
    exit 1
  }
}

assert_denial 3 denied_unknown_tool
assert_denial 4 denied_unknown_tool
assert_denial 5 denied_not_in_manifest
assert_denial 6 denied_not_in_manifest
assert_denial 7 denied_invalid_args

printf 'ok: janus staged MCP negative smoke passed container=%s health=%s network_mode=%s ports=%s traefik=%s tools=%s denials=resolve_secret:denied_unknown_tool,reveal:denied_unknown_tool,raw_describe:denied_not_in_manifest,raw_request_use:denied_not_in_manifest,caller_override:denied_invalid_args value_returned=false permit_issued=false\n' \
  "$CONTAINER" "$health" "$network_mode" "$ports" "$traefik" "$tools"
