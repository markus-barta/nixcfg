#!/usr/bin/env bash
# Git sends old/new/ref lines on stdin. Drain them before checking admission;
# allow cleanup while busy only when every update deletes a ref.
has_updates=false
all_deletions=true
while read -r _old new _ref; do
  has_updates=true
  if [[ ! $new =~ ^0+$ ]]; then
    all_deletions=false
  fi
done
if $has_updates && $all_deletions; then
  exit 0
fi
exec "@guard@"
