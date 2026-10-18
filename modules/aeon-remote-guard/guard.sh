#!/usr/bin/env bash
# Also runnable directly for tests; the Nix wrapper pins all settings.
set -Eeuo pipefail
# Keep command diagnostics out of the client protocol. Unexpected failures use
# one stable busy response; inherited ERR traps print only in the main shell.
exec 3>&2 2>/dev/null
guard_pid=$BASHPID
reservation=''
guard_error() {
  if [[ $BASHPID == "$guard_pid" ]]; then
    printf 'remote busy: guard error; retry in a few minutes or rely on PR CI\n' >&3
  fi
  exit 3
}
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
guard_exit() {
  local rc=$?
  if [[ -n $reservation ]]; then unlink -- "$reservation" 2>/dev/null || true; fi
  if ((rc != 0 && rc != 2 && rc != 3)); then guard_error; fi
}
trap guard_error ERR
trap 'guard_exit' EXIT
export LC_ALL=C

: "${guard_home:=${HOME}}"

: "${guard_hold_file:=${guard_home}/.hold-mbp2606}"
: "${guard_policy_file:=${guard_home}/.aeon-remote-policy}"
: "${guard_default_max_load:=12}"
: "${guard_stale_seconds:=900}"
: "${guard_max_runs_file:=${guard_home}/.aeon-remote-maxruns}"
: "${guard_lease_dir:=${guard_home}/.aeon-remote-leases}"
: "${guard_default_max_runs:=1}"
: "${guard_reservation_ttl_seconds:=120}"
run_id=''
action=check
adopt_pid=''
valid_id() {
  [[ $1 =~ ^[A-Za-z0-9._-]{1,64}$ && $1 != . && $1 != .. && $1 != .reservation.* ]]
}
if (($#)); then
  if { [[ $# == 2 && $1 == reserve ]] || [[ $# == 3 && $1 == adopt ]]; } && valid_id "${2:-}"; then
    action=$1
    run_id=$2
    adopt_pid=${3:-}
  else
    printf 'usage: aeon-remote-guard [reserve <run-id> | adopt <run-id> <pid>]\n' >&3
    exit 2
  fi
fi
pid_alive() {
  [[ $1 =~ ^[1-9][0-9]{0,9}$ ]] && ((10#$1 <= 2147483647)) && kill -0 -- "$1" 2>/dev/null
}
# Atomic replacement never follows a symlink or writes inside a directory.
write_lease() {
  [[ ! -e $guard_lease_dir/$run_id && ! -L $guard_lease_dir/$run_id ]] ||
    [[ -f $guard_lease_dir/$run_id && ! -L $guard_lease_dir/$run_id ]] || return 1
  reservation=$(mktemp "$guard_lease_dir/.reservation.XXXXXXXXXX") || return 1
  printf 'reserved=%s\n' "$budget_now" >"$reservation" || return 1
  local pid
  for pid in "${adopted_pids[@]}"; do
    printf 'pid=%s\n' "$pid" >>"$reservation" || return 1
  done
  chmod 600 "$reservation" || return 1
  mv -fT -- "$reservation" "$guard_lease_dir/$run_id" || return 1
  reservation=''
}
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
leases_readable=false
lease_parent=$(dirname -- "$guard_lease_dir")
if [[ -d $lease_parent && -x $lease_parent ]] && mkdir -p -- "$guard_lease_dir"; then
  if [[ -d $guard_lease_dir && ! -L $guard_lease_dir && -O $guard_lease_dir && -r $guard_lease_dir && -w $guard_lease_dir && -x $guard_lease_dir ]]; then
    leases_readable=true
  else
    reasons+=("cannot read run leases")
  fi
else
  reasons+=("cannot read run leases")
fi
budget_lock_file="${guard_lease_dir%/}.lock"
if $leases_readable && {
  { [[ ! -e $budget_lock_file && ! -L $budget_lock_file ]] ||
    [[ -f $budget_lock_file && ! -L $budget_lock_file && -O $budget_lock_file ]]; } &&
    { exec 9>>"$budget_lock_file"; } && [[ -O $budget_lock_file ]] &&
    perl -e '$SIG{ALRM} = sub { exit 1 }; alarm 30; flock(STDIN, 2) or exit 1; alarm 0' <&9
}; then
  budget_locked=true
else
  reasons+=("cannot lock run budget")
fi

# Adoption records an already admitted client, even if admission is now paused.
# Both adoption and collection hold the same lock, including lease recreation.
if [[ $action == adopt ]]; then
  if ! $budget_locked; then
    reason=${reasons[0]}
  elif ! pid_alive "$adopt_pid"; then
    reason='cannot adopt run pid'
  # Non-root kill -0 already proves same-user ownership. Root needs an
  # explicit uid check because it can signal processes belonging to any user.
  elif ((EUID == 0)) &&
    { ! owner=$(/bin/ps -o uid= -p "$adopt_pid") || [[ ${owner//[[:space:]]/} != "$EUID" ]]; }; then
    reason='cannot adopt run pid'
  else
    budget_now=$(date +%s)
    [[ $budget_now =~ ^[0-9]{1,12}$ ]] || guard_error
    adopted_pids=("$adopt_pid")
    if [[ -f $guard_lease_dir/$run_id && ! -L $guard_lease_dir/$run_id ]]; then
      lines=()
      if mapfile -t lines <"$guard_lease_dir/$run_id"; then
        for line in "${lines[@]}"; do
          if [[ $line =~ ^pid=([1-9][0-9]{0,9})$ && ${line#pid=} != "$adopt_pid" ]] && pid_alive "${BASH_REMATCH[1]}"; then
            adopted_pids+=("${line#pid=}")
          fi
        done
      else
        guard_error
      fi
    fi
    write_lease || guard_error
    exit 0
  fi
  printf 'remote busy: %s; retry in a few minutes or rely on PR CI\n' "$reason" >&3
  exit 3
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

declare -A active_runs=()
adopted_pids=()
add_run() {
  if valid_id "$1" && [[ $1 != "$run_id" ]]; then
    active_runs["$1"]=1
  fi
}
if $budget_locked && [[ -n $budget_now ]]; then
  shopt -s nullglob dotglob
  for entry in "$guard_lease_dir"/*; do
    id=${entry##*/}
    # Never read through links or count non-regular entries. Their names must
    # not stop traversal of other leases.
    [[ -f $entry && ! -L $entry ]] || continue
    mtime=$(stat -c %Y -- "$entry") || {
      [[ -e $entry || -L $entry ]] && guard_error
      continue
    }
    [[ $mtime =~ ^[0-9]{1,12}$ ]] || guard_error
    lease_age=$((10#$budget_now - 10#$mtime))
    if [[ $id == .reservation.* ]]; then
      if ((lease_age >= guard_reservation_ttl_seconds)); then unlink -- "$entry" || true; fi
      continue
    fi
    valid_id "$id" || continue
    lease_lines=()
    parsed=false
    live=false
    reserved=''
    if [[ -r $entry ]] && mapfile -t lease_lines <"$entry"; then
      if ((${#lease_lines[@]} >= 1)) && [[ ${lease_lines[0]} =~ ^reserved=([0-9]{1,12})$ ]]; then
        reserved=${BASH_REMATCH[1]}
        if ((10#$reserved <= 10#$budget_now + 60)); then parsed=true; fi
      fi
      for ((i = 0; i < ${#lease_lines[@]}; i++)); do
        line=${lease_lines[i]}
        if [[ $line =~ ^pid=([1-9][0-9]{0,9})$ ]] && ((10#${BASH_REMATCH[1]} <= 2147483647)); then
          lease_pid=${line#pid=}
          if pid_alive "$lease_pid"; then
            live=true
            if [[ $id == "$run_id" ]]; then adopted_pids+=("$lease_pid"); fi
          fi
          if ((i == 0)); then parsed=false; fi
        elif ((i != 0)); then
          parsed=false
        fi
      done
    fi
    # Even malformed/unreadable leases reserve budget while fresh; only fully
    # parsed, dead and expired entries are safe to collect. Future mtimes do
    # not extend the TTL beyond the same 60-second skew used by policy input.
    if $live || ((lease_age >= -60 && lease_age < guard_reservation_ttl_seconds)); then
      add_run "$id"
    elif $parsed; then
      unlink -- "$entry" || true
    fi
  done
  markers_readable=true
  for marker_dir in "$guard_home/.aeon-remote-test" "$guard_home/ci.noindex/aeon-runs" "$guard_home/aeon-ui-runs"; do
    if [[ -e $marker_dir || -L $marker_dir ]]; then
      if [[ ! -d $marker_dir || -L $marker_dir || ! -r $marker_dir || ! -x $marker_dir ]]; then
        reasons+=("cannot read run markers")
        markers_readable=false
      fi
    fi
  done
  if $markers_readable; then
    for entry in "$guard_home/.aeon-remote-test/"*.pid; do
      id=${entry##*/}
      [[ -f $entry && ! -L $entry ]] || continue
      if [[ ! -r $entry ]]; then
        reasons+=("cannot read run markers")
        continue
      fi
      pid=$(<"$entry") 2>/dev/null || continue
      if pid_alive "$pid"; then add_run "${id%.pid}"; fi
    done
    # Run directories only cover the start window: killed runs leave them
    # behind until the client sweep, so an older directory counts solely through
    # a live adopted lease or pid marker. The guard never removes run directories.
    for entry in "$guard_home/ci.noindex/aeon-runs/"*; do
      [[ -d $entry && ! -L $entry ]] || continue
      mtime=$(stat -c %Y -- "$entry") || {
        [[ -e $entry || -L $entry ]] && guard_error
        continue
      }
      [[ $mtime =~ ^[0-9]{1,12}$ ]] || guard_error
      run_dir_age=$((10#$budget_now - 10#$mtime))
      if ((run_dir_age >= -60 && run_dir_age < guard_reservation_ttl_seconds)); then add_run "${entry##*/}"; fi
    done
    for entry in "$guard_home/aeon-ui-runs/"*; do
      if [[ -d $entry && ! -L $entry ]] && [[ ! -r $entry || ! -x $entry ]]; then
        reasons+=("cannot read run markers")
        continue
      fi
      [[ -d $entry && ! -L $entry && -f $entry/supervisor.pid && ! -L $entry/supervisor.pid && -r $entry/supervisor.pid ]] || continue
      pid=$(<"$entry/supervisor.pid") 2>/dev/null || continue
      if pid_alive "$pid"; then add_run "${entry##*/}"; fi
    done
  fi
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
  printf 'remote paused: OPS budget is 0 (level %s)%s; retry later or rely on PR CI\n' "$level" "$detail" >&3
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
  printf 'remote busy: %s; retry in a few minutes or rely on PR CI\n' "$reason" >&3
  exit 3
fi
if [[ -n $run_id ]]; then
  # mv would otherwise put the reservation *inside* an unexpected directory.
  if [[ -d $guard_lease_dir/$run_id ]]; then
    printf 'remote busy: cannot write run reservation; retry in a few minutes or rely on PR CI\n' >&3
    exit 3
  fi
  write_lease || guard_error
fi
exit 0
