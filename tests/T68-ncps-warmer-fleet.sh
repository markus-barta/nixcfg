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

# Exercise the exact production classifier, not a test-side copy of its rules.
refusal_awk=$(gawk '
  /source=.*\| awk/ { capture=1; next }
  capture && /^[[:space:]]*\047\)\042; then$/ { exit }
  capture { print }
' "$hsb0_config")
fixture="$repo_root/tests/fixtures/ncps-warmer-private-404.txt"

expect_skip() {
  local label="$1" actual
  if ! actual=$(gawk "$refusal_awk") || [ "$actual" != github.com/inspr-at/paimos ]; then
    printf 'T68 failed: %s must skip with only the GitHub owner/repo\n' "$label" >&2
    exit 1
  fi
  printf 'T68 passed: %s skips\n' "$label"
}

expect_no_skip() {
  local label="$1" actual status=0
  actual=$(gawk "$refusal_awk") || status=$?
  if [ "$status" -ne 1 ] || [ -n "$actual" ]; then
    printf 'T68 failed: %s must refuse the skip (exit 1, no source)\n' "$label" >&2
    exit 1
  fi
  printf 'T68 passed: %s refuses the skip\n' "$label"
}

# Verbatim hsb0 dry-run output captured 2026-11-16, including the bare error header.
expect_skip 'real hsb0 HTTP 404 output' <"$fixture"
sed 's/^error:$/   error:   /' "$fixture" | expect_skip 'whitespace around the bare header'
for status in 401 403; do
  sed "s/HTTP error 404/HTTP error $status/" "$fixture" | expect_skip "GitHub HTTP $status"
done
{
  cat "$fixture"
  printf '\nerror: unrelated evaluation failure\n'
} | expect_no_skip 'an additional unrelated error'
sed 's/HTTP error 404/HTTP error 500/' "$fixture" | expect_no_skip 'GitHub HTTP 500'
sed 's@https://github.com/@https://example.org/@' "$fixture" | expect_no_skip 'a non-GitHub host'

printf 'T68 passed: current mbp2607 closure with opt-in GitHub refusal skip; NixOS targets stay strict\n'
