#!/usr/bin/env bash
set -euo pipefail

# Guard: macOS ships bash 3.2, where `set -e` does NOT abort on a failing
# bare `[[ ]]` — this script would report a FALSE PASS. CI runs bash 5.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash %s is too old -- set -e does not abort on a failing [[ ]], so this test would FALSELY PASS. Run under bash 5: nix run nixpkgs#bash -- %s\n' \
    "${0##*/}" "$BASH_VERSION" "$0" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d)
# OPS-127: the specs are the release-pin source of truth (ymls retired)
compose_files=(
  hosts/csb0/docker/compose-spec.nix
  hosts/csb1/docker/compose-spec.nix
  hosts/hsb0/docker/compose-spec.nix
  hosts/hsb1/docker/compose-spec.nix
  hosts/hsb8/docker/compose-spec.nix
  hosts/hsb9/docker/compose-spec.nix
)
readiness=hosts/csb1/docker/janus/managed-service-production/readiness.sh

cleanup() {
  find "$fixture" -type f -delete
  find "$fixture" -depth -type d -exec rmdir '{}' \;
}
trap cleanup EXIT

cp "$repo_root/pharos-release.json" "$fixture/pharos-release.json"
for relative in "${compose_files[@]}"; do
  mkdir -p "$fixture/$(dirname "$relative")"
  cp "$repo_root/$relative" "$fixture/$relative"
done
mkdir -p "$fixture/$(dirname "$readiness")"
cp "$repo_root/$readiness" "$fixture/$readiness"

new_digest="sha256:$(printf 'b%.0s' {1..64})"
expected="ghcr.io/inspr-at/pharos/pharosd:9.8.7@${new_digest}"

"$repo_root/scripts/update-pharos-release.sh" --root "$fixture" 9.8.7 "$new_digest" >/dev/null
[[ "$(jq -r '.reference' "$fixture/pharos-release.json")" == "$expected" ]]
[[ "$(grep -rlF "image = \"$expected\";" "$fixture/hosts" | wc -l | tr -d ' ')" == 6 ]]
[[ "$(grep -rF "image = \"$expected\";" "$fixture/hosts" | wc -l | tr -d ' ')" == 7 ]]
grep -Fq \
  "'^ghcr\\.io/inspr-at/pharos/pharosd:9\\.8\\.7@sha256:[0-9a-f]{64}$'" \
  "$fixture/$readiness"

before=$(find "$fixture" -type f -print | LC_ALL=C sort | xargs sha256sum)
"$repo_root/scripts/update-pharos-release.sh" --root "$fixture" 9.8.7 "$new_digest" >/dev/null
after=$(find "$fixture" -type f -print | LC_ALL=C sort | xargs sha256sum)
[[ "$before" == "$after" ]]

if "$repo_root/scripts/update-pharos-release.sh" --root "$fixture" v9.8.7 "$new_digest" >/dev/null 2>&1; then
  printf 'pharos_release_update_test=failed reason=invalid_version_accepted\n' >&2
  exit 1
fi
if "$repo_root/scripts/update-pharos-release.sh" --root "$fixture" 9.8.7 sha256:short >/dev/null 2>&1; then
  printf 'pharos_release_update_test=failed reason=invalid_digest_accepted\n' >&2
  exit 1
fi

printf 'pharos_release_update_test=passed\n'
