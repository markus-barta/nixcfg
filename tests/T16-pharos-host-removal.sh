#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
prepare="$repo_root/scripts/prepare-pharos-host-removal.sh"
workflow="$repo_root/.github/workflows/pharos-host-removal.yml"
retirements="$repo_root/hosts/csb1/docker/janus/pharos-production/retired-hosts.json"
production_compose="$repo_root/hosts/csb1/docker/docker-compose.yml"

bash -n "$prepare"
"$repo_root/tests/T17-janus-pharos-retirement.sh" >/dev/null
"$repo_root/tests/T18-pharos-retirement-executor.sh" >/dev/null
grep -Fq 'scripts/prepare-pharos-host-removal.sh' "$workflow"
grep -Fq 'uses: peter-evans/create-pull-request@v8' "$workflow"
grep -Fq 'uses: actions/checkout@v5' "$workflow"
grep -Fq 'Validate and open review-only removal' "$workflow"
grep -Fq 'credential_retirement=pending_janus_owner' "$workflow"
grep -Fq 'server_deletion=false' "$workflow"
install_nix_line=$(grep -n -m1 -- '- name: Install Nix' "$workflow" | cut -d: -f1)
validate_line=$(grep -n -m1 -- '- name: Validate removal contract' "$workflow" | cut -d: -f1)
if [[ -z "$install_nix_line" || -z "$validate_line" || "$install_nix_line" -ge "$validate_line" ]]; then
  printf 'host removal workflow must install Nix before its contract validation\n' >&2
  exit 1
fi
if grep -Eq 'gh pr merge|merge validated|docker compose|nixos-rebuild|provider-delete' "$workflow"; then
  printf 'host removal workflow contains a forbidden apply or delete action\n' >&2
  exit 1
fi
grep -Fq 'PHAROS_HOST_REMOVAL_DISPATCH_ENABLED=1' "$production_compose"
grep -Fq 'PHAROS_RETIREMENT_OWNER_HOST=csb1' "$production_compose"

jq -e '
  .schema == "inspr.pharos.janus-retirements.v1"
  and .version == 1
  and (.retirements | type == "array")
' "$retirements" >/dev/null

fixture_root=$(mktemp -d)
cleanup() {
  rm -r "$fixture_root"
}
trap cleanup EXIT

make_fixture() {
  destination=$1
  mkdir -p "$destination/manifests"
  printf '%s\n' \
    'services:' \
    '  pharosd:' \
    '    environment:' \
    '      - PHAROS_MANIFEST_PATHS=/manifests/hsb8.json' \
    >"$destination/docker-compose.yml"
  jq -n '{
    schema: "inspr.pharos.host-preferences.v1",
    version: 1,
    hosts: {
      hsb8: {
        accent: "#e7a05f",
        kind: "server",
        alerts: {
          suppress_down: false,
          suppress_backup: false,
          suppress_nix_freshness: false
        }
      },
      gpc0: {
        accent: "#9868d0",
        kind: "workstation",
        alerts: {
          suppress_down: false,
          suppress_backup: false,
          suppress_nix_freshness: false
        }
      }
    }
  }' >"$destination/preferences.json"
  jq -n '{host: {name: "hsb8"}}' >"$destination/manifests/hsb8.json"
  jq -n '{
    schema: "inspr.pharos.janus-retirements.v1",
    version: 1,
    retirements: []
  }' >"$destination/retired-hosts.json"
}

run_prepare() {
  destination=$1
  shift
  PHAROS_REMOVAL_FIXTURE=1 \
    PHAROS_REMOVAL_REPO_ROOT="$destination" \
    PHAROS_REMOVAL_COMPOSE_FILE="$destination/docker-compose.yml" \
    PHAROS_REMOVAL_PREFERENCES_FILE="$destination/preferences.json" \
    PHAROS_REMOVAL_MANIFEST_DIR="$destination/manifests" \
    PHAROS_REMOVAL_RETIREMENTS_FILE="$destination/retired-hosts.json" \
    "$prepare" "$@" >/dev/null
}

success_fixture="$fixture_root/success"
make_fixture "$success_fixture"
run_prepare "$success_fixture" hsb8 unmanaged '' pharos-host-removal-hsb8-100-1
[[ ! -e "$success_fixture/manifests/hsb8.json" ]]
if grep -Fq 'PHAROS_MANIFEST_PATHS=/manifests/hsb8.json' "$success_fixture/docker-compose.yml"; then
  printf 'removed manifest remains declared in compose\n' >&2
  exit 1
fi
jq -e '.hosts.hsb8 == null' "$success_fixture/preferences.json" >/dev/null
jq -e '
  .retirements == [{
    credential_retirement_required: true,
    disposition: "unmanaged",
    host: "hsb8",
    server_deletion: false,
    successor: null
  }]
' "$success_fixture/retired-hosts.json" >/dev/null

rebuilt_fixture="$fixture_root/rebuilt"
make_fixture "$rebuilt_fixture"
run_prepare "$rebuilt_fixture" hsb8 rebuilt hsb9 pharos-host-removal-hsb8-101-1
jq -e '.retirements[0].successor == "hsb9"' "$rebuilt_fixture/retired-hosts.json" >/dev/null

preference_only_fixture="$fixture_root/preference-only"
make_fixture "$preference_only_fixture"
compose_before=$(shasum "$preference_only_fixture/docker-compose.yml")
run_prepare "$preference_only_fixture" gpc0 destroyed '' pharos-host-removal-gpc0-101-1
[[ "$compose_before" == "$(shasum "$preference_only_fixture/docker-compose.yml")" ]]
[[ -e "$preference_only_fixture/manifests/hsb8.json" ]]
jq -e '.hosts.gpc0 == null and .hosts.hsb8 != null' "$preference_only_fixture/preferences.json" >/dev/null
jq -e '
  .retirements == [{
    credential_retirement_required: true,
    disposition: "destroyed",
    host: "gpc0",
    server_deletion: false,
    successor: null
  }]
' "$preference_only_fixture/retired-hosts.json" >/dev/null

for case_name in invalid-host invalid-disposition missing-successor unexpected-successor invalid-request unknown-host; do
  fixture="$fixture_root/$case_name"
  make_fixture "$fixture"
  before=$(find "$fixture" -type f -print0 | sort -z | xargs -0 shasum)
  case "$case_name" in
  invalid-host) args=(../hsb8 unmanaged '' pharos-host-removal-hsb8-102-1) ;;
  invalid-disposition) args=(hsb8 deleted '' pharos-host-removal-hsb8-102-1) ;;
  missing-successor) args=(hsb8 rebuilt '' pharos-host-removal-hsb8-102-1) ;;
  unexpected-successor) args=(hsb8 unmanaged hsb9 pharos-host-removal-hsb8-102-1) ;;
  invalid-request) args=(hsb8 unmanaged '' request-102) ;;
  unknown-host) args=(unknown unmanaged '' pharos-host-removal-unknown-102-1) ;;
  esac
  if run_prepare "$fixture" "${args[@]}" 2>/dev/null; then
    printf '%s case was accepted\n' "$case_name" >&2
    exit 1
  fi
  after=$(find "$fixture" -type f -print0 | sort -z | xargs -0 shasum)
  [[ "$before" == "$after" ]] || {
    printf '%s failure changed the fixture\n' "$case_name" >&2
    exit 1
  }
done

printf 'pharos_host_removal=passed\n'
