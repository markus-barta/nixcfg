#!/usr/bin/env bash
# Collect the exact Docker status subset HostDash is allowed to publish.
#
# This function intentionally has no fallback. With pipefail enabled by the
# writeShellApplication caller, either Docker or jq failing aborts the producer
# transaction so its last valid atomic artifact remains in place.
hostdash_collect_containers() {
  if [[ "$#" -ne 2 ]]; then
    printf 'usage: hostdash_collect_containers ALLOWED_JSON FILTER\n' >&2
    return 2
  fi

  local allowed=$1
  local filter=$2
  docker ps --all --format '{{json .}}' 2>/dev/null |
    jq -s --argjson allowed "$allowed" -f "$filter" 2>/dev/null
}
