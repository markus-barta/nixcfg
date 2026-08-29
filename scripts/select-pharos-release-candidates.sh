#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
  printf 'usage: %s VERSION REFERENCE NIXCFG_ROOT DSCCFG_ROOT OUTPUT\n' "${0##*/}" >&2
  exit 2
fi

version=$1
reference=$2
nixcfg_root=$3
dsccfg_root=$4
output=$5
title="PHAROS-90: roll fleet to Pharos ${version}"
branch="automation/pharos-release-${version}"

for name in NIXCFG_REPOSITORY DSCCFG_REPOSITORY; do
  if [[ -z "${!name:-}" ]]; then
    printf 'pharos_release_existing=failed reason=missing_input name=%s\n' "$name" >&2
    exit 1
  fi
done
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  [[ ! "$reference" =~ ^ghcr\.io/inspr-at/pharos/pharosd:${version}@sha256:[0-9a-f]{64}$ ]]; then
  printf 'pharos_release_existing=failed reason=invalid_input\n' >&2
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

proposal_row() {
  local label=$1
  local repository=$2
  local proposals
  local count

  proposals=$(gh pr list \
    --repo "$repository" \
    --state open \
    --limit 100 \
    --json title,url,headRefName,headRefOid,baseRefName)
  count=$(jq --arg title "$title" '[.[] | select(.title == $title)] | length' <<<"$proposals")
  if [[ "$count" -gt 1 ]]; then
    printf 'pharos_release_existing=failed reason=duplicate_proposals repo=%s\n' "$label" >&2
    return 1
  fi
  if [[ "$count" -eq 1 ]]; then
    jq -r --arg title "$title" \
      '.[] | select(.title == $title) | [.url, .headRefName, .headRefOid, .baseRefName] | @tsv' \
      <<<"$proposals"
  fi
}

validate_main() {
  local label=$1
  local root=$2
  local head
  local main

  head=$(git -C "$root" rev-parse HEAD)
  main=$(git -C "$root" rev-parse --verify refs/remotes/origin/main)
  if [[ "$head" != "$main" ]] ||
    [[ -n "$(git -C "$root" status --porcelain --untracked-files=no)" ]]; then
    printf 'pharos_release_existing=failed reason=main_checkout_not_clean repo=%s\n' "$label" >&2
    exit 1
  fi
}

validate_proposal() {
  local label=$1
  local root=$2
  local row=$3
  shift 3
  local -a allowed=("$@")
  local url
  local head_branch
  local sha
  local base
  local fetched
  local path
  local changed=false

  IFS=$'\t' read -r url head_branch sha base <<<"$row"
  if [[ "$head_branch" != "$branch" || "$base" != main || ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'pharos_release_existing=failed reason=proposal_identity_mismatch repo=%s\n' "$label" >&2
    exit 1
  fi
  git -C "$root" fetch --no-tags origin "refs/heads/$head_branch"
  fetched=$(git -C "$root" rev-parse FETCH_HEAD)
  if [[ "$fetched" != "$sha" ]]; then
    printf 'pharos_release_existing=failed reason=proposal_head_mismatch repo=%s\n' "$label" >&2
    exit 1
  fi
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    changed=true
    if [[ ! " ${allowed[*]} " == *" $path "* ]]; then
      printf 'pharos_release_existing=failed reason=proposal_path_out_of_scope repo=%s path=%s\n' \
        "$label" "$path" >&2
      exit 1
    fi
  done < <(git -C "$root" diff --name-only "refs/remotes/origin/main...$sha")
  if [[ "$changed" != true ]] ||
    ! git -C "$root" diff --name-only "refs/remotes/origin/main...$sha" | grep -Fxq pharos-release.json; then
    printf 'pharos_release_existing=failed reason=proposal_missing_release_change repo=%s\n' "$label" >&2
    exit 1
  fi
  git -C "$root" checkout --detach "$sha"
  if [[ -n "$(git -C "$root" status --porcelain --untracked-files=no)" ]] ||
    [[ "$(jq -r .reference "$root/pharos-release.json")" != "$reference" ]]; then
    printf 'pharos_release_existing=failed reason=proposal_reference_mismatch repo=%s\n' "$label" >&2
    exit 1
  fi

  printf '%s_changed=true\n%s_branch=%s\n%s_sha=%s\n%s_url=%s\n' \
    "$label" "$label" "$branch" "$label" "$sha" "$label" "$url" >>"$output"
}

validate_aligned_main() {
  local label=$1
  local root=$2
  local sha

  if [[ "$(jq -r .reference "$root/pharos-release.json")" != "$reference" ]]; then
    printf 'pharos_release_existing=failed reason=existing_pair_incomplete repo=%s\n' "$label" >&2
    exit 1
  fi
  sha=$(git -C "$root" rev-parse HEAD)
  printf '%s_changed=false\n%s_branch=%s\n%s_sha=%s\n%s_url=\n' \
    "$label" "$label" "$branch" "$label" "$sha" "$label" >>"$output"
}

validate_main nix "$nixcfg_root"
validate_main dsc "$dsccfg_root"
nix_row=$(proposal_row nix "$NIXCFG_REPOSITORY")
dsc_row=$(proposal_row dsc "$DSCCFG_REPOSITORY")

if [[ -z "$nix_row" && -z "$dsc_row" ]]; then
  printf 'reused=false\n' >>"$output"
  printf 'pharos_release_existing=none version=%s\n' "$version"
  exit 0
fi

if [[ -n "$nix_row" ]]; then
  validate_proposal nix "$nixcfg_root" "$nix_row" "${nixcfg_paths[@]}"
else
  validate_aligned_main nix "$nixcfg_root"
fi
if [[ -n "$dsc_row" ]]; then
  validate_proposal dsc "$dsccfg_root" "$dsc_row" "${dsccfg_paths[@]}"
else
  validate_aligned_main dsc "$dsccfg_root"
fi
printf 'reused=true\n' >>"$output"
printf 'pharos_release_existing=reused version=%s\n' "$version"
