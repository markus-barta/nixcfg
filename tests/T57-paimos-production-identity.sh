#!/usr/bin/env bash
# NIX-584 — csb1 must not run the classic PPM container.
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash %s is too old -- set -e does not abort on a failing [[ ]], so this test would FALSELY PASS. Run under bash 5: nix run nixpkgs#bash -- %s\n' \
    "${0##*/}" "$BASH_VERSION" "$0" >&2
  exit 2
fi

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
if grep -Eq 'ghcr.io/inspr-at/paimos:' "$compose"; then
  fail 'compose still pins the classic paimos image'
fi
if grep -Fq '10.253.253.4' "$compose"; then
  fail 'compose still mentions classic paimos address 10.253.253.4'
fi

printf 'T57 passed: csb1 compose no longer runs classic PPM\n'
