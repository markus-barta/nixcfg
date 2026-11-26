#!/usr/bin/env bash
# OPS-705: preserve the caller (mba for nh, root for nixos-rebuild).
set -euo pipefail
lock=/run/hsb0-deploy.lock
if [[ $(hostname -s) != hsb0 ]]; then
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

if flock -w 900 -E 75 "$lock" "$@"; then
  exit 0
else
  status=$?
  if [[ $status == 75 ]]; then
    echo 'hsb0 deploy lock busy (hausnetz-cd running?)' >&2
  fi
  exit "$status"
fi
