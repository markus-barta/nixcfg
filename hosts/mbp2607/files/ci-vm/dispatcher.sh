#!/usr/bin/env bash
# One launchd poll. Only the `ci` Colima profile is ever addressed.
set +x
set -euo pipefail
umask 077
# Keep the CLI and the explicitly scoped profile/PID paths in the same home.
if [ "${COLIMA_HOME:-}" != "${XDG_CONFIG_HOME:-$HOME/.config}/colima" ] ||
  [ "${LIMA_HOME:-}" != "${COLIMA_HOME:-}/_lima" ]; then
  printf 'ci-vm: requires the module XDG Colima and Lima homes\n' >&2
  exit 1
fi
state=${CI_VM_STATE_DIR:-$HOME/.local/state/ci-vm}
secrets="$state/secrets"
profile="$COLIMA_HOME/ci"
helper=${CI_VM_HOST_HELPER:-$(dirname "$0")/host.py}
mkdir -p "$state"
if [ "${1:-}" != --locked ]; then
  exec python3 "$helper" lock "$state/dispatcher.lock" /bin/bash "$0" --locked "$@"
fi
shift
action=${1:-tick}
log() { printf '%s ci-vm: %s\n' "$(date '+%F %T')" "$*"; }
bounded() { python3 "$helper" run "$@"; }
guest() { bounded "$1" colima --profile ci ssh -- sudo /usr/local/libexec/ci-vm/control "${@:2}" </dev/null; }
scan_started=$SECONDS
failure_delay=60
qos_failed=false
active=false

stamp() { printf '%s\n' "$now" >"$state/$1"; }
clear_stamp() { : >"$state/$1"; }
read_stamp() {
  last=$now
  if [ -f "$state/$1" ]; then IFS= read -r last <"$state/$1" || last=$now; fi
  case "$last" in '' | *[!0-9]*) last=$now ;; esac
  if [ "${#last}" -gt 11 ]; then last=$now; fi
  last=$((10#$last))
  if [ "$last" -gt "$now" ]; then last=$now; fi
  printf '%s\n' "$last" >"$state/$1"
}

read_backoff() {
  failures=0 retry_after=0
  if [ -f "$state/backoff" ]; then
    read -r failures retry_after <"$state/backoff" || true
    if ! [[ "$failures" =~ ^[0-9]{1,2}$ && "$retry_after" =~ ^[0-9]{1,11}$ ]]; then
      failures=0 retry_after=0
    fi
  fi
  failures=$((10#$failures)) retry_after=$((10#$retry_after))
  if [ "$failures" -gt 7 ] || [ "$retry_after" -gt "$((now + 21600))" ]; then
    failures=0 retry_after=0
  fi
}
record_failure() {
  local delay
  read_backoff
  if [ "$failures" -lt 7 ]; then failures=$((failures + 1)); fi
  delay=$(($2 * (1 << (failures - 1))))
  if [ "$delay" -gt 3600 ]; then delay=3600; fi
  printf '%s %s\n' "$failures" "$((now + delay))" >"$state/backoff"
  log "FAILURE: $1; attempt $failures, backing off ${delay}s"
}
backoff_pending() {
  read_backoff
  if [ "$retry_after" -gt "$now" ]; then
    log "failure backoff: retry in $((retry_after - now))s (attempt $failures)"
    return 0
  fi
  return 1
}
picked_up() {
  stamp last-demand
  stamp queue-since
  stamp no-worker-since
  if [ "$active" = true ]; then
    clear_stamp worker-without-api-demand-since
  else
    read_stamp worker-without-api-demand-since
  fi
  printf '0 0\n' >"$state/backoff"
}
local_worker_active() {
  local rc
  if guest 15 worker-active; then
    if [ "$active" != true ]; then read_stamp worker-without-api-demand-since; fi
    return 0
  else
    rc=$?
  fi
  # An unreachable guest cannot reset an already established absolute cap.
  if [ "$rc" -eq 1 ]; then clear_stamp worker-without-api-demand-since; fi
  return "$rc"
}
worker_cap_reached() {
  [ "$active" != true ] && [ -s "$state/worker-without-api-demand-since" ] || return 1
  read_stamp worker-without-api-demand-since
  [ "$((now - last))" -ge 3600 ]
}
stop_now() {
  bounded 180 colima stop ci || return 1
  clear_stamp unknown-since
  clear_stamp no-worker-since
  clear_stamp queue-since
  clear_stamp worker-without-api-demand-since
  stamp last-demand
}
failed_vm() {
  local rc
  if [ "$running" = true ] && [ "$qos_failed" = false ]; then
    if [ "$active" = true ] || local_worker_active; then
      log "RETRY: $1; active work retained, retrying next tick"
      picked_up
      return 1
    fi
    record_failure "$1" "$failure_delay"
    if stop_if_idle 'reactivation failed; draining the already-running ci instance'; then :; else
      rc=$?
      if [ "$rc" -ne 3 ]; then log 'ci stop failed or timed out; next poll must retry'; fi
    fi
    return 1
  fi
  record_failure "$1" "$failure_delay"
  log 'stopping any partially started or unhealthy ci instance'
  if [ -f "$profile/.nixcfg-ci-vm" ] && [ ! -L "$profile" ]; then
    stop_now || log 'ci stop failed or timed out; next poll must retry'
  fi
  return 1
}
stop_if_idle() {
  local rc
  log "$1"
  if [ "${2:-false}" != true ] && ! worker_cap_reached; then
    if guest 150 drain; then :; else
      rc=$?
      if [ "$rc" -eq 3 ]; then
        log 'drain found a Runner.Worker; retaining ci'
        picked_up
        return 3
      fi
      log 'guest drain unavailable; enforcing the bounded uptime policy'
    fi
  fi
  stop_now
}

vm_status() {
  local output
  if output=$(bounded 20 colima status ci --json 2>&1); then
    if [ ! -f "$profile/.nixcfg-ci-vm" ] || [ -L "$profile" ]; then
      log 'refusing an unowned running ci profile'
      return 1
    fi
    # A successful Colima status denotes a running VM (including runtime none).
    running=true
  elif [[ "$output" == *'not running'* ]]; then
    running=false
  else
    log 'cannot determine ci status; leaving VM unchanged'
    return 1
  fi
}

prepare() {
  # Refuse an unrelated pre-existing profile; never adopt someone else's data.
  if [ -e "$profile/colima.yaml" ] && [ ! -f "$profile/.nixcfg-ci-vm" ]; then
    log 'ci profile already exists without the nixcfg ownership marker'
    return 1
  fi
  if [ -L "$profile" ] || [ -L "$secrets" ] || [ -L "$profile/colima.yaml" ]; then
    log 'refusing symlinked ci configuration or secrets directory'
    return 1
  fi
  mkdir -p "$profile" "$secrets" || return 1
  chmod 0700 "$state" "$secrets" || return 1
  # Colima rewrites YAML on start. An immutable Nix-store symlink cannot work.
  cp "$CI_VM_CONFIG" "$profile/colima.yaml.next" || return 1
  chmod 0600 "$profile/colima.yaml.next" || return 1
  mv -f "$profile/colima.yaml.next" "$profile/colima.yaml" || return 1
  touch "$profile/.nixcfg-ci-vm"
}

background_vm() {
  if ! bounded 30 "$CI_VM_QOS"; then
    qos_failed=true
    return 1
  fi
}

cleanup_tokens() {
  local id token
  for id in $1; do
    jq -e --arg id "$id" 'any(.[]; .id == $id)' "$CI_VM_REPOSITORIES" >/dev/null || return 1
    token="$secrets/$id.token"
    if [ -e "$token" ] || [ -L "$token" ]; then
      if [ ! -f "$token" ] || [ -L "$token" ]; then
        log "refusing unsafe token path for $id"
        return 1
      fi
      trash "$token" || return 1
      log "retired the one-shot token for $id after enrollment"
    fi
  done
}

check_enrollments() {
  local id repo name response page count total found
  scan_started=$SECONDS
  for id in $1; do
    repo=$(jq -er --arg id "$id" '.[] | select(.id == $id) | .repository' "$CI_VM_REPOSITORIES") || return 1
    name=$(jq -er --arg id "$id" '.[] | select(.id == $id) | .runnerName' "$CI_VM_REPOSITORIES") || return 1
    page=1 found=false
    while :; do
      # API uncertainty is handled by local worker/uptime limits in tick.
      response=$(api_get "https://api.github.com/repos/$repo/actions/runners?per_page=100&page=$page") || break
      jq -e '(.runners | type == "array") and (.total_count | type == "number" and . >= 0 and . <= 100000000 and . == floor) and all(.runners[]; (.name | type == "string"))' <<<"$response" >/dev/null || break
      if jq -e --arg name "$name" 'any(.runners[]; .name == $name)' <<<"$response" >/dev/null; then
        found=true
        break
      fi
      count=$(jq '.runners | length' <<<"$response") || return 1
      total=$(jq .total_count <<<"$response") || return 1
      if [ "$count" -lt 100 ] && [ "$(((page - 1) * 100 + count))" -lt "$total" ]; then break; fi
      if [ "$((page * 100))" -ge "$total" ]; then
        log "$id needs re-enrollment: local .runner exists but GitHub removed $name"
        failure_delay=3600
        return 1
      fi
      [ "$count" -eq 100 ] && [ "$page" -lt 100 ] || break
      page=$((page + 1))
    done
    if [ "$found" = false ]; then log "cannot confirm GitHub enrollment for $id; local uptime limits still apply"; fi
  done
}

activate_runners() {
  local ready=true maintenance=false enrolled
  if [ "$running" = false ] || { [ "$active" != true ] && ! local_worker_active; }; then
    maintenance=true
  fi
  if ! bounded 150 colima --profile ci ssh -- sudo /usr/local/libexec/ci-vm/host-ready </dev/null; then
    ready=false
  fi
  # ExecStartPre may have enrolled successfully even if ExecStart then failed.
  # Fetch once, after activation, and keep maintenance off busy runners.
  if [ "$maintenance" = true ]; then
    enrolled=$(guest 20 enrolled) || return 1
    cleanup_tokens "$enrolled" || return 1
    check_enrollments "$enrolled" || return 1
  fi
  [ "$ready" = true ]
}

ensure_vm() {
  if [ "$running" = false ]; then
    prepare || return 1
    log 'starting ci (6 CPUs, 16 GiB RAM, 150 GiB disk)'
    bounded 900 taskpolicy -b -c background colima start ci --activate=false --ssh-config=false </dev/null || return 1
    now=$(date +%s)
    stamp last-demand
    stamp queue-since
    clear_stamp unknown-since
    clear_stamp no-worker-since
    clear_stamp worker-without-api-demand-since
  fi
  background_vm || return 1
  if [ "${1:-}" = --provision-only ]; then
    bounded 30 colima --profile ci ssh -- sudo /usr/local/libexec/ci-vm/host-ready --provision-only </dev/null || return 1
    log 'provision verified; no runner activation requested'
  else
    activate_runners || return 1
  fi
}

# Source only inside the request subshell. curl receives the Authorization
# header on stdin, so the agent token never appears in process arguments.
api_get() (
  set +x
  set +a
  unset GH_TOKEN
  # shellcheck source=/dev/null
  source "${CI_VM_AGENT_TOKEN_FILE:-$HOME/.inspr/secrets/agents/GH_TOKEN.env}" || exit 1
  [ -n "${GH_TOKEN:-}" ] || exit 1
  set +a
  export -n GH_TOKEN
  remaining=$((45 - (SECONDS - scan_started)))
  [ "$remaining" -gt 0 ] || exit 1
  if [ "$remaining" -gt 20 ]; then remaining=20; fi
  printf 'header = "Authorization: Bearer %s"\n' "$GH_TOKEN" |
    (
      unset GH_TOKEN
      exec curl -q --config - --fail --silent --show-error --max-time "$remaining" --proto '=https' \
        --header 'Accept: application/vnd.github+json' \
        --header 'X-GitHub-Api-Version: 2022-11-28' "$1"
    )
)

# Scan all pages; malformed/failed/truncated responses mean UNKNOWN, not idle.
# GitHub limits filtered workflow-run searches to 1000 results: refuse a full
# tenth page rather than incorrectly certify an empty queue.
demand_for_repo() {
  local repo=$1 offered runner status page response count total ids run_id jobs_page jobs job_count job_total match queued=false
  # Every command is checked explicitly: this function is called in an `if`,
  # where Bash deliberately suspends errexit, even for nested commands.
  offered=$(jq -c '["self-hosted", "linux", "arm64"] + .labels | map(ascii_downcase) | unique' <<<"$repo") || return 2
  runner=$(jq -er .runnerName <<<"$repo") || return 2
  repo=$(jq -er .repository <<<"$repo") || return 2
  for status in in_progress queued; do
    page=1
    while :; do
      response=$(api_get "https://api.github.com/repos/$repo/actions/runs?status=$status&per_page=100&page=$page") || return 2
      jq -e '(.workflow_runs | type == "array") and (.total_count | type == "number" and . >= 0 and . <= 100000000 and . == floor) and all(.workflow_runs[]; (.id | type == "number" and . > 0 and . <= 9007199254740991 and . == floor))' <<<"$response" >/dev/null || return 2
      count=$(jq '.workflow_runs | length' <<<"$response") || return 2
      total=$(jq .total_count <<<"$response") || return 2
      ids=$(jq -r '.workflow_runs[].id' <<<"$response") || return 2
      for run_id in $ids; do
        jobs_page=1
        while :; do
          jobs=$(api_get "https://api.github.com/repos/$repo/actions/runs/$run_id/jobs?filter=latest&per_page=100&page=$jobs_page") || return 2
          jq -e '(.jobs | type == "array") and (.total_count | type == "number" and . >= 0 and . <= 100000000 and . == floor) and all(.jobs[]; (.status | type == "string") and (.labels | type == "array") and all(.labels[]; type == "string") and (.status != "in_progress" or (.runner_name | type == "string" and length > 0)))' <<<"$jobs" >/dev/null || return 2
          match=$(jq -r --argjson offered "$offered" --arg runner "$runner" '
            if any(.jobs[]; .status == "in_progress" and .runner_name == $runner) then "active"
            elif any(.jobs[]; .status == "queued" and (.labels | length > 0) and all(.labels[]; ascii_downcase as $label | $offered | index($label) != null)) then "queued"
            else "idle" end' <<<"$jobs") || return 2
          if [ "$match" = active ]; then return 0; fi
          if [ "$match" = queued ]; then queued=true; fi
          job_count=$(jq '.jobs | length' <<<"$jobs") || return 2
          job_total=$(jq .total_count <<<"$jobs") || return 2
          if [ "$job_count" -lt 100 ] && [ "$(((jobs_page - 1) * 100 + job_count))" -lt "$job_total" ]; then return 2; fi
          if [ "$((jobs_page * 100))" -ge "$job_total" ]; then break; fi
          [ "$job_count" -eq 100 ] && [ "$jobs_page" -lt 100 ] || return 2
          jobs_page=$((jobs_page + 1))
        done
      done
      if [ "$count" -lt 100 ] && [ "$(((page - 1) * 100 + count))" -lt "$total" ]; then return 2; fi
      if [ "$page" -eq 10 ] && [ "$count" -eq 100 ]; then return 2; fi
      if [ "$((page * 100))" -ge "$total" ]; then break; fi
      [ "$count" -eq 100 ] && [ "$page" -lt 10 ] || return 2
      page=$((page + 1))
    done
  done
  if [ "$queued" = true ]; then return 3; fi
  return 1
}

now=$(date +%s)
case "$action" in
start)
  vm_status
  if [ -n "${2:-}" ] && [ "$2" != --provision-only ]; then exit 2; fi
  if ! ensure_vm "${2:-}"; then
    failed_vm 'startup, provisioning, QoS or runner readiness failed'
  fi
  exit
  ;;
stop)
  if [ -n "${2:-}" ] && [ "$2" != --force ]; then exit 2; fi
  force=false
  if [ "${2:-}" = --force ]; then force=true; fi
  stop_if_idle 'operator requested ci shutdown (force or expired worker cap skips drain)' "$force"
  exit
  ;;
prepare)
  vm_status
  [ "$running" = false ] || {
    log 'stop ci before preparing its configuration'
    exit 1
  }
  prepare
  exit
  ;;
tick) ;;
*)
  log 'usage: ci-vm [tick|start [--provision-only]|stop [--force]|prepare]'
  exit 2
  ;;
esac

queued=false
unknown=false
repositories=$(jq -c '.[]' "$CI_VM_REPOSITORIES")
[ -n "$repositories" ] || {
  log 'no repositories configured'
  exit 1
}
while IFS= read -r repo; do
  if demand_for_repo "$repo"; then
    active=true
    break
  else
    rc=$?
    case "$rc" in
    1) ;;
    3) queued=true ;;
    *) unknown=true ;;
    esac
  fi
done <<<"$repositories"
now=$(date +%s)
vm_status
if [ "$active" = true ] || [ "$running" = false ]; then
  clear_stamp worker-without-api-demand-since
elif worker_cap_reached; then
  stop_if_idle 'absolute 60-minute local worker cap without API-confirmed active work reached; stopping ci' true
  record_failure 'local worker has no API-confirmed active work for 60 minutes' 300
  exit 0
fi
if [ "$active" = true ] || [ "$queued" = true ]; then
  clear_stamp unknown-since
  clear_stamp no-worker-since
  if [ "$running" = false ] && backoff_pending; then exit 0; fi
  if ! ensure_vm; then failed_vm 'startup, provisioning, QoS or runner readiness failed'; fi
  now=$(date +%s)
  if [ "$active" = true ] || local_worker_active; then
    picked_up
  else
    read_stamp queue-since
    if [ "$((now - last))" -ge 600 ]; then
      if stop_if_idle 'UNSERVABLE: queued demand has picked up no job for 10 minutes; stopping ci'; then
        record_failure 'queued demand is unservable; check enrollment, labels and runner update deadline' 300
      else
        rc=$?
        [ "$rc" -eq 3 ] || exit "$rc"
      fi
    fi
  fi
elif [ "$running" = true ]; then
  if ! background_vm; then failed_vm 'background policy could not be verified'; fi
  if [ "$unknown" = true ]; then
    read_stamp unknown-since
    if [ "$((now - last))" -ge 3600 ]; then
      stop_if_idle 'UNKNOWN: absolute 60-minute API outage cap reached, even if a worker is active; stopping ci' true
      record_failure 'absolute unknown-state uptime cap reached' 300
      exit 0
    fi
    # Local, bounded, API-free signal. Failed SSH is not evidence of work.
    if local_worker_active; then
      stamp no-worker-since
      log 'GitHub demand unknown; local Runner.Worker active (60-minute absolute cap applies)'
    else
      read_stamp no-worker-since
      log "GitHub demand unknown; no verified local worker for $((now - last))s"
      if [ "$((now - last))" -ge 1200 ]; then
        if stop_if_idle 'UNKNOWN: no local worker for 20 minutes; stopping ci'; then
          record_failure 'unknown demand without local work' 300
        else
          rc=$?
          [ "$rc" -eq 3 ] || exit "$rc"
        fi
      fi
    fi
  else
    clear_stamp unknown-since
    clear_stamp no-worker-since
    clear_stamp queue-since
    if local_worker_active; then picked_up; else
      read_stamp last-demand
      if [ "$((now - last))" -ge 1200 ]; then
        if stop_if_idle 'no matching demand or local worker for 20 minutes; stopping ci'; then :; else
          rc=$?
          [ "$rc" -eq 3 ] || exit "$rc"
        fi
      fi
    fi
  fi
else
  stamp last-demand
  clear_stamp queue-since
  clear_stamp unknown-since
  clear_stamp no-worker-since
  if [ "$unknown" = true ]; then log 'GitHub demand unknown; ci remains stopped'; fi
fi
