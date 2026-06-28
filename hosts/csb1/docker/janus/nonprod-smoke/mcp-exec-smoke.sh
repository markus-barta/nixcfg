#!/usr/bin/env bash
set -euo pipefail

CONTAINER=${JANUS_ENGINE_CONTAINER:-janus-engine-staged}
SECRET_REF=${JANUS_SMOKE_SECRET_REF:-sec_9143cb19a04cc2dc154e}
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
  printf 'janus MCP smoke failed: %s is not running (status=%s)\n' "$CONTAINER" "${status:-missing}" >&2
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
    printf 'janus MCP smoke failed: %s is not healthy after %ss (health=%s)\n' \
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
  printf 'janus MCP smoke failed: expected internal-only container, got network_mode=%s ports=%s traefik=%s\n' \
    "$network_mode" "$ports" "$traefik" >&2
  exit 1
fi

tmp_dir=$(mktemp -d)
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

cat >"${tmp_dir}/mcp.jsonl" <<EOF
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"janus-engine-exec-smoke","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"health","arguments":{}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_secrets","arguments":{}}}
EOF

docker exec -i "$CONTAINER" janus-warden \
  <"${tmp_dir}/mcp.jsonl" \
  >"${tmp_dir}/mcp.out" \
  2>"${tmp_dir}/mcp.err"

if grep -q "$FORBIDDEN_VALUE_PREFIX" "${tmp_dir}/mcp.out" "${tmp_dir}/mcp.err"; then
  printf 'janus MCP smoke failed: transcript exposed fixture value prefix\n' >&2
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
  printf 'janus MCP smoke failed: unexpected tool catalog: %s\n' "$tools" >&2
  exit 1
fi

jq -e '
  select(.id == 3)
  | .result.isError == false
  and .result.structuredContent.ok == true
  and .result.structuredContent.value_returned == false
  and .result.structuredContent.result.ok == true
  and .result.structuredContent.result.backend == "age"
  and .result.structuredContent.result.value_returned == false
' <"${tmp_dir}/mcp.out" >/dev/null

jq -e --arg secret_ref "$SECRET_REF" '
  select(.id == 4)
  | .result.isError == false
  and .result.structuredContent.ok == true
  and .result.structuredContent.value_returned == false
  and .result.structuredContent.result.value_returned == false
  and (
    .result.structuredContent.result.secrets[]
    | select(.secret_ref == $secret_ref)
    | .present == true
      and .metadata_state == "complete"
      and .normal_use_allowed == true
      and .value_returned == false
  )
' <"${tmp_dir}/mcp.out" >/dev/null

printf 'ok: janus staged MCP exec smoke passed container=%s health=%s network_mode=%s ports=%s traefik=%s tools=%s secret_ref=%s value_returned=false\n' \
  "$CONTAINER" "$health" "$network_mode" "$ports" "$traefik" "$tools" "$SECRET_REF"
