#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mutation_host=""
if [[ "${1:-}" == "--inject-disabled-healthcheck=csb0" ]]; then
  mutation_host="csb0"
elif [[ $# -ne 0 ]]; then
  printf 'pharos_rollout=failed reason=invalid_argument\n' >&2
  exit 1
fi

# OPS-127: reads the pin from the compose SPEC (ymls retired). Single awk over
# the file -- no producer pipe, so the NIX-337 SIGPIPE race is structurally
# impossible here (the old service_block|awk-exit pattern died with the yml).
service_block() {
  awk -v heading="    ${2} = {" '
    $0 == heading { found = 1 }
    found { print }
    found && $0 == "    };" { found = 0 }
  ' "$1"
}

service_image() {
  awk -v heading="    ${2} = {" '
    $0 == heading { found = 1 }
    found && /^      image = "/ {
      gsub(/^      image = "|";$/, ""); print; found = 0
    }
    found && $0 == "    };" { found = 0 }
  ' "$1"
}

control_plane="$repo_root/hosts/csb1/docker/compose-spec.nix"
release_file="$repo_root/pharos-release.json"
rollout_workflow="$repo_root/.github/workflows/pharos-release-rollout.yml"
expected_image=$(service_image "$control_plane" pharosd)
immutable_pattern='^ghcr\.io/inspr-at/pharos/pharosd:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$'

grep -Fq 'name: Resolve the public immutable image digest' "$rollout_workflow"
grep -Fq 'image=ghcr.io/inspr-at/pharos/pharosd' "$rollout_workflow"
grep -Fq 'DSCCFG_REPOSITORY: inspr-at/dsccfg' "$rollout_workflow"
grep -Fq 'tests/T32-managed-secret-production-preflight.sh' "$rollout_workflow"
grep -Fq \
  'hosts/csb1/docker/janus/managed-service-production/readiness.sh' \
  "$rollout_workflow"
for compose_spec in \
  hosts/csb0/docker/compose-spec.nix \
  hosts/csb1/docker/compose-spec.nix \
  hosts/hsb0/docker/compose-spec.nix \
  hosts/hsb1/docker/compose-spec.nix \
  hosts/hsb8/docker/compose-spec.nix \
  hosts/hsb9/docker/compose-spec.nix; do
  grep -Fq "$compose_spec" "$rollout_workflow" || {
    printf 'pharos_rollout=failed reason=workflow_missing_compose_spec path=%s\n' \
      "$compose_spec" >&2
    exit 1
  }
done
if grep -Eq 'hosts/(csb0|csb1|hsb0|hsb1|hsb8|hsb9)/docker/docker-compose\.yml' \
  "$rollout_workflow"; then
  printf 'pharos_rollout=failed reason=workflow_stages_retired_compose_yml\n' >&2
  exit 1
fi
if grep -Fq 'markus-barta/dsccfg' "$rollout_workflow"; then
  printf 'pharos_rollout=failed reason=legacy_dsccfg_owner\n' >&2
  exit 1
fi
if grep -Fq 'Authenticate to the private Pharos package' "$rollout_workflow" ||
  grep -Fq "password: \${{ secrets.GH_TOKEN_FOR_UPDATES }}" "$rollout_workflow"; then
  printf 'pharos_rollout=failed reason=public_registry_uses_private_credential\n' >&2
  exit 1
fi

jq -e '
  .schema == "inspr.pharos.fleet-release.v1"
  and (.version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
  and .tag == ("v" + .version)
  and .image == "ghcr.io/inspr-at/pharos/pharosd"
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
  "$repo_root/hosts/csb0/docker/compose-spec.nix"
  "$repo_root/hosts/csb1/docker/compose-spec.nix"
  "$repo_root/hosts/hsb0/docker/compose-spec.nix"
  "$repo_root/hosts/hsb1/docker/compose-spec.nix"
  "$repo_root/hosts/hsb8/docker/compose-spec.nix"
  "$repo_root/hosts/hsb9/docker/compose-spec.nix"
)

for compose_file in "${compose_files[@]}"; do
  beacon_block=$(service_block "$compose_file" pharos-beacon)
  host=$(basename "$(dirname "$(dirname "$compose_file")")")
  if [[ "$mutation_host" == "$host" ]]; then
    beacon_block+=$'\n      healthcheck = {\n        disable = true;\n      };'
  fi
  beacon_image=$(awk '/^      image = "/ { gsub(/^      image = "|";$/, ""); print; exit }' <<<"$beacon_block")

  if [[ "$beacon_image" != "$expected_image" ]]; then
    printf 'pharos_rollout=failed reason=mixed_release path=%s\n' \
      "${compose_file#"$repo_root/"}" >&2
    exit 1
  fi

  for required in \
    '      init = true;' \
    '      read_only = true;' \
    '        "ALL"' \
    '        "no-new-privileges:true"' \
    '      pids_limit = 64;' \
    '      mem_limit = "256m";' \
    '      cpus = "0.5";'; do
    if ! grep -Fqx -- "$required" <<<"$beacon_block"; then
      printf 'pharos_rollout=failed reason=runtime_guard_missing path=%s\n' \
        "${compose_file#"$repo_root/"}" >&2
      exit 1
    fi
  done

  if ! grep -Eq '^[[:space:]]+"com\.centurylinklabs\.watchtower\.enable=false"' \
    <<<"$beacon_block"; then
    printf 'pharos_rollout=failed reason=mutable_updater_enabled path=%s\n' \
      "${compose_file#"$repo_root/"}" >&2
    exit 1
  fi

  if grep -Eq '^      healthcheck[[:space:]]*=' <<<"$beacon_block"; then
    printf 'pharos_rollout=failed reason=beacon_healthcheck_overridden path=%s\n' \
      "${compose_file#"$repo_root/"}" >&2
    exit 1
  fi

  for required in \
    '        "PHAROS_URL=http://100.64.0.4:8088"' \
    '        "PHAROS_INTERVAL=60"'; do
    if ! grep -Fqx -- "$required" <<<"$beacon_block"; then
      printf 'pharos_rollout=failed reason=beacon_health_contract_missing path=%s\n' \
        "${compose_file#"$repo_root/"}" >&2
      exit 1
    fi
  done
done

printf 'pharos_rollout=passed beacons=%s release=%s\n' \
  "${#compose_files[@]}" "${expected_image%%@*}"

if [[ -z "$mutation_host" ]]; then
  mutation_output=""
  if mutation_output=$(bash "$0" --inject-disabled-healthcheck=csb0 2>&1); then
    printf 'pharos_rollout=failed reason=healthcheck_mutation_accepted path=hosts/csb0/docker/compose-spec.nix\n' >&2
    exit 1
  fi

  expected='pharos_rollout=failed reason=beacon_healthcheck_overridden path=hosts/csb0/docker/compose-spec.nix'
  if [[ "$mutation_output" != *"$expected"* ]]; then
    printf 'pharos_rollout=failed reason=healthcheck_mutation_wrong_verdict path=hosts/csb0/docker/compose-spec.nix\n' >&2
    exit 1
  fi

  printf 'pharos_rollout_healthcheck_mutation=passed path=hosts/csb0/docker/compose-spec.nix\n'
fi
