#!/usr/bin/env bash
# NIX-431 — the hsb0 NCPS warmer must follow the current macOS fleet identity.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
hsb0_config="$repo_root/hosts/hsb0/configuration.nix"
flake="$repo_root/flake.nix"

grep -Fq 'warm mbp2607   '\''.#homeConfigurations."markus@mbp2607".activationPackage'\''' "$hsb0_config"
grep -Fq 'homeConfigurations."markus@mbp2607"' "$flake"

if grep -Fq 'homeConfigurations."mba@mbp0"' "$hsb0_config"; then
  printf 'T68 failed: hsb0 NCPS warmer still references retired mba@mbp0\n' >&2
  exit 1
fi

printf 'T68 passed: hsb0 NCPS warmer targets current mbp2607 Home Manager closure\n'
