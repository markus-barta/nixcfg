#!/usr/bin/env bash
# NIX-600 / AEON-438 mode B: runner-side admission, baked into the base image.
# ACTIONS_RUNNER_HOOK_JOB_STARTED runs this before the first step; a non-zero
# exit fails the job before any repository code runs. The repository cannot
# change this file, so it holds even when a PR edits the workflow's runs-on.
set -uo pipefail

ALLOW="${AEON_ALLOWLIST:-/opt/aeon/allowlist.json}"
LOG="${AEON_HOOK_LOG:-/var/lib/aeon/hook.log}"

deny() {
  echo "aeon-hook deny run=${GITHUB_RUN_ID:-?} reason=$*" >>"$LOG"
  echo "::error::mbp2606 admission denied: $*" >&2
  exit 1
}

[ -r "$ALLOW" ] || deny "allowlist missing"
repo=$(jq -r '.repo' "$ALLOW") || deny "allowlist unreadable"
ref=$(jq -r '.ref' "$ALLOW")

[ "${GITHUB_REPOSITORY:-}" = "$repo" ] || deny "repository ${GITHUB_REPOSITORY:-unset}"
jq -e --arg e "${GITHUB_EVENT_NAME:-}" '.events | index($e) != null' "$ALLOW" >/dev/null ||
  deny "event ${GITHUB_EVENT_NAME:-unset}"
[ "${GITHUB_REF:-}" = "$ref" ] || deny "ref ${GITHUB_REF:-unset}"
jq -e --arg w "${GITHUB_WORKFLOW_REF:-}" '.workflowRefs | index($w) != null' "$ALLOW" >/dev/null ||
  deny "workflow ${GITHUB_WORKFLOW_REF:-unset}"

event="${GITHUB_EVENT_PATH:-}"
[ -r "$event" ] || deny "event payload missing"
[ "$(jq -r '.repository.full_name // empty' "$event")" = "$repo" ] || deny "payload repository"
[ -z "$(jq -r '.pull_request // empty | tostring' "$event")" ] || deny "pull request payload"
[[ "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || deny "sha ${GITHUB_SHA:-unset}"

echo "aeon-hook allow run=${GITHUB_RUN_ID:-} attempt=${GITHUB_RUN_ATTEMPT:-} job=${GITHUB_JOB:-} event=${GITHUB_EVENT_NAME} sha=${GITHUB_SHA}" >>"$LOG"
