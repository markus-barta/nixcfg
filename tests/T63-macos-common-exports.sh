#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

exports=$(nix eval --json --impure --expr '
  let
    flake = builtins.getFlake (toString ./.);
    pkgs = import flake.inputs.nixpkgs {
      system = "aarch64-darwin";
      config.allowUnfree = true;
    };
  in
  builtins.attrNames (import ./modules/uzumaki/macos-common.nix {
    inherit pkgs;
    lib = pkgs.lib;
  })
' | jq -r '.[]')

expected='commonPackages
darwinDefaults
ghosttyCheckActivation
ghosttyConfig
loginShellCheckActivation
mkBrewfile
playwrightSessionVars'

if [[ "$exports" != "$expected" ]]; then
  printf 'macos_common_exports=failed reason=unexpected_public_api\n' >&2
  diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$exports") >&2 || true
  exit 1
fi

while IFS= read -r export_name; do
  if ! find hosts -type f -name '*.nix' -exec grep -Fq \
    "macosCommon.${export_name}" {} +; then
    printf 'macos_common_exports=failed reason=unconsumed_export export=%s\n' \
      "$export_name" >&2
    exit 1
  fi
done <<<"$exports"

printf 'macos_common_exports=passed exports=7 unconsumed=0\n'
