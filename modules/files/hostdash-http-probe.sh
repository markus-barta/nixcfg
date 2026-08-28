#!/usr/bin/env bash
set -euo pipefail

url=${1:-}
if [[ ! "$url" =~ ^https?://127\.0\.0\.1(:[0-9]+)?(/.*)?$ ]]; then
  printf 'hostdash-http-probe: refusing non-loopback URL\n' >&2
  exit 2
fi

raw="$(
  curl --insecure --silent --output /dev/null --max-time 3 \
    --write-out '%{http_code} %{time_total}' "$url" 2>/dev/null
)" || raw='000 0'

read -r code seconds extra <<<"$raw"
if [[ -n "${extra:-}" || ! "${code:-}" =~ ^[0-9]{3}$ ]]; then
  code=000
  seconds=0
fi

if [[ "$code" == 000 ]]; then
  code=0
  milliseconds=0
else
  code=$((10#$code))
  milliseconds="$(
    jq -nr --arg seconds "${seconds:-0}" \
      'try (($seconds | tonumber) * 1000 | round) catch 0'
  )"
fi

jq -cn --argjson code "$code" --argjson ms "$milliseconds" \
  '{code: $code, ms: $ms}'
