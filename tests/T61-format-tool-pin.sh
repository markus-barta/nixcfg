#!/usr/bin/env bash
# NIX-336: local hooks and hosted formatting must resolve one formatter pin.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

workflow=.github/workflows/format-check.yml
resolver=lib/devenv-nixpkgs-ref.nix

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

resolved_ref="$(nix eval --raw --file "$resolver")"
case "$resolved_ref" in
github:*/*/*) ;;
*) fail "resolver did not return an immutable 40-character GitHub revision" ;;
esac
revision="${resolved_ref##*/}"
if [ "${#revision}" -ne 40 ]; then
  fail "resolver revision is not 40 characters"
fi
case "$revision" in
*[!0-9a-f]* | '') fail "resolver revision is not lowercase hexadecimal" ;;
esac

grep -Fq 'nix eval --raw --file ./lib/devenv-nixpkgs-ref.nix' "$workflow" ||
  fail "format workflow does not consume the devenv lock resolver"

if grep -Eq 'channel:nixos-unstable|(^|[^_])nixpkgs#' "$workflow"; then
  fail "format workflow still contains a floating nixpkgs formatter source"
fi

for tool in nixfmt deadnix statix shfmt shellcheck prettier just; do
  needle="\"\${formatter_nixpkgs_ref}#$tool\""
  grep -Fq "$needle" "$workflow" ||
    fail "format workflow does not resolve $tool from the shared pin"
done

printf 'ok: local hooks and hosted formatting share the devenv nixpkgs pin (%s)\n' "$resolved_ref"
