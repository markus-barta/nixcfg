#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mutation_host=""
mutation_shape=""
sigpipe_self_test=false
if [[ "${1:-}" == "--self-test-sigpipe" ]]; then
  sigpipe_self_test=true
elif [[ "${1:-}" == "--inject-disabled-healthcheck=csb0" ]]; then
  mutation_host="csb0"
  mutation_shape="nested"
elif [[ "${1:-}" == "--inject-dotted-disabled-healthcheck=csb0" ]]; then
  mutation_host="csb0"
  mutation_shape="dotted"
elif [[ "${1:-}" == "--inject-quoted-disabled-healthcheck=csb0" ]]; then
  mutation_host="csb0"
  mutation_shape="quoted"
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

if [[ "$sigpipe_self_test" == true ]]; then
  large_service_fixture() {
    awk 'BEGIN {
      print "    pharosd = {"
      print "      image = \"ghcr.io/inspr-at/pharos/pharosd:1.2.3@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\";"
      for (line = 0; line < 131072; line++) {
        print "      # pipe-buffer-padding-" line
      }
      print "    };"
    }'
  }

  expected_fixture_image='ghcr.io/inspr-at/pharos/pharosd:1.2.3@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  fixture_image=""
  if ! fixture_image=$(service_image <(large_service_fixture) pharosd); then
    printf 'pharos_rollout_sigpipe=failed reason=image_reader_did_not_drain_input\n' >&2
    exit 1
  fi
  if [[ "$fixture_image" != "$expected_fixture_image" ]]; then
    printf 'pharos_rollout_sigpipe=failed reason=fixture_image_mismatch\n' >&2
    exit 1
  fi

  printf 'pharos_rollout_sigpipe=passed fixture_lines=131072\n'
  exit 0
fi

control_plane="$repo_root/hosts/csb1/docker/compose-spec.nix"
release_file="$repo_root/pharos-release.json"
rollout_workflow="$repo_root/.github/workflows/pharos-release-rollout.yml"
candidate_prepare="$repo_root/scripts/prepare-pharos-release-candidates.sh"
candidate_select="$repo_root/scripts/select-pharos-release-candidates.sh"
candidate_publish="$repo_root/scripts/publish-pharos-release-candidates.sh"
expected_image=$(service_image "$control_plane" pharosd)
immutable_pattern='^ghcr\.io/inspr-at/pharos/pharosd:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$'

grep -Fq 'name: Resolve the public immutable image digest' "$rollout_workflow"
grep -Fq 'image=ghcr.io/inspr-at/pharos/pharosd' "$rollout_workflow"
grep -Fq 'tests/T32-managed-secret-production-preflight.sh' "$rollout_workflow"
grep -Fq 'scripts/prepare-pharos-release-candidates.sh' "$rollout_workflow"
grep -Fq 'scripts/publish-pharos-release-candidates.sh' "$rollout_workflow"
grep -Fq \
  'hosts/csb1/docker/janus/managed-service-production/readiness.sh' \
  "$rollout_workflow" "$candidate_prepare"
for compose_spec in \
  hosts/csb0/docker/compose-spec.nix \
  hosts/csb1/docker/compose-spec.nix \
  hosts/hsb0/docker/compose-spec.nix \
  hosts/hsb1/docker/compose-spec.nix \
  hosts/hsb8/docker/compose-spec.nix \
  hosts/hsb9/docker/compose-spec.nix; do
  grep -Fq "$compose_spec" "$rollout_workflow" "$candidate_prepare" || {
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
if grep -Eiq 'dsccfg|dsc0' \
  "$rollout_workflow" "$candidate_prepare" "$candidate_select" "$candidate_publish"; then
  printf 'pharos_rollout=failed reason=retired_dsc0_coordination_present\n' >&2
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
bootstrap_image=$(
  nix eval --raw \
    .#nixosConfigurations.csb1.config.inspr.pharosProvisioningExecutor.beaconImage
)

if [[ ! "$expected_image" =~ $immutable_pattern ]]; then
  printf 'pharos_rollout=failed reason=control_plane_pin_not_immutable\n' >&2
  exit 1
fi

if [[ "$expected_image" != "$manifest_image" ]]; then
  printf 'pharos_rollout=failed reason=control_plane_manifest_mismatch\n' >&2
  exit 1
fi
if [[ "$bootstrap_image" != "$manifest_image" ]]; then
  printf 'pharos_rollout=failed reason=bootstrap_manifest_mismatch\n' >&2
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
    if [[ "$mutation_shape" == "nested" ]]; then
      beacon_block+=$'\n      healthcheck = {\n        disable = true;\n      };'
    elif [[ "$mutation_shape" == "dotted" ]]; then
      beacon_block+=$'\n      healthcheck.disable = true;'
    elif [[ "$mutation_shape" == "quoted" ]]; then
      beacon_block+=$'\n      "healthcheck" = {\n        disable = true;\n      };'
    else
      printf 'pharos_rollout=failed reason=unsupported_mutation_shape\n' >&2
      exit 1
    fi
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

  if grep -Eq '^      ("healthcheck"|healthcheck)([[:space:]]*=|\.)' \
    <<<"$beacon_block"; then
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
  sigpipe_output=$(bash "$0" --self-test-sigpipe)
  if [[ "$sigpipe_output" != 'pharos_rollout_sigpipe=passed fixture_lines=131072' ]]; then
    printf 'pharos_rollout=failed reason=sigpipe_self_test_wrong_verdict\n' >&2
    exit 1
  fi
  printf '%s\n' "$sigpipe_output"

  for mutation in \
    --inject-disabled-healthcheck=csb0 \
    --inject-dotted-disabled-healthcheck=csb0 \
    --inject-quoted-disabled-healthcheck=csb0; do
    mutation_output=""
    if mutation_output=$(bash "$0" "$mutation" 2>&1); then
      printf 'pharos_rollout=failed reason=healthcheck_mutation_accepted mutation=%s\n' \
        "$mutation" >&2
      exit 1
    fi

    expected='pharos_rollout=failed reason=beacon_healthcheck_overridden path=hosts/csb0/docker/compose-spec.nix'
    if [[ "$mutation_output" != *"$expected"* ]]; then
      printf 'pharos_rollout=failed reason=healthcheck_mutation_wrong_verdict mutation=%s\n' \
        "$mutation" >&2
      exit 1
    fi

    printf 'pharos_rollout_healthcheck_mutation=passed mutation=%s\n' "$mutation"
  done
fi
