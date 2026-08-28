#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  printf 'usage: %s VERSION NIXCFG_ROOT DSCCFG_ROOT\n' "${0##*/}" >&2
  exit 2
fi

version=$1
nixcfg_root=$2
dsccfg_root=$3
run_id=${GITHUB_RUN_ID:-}
output=${GITHUB_OUTPUT:-}

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'pharos_release_candidates=failed reason=invalid_version\n' >&2
  exit 1
fi
if [[ ! "$run_id" =~ ^[0-9]+$ ]]; then
  printf 'pharos_release_candidates=failed reason=invalid_run_id\n' >&2
  exit 1
fi
if [[ -z "$output" ]]; then
  printf 'pharos_release_candidates=failed reason=missing_github_output\n' >&2
  exit 1
fi

nixcfg_paths=(
  pharos-release.json
  hosts/csb0/docker/compose-spec.nix
  hosts/csb1/docker/compose-spec.nix
  hosts/csb1/docker/janus/managed-service-production/readiness.sh
  hosts/hsb0/docker/compose-spec.nix
  hosts/hsb1/docker/compose-spec.nix
  hosts/hsb8/docker/compose-spec.nix
  hosts/hsb9/docker/compose-spec.nix
)
dsccfg_paths=(
  pharos-release.json
  hosts/dsc0/docker/docker-compose.yml
)

validate_main_base() {
  local label=$1
  local root=$2
  local head
  local main

  head=$(git -C "$root" rev-parse HEAD)
  main=$(git -C "$root" rev-parse --verify refs/remotes/origin/main)
  if [[ "$head" != "$main" ]]; then
    printf 'pharos_release_candidates=failed reason=base_not_origin_main repo=%s\n' "$label" >&2
    exit 1
  fi
}

prepare_candidate() {
  local label=$1
  local root=$2
  local branch=$3
  local message=$4
  shift 4
  local -a allowed=("$@")
  local changed=false
  local path
  local sha

  git -C "$root" rev-parse --is-inside-work-tree >/dev/null
  if [[ -n "$(git -C "$root" diff --cached --name-only)" ]]; then
    printf 'pharos_release_candidates=failed reason=pre_staged_changes repo=%s\n' "$label" >&2
    exit 1
  fi

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if [[ ! " ${allowed[*]} " == *" $path "* ]]; then
      printf 'pharos_release_candidates=failed reason=unexpected_change repo=%s path=%s\n' \
        "$label" "$path" >&2
      exit 1
    fi
  done < <(git -C "$root" diff --name-only --diff-filter=ACMR)

  if [[ -n "$(git -C "$root" diff --name-only --diff-filter=ACMR)" ]]; then
    changed=true
    git -C "$root" config user.name 'Markus Barta'
    git -C "$root" config user.email 'markus@barta.com'
    git -C "$root" switch -c "$branch"
    git -C "$root" add -- "${allowed[@]}"
    git -C "$root" diff --cached --check
    git -C "$root" commit -m "$message"
  fi

  if [[ -n "$(git -C "$root" status --porcelain --untracked-files=no)" ]]; then
    printf 'pharos_release_candidates=failed reason=tracked_tree_not_clean repo=%s\n' "$label" >&2
    exit 1
  fi
  sha=$(git -C "$root" rev-parse HEAD)
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'pharos_release_candidates=failed reason=invalid_commit repo=%s\n' "$label" >&2
    exit 1
  fi

  printf '%s_changed=%s\n%s_branch=%s\n%s_sha=%s\n' \
    "$label" "$changed" "$label" "$branch" "$label" "$sha" >>"$output"
}

branch="automation/pharos-release-${version}-${run_id}"
validate_main_base dsc "$dsccfg_root"
validate_main_base nix "$nixcfg_root"
prepare_candidate \
  dsc \
  "$dsccfg_root" \
  "$branch" \
  "PHAROS-90: roll dsc0 beacon to Pharos ${version}" \
  "${dsccfg_paths[@]}"
prepare_candidate \
  nix \
  "$nixcfg_root" \
  "$branch" \
  "PHAROS-90: roll fleet to Pharos ${version}" \
  "${nixcfg_paths[@]}"

printf 'pharos_release_candidates=prepared version=%s\n' "$version"
