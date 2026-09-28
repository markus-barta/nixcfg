#!/usr/bin/env bash
# NIX-584 — csb1 must not run the classic PPM container.
set -euo pipefail

repo_root=$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compose="$repo_root/hosts/csb1/docker/compose-spec.nix"

fail() {
  printf 'T57 failed: %s\n' "$*" >&2
  exit 1
}

nix-instantiate --parse "$compose" >/dev/null
has_ppm=$(nix eval --impure --json --expr "(import $compose).services ? ppm")
[[ "$has_ppm" == "false" ]] || fail "classic ppm service must be absent, got $has_ppm"

if grep -Eq 'container_name = "ppm"' "$compose"; then
  fail 'compose still declares the classic ppm container'
fi

printf 'T57 passed: csb1 compose no longer runs classic PPM\n'
