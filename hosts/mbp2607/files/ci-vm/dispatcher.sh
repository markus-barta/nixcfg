#!/usr/bin/env bash
# One launchd poll. Only the `ci` Colima profile is ever addressed.
set +x
set -euo pipefail
umask 077
# Keep the CLI and the explicitly scoped profile/PID paths in the same home.
export COLIMA_HOME="$HOME/.colima"
state=${CI_VM_STATE_DIR:-$HOME/.local/state/ci-vm}
secrets="$state/secrets"
profile="$HOME/.colima/ci"
helper=${CI_VM_HOST_HELPER:-$(dirname "$0")/host.py}
mkdir -p "$state"
if [ "${1:-}" != --locked ]; then
  exec python3 "$helper" lock "$state/dispatcher.lock" /bin/bash "$0" --locked "$@"
fi
shift
action=${1:-tick}
log() { printf '%s ci-vm: %s\n' "$(date '+%F %T')" "$*"; }

vm_status() {
  local output
  if output=$(colima status ci --json 2>&1); then
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
  mkdir -p "$profile" "$secrets"
  chmod 0700 "$state" "$secrets"
  # Colima rewrites YAML on start. An immutable Nix-store symlink cannot work.
  cp "$CI_VM_CONFIG" "$profile/colima.yaml.next"
  chmod 0600 "$profile/colima.yaml.next"
  mv -f "$profile/colima.yaml.next" "$profile/colima.yaml"
  touch "$profile/.nixcfg-ci-vm"
}

background_vm() {
  if ! "$CI_VM_QOS"; then
    log 'background policy could not be verified; stopping ci'
    colima stop ci
    return 1
  fi
}

activate_runners() {
  if ! colima --profile ci ssh -- sudo /usr/local/libexec/ci-vm/host-ready; then
    log 'ci provisioning or runner readiness failed; stopping ci'
    colima stop ci
    return 1
  fi
}

start_vm() {
  prepare
  log 'starting ci (6 CPUs, 16 GiB RAM, 150 GiB disk)'
  # The launchd agent and every child start in background QoS; the explicit
  # PID pass also covers the separately launched Virtualization XPC service.
  if ! taskpolicy -b -c background colima start ci --activate=false --ssh-config=false; then
    log 'ci startup failed; stopping any partially started ci instance'
    colima stop ci || true
    return 1
  fi
  background_vm
  activate_runners
}

# Source only inside the request subshell. curl receives the Authorization
# header on stdin, so the agent token never appears in process arguments.
api_get() (
  set +x
  set -a
  # shellcheck source=/dev/null
  source "${CI_VM_AGENT_TOKEN_FILE:-$HOME/.inspr/secrets/agents/GH_TOKEN.env}" || exit 1
  set +a
  [ -n "${GH_TOKEN:-}" ] || exit 1
  printf 'header = "Authorization: Bearer %s"\n' "$GH_TOKEN" |
    curl --config - --fail --silent --show-error --max-time 20 --proto '=https' \
      --header 'Accept: application/vnd.github+json' \
      --header 'X-GitHub-Api-Version: 2022-11-28' "$1"
)

# Scan all pages; malformed/failed/truncated responses mean UNKNOWN, not idle.
# GitHub limits filtered workflow-run searches to 1000 results: refuse a full
# tenth page rather than incorrectly certify an empty queue.
demand_for_repo() {
  local repo=$1 offered status page response count total ids run_id jobs_page jobs job_count job_total match
  offered=$(jq -c '["self-hosted", "linux", "arm64"] + .labels | map(ascii_downcase) | unique' <<<"$repo")
  repo=$(jq -r .repository <<<"$repo")
  for status in queued in_progress; do
    page=1
    while :; do
      response=$(api_get "https://api.github.com/repos/$repo/actions/runs?status=$status&per_page=100&page=$page") || return 2
      jq -e '(.workflow_runs | type == "array") and (.total_count | type == "number" and . >= 0 and . == floor) and all(.workflow_runs[]; (.id | type == "number"))' <<<"$response" >/dev/null || return 2
      count=$(jq '.workflow_runs | length' <<<"$response")
      total=$(jq .total_count <<<"$response")
      ids=$(jq -r '.workflow_runs[].id' <<<"$response")
      for run_id in $ids; do
        jobs_page=1
        while :; do
          jobs=$(api_get "https://api.github.com/repos/$repo/actions/runs/$run_id/jobs?filter=latest&per_page=100&page=$jobs_page") || return 2
          jq -e '(.jobs | type == "array") and (.total_count | type == "number" and . >= 0 and . == floor) and all(.jobs[]; (.status | type == "string") and (.labels | type == "array") and all(.labels[]; type == "string"))' <<<"$jobs" >/dev/null || return 2
          match=$(jq --argjson offered "$offered" '[.jobs[] | select(.status == "queued" or .status == "in_progress") | select(.labels | length > 0) | select(all(.labels[]; ascii_downcase as $label | $offered | index($label) != null))] | length' <<<"$jobs")
          if [ "$match" -gt 0 ]; then return 0; fi
          job_count=$(jq '.jobs | length' <<<"$jobs")
          job_total=$(jq .total_count <<<"$jobs")
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
  return 1
}

case "$action" in
start)
  vm_status
  if [ "$running" = false ]; then start_vm; else
    background_vm
    activate_runners
  fi
  exit
  ;;
stop)
  colima stop ci
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
  log 'usage: ci-vm [tick|start|stop|prepare]'
  exit 2
  ;;
esac

demand=false
unknown=false
repositories=$(jq -c '.[]' "$CI_VM_REPOSITORIES")
[ -n "$repositories" ] || {
  log 'no repositories configured'
  exit 1
}
while IFS= read -r repo; do
  if demand_for_repo "$repo"; then
    demand=true
    break
  else
    rc=$?
    if [ "$rc" -ne 1 ]; then unknown=true; fi
  fi
done <<<"$repositories"
now=$(date +%s)
if [ "$unknown" = true ] && [ "$demand" = false ]; then
  printf '%s\n' "$now" >"$state/last-demand"
  log 'GitHub demand unknown; resetting idle grace and leaving ci unchanged'
  exit 0
fi
vm_status
if [ "$demand" = true ]; then
  printf '%s\n' "$now" >"$state/last-demand"
  if [ "$running" = false ]; then start_vm; else
    background_vm
    activate_runners
  fi
elif [ "$running" = true ]; then
  background_vm
  last=$now
  if [ -f "$state/last-demand" ]; then IFS= read -r last <"$state/last-demand" || last=$now; fi
  case "$last" in '' | *[!0-9]*) last=$now ;; esac
  if [ "$last" -gt "$now" ]; then last=$now; fi
  printf '%s\n' "$last" >"$state/last-demand"
  if [ "$((now - last))" -ge 1200 ]; then
    log 'no matching demand for 20 minutes; stopping ci'
    colima stop ci
  fi
else
  printf '%s\n' "$now" >"$state/last-demand"
fi
