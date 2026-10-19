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
: "${guard_budget_file:=${guard_home}/.aeon-remote-budget}"
: "${guard_allow_unknown_lane:=true}"
: "${guard_units_total:=4}"
: "${guard_units_new_max:=3}"
: "${guard_units_finishing_reserve:=1}"
: "${guard_aeon_new_max:=2}"
: "${guard_ait_new_max:=1}"
: "${guard_ops_new_max:=1}"
: "${guard_browser_max:=1}"
: "${guard_units_new_max_during_browser:=2}"
: "${guard_yellow_units_new_max:=1}"
: "${guard_yellow_browser_max:=0}"
: "${guard_red_units_new_max:=0}"
: "${guard_red_browser_max:=0}"
: "${guard_finish_window_seconds:=1800}"
: "${guard_recent_round_limit:=128}"
run_id=''
action=check
adopt_pid=''
lane=unknown
kind='test'
round=''
phase=new
valid_round() { [[ $1 =~ ^[A-Za-z0-9._-]{1,64}$ ]]; }
valid_id() {
  valid_round "$1" && [[ $1 != . && $1 != .. && $1 != .reservation.* && $1 != .recent-rounds ]]
}
adoption_recorded=false
adoption_classifying=false
adopt_warning() { printf 'remote warning: %s; adoption retained\n' "$1" >&3; }
busy() {
  if $adoption_recorded; then
    if $adoption_classifying; then
      # The work is already running. Count its requested lane/kind, but never
      # grant finish status or round proof when classification was refused.
      round='' phase=new
      write_lease || guard_error
    fi
    adopt_warning "$1"
    exit 0
  fi
  printf 'remote busy: %s; retry in a few minutes or rely on PR CI\n' "$1" >&3
  exit 3
}
if (($#)) && [[ $1 == reserve || $1 == adopt || $1 == release ]]; then
  action=$1
  if (($# < 2)) || ! valid_id "$2"; then
    printf 'usage: aeon-remote-guard [reserve <run-id> | adopt <run-id> <pid> | release <run-id>] [lane=... kind=... round=... [phase=finish]]\n' >&3
    exit 2
  fi
  run_id=$2
  shift 2
  if [[ $action == adopt ]]; then
    (($#)) || busy 'cannot adopt run pid'
    adopt_pid=$1
    shift
  fi
fi
declare -A supplied=()
client_reason=''
parse_client() {
  local parameter key value
  for parameter in "$@"; do
    [[ $parameter == *=* ]] || {
      client_reason='invalid client parameters'
      return 1
    }
    key=${parameter%%=*}
    value=${parameter#*=}
    case $key in lane | kind | round | phase) ;; *)
      client_reason='invalid client parameters'
      return 1
      ;;
    esac
    [[ ! ${supplied[$key]+yes} ]] || {
      client_reason='duplicate client parameter'
      return 1
    }
    supplied[$key]=1
    case $key in
    lane)
      [[ $value == aeon || $value == ait || $value == ops ]] || {
        client_reason='invalid lane'
        return 1
      }
      lane=$value
      ;;
    kind)
      [[ $value == test || $value == browser ]] || {
        client_reason='invalid kind'
        return 1
      }
      kind=$value
      ;;
    round)
      valid_round "$value" || {
        client_reason='invalid round'
        return 1
      }
      round=$value
      ;;
    phase)
      [[ $value == finish ]] || {
        client_reason='invalid phase'
        return 1
      }
      phase=$value
      ;;
    esac
  done
  if ((${#supplied[@]})) && [[ ! ${supplied[kind]+yes} || ! ${supplied[round]+yes} ]]; then
    client_reason='incomplete client parameters'
    return 1
  fi
}
if ! parse_client "$@" && [[ $action != adopt ]]; then busy "$client_reason"; fi
# Legacy callers inherit their existing metadata on refresh/adopt. They cannot
# erase a lane or convert a browser into an unclassified test by omitting args.
read_metadata() {
  lease_lane=unknown lease_kind='test' lease_round='' lease_phase=new
  local line key value
  local -A seen=()
  metadata_ok=true
  for line in "${lease_lines[@]:1}"; do
    key=${line%%=*} value=${line#*=}
    case $key in
    pid) continue ;;
    lane)
      [[ $value == aeon || $value == ait || $value == ops || $value == unknown ]] || metadata_ok=false
      lease_lane=$value
      ;;
    kind)
      [[ $value == test || $value == browser ]] || metadata_ok=false
      lease_kind=$value
      ;;
    round)
      [[ -z $value ]] || valid_round "$value" || metadata_ok=false
      lease_round=$value
      ;;
    phase)
      [[ $value == new || $value == finish ]] || metadata_ok=false
      lease_phase=$value
      ;;
    *)
      metadata_ok=false
      continue
      ;;
    esac
    [[ ! ${seen[$key]+yes} ]] || metadata_ok=false
    seen[$key]=1
  done
  if ((${#seen[@]})) && ((${#seen[@]} != 4)); then metadata_ok=false; fi
  if [[ $lease_phase == finish && -z $lease_round ]]; then metadata_ok=false; fi
  if ! $metadata_ok; then
    lease_lane=unknown lease_kind='test' lease_round='' lease_phase=new
  fi
}
inherit_metadata() {
  if ((${#supplied[@]} == 0)); then
    lane=$lease_lane kind=$lease_kind round=$lease_round phase=$lease_phase
  elif [[ -n $lease_round ]] && [[ $lane != "$lease_lane" || $kind != "$lease_kind" || $round != "$lease_round" || $phase != "$lease_phase" ]]; then
    busy 'run metadata mismatch'
  fi
}
pid_alive() {
  [[ $1 =~ ^[1-9][0-9]{0,9}$ ]] && ((10#$1 <= 2147483647)) && kill -0 -- "$1" 2>/dev/null
}
# Atomic replacement never follows a symlink or writes inside a directory.
write_lease() {
  [[ ! -e $guard_lease_dir/$run_id && ! -L $guard_lease_dir/$run_id ]] ||
    [[ -f $guard_lease_dir/$run_id && ! -L $guard_lease_dir/$run_id ]] || return 1
  reservation=$(mktemp "$guard_lease_dir/.reservation.XXXXXXXXXX") || return 1
  printf 'reserved=%s\n' "$budget_now" >"$reservation" || return 1
  printf 'lane=%s\nkind=%s\nround=%s\nphase=%s\n' "$lane" "$kind" "$round" "$phase" >>"$reservation" || return 1
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
    requested_lane=$lane requested_kind=$kind requested_round=$round requested_phase=$phase
    lane=unknown kind=test round='' phase=new
    adopted_pids=("$adopt_pid")
    lease_exists=false
    if [[ -f $guard_lease_dir/$run_id && ! -L $guard_lease_dir/$run_id ]]; then
      lease_exists=true
      lines=()
      mapfile -t lines <"$guard_lease_dir/$run_id" || guard_error
      lease_lines=("${lines[@]}")
      read_metadata
      lane=$lease_lane kind=$lease_kind round=$lease_round phase=$lease_phase
      for line in "${lines[@]}"; do
        if [[ $line =~ ^pid=([1-9][0-9]{0,9})$ && ${line#pid=} != "$adopt_pid" ]] && pid_alive "${BASH_REMATCH[1]}"; then
          adopted_pids+=("${line#pid=}")
        fi
      done
    fi
    # Persist liveness first. Metadata can never stop an admitted run counting.
    write_lease || guard_error
    adoption_recorded=true
    if [[ -n $client_reason ]]; then
      adopt_warning "$client_reason"
      exit 0
    fi
    if ((${#supplied[@]} == 0)); then exit 0; fi
    if ! $lease_exists; then
      adopt_warning 'missing lease metadata ignored'
      exit 0
    fi
    if [[ -n $round ]]; then
      if [[ $lane != "$requested_lane" || $kind != "$requested_kind" || $round != "$requested_round" || $phase != "$requested_phase" ]]; then
        adopt_warning 'run metadata mismatch'
      fi
      exit 0
    fi
    # Classifying an unclassified lease uses exactly the reserve gates below.
    lane=$requested_lane kind=$requested_kind round=$requested_round phase=$requested_phase
    adoption_classifying=true
  fi
  if ! $adoption_recorded; then busy "$reason"; fi
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

# All caps use decimal integers. The optional override is a single line of
# whitelisted key=value tokens, in any order, with exactly one fresh epoch.
# Validate the whole file before applying any field; never source OPS input.
declare -A caps=() overrides=()
for key in units_total units_new_max units_finishing_reserve aeon_new_max ait_new_max ops_new_max browser_max units_new_max_during_browser yellow_units_new_max yellow_browser_max red_units_new_max red_browser_max; do
  setting=guard_$key
  caps[$key]=${!setting}
done
if [[ -n $budget_now && -f $guard_budget_file && ! -L $guard_budget_file && -r $guard_budget_file ]]; then
  override_lines=()
  if mapfile -t override_lines <"$guard_budget_file" && ((${#override_lines[@]} == 1)); then
    override_valid=true
    read -r -a tokens <<<"${override_lines[0]}"
    for token in "${tokens[@]}"; do
      if [[ ! $token =~ ^([a-z_]+)=([0-9]{1,12})$ ]]; then
        override_valid=false
        break
      fi
      key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
      if [[ ${overrides[$key]+yes} || ($key != epoch && ! ${caps[$key]+yes}) ]]; then
        override_valid=false
        break
      fi
      if [[ $key != epoch && ! $value =~ ^(0|[1-9][0-9]{0,2})$ ]]; then
        override_valid=false
        break
      fi
      overrides[$key]=$value
    done
    if $override_valid && [[ ${overrides[epoch]+yes} ]] && ((${#overrides[@]} > 1)); then
      override_age=$((10#$budget_now - 10#${overrides[epoch]}))
      if ((override_age >= -60 && override_age <= guard_stale_seconds)); then
        for key in "${!caps[@]}"; do
          if [[ ${overrides[$key]+yes} ]] && ((overrides[$key] > caps[$key])); then override_valid=false; fi
        done
        if ! $override_valid; then
          printf 'remote warning: budget override violates pinned caps; override ignored\n' >&3
        else
          for key in "${!caps[@]}"; do
            if [[ ${overrides[$key]+yes} ]] && ((overrides[$key] < caps[$key])); then caps[$key]=${overrides[$key]}; fi
          done
        fi
      fi
    fi
  fi
fi
# A lower total is a tightening even if other pins now exceed it. Preserve
# one finishing slot (except at total zero), then bound every dependent cap.
new_ceiling=$((caps[units_total] > 0 ? caps[units_total] - 1 : 0))
((caps[units_new_max] <= new_ceiling)) || caps[units_new_max]=$new_ceiling
for key in units_finishing_reserve browser_max; do
  ((caps[$key] <= caps[units_total])) || caps[$key]=${caps[units_total]}
done
for key in aeon_new_max ait_new_max ops_new_max units_new_max_during_browser yellow_units_new_max red_units_new_max; do
  ((caps[$key] <= caps[units_new_max])) || caps[$key]=${caps[units_new_max]}
done
for key in yellow_browser_max red_browser_max; do
  ((caps[$key] <= caps[browser_max])) || caps[$key]=${caps[browser_max]}
done
if [[ $level == YELLOW ]]; then
  ((caps[units_new_max] <= caps[yellow_units_new_max])) || caps[units_new_max]=${caps[yellow_units_new_max]}
  ((caps[browser_max] <= caps[yellow_browser_max])) || caps[browser_max]=${caps[yellow_browser_max]}
elif [[ $level == RED ]]; then
  ((caps[units_new_max] <= caps[red_units_new_max])) || caps[units_new_max]=${caps[red_units_new_max]}
  ((caps[browser_max] <= caps[red_browser_max])) || caps[browser_max]=${caps[red_browser_max]}
fi

declare -A active_runs=() run_lanes=() run_kinds=() run_rounds=() run_phases=() recent_rounds=() expired_leases=()
recent_file=$guard_lease_dir/.recent-rounds
recent_ok=true
# Bounded, atomic round history survives both GC and client-owned unlink. A
# timestamp is proof the round held a live unit then, never an assumed death
# time. release records the exact end; unobserved deaths use last proof only.
remember_round() {
  local previous=${recent_rounds[$1]:-0}
  if (($2 > previous)); then recent_rounds[$1]=$2; fi
}
write_recent() {
  $recent_ok || return 1
  [[ ! -e $recent_file && ! -L $recent_file ]] || [[ -f $recent_file && ! -L $recent_file ]] || return 1
  reservation=$(mktemp "$guard_lease_dir/.reservation.XXXXXXXXXX") || return 1
  local r
  for r in "${!recent_rounds[@]}"; do
    printf '%s %s\n' "${recent_rounds[$r]}" "$r"
  done | sort -rn | awk -v limit="$guard_recent_round_limit" 'NR <= limit' >"$reservation" || return 1
  chmod 600 "$reservation" || return 1
  mv -fT -- "$reservation" "$recent_file" || return 1
  reservation=''
}
# History is optional for ordinary work, mandatory evidence for finish work.
# Over-limit input is trimmed on this call, but cannot authorize a finisher yet.
history_over_limit=false
if $budget_locked && [[ -n $budget_now && (-e $recent_file || -L $recent_file) ]]; then
  if [[ -f $recent_file && ! -L $recent_file && -r $recent_file ]]; then
    history=()
    if mapfile -t history <"$recent_file"; then
      if ((${#history[@]} > guard_recent_round_limit)); then history_over_limit=true; fi
      for line in "${history[@]}"; do
        if [[ $line =~ ^([0-9]{1,12})\ ((aeon|ait|ops|unknown):[A-Za-z0-9._-]{1,64})$ ]]; then
          epoch=${BASH_REMATCH[1]} r=${BASH_REMATCH[2]}
          age=$((10#$budget_now - 10#$epoch))
          if ((age >= 0 && age <= guard_finish_window_seconds)); then remember_round "$r" "$((10#$epoch))"; fi
        fi
      done
    else
      recent_ok=false
    fi
  else
    recent_ok=false
  fi
fi
persist_recent() {
  # Adoption only attaches liveness/classifies; it never creates round proof.
  [[ $action != adopt ]] || return 0
  if ! write_recent; then
    recent_ok=false
    if [[ -n $reservation ]]; then
      unlink -- "$reservation" 2>/dev/null || true
      reservation=''
    fi
  fi
}

adopted_pids=()
add_run() {
  if valid_id "$1"; then
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
    [[ $id != .recent-rounds ]] || continue
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
        elif ((i != 0)) && [[ ! $line =~ ^(lane|kind|round|phase)= ]]; then
          parsed=false
        fi
      done
    fi
    read_metadata
    $metadata_ok || parsed=false
    run_lanes[$id]=$lease_lane run_kinds[$id]=$lease_kind run_rounds[$id]=$lease_round run_phases[$id]=$lease_phase
    # Even malformed/unreadable leases reserve budget while fresh; only fully
    # parsed, dead and expired entries are safe to collect. Future mtimes do
    # not extend the TTL beyond the same 60-second skew used by policy input.
    if $live || ((lease_age >= -60 && lease_age < guard_reservation_ttl_seconds)); then
      add_run "$id"
      if [[ -n $lease_round ]]; then remember_round "$lease_lane:$lease_round" "$budget_now"; fi
      if [[ $id == "$run_id" ]]; then inherit_metadata; fi
    elif $parsed; then
      if [[ -n $lease_round ]] && ((lease_age >= 0 && lease_age <= guard_finish_window_seconds)); then
        remember_round "$lease_lane:$lease_round" "$((10#$mtime))"
      fi
      expired_leases[$id]=$entry
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
# Collection waits for every liveness source. An expired pid-less lease with
# a live client marker must retain its lane/browser/round metadata across calls.
if ${markers_readable:-false}; then
  for id in "${!expired_leases[@]}"; do
    if [[ ! ${active_runs[$id]+yes} ]]; then unlink -- "${expired_leases[$id]}" || true; fi
  done
fi
# A live legacy marker can outlast its pid-less reservation. Its retained
# metadata still proves a live round and must survive this ID's refresh.
for id in "${!active_runs[@]}"; do
  r=${run_rounds[$id]:-}
  if [[ -n $r ]]; then remember_round "${run_lanes[$id]:-unknown}:$r" "$budget_now"; fi
  if [[ $id == "$run_id" && ${run_lanes[$id]+yes} ]]; then
    lease_lane=${run_lanes[$id]} lease_kind=${run_kinds[$id]} lease_round=$r lease_phase=${run_phases[$id]}
    inherit_metadata
  fi
done
# A release is cleanup, allowed even while held or paused. Keep marker files
# client-owned; the caller releases after stopping its work and its markers.
if [[ $action == release ]]; then
  $budget_locked && [[ -n $budget_now ]] || guard_error
  if [[ -f $guard_lease_dir/$run_id && ! -L $guard_lease_dir/$run_id ]]; then
    r=${run_rounds[$run_id]:-}
    if [[ -n $r ]]; then remember_round "${run_lanes[$run_id]:-unknown}:$r" "$budget_now"; fi
    persist_recent
    unlink -- "$guard_lease_dir/$run_id" || guard_error
  elif [[ -e $guard_lease_dir/$run_id || -L $guard_lease_dir/$run_id ]]; then
    guard_error
  fi
  exit 0
fi
if [[ -n $run_id && $lane == unknown && $guard_allow_unknown_lane != true ]]; then busy 'lane required'; fi
active_count=${#active_runs[@]}
if [[ -n $run_id && ${active_runs[$run_id]+yes} ]]; then active_count=$((active_count - 1)); fi
budget_full=false
if [[ -n $run_id ]]; then
  if ((active_count >= maxruns)); then budget_full=true; fi
elif ((active_count > maxruns)); then
  budget_full=true
fi
if ((maxruns > 0)) && $budget_full; then
  reasons+=("$active_count/$maxruns runs active (OPS budget)")
fi

# Project the complete admitted set, replacing only this ID. Marker-only and
# malformed leases count conservatively as unknown new test units.
total=0 new=0 browsers=0 finishing=0
declare -A lane_new=([aeon]=0 [ait]=0 [ops]=0 [unknown]=0)
for id in "${!active_runs[@]}"; do
  [[ -z $run_id || $id != "$run_id" ]] || continue
  total=$((total + 1))
  if [[ ${run_kinds[$id]:-test} == browser ]]; then browsers=$((browsers + 1)); fi
  if [[ ${run_phases[$id]:-new} == finish ]]; then
    finishing=$((finishing + 1))
  else
    new=$((new + 1))
    l=${run_lanes[$id]:-unknown}
    lane_new[$l]=$((lane_new[$l] + 1))
  fi
done
if [[ -n $run_id ]]; then
  total=$((total + 1))
  if [[ $kind == browser ]]; then browsers=$((browsers + 1)); fi
  if [[ $phase == finish ]]; then
    finishing=$((finishing + 1))
    if ! $recent_ok || $history_over_limit; then
      persist_recent
      busy 'finish history unavailable'
    fi
    round_key=$lane:$round
    if [[ -z $round || ! ${recent_rounds[$round_key]+yes} ]]; then busy 'finish round not recent'; fi
  else
    new=$((new + 1))
    lane_new[$lane]=$((lane_new[$lane] + 1))
  fi
fi
joint_reason=''
if ((total > caps[units_total])); then
  joint_reason='joint total cap'
elif ((finishing > caps[units_finishing_reserve])) && [[ -z $run_id || $phase == finish ]]; then
  joint_reason='finishing reserve cap'
elif ((browsers > caps[browser_max])) && [[ -z $run_id || $kind == browser ]]; then
  joint_reason='browser cap'
elif ((new > caps[units_new_max])) && [[ -z $run_id || $phase != finish ]]; then
  joint_reason='joint new cap'
elif ((browsers > 0 && new > caps[units_new_max_during_browser])) && [[ -z $run_id || $phase != finish || $kind == browser ]]; then
  joint_reason='new cap during browser'
elif [[ -z $run_id || $phase != finish ]]; then
  lanes_to_check=(aeon ait ops)
  if [[ -n $run_id ]]; then lanes_to_check=("$lane"); fi
  for l in "${lanes_to_check[@]}"; do
    [[ $l != unknown ]] || continue
    key=${l}_new_max
    if ((lane_new[$l] > caps[$key])); then
      joint_reason='lane new cap'
      break
    fi
  done
fi
# Policy reductions stop new work; they cannot prevent an eligible finisher
# merely because already admitted new units exceed the newly lowered ceiling.
# Persist observations even on refusals, but admission itself is recorded only
# after all gates pass. One value-free reason covers a joint-budget refusal.
if $budget_locked && [[ -n $budget_now ]]; then persist_recent; fi
if [[ -n $run_id && $phase == finish ]] && ! $recent_ok; then busy 'finish history unavailable'; fi
# Bare main/tag checks start no work and retain only the pre-OPS-393 gates.
if [[ -n $run_id && -n $joint_reason ]] && ((${#reasons[@]} == 0)) && ((maxruns != 0)); then busy "$joint_reason"; fi

# Keep all existing reasons together, including alongside a paused budget.
if ((maxruns == 0)); then
  if $adoption_recorded; then busy 'admission paused'; fi
  detail=''
  if $malformed_policy; then reasons+=("malformed policy ignored; using default maxload"); fi
  for item in "${reasons[@]}"; do detail+="; $item"; done
  printf 'remote paused: OPS budget is 0 (level %s)%s; retry later or rely on PR CI\n' "$level" "$detail" >&3
  exit 3
fi

if ((${#reasons[@]})); then
  if $adoption_recorded; then busy 'metadata admission refused'; fi
  if $malformed_policy; then
    reasons+=("malformed policy ignored; using default maxload")
  fi
  reason=${reasons[0]}
  for item in "${reasons[@]:1}"; do
    reason+="; $item"
  done
  busy "$reason"
fi
if [[ -n $run_id ]]; then
  # mv would otherwise put the reservation *inside* an unexpected directory.
  if [[ -d $guard_lease_dir/$run_id ]]; then
    printf 'remote busy: cannot write run reservation; retry in a few minutes or rely on PR CI\n' >&3
    exit 3
  fi
  write_lease || guard_error
  if [[ -n $round && $action != adopt ]]; then
    remember_round "$lane:$round" "$budget_now"
    persist_recent
  fi
fi
exit 0
