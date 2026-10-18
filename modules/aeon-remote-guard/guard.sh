#!/usr/bin/env bash
# Also runnable directly for tests; the Nix wrapper pins all settings.
set -euo pipefail
export LC_ALL=C

: "${guard_hold_file:=${HOME}/.hold-mbp2606}"
: "${guard_policy_file:=${HOME}/.aeon-remote-policy}"
: "${guard_default_max_load:=12}"
: "${guard_stale_seconds:=900}"
: "${guard_max_runs_file:=${HOME}/.aeon-remote-maxruns}"
: "${guard_lease_dir:=${HOME}/.aeon-remote-leases}"
: "${guard_default_max_runs:=1}"
: "${guard_reservation_ttl_seconds:=120}"
run_id=''
valid_id() { [[ $1 =~ ^[A-Za-z0-9._-]{1,64}$ && $1 != . && $1 != .. ]]; }
if (($#)); then
  if [[ $# != 2 || $1 != reserve ]] || ! valid_id "${2:-}"; then
    printf 'usage: aeon-remote-guard [reserve <run-id>]\n' >&2
    exit 2
  fi
  run_id=$2
fi
reasons=()
malformed_policy=false
number='[0-9]+([.][0-9]+)?'
maxload=$guard_default_max_load
level=UNKNOWN

# flock is attached to the open file description, shared by Perl's stdin and
# this shell's fd 9. It stays held after Perl exits, until this shell dies.
# Keep the lock inode outside the lease namespace: even a run named .lock must
# never replace it. Never unlink this persistent file (including on cleanup).
umask 077
budget_locked=false
lease_parent=$(dirname -- "$guard_lease_dir")
if {
  [[ -d $lease_parent && -x $lease_parent ]] &&
    mkdir -p -- "$guard_lease_dir" &&
    { exec 9>>"${guard_lease_dir%/}.lock"; } &&
    perl -e 'flock(STDIN, 2) or exit 1' <&9
} 2>/dev/null; then
  budget_locked=true
else
  reasons+=("cannot lock run budget")
fi

# -L also catches a dangling hold symlink. An inaccessible/missing parent is
# not evidence that the hold is absent, so refuse rather than failing open.
hold_parent=$(dirname -- "$guard_hold_file")
if [[ -e "$guard_hold_file" || -L "$guard_hold_file" ]]; then
  reasons+=("hold file exists")
elif [[ ! -d "$hold_parent" || ! -x "$hold_parent" ]]; then
  reasons+=("cannot check hold file")
fi

if [[ -e "$guard_policy_file" || -L "$guard_policy_file" ]]; then
  policy_lines=()
  policy_pattern="^block=([01]) maxload=($number) level=(GREEN|YELLOW|RED) epoch=([0-9]{1,12})$"
  # Never source policy text. Require exactly one line and validate every field
  # before interpreting it; unreadable policy is treated as malformed/missing.
  if [[ -f "$guard_policy_file" && -r "$guard_policy_file" ]] &&
    mapfile -t policy_lines 2>/dev/null <"$guard_policy_file" &&
    [[ ${#policy_lines[@]} == 1 && ${policy_lines[0]} =~ $policy_pattern ]]; then
    block=${BASH_REMATCH[1]}
    policy_maxload=${BASH_REMATCH[2]}
    policy_level=${BASH_REMATCH[4]}
    epoch=${BASH_REMATCH[5]}
    if now=$(date +%s 2>/dev/null) && [[ $now =~ ^[0-9]{1,12}$ ]]; then
      # Bound and decimalize epoch before arithmetic; tolerate at most 60 s of
      # future skew without extending freshness indefinitely after a clock jump.
      age=$((10#$now - 10#$epoch))
      if ((age >= -60 && age <= guard_stale_seconds)); then
        maxload=$policy_maxload
        level=$policy_level
        if [[ $block == 1 ]]; then
          reasons+=("fresh policy block=1")
        fi
      fi
    else
      reasons+=("cannot read policy clock")
    fi
  else
    malformed_policy=true
  fi
fi

load_sample=''
if [[ ${AEON_REMOTE_GUARD_LOAD+x} ]]; then
  load_sample=$AEON_REMOTE_GUARD_LOAD
else
  load_sample=$(/usr/sbin/sysctl -n vm.loadavg 2>/dev/null) || true
fi
load=''
if [[ $load_sample =~ ^$number$ ]]; then
  load=$load_sample
elif [[ $load_sample =~ ^\{[[:space:]]+($number)[[:space:]]+${number}[[:space:]]+${number}[[:space:]]+\}$ ]]; then
  load=${BASH_REMATCH[1]}
fi
if [[ -z $load ]]; then
  reasons+=("cannot read 1-minute load")
elif [[ ! $maxload =~ ^$number$ ]]; then
  reasons+=("invalid maximum load")
elif comparison=$(LC_ALL=C awk -v cur="$load" -v lim="$maxload" 'BEGIN { print (cur > lim ? "busy" : "ok") }' 2>/dev/null); then
  if [[ $comparison == busy ]]; then
    reasons+=("1-minute load $load exceeds maxload $maxload")
  elif [[ $comparison != ok ]]; then
    reasons+=("cannot compare 1-minute load")
  fi
else
  reasons+=("cannot compare 1-minute load")
fi

maxruns=$guard_default_max_runs
budget_now=''
if budget_now=$(date +%s 2>/dev/null) && [[ $budget_now =~ ^[0-9]{1,12}$ ]]; then
  budget_lines=()
  budget_pattern='^maxruns=([0-9]) epoch=([0-9]{1,12})$'
  if [[ -f $guard_max_runs_file && -r $guard_max_runs_file ]] &&
    mapfile -t budget_lines 2>/dev/null <"$guard_max_runs_file" &&
    [[ ${#budget_lines[@]} == 1 && ${budget_lines[0]} =~ $budget_pattern ]]; then
    budget_value=${BASH_REMATCH[1]}
    budget_epoch=${BASH_REMATCH[2]}
    budget_age=$((10#$budget_now - 10#$budget_epoch))
    if ((budget_age >= -60 && budget_age <= guard_stale_seconds)); then
      maxruns=$budget_value
    fi
  fi
else
  reasons+=("cannot read run budget clock")
  budget_now=''
fi

pid_alive() {
  [[ $1 =~ ^[1-9][0-9]{0,9}$ ]] && ((10#$1 <= 2147483647)) && kill -0 -- "$1" 2>/dev/null
}
declare -A active_runs=()
adopted_pid=''
add_run() {
  if valid_id "$1" && [[ $1 != "$run_id" ]]; then
    active_runs["$1"]=1
  fi
}
if $budget_locked && [[ -n $budget_now ]]; then
  shopt -s nullglob dotglob
  for entry in "$guard_lease_dir"/*; do
    id=${entry##*/}
    valid_id "$id" || continue
    [[ -f $entry && ! -L $entry && -r $entry ]] || continue
    lease_lines=()
    mapfile -t lease_lines <"$entry" || continue
    [[ ${#lease_lines[@]} -ge 1 && ${lease_lines[0]} =~ ^reserved=([0-9]{1,12})$ ]] || continue
    reserved=${BASH_REMATCH[1]}
    if [[ ${#lease_lines[@]} == 2 && ${lease_lines[1]} =~ ^pid=([1-9][0-9]{0,9})$ ]]; then
      lease_pid=${BASH_REMATCH[1]}
      if pid_alive "$lease_pid"; then
        add_run "$id"
        if [[ $id == "$run_id" ]]; then adopted_pid=$lease_pid; fi
      else
        unlink -- "$entry"
      fi
    elif [[ ${#lease_lines[@]} == 1 ]]; then
      if ((10#$budget_now - 10#$reserved < guard_reservation_ttl_seconds)); then
        add_run "$id"
      else
        unlink -- "$entry"
      fi
    fi
  done
  for entry in "$HOME/.aeon-remote-test/"*.pid; do
    id=${entry##*/}
    [[ -f $entry && -r $entry ]] || continue
    pid=$(<"$entry")
    if pid_alive "$pid"; then add_run "${id%.pid}"; fi
  done
  for entry in "$HOME/ci.noindex/aeon-runs/"*; do
    if [[ -d $entry ]]; then add_run "${entry##*/}"; fi
  done
  for entry in "$HOME/aeon-ui-runs/"*; do
    [[ -f $entry/supervisor.pid && -r $entry/supervisor.pid ]] || continue
    pid=$(<"$entry/supervisor.pid")
    if pid_alive "$pid"; then add_run "${entry##*/}"; fi
  done
fi
active_count=${#active_runs[@]}
budget_full=false
if [[ -n $run_id ]]; then
  if ((active_count >= maxruns)); then budget_full=true; fi
elif ((active_count > maxruns)); then
  budget_full=true
fi
if ((maxruns > 0)) && $budget_full; then
  reasons+=("$active_count/$maxruns runs active (OPS budget)")
fi

# Keep all existing reasons together, including alongside a paused budget.
if ((maxruns == 0)); then
  detail=''
  if $malformed_policy; then reasons+=("malformed policy ignored; using default maxload"); fi
  for item in "${reasons[@]}"; do detail+="; $item"; done
  printf 'remote paused: OPS budget is 0 (level %s)%s; retry later or rely on PR CI\n' "$level" "$detail" >&2
  exit 3
fi

if ((${#reasons[@]})); then
  if $malformed_policy; then
    reasons+=("malformed policy ignored; using default maxload")
  fi
  reason=${reasons[0]}
  for item in "${reasons[@]:1}"; do
    reason+="; $item"
  done
  printf 'remote busy: %s; retry in a few minutes or rely on PR CI\n' "$reason" >&2
  exit 3
fi
if [[ -n $run_id ]]; then
  # mv would otherwise put the reservation *inside* an unexpected directory.
  if [[ -d $guard_lease_dir/$run_id ]]; then
    printf 'remote busy: cannot write run reservation; retry in a few minutes or rely on PR CI\n' >&2
    exit 3
  fi
  reservation=$(mktemp "$guard_lease_dir/.reservation.XXXXXXXXXX")
  trap 'unlink -- "$reservation"' EXIT
  printf 'reserved=%s\n' "$budget_now" >"$reservation"
  # Re-pushing an adopted run must not turn its live lease back into a timer.
  if [[ -n $adopted_pid ]]; then printf 'pid=%s\n' "$adopted_pid" >>"$reservation"; fi
  chmod 600 "$reservation"
  mv -f -- "$reservation" "$guard_lease_dir/$run_id"
  trap - EXIT
fi
exit 0
