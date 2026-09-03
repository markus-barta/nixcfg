#!/usr/bin/env bash
# NIX-423 — every general INSPR worker harness gets the exact official
# Higgsfield CLI, while authentication remains outside the Nix store.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  printf 'T67 failed: %s\n' "$*" >&2
  exit 1
}

package_file="$repo_root/pkgs/higgsfield-cli/default.nix"
smoke_file="$repo_root/pkgs/higgsfield-cli/higgsfield-smoke.sh"
home_module="$repo_root/modules/uzumaki/home-manager.nix"

grep -Fq 'version = "1.1.24";' "$package_file" || fail 'package version is not pinned to 1.1.24'
# shellcheck disable=SC2016 # Match the literal Nix interpolation contract.
grep -Fq 'higgsfield-ai/cli/releases/download/v${version}' "$package_file" || fail 'package does not use the official immutable release path'
grep -Fq 'sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];' "$package_file" || fail 'binary provenance is not declared'
grep -Fq 'pkgs.higgsfield-cli' "$home_module" || fail 'general worker Home Manager module does not install the CLI'

for forbidden in 'auth token' 'auth login' 'auth logout' 'API_KEY' 'TOKEN='; do
  if grep -Fq "$forbidden" "$smoke_file"; then
    fail "smoke check contains forbidden credential operation: $forbidden"
  fi
done
grep -Fq 'account status --json' "$smoke_file" || fail 'authenticated account read is not checked'
grep -Fq 'model list --image --json' "$smoke_file" || fail 'complete image catalog read is not checked'
grep -Fq 'unset account_json' "$smoke_file" || fail 'account response is not cleared after validation'
grep -Fq 'HIGGSFIELD_BIN:-@higgsfield@' "$smoke_file" || fail 'smoke does not default to its immutable packaged binary'
grep -Fq 'expected_version="@version@"' "$smoke_file" || fail 'smoke version is not derived from the package pin'

package_version=$(cd "$repo_root" && nix eval --raw '.#packages.aarch64-darwin.higgsfield-cli.version')
[ "$package_version" = 1.1.24 ] || fail "evaluated package version drifted: $package_version"
package_out=$(cd "$repo_root" && nix eval --raw '.#packages.aarch64-darwin.higgsfield-cli.outPath')

for home in 'markus@mbp2607' 'mba@mbp2606' 'mailina@mbp2606'; do
  packages=$(cd "$repo_root" && nix eval --json ".#homeConfigurations.\"$home\".config.home.packages")
  printf '%s' "$packages" | python3 -c '
import json, sys
package = sys.argv[1]
paths = json.load(sys.stdin)
if package not in paths:
    raise SystemExit(f"missing Higgsfield package in Home Manager package set: {package}")
' "$package_out" || fail "$home does not inherit the general worker package"
done

current_system=$(nix eval --impure --raw --expr builtins.currentSystem)
if [ "$current_system" = aarch64-darwin ]; then
  cd "$repo_root"
  nix build '.#packages.aarch64-darwin.higgsfield-cli' --no-link
  nix build '.#homeConfigurations."markus@mbp2607".activationPackage' --no-link
  [ -x "$package_out/bin/higgsfield" ] || fail 'realised Higgsfield binary is missing'
  [ -x "$package_out/bin/higgsfield-smoke" ] || fail 'realised safe smoke command is missing'
  "$package_out/bin/higgsfield" --version | grep -Fq 'higgsfield 1.1.24 ' || fail 'realised binary version mismatch'
fi

printf 'T67 passed: Higgsfield 1.1.24 is packaged for every general INSPR worker harness\n'
