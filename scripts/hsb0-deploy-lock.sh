#!/usr/bin/env bash
# OPS-705: preserve the caller (mba for nh, root for nixos-rebuild).
set -euo pipefail
lock=/run/hsb0-deploy.lock
if ! host=$(hostname -s) || [[ -z $host ]]; then
  echo 'cannot determine hostname; refusing deploy or cleanup without lock' >&2
  exit 1
fi
if [[ $host != hsb0 ]]; then
  exec "$@"
fi
if [[ ! -e $lock ]]; then
  echo 'no hsb0 deploy lock yet'
  exec "$@"
fi

# An outer `flock ... just switch` passes its locked open file description
# to us. Reuse it so the documented manual command cannot deadlock itself.
# A successful flock on that same descriptor proves the lock is held; an
# unrelated reader must acquire it too. Never infer ownership from a PID.
for descriptor in /proc/"$$"/fd/[0-9]*; do
  if [[ $descriptor -ef $lock ]]; then
    if flock -w 900 -E 75 "${descriptor##*/}"; then
      exec "$@"
    else
      status=$?
      if [[ $status == 75 ]]; then
        echo 'hsb0 deploy lock busy (hausnetz-cd running?)' >&2
      fi
      exit "$status"
    fi
  fi
done

# sudo normally closes inherited descriptors. An outer flock can therefore
# survive in an ancestor while our descriptor was closed. Refuse immediately
# instead of waiting 900 seconds for our own parent. Root recipes must run
# directly, without an outer `flock ... just <root recipe>` wrapper.
ancestor=$PPID
for ((depth = 0; depth < 64 && ancestor > 1; depth++)); do
  for descriptor in /proc/"$ancestor"/fd/[0-9]*; do
    if [[ $descriptor -ef $lock ]]; then
      echo 'hsb0 deploy lock held by ancestor after descriptor closure; run root recipes directly without outer flock' >&2
      exit 75
    fi
  done
  parent=0
  if [[ -r /proc/"$ancestor"/status ]]; then
    while read -r field value _; do
      if [[ $field == PPid: ]]; then
        parent=$value
        break
      fi
    done </proc/"$ancestor"/status
  fi
  ancestor=$parent
done

# Acquire separately: a wrapped command may itself return 75, which is not
# evidence of lock contention. The descriptor survives exec for the full run.
# A fixed descriptor (not {var}) keeps this working on bash 3.2 (macOS tests).
exec 9<"$lock"
if flock -w 900 -E 75 9; then
  exec "$@"
else
  status=$?
  if [[ $status == 75 ]]; then
    echo 'hsb0 deploy lock busy (hausnetz-cd running?)' >&2
  fi
  exit "$status"
fi
