#!/usr/bin/env bash
# NIX-431 — the hsb0 NCPS warmer must follow the current macOS fleet identity.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
hsb0_config="$repo_root/hosts/hsb0/configuration.nix"
flake="$repo_root/flake.nix"

# OPS-600: the refusal skip is explicit and belongs only to the macOS target.
grep -Fq 'warm mbp2607   '\''.#homeConfigurations."markus@mbp2607".activationPackage'\'' true || failed=1' "$hsb0_config"
grep -Fq "skip_private_github=\"''\${3:-false}\"" "$hsb0_config"
grep -Fq "if [ \"\$skip_private_github\" = true ]" "$hsb0_config"
grep -Fq 'warm hsb1      ".#nixosConfigurations.hsb1.config.system.build.toplevel" || failed=1' "$hsb0_config"
grep -Fq 'warm hsb0      ".#nixosConfigurations.hsb0.config.system.build.toplevel" || failed=1' "$hsb0_config"
grep -Fq 'warmer: done (mbp2607 skipped)' "$hsb0_config"
grep -Fq 'homeConfigurations."markus@mbp2607"' "$flake"

if grep -Fq 'homeConfigurations."mba@mbp0"' "$hsb0_config"; then
  printf 'T68 failed: hsb0 NCPS warmer still references retired mba@mbp0\n' >&2
  exit 1
fi

printf 'T68 passed: current mbp2607 closure with opt-in GitHub refusal skip; NixOS targets stay strict\n'
