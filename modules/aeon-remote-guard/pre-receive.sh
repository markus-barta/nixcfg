#!/usr/bin/env bash
# Git sends old/new/ref lines on stdin. Drain them before checking admission.
while IFS= read -r _ref; do
  :
done
exec "@guard@"
