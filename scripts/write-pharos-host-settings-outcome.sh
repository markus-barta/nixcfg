#!/usr/bin/env bash
set -euo pipefail

host=${1-}
request_id=${2-}
outcome=${3-}
pull_request_number=${4-}
output_file=${5-}

fail() {
  printf 'pharos_host_settings_outcome=failed reason=%s\n' "$1" >&2
  exit 1
}

[[ "$host" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || fail invalid_host
[[ "$request_id" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$ ]] || fail invalid_request_id
[[ "$outcome" == merged || "$outcome" == already_declared ]] || fail invalid_outcome
[[ -n "$output_file" ]] || fail missing_output_file
[[ "${GITHUB_REPOSITORY:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail invalid_repository
[[ "${GITHUB_RUN_ID:-}" =~ ^[1-9][0-9]*$ ]] || fail invalid_run_id
[[ "${GITHUB_RUN_ATTEMPT:-}" =~ ^[1-9][0-9]*$ ]] || fail invalid_run_attempt

if [[ "$outcome" == merged ]]; then
  [[ "$pull_request_number" =~ ^[1-9][0-9]*$ ]] || fail invalid_pull_request_number
else
  [[ -z "$pull_request_number" ]] || fail unexpected_pull_request_number
fi

output_dir=$(dirname "$output_file")
[[ -d "$output_dir" ]] || fail missing_output_directory

jq -n \
  --arg schema 'inspr.pharos.host-settings-outcome.v1' \
  --arg request_id "$request_id" \
  --arg host "$host" \
  --arg outcome "$outcome" \
  --arg repository "$GITHUB_REPOSITORY" \
  --argjson workflow_run_id "$GITHUB_RUN_ID" \
  --argjson workflow_run_attempt "$GITHUB_RUN_ATTEMPT" \
  --arg pull_request_number "$pull_request_number" \
  '{
    schema: $schema,
    request_id: $request_id,
    host: $host,
    outcome: $outcome,
    repository: $repository,
    workflow_run_id: $workflow_run_id,
    workflow_run_attempt: $workflow_run_attempt,
    pull_request_number:
      (if $pull_request_number == "" then null else ($pull_request_number | tonumber) end)
  }' >"$output_file"

jq -e '
  .schema == "inspr.pharos.host-settings-outcome.v1"
  and (.request_id | type == "string" and length > 0)
  and (.host | type == "string" and length > 0)
  and (.outcome == "merged" or .outcome == "already_declared")
  and (.repository | type == "string" and contains("/"))
  and (.workflow_run_id | type == "number")
  and (.workflow_run_attempt | type == "number")
  and (.pull_request_number == null or (.pull_request_number | type == "number"))
' "$output_file" >/dev/null || fail invalid_generated_document

printf 'pharos_host_settings_outcome=written outcome=%s\n' "$outcome"
