#!/usr/bin/env bash
# Also runnable directly for tests; the Nix wrapper pins these four settings.
set -euo pipefail

: "${guard_hold_file:=${HOME}/.hold-mbp2606}"
: "${guard_policy_file:=${HOME}/.aeon-remote-policy}"
: "${guard_default_max_load:=12}"
: "${guard_stale_seconds:=900}"
reasons=()
malformed_policy=false
number='[0-9]+([.][0-9]+)?'
maxload=$guard_default_max_load

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
    epoch=${BASH_REMATCH[5]}
    if now=$(date +%s 2>/dev/null) && [[ $now =~ ^[0-9]{1,12}$ ]]; then
      # Bound and decimalize epoch before arithmetic; future policies are not
      # fresh and cannot extend their lifetime indefinitely after a clock jump.
      age=$((10#$now - 10#$epoch))
      if ((age >= 0 && age <= guard_stale_seconds)); then
        maxload=$policy_maxload
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
exit 0
