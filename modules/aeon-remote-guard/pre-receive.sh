#!/usr/bin/env bash
# Git sends old/new/ref lines on stdin. Drain them before checking admission;
# allow cleanup while busy only when every update deletes a ref.
export LC_ALL=C
has_updates=false
all_deletions=true
ref_count=0
run_id=''
while read -r _old new ref; do
  has_updates=true
  ref_count=$((ref_count + 1))
  if [[ $ref =~ ^refs/runs/([A-Za-z0-9._-]{1,64})$ ]]; then
    run_id=${BASH_REMATCH[1]}
  else
    run_id=''
  fi
  if [[ ! $new =~ ^0+$ ]]; then
    all_deletions=false
  fi
done
if $has_updates && $all_deletions; then
  exit 0
fi
if ((ref_count == 1)) && [[ -n $run_id && $run_id != . && $run_id != .. ]]; then
  exec "@guard@" reserve "$run_id"
fi
exec "@guard@"
