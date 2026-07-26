#!/usr/bin/env bash
# T33 — every test that relies on set -e to enforce a bare [[ ]] must
# guard its bash version.
#
# WHY: macOS ships bash 3.2.57, where set -e does NOT abort on a failing
# bare [[ ]] command. Proof:
#
#   bash -c 'set -euo pipefail; v=6; [[ "$v" == 7 ]]; echo reached'
#   -> prints "reached", exits 0
#
# CI runs bash 5 and aborts correctly. So a test written that way passes
# silently on a macOS workstation no matter what its assertions say. That
# is worse than a failing test: it manufactures false confidence. It hid a
# real T22 break (hard-coded fleet size) during the 2026-07 gpc0 teardown.
#
# This meta-test fails if any tests/*.sh combines set -e with a bare
# [[ ]] assertion but lacks a BASH_VERSINFO guard.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tests_dir="$repo_root/tests"
self=${BASH_SOURCE[0]##*/}

unguarded=()
for script in "$tests_dir"/*.sh; do
  name=${script##*/}
  [ "$name" != "$self" ] || continue

  # Only scripts that both enable errexit and use a bare [[ ]] at the
  # start of a line are exposed. `[[ ]] || fail` forms are explicit and safe.
  grep -qE '^set -[a-zA-Z]*e' "$script" || continue
  grep -qE '^[[:space:]]*\[\[ ' "$script" || continue

  grep -q 'BASH_VERSINFO' "$script" || unguarded+=("$name")
done

if [ ${#unguarded[@]} -gt 0 ]; then
  printf 'bash_version_guards=failed\n' >&2
  printf '\nThese tests rely on "set -e" to enforce a bare [[ ]] but do not guard\n' >&2
  printf 'their bash version, so they FALSELY PASS on macOS bash 3.2:\n\n' >&2
  printf '  %s\n' "${unguarded[@]}" >&2
  printf '\nAdd after the set- line:\n\n' >&2
  cat >&2 <<'SNIPPET'
  if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    printf '%s: bash %s is too old -- set -e does not abort on a failing [[ ]], so this test would FALSELY PASS. Run under bash 5: nix run nixpkgs#bash -- %s\n' \
      "${0##*/}" "$BASH_VERSION" "$0" >&2
    exit 2
  fi
SNIPPET
  printf '\n...or make the assertion explicit instead: [[ a == b ]] || fail "..."\n' >&2
  exit 1
fi

printf 'bash_version_guards=passed\n'
