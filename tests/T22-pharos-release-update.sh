#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d)
compose_files=(
  hosts/csb0/docker/docker-compose.yml
  hosts/csb1/docker/docker-compose.yml
  hosts/gpc0/docker/docker-compose.yml
  hosts/hsb0/docker/docker-compose.yml
  hosts/hsb1/docker/docker-compose.yml
  hosts/hsb8/docker/docker-compose.yml
  hosts/hsb9/docker/docker-compose.yml
)

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

new_digest="sha256:$(printf 'b%.0s' {1..64})"
expected="ghcr.io/markus-barta/pharos/pharosd:9.8.7@${new_digest}"

"$repo_root/scripts/update-pharos-release.sh" --root "$fixture" 9.8.7 "$new_digest" >/dev/null
[[ "$(jq -r '.reference' "$fixture/pharos-release.json")" == "$expected" ]]
[[ "$(grep -rlF "image: $expected" "$fixture/hosts" | wc -l | tr -d ' ')" == 7 ]]
[[ "$(grep -rF "image: $expected" "$fixture/hosts" | wc -l | tr -d ' ')" == 8 ]]

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
