#!/usr/bin/env bash
set -euo pipefail

required=(
  VERSION
  NIXCFG_ROOT
  DSCCFG_ROOT
  NIXCFG_REPOSITORY
  DSCCFG_REPOSITORY
  NIX_CHANGED
  DSC_CHANGED
  NIX_BRANCH
  DSC_BRANCH
  NIX_SHA
  DSC_SHA
  GITHUB_OUTPUT
)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    printf 'pharos_release_publish=failed reason=missing_input name=%s\n' "$name" >&2
    exit 1
  fi
done

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  [[ ! "$NIX_SHA" =~ ^[0-9a-f]{40}$ ]] ||
  [[ ! "$DSC_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  printf 'pharos_release_publish=failed reason=invalid_input\n' >&2
  exit 1
fi
if [[ "$NIX_BRANCH" != "automation/pharos-release-${VERSION}" ]] ||
  [[ "$DSC_BRANCH" != "$NIX_BRANCH" ]]; then
  printf 'pharos_release_publish=failed reason=branch_mismatch\n' >&2
  exit 1
fi
for flag in "$NIX_CHANGED" "$DSC_CHANGED"; do
  if [[ "$flag" != true && "$flag" != false ]]; then
    printf 'pharos_release_publish=failed reason=invalid_change_flag\n' >&2
    exit 1
  fi
done

for tuple in "nix:$NIXCFG_ROOT:$NIX_SHA" "dsc:$DSCCFG_ROOT:$DSC_SHA"; do
  IFS=: read -r label root expected_sha <<<"$tuple"
  if [[ "$(git -C "$root" rev-parse HEAD)" != "$expected_sha" ]] ||
    [[ -n "$(git -C "$root" status --porcelain --untracked-files=no)" ]]; then
    printf 'pharos_release_publish=failed reason=unvalidated_commit repo=%s\n' "$label" >&2
    exit 1
  fi
done

if [[ "$NIX_CHANGED" == false && "$DSC_CHANGED" == false ]]; then
  printf 'nix_url=\ndsc_url=\n' >>"$GITHUB_OUTPUT"
  printf 'pharos_release_publish=unchanged version=%s\n' "$VERSION"
  exit 0
fi

title="PHAROS-90: roll fleet to Pharos ${VERSION}"

existing_proposal() {
  local label=$1
  local repository=$2
  local branch=$3
  local sha=$4
  local proposals
  local count
  local candidate
  local url
  local head_name
  local head_sha
  local base_name

  proposals=$(gh pr list \
    --repo "$repository" \
    --state open \
    --limit 100 \
    --json title,url,headRefName,headRefOid,baseRefName)
  count=$(jq --arg title "$title" '[.[] | select(.title == $title)] | length' <<<"$proposals")
  if [[ "$count" -gt 1 ]]; then
    printf 'pharos_release_publish=failed reason=duplicate_existing_proposals repo=%s\n' "$label" >&2
    return 1
  fi
  if [[ "$count" -eq 0 ]]; then
    return 0
  fi

  candidate=$(jq -r --arg title "$title" \
    '.[] | select(.title == $title) | [.url, .headRefName, .headRefOid, .baseRefName] | @tsv' \
    <<<"$proposals")
  IFS=$'\t' read -r url head_name head_sha base_name <<<"$candidate"
  if [[ "$head_name" != "$branch" || "$head_sha" != "$sha" || "$base_name" != main ]]; then
    printf 'pharos_release_publish=failed reason=stale_existing_proposal repo=%s\n' "$label" >&2
    return 1
  fi
  printf '%s\n' "$url"
}

nix_existing=""
dsc_existing=""
if [[ "$NIX_CHANGED" == true ]]; then
  nix_existing=$(existing_proposal nix "$NIXCFG_REPOSITORY" "$NIX_BRANCH" "$NIX_SHA")
fi
if [[ "$DSC_CHANGED" == true ]]; then
  dsc_existing=$(existing_proposal dsc "$DSCCFG_REPOSITORY" "$DSC_BRANCH" "$DSC_SHA")
fi
if [[ "$NIX_CHANGED" == true && "$DSC_CHANGED" == true ]] &&
  { [[ -n "$nix_existing" && -z "$dsc_existing" ]] ||
    [[ -z "$nix_existing" && -n "$dsc_existing" ]]; }; then
  printf 'pharos_release_publish=failed reason=existing_pair_incomplete\n' >&2
  exit 1
fi
if { [[ "$NIX_CHANGED" == false || -n "$nix_existing" ]] &&
  [[ "$DSC_CHANGED" == false || -n "$dsc_existing" ]]; }; then
  printf 'nix_url=%s\ndsc_url=%s\n' "$nix_existing" "$dsc_existing" >>"$GITHUB_OUTPUT"
  printf 'pharos_release_publish=reused version=%s\n' "$VERSION"
  exit 0
fi

preflight_branch_absent() {
  local label=$1
  local root=$2
  local changed=$3
  local branch=$4
  local remote_ref

  [[ "$changed" == true ]] || return 0
  remote_ref=$(git -C "$root" ls-remote --heads origin "refs/heads/$branch") || {
    printf 'pharos_release_publish=failed reason=branch_preflight_unavailable repo=%s\n' "$label" >&2
    return 1
  }
  if [[ -n "$remote_ref" ]]; then
    printf 'pharos_release_publish=failed reason=branch_collision repo=%s\n' "$label" >&2
    return 1
  fi
}

preflight_branch_absent nix "$NIXCFG_ROOT" "$NIX_CHANGED" "$NIX_BRANCH"
preflight_branch_absent dsc "$DSCCFG_ROOT" "$DSC_CHANGED" "$DSC_BRANCH"

nix_pr=""
dsc_pr=""
published=false

cleanup_partial_pair() {
  local exit_code=$?
  local cleanup_failed=false
  local branch
  local changed
  local proposals
  local discovered
  local expected_sha
  local label
  local known_pr
  local pr
  local repository
  local root
  local seen
  local state
  local remote_ref
  local remote_sha
  local status
  local tuple
  trap - EXIT
  if [[ "$published" == true ]]; then
    return 0
  fi
  set +e
  for tuple in \
    "nix|$NIX_CHANGED|$NIXCFG_ROOT|$NIXCFG_REPOSITORY|$NIX_BRANCH|$NIX_SHA|$nix_pr" \
    "dsc|$DSC_CHANGED|$DSCCFG_ROOT|$DSCCFG_REPOSITORY|$DSC_BRANCH|$DSC_SHA|$dsc_pr"; do
    IFS='|' read -r label changed root repository branch expected_sha known_pr <<<"$tuple"
    [[ "$changed" == true ]] || continue

    proposals=$(gh pr list \
      --repo "$repository" \
      --state open \
      --limit 100 \
      --json title,url,headRefName,headRefOid,baseRefName)
    status=$?
    if [[ $status -ne 0 ]]; then
      printf 'pharos_release_cleanup=failed action=discover_pr repo=%s\n' "$label" >&2
      cleanup_failed=true
      discovered=""
    else
      discovered=$(jq -r \
        --arg title "$title" \
        --arg branch "$branch" \
        --arg sha "$expected_sha" \
        '.[] | select(.title == $title and .headRefName == $branch and .headRefOid == $sha and .baseRefName == "main") | .url' \
        <<<"$proposals")
    fi
    [[ -z "$known_pr" ]] || discovered="${discovered:+${discovered}$'\n'}${known_pr}"
    seen=$'\n'
    while IFS= read -r pr; do
      [[ -n "$pr" ]] || continue
      [[ "$seen" != *$'\n'"$pr"$'\n'* ]] || continue
      seen+="$pr"$'\n'
      if ! gh pr close "$pr" --comment 'Closing incomplete paired release proposal; the transaction did not finish.'; then
        printf 'pharos_release_cleanup=failed action=close_pr repo=%s\n' "$label" >&2
        cleanup_failed=true
      fi
      state=$(gh pr view "$pr" --json state --jq .state)
      status=$?
      if [[ $status -ne 0 || "$state" != CLOSED ]]; then
        printf 'pharos_release_cleanup=failed action=verify_pr_closed repo=%s\n' "$label" >&2
        cleanup_failed=true
      fi
    done <<<"$discovered"

    remote_ref=$(git -C "$root" ls-remote --heads origin "refs/heads/$branch")
    status=$?
    if [[ $status -ne 0 ]]; then
      printf 'pharos_release_cleanup=failed action=discover_branch repo=%s\n' "$label" >&2
      cleanup_failed=true
      continue
    fi
    remote_sha=$(awk 'NR == 1 { print $1 }' <<<"$remote_ref")
    [[ -n "$remote_sha" ]] || continue
    if [[ "$remote_sha" != "$expected_sha" ]]; then
      printf 'pharos_release_cleanup=failed action=branch_head_mismatch repo=%s\n' "$label" >&2
      cleanup_failed=true
      continue
    fi
    if ! git -C "$root" push origin --delete "$branch"; then
      printf 'pharos_release_cleanup=failed action=delete_branch repo=%s\n' "$label" >&2
      cleanup_failed=true
    fi
    git -C "$root" ls-remote --exit-code --heads origin "refs/heads/$branch" >/dev/null
    status=$?
    if [[ $status -ne 2 ]]; then
      printf 'pharos_release_cleanup=failed action=verify_branch_absent repo=%s\n' "$label" >&2
      cleanup_failed=true
    fi
  done
  set -e
  if [[ "$cleanup_failed" == true ]]; then
    printf 'pharos_release_publish=failed reason=cleanup_incomplete\n' >&2
    exit 70
  fi
  printf 'pharos_release_publish=failed reason=partial_pair_cleaned\n' >&2
  exit "$exit_code"
}
trap cleanup_partial_pair EXIT

if [[ "$DSC_CHANGED" == true ]]; then
  git -C "$DSCCFG_ROOT" push --set-upstream origin "$DSC_BRANCH"
fi
if [[ "$NIX_CHANGED" == true ]]; then
  git -C "$NIXCFG_ROOT" push --set-upstream origin "$NIX_BRANCH"
fi

if [[ "$DSC_CHANGED" == true ]]; then
  dsc_body="Paired immutable Pharos ${VERSION} fleet release proposal. This change does not deploy or restart dsc0."
  if [[ "$NIX_CHANGED" == false ]]; then
    dsc_body+=$'\n\nThe validated nixcfg main commit is already aligned to this release.'
  fi
  dsc_pr=$(
    gh pr create \
      --repo "$DSCCFG_REPOSITORY" \
      --base main \
      --head "$DSC_BRANCH" \
      --title "$title" \
      --body "$dsc_body"
  )
  [[ "$dsc_pr" == https://* ]]
fi
if [[ "$NIX_CHANGED" == true ]]; then
  nix_body="Paired immutable Pharos ${VERSION} fleet release proposal. This change does not deploy or restart any host."
  if [[ -n "$dsc_pr" ]]; then
    nix_body+=$'\n\n'"Paired dsccfg proposal: ${dsc_pr}"
  else
    nix_body+=$'\n\n'"The validated dsccfg main commit is already aligned to this release."
  fi
  nix_pr=$(
    gh pr create \
      --repo "$NIXCFG_REPOSITORY" \
      --base main \
      --head "$NIX_BRANCH" \
      --title "$title" \
      --body "$nix_body"
  )
  [[ "$nix_pr" == https://* ]]
fi
if [[ -n "$dsc_pr" && -n "$nix_pr" ]]; then
  gh pr comment "$dsc_pr" --body "Paired nixcfg proposal: ${nix_pr}"
fi

printf 'nix_url=%s\ndsc_url=%s\n' "$nix_pr" "$dsc_pr" >>"$GITHUB_OUTPUT"
published=true
trap - EXIT
printf 'pharos_release_publish=passed version=%s\n' "$VERSION"
