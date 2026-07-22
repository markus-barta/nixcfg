#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

service_block() {
  local file=$1
  local service=$2
  awk -v heading="  ${service}:" '
    $0 == heading { found = 1 }
    found && $0 != heading && /^  [^ ]/ { exit }
    found { print }
  ' "$file"
}

service_image() {
  service_block "$1" "$2" | awk '$1 == "image:" { print $2; exit }'
}

control_plane="$repo_root/hosts/csb1/docker/docker-compose.yml"
release_file="$repo_root/pharos-release.json"
expected_image=$(service_image "$control_plane" pharosd)
immutable_pattern='^ghcr\.io/markus-barta/pharos/pharosd:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$'

jq -e '
  .schema == "inspr.pharos.fleet-release.v1"
  and (.version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
  and .tag == ("v" + .version)
  and .image == "ghcr.io/markus-barta/pharos/pharosd"
  and (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$"))
  and .reference == (.image + ":" + .version + "@" + .digest)
' "$release_file" >/dev/null || {
  printf 'pharos_rollout=failed reason=invalid_release_manifest\n' >&2
  exit 1
}

manifest_image=$(jq -r '.reference' "$release_file")

if [[ ! "$expected_image" =~ $immutable_pattern ]]; then
  printf 'pharos_rollout=failed reason=control_plane_pin_not_immutable\n' >&2
  exit 1
fi

if [[ "$expected_image" != "$manifest_image" ]]; then
  printf 'pharos_rollout=failed reason=control_plane_manifest_mismatch\n' >&2
  exit 1
fi

compose_files=(
  "$repo_root/hosts/csb0/docker/docker-compose.yml"
  "$repo_root/hosts/csb1/docker/docker-compose.yml"
  "$repo_root/hosts/gpc0/docker/docker-compose.yml"
  "$repo_root/hosts/hsb0/docker/docker-compose.yml"
  "$repo_root/hosts/hsb1/docker/docker-compose.yml"
  "$repo_root/hosts/hsb8/docker/docker-compose.yml"
  "$repo_root/hosts/hsb9/docker/docker-compose.yml"
)

for compose_file in "${compose_files[@]}"; do
  beacon_block=$(service_block "$compose_file" pharos-beacon)
  beacon_image=$(awk '$1 == "image:" { print $2; exit }' <<<"$beacon_block")

  if [[ "$beacon_image" != "$expected_image" ]]; then
    printf 'pharos_rollout=failed reason=mixed_release path=%s\n' \
      "${compose_file#"$repo_root/"}" >&2
    exit 1
  fi

  for required in \
    '    init: true' \
    '    read_only: true' \
    '      - ALL' \
    '      - no-new-privileges:true' \
    '    pids_limit: 64' \
    '    mem_limit: 256m' \
    '    cpus: "0.5"'; do
    if ! grep -Fqx -- "$required" <<<"$beacon_block"; then
      printf 'pharos_rollout=failed reason=runtime_guard_missing path=%s\n' \
        "${compose_file#"$repo_root/"}" >&2
      exit 1
    fi
  done

  if ! grep -Eq '^[[:space:]]+- "?com\.centurylinklabs\.watchtower\.enable=false"?$' \
    <<<"$beacon_block"; then
    printf 'pharos_rollout=failed reason=mutable_updater_enabled path=%s\n' \
      "${compose_file#"$repo_root/"}" >&2
    exit 1
  fi

  if [[ "$compose_file" == "$control_plane" ]]; then
    grep -Fqx '      - PHAROS_ADDR=0.0.0.0:8088' <<<"$beacon_block" || {
      printf 'pharos_rollout=failed reason=local_healthcheck_target_missing\n' >&2
      exit 1
    }
    if grep -Fq 'disable: true' <<<"$beacon_block"; then
      printf 'pharos_rollout=failed reason=control_plane_healthcheck_disabled\n' >&2
      exit 1
    fi
  elif ! grep -Fq $'    healthcheck:\n      disable: true' <<<"$beacon_block"; then
    printf 'pharos_rollout=failed reason=remote_healthcheck_not_disabled path=%s\n' \
      "${compose_file#"$repo_root/"}" >&2
    exit 1
  fi
done

printf 'pharos_rollout=passed beacons=%s release=%s\n' \
  "${#compose_files[@]}" "${expected_image%%@*}"
