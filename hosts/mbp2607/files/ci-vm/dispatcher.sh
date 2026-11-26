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
heavy_helper=${CI_VM_HEAVY_LOCK_HELPER:-$(dirname "$0")/heavy-lock.py}
heavy_lock=${CI_VM_HEAVY_LOCK:-/Users/Shared/ci-locks/mbp2607-heavy.lock.d}
mkdir -p "$state"
if [ "${1:-}" != --locked ]; then
  exec python3 "$helper" lock "$state/dispatcher.lock" /bin/bash "$0" --locked "$@"
fi
shift
action=${1:-tick}
log() { printf '%s ci-vm: %s\n' "$(date '+%F %T')" "$*"; }
bounded() { python3 "$helper" run "$@"; }
guest() { bounded "$1" "$2" </dev/null; }
# Colima collapses every nonzero guest exit to 1. Only a successful transport
# with exactly one recognized stdout record is evidence of guest state.
guest_status() {
  local output ids
  # Bash cannot retain NUL bytes; translate them to a rejected control byte.
  if output=$(guest "$1" "$2" | LC_ALL=C tr '\000' '\001' && printf '.'); then
    case "$2:$output" in
    worker-active:$'CI_VM_STATUS=worker-busy\n.' | drain:$'CI_VM_STATUS=worker-busy\n.')
      printf 'worker-busy\n'
      return
      ;;
    worker-active:$'CI_VM_STATUS=no-worker\n.')
      printf 'no-worker\n'
      return
      ;;
    drain:$'CI_VM_STATUS=drained\n.')
      printf 'drained\n'
      return
      ;;
    enrolled:CI_VM_STATUS=enrolled:*$'\n.')
      ids=${output#CI_VM_STATUS=enrolled:}
      ids=${ids%$'\n.'}
      if [[ "$ids" =~ ^([a-z][a-z0-9-]{0,23}(,[a-z][a-z0-9-]{0,23})*)?$ ]] &&
        jq -e --arg ids "$ids" '. as $repos | ($ids | if . == "" then [] else split(",") end) as $enrolled |
          ($enrolled | length) == ($enrolled | unique | length) and
          all($enrolled[]; . as $id | any($repos[]; .id == $id))' "$CI_VM_REPOSITORIES" >/dev/null; then
        printf 'enrolled:%s\n' "$ids"
        return
      fi
      ;;
    esac
  fi
  printf 'unknown\n'
}
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
  local status
  status=$(guest_status 15 worker-active)
  case "$status" in
  worker-busy)
    if [ "$active" != true ]; then read_stamp worker-without-api-demand-since; fi
    return 0
    ;;
  no-worker)
    clear_stamp worker-without-api-demand-since
    return 1
    ;;
  esac
  # An unreachable guest cannot reset an already established absolute cap.
  return 2
}
worker_cap_reached() {
  [ "$active" != true ] && [ -s "$state/worker-without-api-demand-since" ] || return 1
  read_stamp worker-without-api-demand-since
  [ "$((now - last))" -ge 3600 ]
}
stop_now() {
  local holder remaining_hostagent
  # Capture the independently validated process identity before stopping it.
  holder=$(bounded 20 hostagent 2>/dev/null) || holder=$$
  bounded 180 stop || return 1
  # A successful stop plus a fresh stopped status is required before release.
  vm_status || return 1
  if [ "$running" != false ]; then return 1; fi
  remaining_hostagent=$(bounded 20 hostagent-state 2>/dev/null) || return 1
  [ "$remaining_hostagent" = 0 ] || return 1
  heavy_operation release "$holder" || return 1
  clear_stamp unknown-since
  clear_stamp no-worker-since
  clear_stamp queue-since
  clear_stamp worker-without-api-demand-since
  stamp last-demand
}
failed_vm() {
  local rc remaining_hostagent
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
  vm_status || return 1
  if [ "$running" = false ]; then
    remaining_hostagent=$(bounded 20 hostagent-state 2>/dev/null) || return 1
    [ "$remaining_hostagent" = 0 ] || return 1
    heavy_operation release "$$" || return 1
  fi
  return 1
}
stop_if_idle() {
  local status
  log "$1"
  if [ "${2:-false}" != true ] && ! worker_cap_reached; then
    status=$(guest_status 150 drain)
    case "$status" in
    worker-busy)
      log 'drain found a Runner.Worker; retaining ci'
      picked_up
      return 3
      ;;
    drained) ;;
    *) log 'guest drain unavailable; enforcing the bounded uptime policy' ;;
    esac
  fi
  stop_now
}

vm_status() {
  local output
  if output=$(bounded 20 status 2>&1); then
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

verify_vm_qos() {
  if ! bounded 30 qos; then
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
  if ! bounded 150 host-ready </dev/null; then
    ready=false
  fi
  # ExecStartPre may have enrolled successfully even if ExecStart then failed.
  # Fetch once, after activation, and keep maintenance off busy runners.
  if [ "$maintenance" = true ]; then
    enrolled=$(guest_status 20 enrolled)
    case "$enrolled" in
    enrolled:*)
      enrolled=${enrolled#enrolled:}
      enrolled=${enrolled//,/ }
      ;;
    *) return 1 ;;
    esac
    cleanup_tokens "$enrolled" || return 1
    check_enrollments "$enrolled" || return 1
  fi
  [ "$ready" = true ]
}

ensure_vm() {
  if [ "$running" = false ]; then
    # Busy is handled before this function, so failure cleanup cannot stop work
    # belonging to another holder. Explicit starts use the same acquisition.
    [ "$heavy_acquired" = true ] || return 1
    prepare || return 1
    log 'starting ci (4 CPUs, 16 GiB RAM, 150 GiB disk, standard priority)'
    bounded 900 start </dev/null || return 1
    local hostagent
    hostagent=$(bounded 20 hostagent) || return 1
    [[ "$hostagent" =~ ^[1-9][0-9]*$ ]] || return 1
    heavy_operation handoff "$$" "" "$hostagent" || return 1
    now=$(date +%s)
    stamp last-demand
    stamp queue-since
    clear_stamp unknown-since
    clear_stamp no-worker-since
    clear_stamp worker-without-api-demand-since
  fi
  verify_vm_qos || return 1
  if [ "${1:-}" = --provision-only ]; then
    bounded 30 provision-only </dev/null || return 1
    log 'provision verified; no runner activation requested'
  else
    activate_runners || return 1
  fi
}

# Source only inside the request subshell. curl receives the Authorization
# header on stdin, so the agent token never appears in process arguments.
api_request() (
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
        --header 'X-GitHub-Api-Version: 2022-11-28' "${@:2}" "$1"
    )
)

api_get() { api_request "$1"; }
api_post() { api_request "$1" --request POST --header 'Content-Type: application/json' --data-raw "$2" "${@:3}"; }

# Preserve both the HTTP status and transport outcome, including curl --fail.
post_outcome() {
  local output
  post_transport=0
  output=$(api_post "$1" "$2" --write-out $'\n%{http_code}') || post_transport=$?
  post_code=${output##*$'\n'}
  post_body=${output%$'\n'*}
}

clear_heavy_waits() {
  local file
  for file in "$state"/heavy-wait-*.wait; do
    [ ! -s "$file" ] || : >"$file"
  done
}

# A complete scan can retire waits for runs no longer queued. Keep outcome
# files for bounded retries/deduplication, and prune all run state after 7 days.
reconcile_heavy_waits() {
  python3 - "$state" "$now" "$1" <<'PY_STATE'
import json
from pathlib import Path
import sys
state, now, complete = Path(sys.argv[1]), int(sys.argv[2]), sys.argv[3] == "true"
keys = set()
for line in (state / "heavy-demand.jsonl").read_text().splitlines():
    run = json.loads(line)
    keys.add("heavy-wait-" + run["repository"].replace("/", "-") + "-" + str(run["id"]) + "-" + str(run["run_attempt"]) + ".wait")
for path in state.glob("heavy-wait-*"):
    if path.is_file():
        if now - path.stat().st_mtime > 7 * 86400:
            path.unlink()
        elif complete and path.name.endswith(".wait") and path.name not in keys and path.stat().st_size:
            path.write_text("")
PY_STATE
}

clear_issue_uncertainty() {
  python3 - "$1.create-uncertain" <<'PY_CLEAR_ISSUE'
from pathlib import Path
import sys
Path(sys.argv[1]).unlink(missing_ok=True)
PY_CLEAR_ISSUE
}

retry_count() {
  retries=0
  if [ -f "$state/$1" ]; then read -r retries <"$state/$1" || retries=0; fi
  if ! [[ "$retries" =~ ^[0-3]$ ]]; then retries=0; fi
}

comment_processed="|"
heavy_acquired=false
heavy_result='{}'
heavy_operation() {
  local operation=$1 pid=$2 transition
  heavy_result=$(python3 "$heavy_helper" "$operation" "$pid" "$now" "${3:-}" "${4:-0}") || return 1
  while IFS= read -r transition; do
    [ -z "$transition" ] || log "heavy lock $transition"
  done < <(jq -r '.transitions[]' <<<"$heavy_result")
}
heavy_acquire() {
  local job_url hostagent=0 repo
  repo=$(jq -er '.[0].repository' "$CI_VM_REPOSITORIES") || return 1
  job_url=$(jq -sr --arg repo "$repo" '.[0].html_url // ("https://github.com/" + $repo + "/actions")' "$state/heavy-demand.jsonl") || return 1
  # This identifies PID reuse conservatively; a real hostagent remains live
  # even if an inconsistent Colima status reports stopped.
  hostagent=$(bounded 20 hostagent-state 2>/dev/null) || return 1
  heavy_operation acquire "$$" "$job_url" "$hostagent" || return 1
  if jq -e '.busy' <<<"$heavy_result" >/dev/null; then return 75; fi
  heavy_acquired=true
  clear_heavy_waits
}

heavy_retain() {
  local hostagent repo
  hostagent=$(bounded 20 hostagent-state 2>/dev/null) || return 1
  [[ "$hostagent" =~ ^[1-9][0-9]*$ ]] || return 1
  repo=$(jq -er '.[0].repository' "$CI_VM_REPOSITORIES") || return 1
  heavy_operation retain "$$" "https://github.com/$repo/actions" "$hostagent" || return 1
  if jq -e '.busy' <<<"$heavy_result" >/dev/null; then
    log 'ERROR: running ci cannot reassert heavy lock; operator inspection required'
  fi
}

busy_runs() {
  local run repo id url workflow pr key waited limit owner reason response issue issue_file page count found retries attempt
  local mode=${1:-queued} file
  owner=$(jq -r '.owner | "\(.owner // "unknown") since \(.started_at // "unknown") (\(.job_url // "unknown"))"' <<<"$heavy_result") || return 1
  reason="host busy: mbp2607 heavy-CI lock held by $owner"
  while IFS= read -r run; do
    repo=$(jq -r .repository <<<"$run") || return 1
    id=$(jq -r .id <<<"$run") || return 1
    attempt=$(jq -r .run_attempt <<<"$run") || return 1
    url=$(jq -r .html_url <<<"$run") || return 1
    workflow=$(jq -r .path <<<"$run") || return 1
    pr=$(jq -r '.pull_requests[0].number // empty' <<<"$run") || return 1
    key="heavy-wait-${repo//\//-}-$id-$attempt"
    reason=$(jq -r --arg reason "$reason" ' .busy_reason // $reason' <<<"$run") || return 1
    if [ "$mode" != pending ] && [ ! -e "$state/$key.cancel-attempted" ]; then
      read_stamp "$key.wait"
      waited=$((now - last))
      limit=600
      if [ "$workflow" = .github/workflows/nightly.yml ]; then limit=2700; fi
      log "heavy lock busy-waiting run=$id attempt=$attempt waited=${waited}s limit=${limit}s; $reason"
      [ "$waited" -ge "$limit" ] || continue
      retry_count "$key.cancel-tries"
      [ "$retries" -lt 3 ] || continue
      retries=$((retries + 1))
      printf '%s\n' "$retries" >"$state/$key.cancel-tries"
      scan_started=$SECONDS
      post_outcome "https://api.github.com/repos/$repo/actions/runs/$id/cancel" '{}'
      if [ "$post_code" = 202 ] && [ "$post_transport" = 0 ]; then
        stamp "$key.cancelled"
        stamp "$key.cancel-attempted"
        jq -c --arg reason "$reason" '. + {busy_reason:$reason}' <<<"$run" >"$state/$key.pending.json" || return 1
        clear_stamp "$key.wait"
        log "heavy lock cancelled run=$id $url; $reason"
      elif [[ "$post_code" =~ ^4[0-9][0-9]$ ]]; then
        stamp "$key.cancel_failed"
        stamp "$key.cancel-attempted"
        log "ERROR: heavy lock cancel_failed run=$id HTTP $post_code; no cancellation comment"
      else
        log "heavy lock cancel uncertain run=$id HTTP $post_code transport=$post_transport attempt=$retries/3"
        if [ "$retries" -ge 3 ]; then stamp "$key.cancel_uncertain"; fi
      fi
    fi
    [ -e "$state/$key.cancelled" ] || continue
    [ ! -e "$state/$key.commented" ] || continue
    [[ "$comment_processed" != *"|$key|"* ]] || continue
    comment_processed="$comment_processed$key|"
    retry_count "$key.comment-tries"
    [ "$retries" -lt 3 ] || continue
    retries=$((retries + 1))
    printf '%s\n' "$retries" >"$state/$key.comment-tries"
    scan_started=$SECONDS
    issue=$pr
    if [ -z "$issue" ]; then
      page=1 found=false count=-1
      # Cache the confirmed issue number, but reconcile an uncertain creation
      # through GET before trying again. Never repeat an uncertain create.
      issue_file="$state/heavy-issue-${repo//\//-}"
      if [ -s "$issue_file" ]; then
        read -r issue <"$issue_file" || issue=''
        if [[ "$issue" =~ ^[1-9][0-9]*$ ]]; then
          response=$(api_get "https://api.github.com/repos/$repo/issues/$issue") || response='{}'
          if jq -e '.state == "open" and .locked != true and (has("pull_request") | not) and .title == "CI nightly: host busy / cancellations"' <<<"$response" >/dev/null; then
            found=true
          else
            issue=''
            : >"$issue_file"
          fi
        fi
      fi
      while [ "$found" = false ]; do
        response=$(api_get "https://api.github.com/repos/$repo/issues?state=open&per_page=100&page=$page") || break
        jq -e 'type == "array"' <<<"$response" >/dev/null || break
        issue=$(jq -r '[.[] | select(.title == "CI nightly: host busy / cancellations" and .locked != true and (has("pull_request") | not)) | .number][0] // empty' <<<"$response") || return 1
        if [ -n "$issue" ]; then
          found=true
          printf '%s\n' "$issue" >"$issue_file"
          break
        fi
        count=$(jq length <<<"$response") || return 1
        [ "$count" -eq 100 ] || break
        [ "$page" -lt 100 ] || break
        page=$((page + 1))
      done
      if [ "$found" = true ]; then clear_issue_uncertainty "$issue_file"; fi
      if [ "$found" = false ] && [ "$count" -ge 0 ] && [ "$count" -lt 100 ] && [ ! -e "$issue_file.create-uncertain" ]; then
        # Even a 201 with a lost/malformed body must not duplicate creation.
        stamp "${issue_file##*/}.create-uncertain"
        post_outcome "https://api.github.com/repos/$repo/issues" '{"title":"CI nightly: host busy / cancellations","body":"CI runs cancelled because the shared mbp2607 heavy-CI host is busy are recorded here."}'
        if [ "$post_code" = 201 ] && [ "$post_transport" = 0 ]; then
          issue=$(jq -er '.number | select(type == "number" and . > 0 and . == floor)' <<<"$post_body") || issue=''
          if [ -n "$issue" ]; then
            printf '%s\n' "$issue" >"$issue_file"
            clear_issue_uncertainty "$issue_file"
          fi
        elif [[ "$post_code" =~ ^4[0-9][0-9]$ ]]; then
          # A definite rejection cannot have created an issue; allow later recovery.
          clear_issue_uncertainty "$issue_file"
          log "ERROR: heavy lock issue creation rejected HTTP $post_code"
        else
          log "heavy lock issue creation uncertain HTTP $post_code; reconcile by title next tick"
        fi
      fi
    fi
    if ! [[ "$issue" =~ ^[1-9][0-9]*$ ]]; then
      log "heavy lock comment failed run=$id: no confirmed issue; attempt=$retries/3"
      continue
    fi
    response=$(jq -nc --arg body "$url: $reason" '{body:$body}') || return 1
    post_outcome "https://api.github.com/repos/$repo/issues/$issue/comments" "$response"
    if [ "$post_code" = 201 ] && [ "$post_transport" = 0 ]; then
      stamp "$key.commented"
    else
      log "heavy lock comment failed run=$id HTTP $post_code transport=$post_transport attempt=$retries/3"
    fi
  done < <(
    if [ "$mode" = pending ]; then
      for file in "$state"/heavy-wait-*.pending.json; do
        [ ! -f "$file" ] || cat "$file"
      done
    else
      cat "$state/heavy-demand.jsonl"
    fi | jq -sc 'unique_by([.repository,.id,.run_attempt])[]'
  )
}

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
      jq -e '(.workflow_runs | type == "array") and (.total_count | type == "number" and . >= 0 and . <= 100000000 and . == floor) and all(.workflow_runs[]; (.id | type == "number" and . > 0 and . <= 9007199254740991 and . == floor) and ((.run_attempt // 1) | type == "number" and . > 0 and . <= 9007199254740991 and . == floor))' <<<"$response" >/dev/null || return 2
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
          if [ "$match" = queued ]; then
            queued=true
            jq -c --argjson id "$run_id" --arg repo "$repo" '.workflow_runs[] | select(.id == $id) |
              {id, run_attempt:(.run_attempt // 1), repository:$repo, html_url:(.html_url // ("https://github.com/" + $repo + "/actions/runs/" + (.id|tostring))),
               path:(.path // ""), pull_requests:(.pull_requests // [])}' <<<"$response" >>"$state/heavy-demand.jsonl" || return 2
          fi
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
: >"$state/heavy-demand.jsonl"
case "$action" in
start)
  vm_status
  if [ "$running" = true ]; then heavy_retain; fi
  if [ -n "${2:-}" ] && [ "$2" != --provision-only ]; then exit 2; fi
  if [ "$running" = false ]; then
    if heavy_acquire; then :; else
      rc=$?
      if [ "$rc" -eq 75 ]; then log 'heavy lock busy-waiting operator start'; fi
      exit "$rc"
    fi
  fi
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
complete_scan=false
if [ "$unknown" = false ] && [ "$active" = false ]; then complete_scan=true; fi
reconcile_heavy_waits "$complete_scan"
# Cancellation removes runs from the next queue scan. Persisted notifications
# must still retry after that, independently of the current VM/lock state.
busy_runs pending
vm_status
if [ "$running" = true ]; then heavy_retain; fi
if [ "$running" = false ] && [ -d "$heavy_lock" ]; then
  residue_hostagent=$(bounded 20 hostagent-state 2>/dev/null) || residue_hostagent=-1
  heavy_operation residue "$$" "" "$residue_hostagent"
fi
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
  if [ "$running" = false ]; then
    if heavy_acquire; then :; else
      rc=$?
      if [ "$rc" -eq 75 ]; then
        if [ "$unknown" = false ]; then busy_runs; fi
        exit 0
      fi
      exit "$rc"
    fi
  fi
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
  if ! verify_vm_qos; then failed_vm 'standard policy could not be verified'; fi
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
