#!/usr/bin/env bash
# NIX-600 / AEON-438 mode B: runner-side admission, baked into the base image.
# ACTIONS_RUNNER_HOOK_JOB_STARTED runs this before the first step. A failing
# hook does NOT stop the job in actions/runner (always() steps and action pre:
# steps still run), so a deny kills the runner and powers the VM off before this
# script could ever return. The repository cannot change this file.
#
# On admission it leaves a marker and waits until the controller, after its own
# API attribution of this runner's job, has unlocked the encrypted cache.
set -uo pipefail

ALLOW="${AEON_ALLOWLIST:-/opt/aeon/allowlist.json}"
STATE="${AEON_STATE_DIR:-/var/lib/aeon}"
LOG="$STATE/hook.log"
WAIT="${AEON_CACHE_WAIT:-240}"

deny() {
  echo "aeon-hook deny run=${GITHUB_RUN_ID:-?} reason=$*" >>"$LOG"
  echo "::error::mbp2606 admission denied: $* (runner and VM are being killed)" >&2
  sync
  exec >/dev/null 2>&1 </dev/null
  if [ -n "${AEON_TEST_DENY:-}" ]; then
    exit 97
  fi
  sudo -n /usr/bin/pkill -9 -f 'Runner\.(Listener|Worker)'
  sudo -n /sbin/poweroff -ff
  sleep infinity
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

line="run=${GITHUB_RUN_ID:-} attempt=${GITHUB_RUN_ATTEMPT:-} job=${GITHUB_JOB:-} event=${GITHUB_EVENT_NAME} sha=${GITHUB_SHA}"
echo "aeon-hook allow $line" >>"$LOG"
echo "$line" >"$STATE/admitted"

for _ in $(seq 1 "$WAIT"); do
  [ -e "$STATE/cache-ready" ] && exit 0
  sleep 1
done
deny "controller did not confirm admission within ${WAIT}s"
