#!/usr/bin/env bash
# Git sends old/new/ref lines on stdin. Always drain before refusing, and allow
# deletions-only cleanup even while busy or when the old id is invalid.
export LC_ALL=C
has_updates=false
all_deletions=true
run_count=0
invalid_run=false
run_id=''
while read -r _old new ref; do
  has_updates=true
  if [[ ! $new =~ ^0+$ ]]; then
    all_deletions=false
    if [[ $ref == refs/runs/* ]]; then
      run_count=$((run_count + 1))
      run_id=${ref#refs/runs/}
      if [[ ! $run_id =~ ^[A-Za-z0-9._-]{1,64}$ || $run_id == . || $run_id == .. || $run_id == .reservation.* || $run_id == .recent-rounds ]]; then
        invalid_run=true
      fi
    fi
  fi
done
if $has_updates && $all_deletions; then
  exit 0
fi
if ((run_count > 1)); then
  printf 'remote busy: more than one run ref in one push; retry in a few minutes or rely on PR CI\n' >&2
  exit 3
fi
if $invalid_run; then
  printf 'remote busy: invalid run id; retry in a few minutes or rely on PR CI\n' >&2
  exit 3
fi
if ((run_count == 1)); then
  exec "@guard@" reserve "$run_id"
fi
exec "@guard@"
