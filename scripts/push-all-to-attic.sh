#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s [CACHE [SYSTEM_PATH]]\n' "${0##*/}" >&2
  exit 2
}

[[ $# -le 2 ]] || usage
cache=${1:-main}
system_path=${2:-/run/current-system}

[[ "$cache" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] || {
  printf 'attic_push=failed reason=invalid_cache\n' >&2
  exit 2
}
command -v attic >/dev/null || {
  printf 'attic_push=failed reason=attic_missing\n' >&2
  exit 1
}
command -v nix-store >/dev/null || {
  printf 'attic_push=failed reason=nix_store_missing\n' >&2
  exit 1
}

store_path=$(realpath "$system_path") || {
  printf 'attic_push=failed reason=system_path_unavailable\n' >&2
  exit 1
}
[[ "$store_path" == /nix/store/* && -e "$store_path" ]] || {
  printf 'attic_push=failed reason=system_path_not_in_store\n' >&2
  exit 1
}

# Attic pushes the closure unless --no-closure is requested. Passing the system
# root once is complete and avoids one network transaction per executable.
if ! closure_paths=$(nix-store --query --requisites "$store_path" | awk 'END { print NR }'); then
  printf 'attic_push=failed reason=closure_query_failed\n' >&2
  exit 1
fi
[[ "$closure_paths" =~ ^[1-9][0-9]*$ ]] || {
  printf 'attic_push=failed reason=empty_closure\n' >&2
  exit 1
}

printf 'attic_push=starting cache=%s closure_paths=%s\n' "$cache" "$closure_paths"
attic push --ignore-upstream-cache-filter "$cache" "$store_path"
printf 'attic_push=passed cache=%s closure_paths=%s\n' "$cache" "$closure_paths"
