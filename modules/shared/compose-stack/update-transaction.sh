#!/usr/bin/env bash
set -euo pipefail

if (( $# < 8 )); then
  echo "usage: $0 ACTIVE_COMPOSE EXPECTED_COMPOSE LOCK TIMEOUT COMPOSE PROJECT PROJECT_DIR PULL_MODE [PULL_TARGET ...]" >&2
  exit 64
fi

active_compose="$1"
expected_compose="$2"
lock_file="$3"
lock_timeout="$4"
compose_bin="$5"
project="$6"
project_directory="$7"
pull_mode="$8"
shift 8

expected_resolved="$(readlink -e -- "$expected_compose")" || {
  echo "compose update refused: expected compose file is unavailable" >&2
  exit 1
}

generation_is_current() {
  local active_resolved
  active_resolved="$(readlink -e -- "$active_compose")" || {
    echo "compose update refused: active compose file is unavailable" >&2
    exit 1
  }
  [[ "$active_resolved" == "$expected_resolved" ]]
}

exec 9>"$lock_file"
flock -w "$lock_timeout" 9

if ! generation_is_current; then
  echo "compose update skipped: a newer compose generation is active"
  exit 0
fi

compose_args=(-p "$project" -f "$expected_resolved")
if [[ -n "$project_directory" ]]; then
  compose_args+=(--project-directory "$project_directory")
fi

case "$pull_mode" in
  all)
    if (( $# != 0 )); then
      echo "compose update refused: pull targets supplied in all mode" >&2
      exit 64
    fi
    "$compose_bin" "${compose_args[@]}" pull --quiet
    ;;
  none)
    if (( $# != 0 )); then
      echo "compose update refused: pull targets supplied in none mode" >&2
      exit 64
    fi
    ;;
  targets)
    if (( $# == 0 )); then
      echo "compose update refused: targets mode requires at least one service" >&2
      exit 64
    fi
    "$compose_bin" "${compose_args[@]}" pull --quiet "$@"
    ;;
  *)
    echo "compose update refused: invalid pull mode" >&2
    exit 64
    ;;
esac

# Activation can replace /etc while a registry pull is in flight. Check again
# while retaining the lock; if this closure became stale, the new reconcile
# unit will acquire the lock next and converge its own compose generation.
if ! generation_is_current; then
  echo "compose update skipped: compose generation changed during pull"
  exit 0
fi

"$compose_bin" "${compose_args[@]}" up -d
