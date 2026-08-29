#!/usr/bin/env bash
# shellcheck disable=SC2016 # GitHub expressions and shell assertions are matched literally.
set -euo pipefail

if [[ ${BASH_VERSINFO[0]} -lt 4 ]]; then
  printf '%s: bash %s is too old; run under bash 5\n' "${0##*/}" "$BASH_VERSION" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
select_existing="$repo_root/scripts/select-pharos-release-candidates.sh"
prepare="$repo_root/scripts/prepare-pharos-release-candidates.sh"
publish="$repo_root/scripts/publish-pharos-release-candidates.sh"
workflow="$repo_root/.github/workflows/pharos-release-rollout.yml"
infrastructure="$repo_root/docs/INFRASTRUCTURE.md"

bash -n "$select_existing"
bash -n "$prepare"
bash -n "$publish"

grep -Fq '`automation/pharos-release-<version>-<run_id>` proposals are never reusable.' \
  "$infrastructure"
grep -Fq 'Leaving a legacy proposal open makes selection fail closed' "$infrastructure"
grep -Fq 'historical branches. Leaving a legacy proposal open' "$infrastructure"

fixture_root=$(mktemp -d)
cleanup() {
  find "$fixture_root" -type f -delete
  find "$fixture_root" -type l -delete
  find "$fixture_root" -depth -type d -exec rmdir '{}' \;
}
trap cleanup EXIT

validate_workflow_contract() {
  local candidate=$1
  local prepare_line
  local validate_line
  local publish_line
  local signature_line
  local select_line
  local update_line
  local validate_block

  prepare_line=$(grep -n -m1 'Prepare clean local release candidates' "$candidate" | cut -d: -f1)
  validate_line=$(grep -n -m1 'Validate the exact committed candidates' "$candidate" | cut -d: -f1)
  publish_line=$(grep -n -m1 'Publish both validated proposals transactionally' "$candidate" | cut -d: -f1)
  signature_line=$(grep -n -m1 'Verify the release signature and workflow identity' "$candidate" | cut -d: -f1)
  select_line=$(grep -n -m1 'Select an exact existing proposal pair' "$candidate" | cut -d: -f1)
  update_line=$(grep -n -m1 'Prepare both repositories from the same digest' "$candidate" | cut -d: -f1)
  [[ -n "$signature_line" && -n "$select_line" && -n "$update_line" && -n "$prepare_line" &&
    -n "$validate_line" && -n "$publish_line" ]] || return 1
  [[ "$signature_line" -lt "$select_line" && "$select_line" -lt "$update_line" &&
    "$update_line" -lt "$prepare_line" && "$prepare_line" -lt "$validate_line" &&
    "$validate_line" -lt "$publish_line" ]] || return 1

  validate_block=$(awk '
    /- name: Validate the exact committed candidates/ { found = 1 }
    found && /^      - name:/ && !/Validate the exact committed candidates/ { exit }
    found { print }
  ' "$candidate")
  ! grep -Eq '^        if:' <<<"$validate_block" || return 1
  grep -Fq 'DSC_SHA: ${{ steps.existing.outputs.dsc_sha || steps.prepared.outputs.dsc_sha }}' \
    <<<"$validate_block" || return 1
  grep -Fq 'NIX_SHA: ${{ steps.existing.outputs.nix_sha || steps.prepared.outputs.nix_sha }}' \
    <<<"$validate_block" || return 1
  grep -Fq '[[ "$(git rev-parse HEAD)" == "$NIX_SHA" ]]' <<<"$validate_block" || return 1
  grep -Fq '[[ "$(git -C _release-dsccfg rev-parse HEAD)" == "$DSC_SHA" ]]' \
    <<<"$validate_block" || return 1
  grep -Fq '[[ -z "$(git status --porcelain --untracked-files=no)" ]]' \
    <<<"$validate_block" || return 1
  grep -Fq '[[ -z "$(git -C _release-dsccfg status --porcelain --untracked-files=no)" ]]' \
    <<<"$validate_block" || return 1
  grep -Fq 'tests/T20-pharos-beacon-healthcheck.sh' <<<"$validate_block" || return 1
  grep -Fq 'tests/T21-pharos-release-rollout.sh' <<<"$validate_block" || return 1
  grep -Fq 'tests/T22-pharos-release-update.sh' <<<"$validate_block" || return 1
  grep -Fq 'tests/T32-managed-secret-production-preflight.sh' <<<"$validate_block" || return 1
  grep -Fq '_release-dsccfg/tests/pharos-release-rollout.sh' <<<"$validate_block" || return 1
  grep -Fq '_release-dsccfg/tests/pharos-release-update.sh' <<<"$validate_block" || return 1
}

validate_workflow_contract "$workflow" || {
  printf 'pharos_release_proposals=failed reason=workflow_contract\n' >&2
  exit 1
}
workflow_if_mutant="$fixture_root/workflow-if-mutant.yml"
while IFS= read -r line; do
  printf '%s\n' "$line"
  if [[ "$line" == *'- name: Validate the exact committed candidates' ]]; then
    printf "        if: steps.existing.outputs.reused != 'true'\n"
  fi
done <"$workflow" >"$workflow_if_mutant"
if validate_workflow_contract "$workflow_if_mutant"; then
  printf 'pharos_release_proposals=failed reason=conditional_validation_mutant_survived\n' >&2
  exit 1
fi
workflow_assert_mutant="$fixture_root/workflow-assert-mutant.yml"
while IFS= read -r line; do
  case "$line" in
  *'git rev-parse HEAD'*NIX_SHA* | *'_release-dsccfg rev-parse HEAD'*DSC_SHA* | \
    *'git status --porcelain --untracked-files=no'* | \
    *'_release-dsccfg status --porcelain --untracked-files=no'*)
    printf '          true\n'
    ;;
  *) printf '%s\n' "$line" ;;
  esac
done <"$workflow" >"$workflow_assert_mutant"
if validate_workflow_contract "$workflow_assert_mutant"; then
  printf 'pharos_release_proposals=failed reason=exact_validation_mutant_survived\n' >&2
  exit 1
fi

grep -Fq 'scripts/prepare-pharos-release-candidates.sh' "$workflow"
grep -Fq 'scripts/publish-pharos-release-candidates.sh' "$workflow"
grep -Fq 'scripts/select-pharos-release-candidates.sh' "$workflow"
grep -Fq 'Verify the release signature and workflow identity' "$workflow"
awk '
  /- name: Checkout nixcfg/ { in_checkout = 1 }
  in_checkout && /ref: main/ { found = 1 }
  in_checkout && /- name: Checkout dsccfg/ { exit }
  END { exit !found }
' "$workflow"
grep -Fq 'refs/remotes/origin/main' "$prepare"
if grep -Eq 'git push|gh pr create' "$workflow"; then
  printf 'pharos_release_proposals=failed reason=untransactional_publish_in_workflow\n' >&2
  exit 1
fi

nix_changed=""
dsc_changed=""
nix_branch=""
dsc_branch=""
nix_sha=""
dsc_sha=""
reused=""
fixture_reference='ghcr.io/inspr-at/pharos/pharosd:9.8.7@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

fake_bin="$fixture_root/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_GH_LOG"

if [[ "$1 $2" == 'pr list' ]]; then
  repo=''
  while [[ $# -gt 0 ]]; do
    if [[ $1 == --repo ]]; then
      repo=$2
      break
    fi
    shift
  done
  if grep -Fxq "$repo" "$FAKE_GH_STATE"; then
    if [[ "$repo" == example/nixcfg ]]; then
      sha=$FAKE_NIX_SHA
    elif [[ "$repo" == example/dsccfg ]]; then
      sha=$FAKE_DSC_SHA
    else
      exit 2
    fi
    if [[ "${FAKE_GH_INCLUDE_FOREIGN:-false}" == true ]]; then
      printf '[{"title":"PHAROS-90: roll fleet to Pharos 9.8.7","url":"https://example.invalid/%s/pull/1","headRefName":"%s","headRefOid":"%s","baseRefName":"main"},{"title":"PHAROS-90: roll fleet to Pharos 9.8.7","url":"https://example.invalid/%s/pull/foreign","headRefName":"foreign-branch","headRefOid":"0000000000000000000000000000000000000000","baseRefName":"other"}]\n' \
        "$repo" "$FAKE_BRANCH" "$sha" "$repo"
    else
      printf '[{"title":"PHAROS-90: roll fleet to Pharos 9.8.7","url":"https://example.invalid/%s/pull/1","headRefName":"%s","headRefOid":"%s","baseRefName":"main"}]\n' \
        "$repo" "$FAKE_BRANCH" "$sha"
    fi
    exit 0
  fi
  case "${FAKE_GH_LIST_MODE:-empty}" in
    empty)
      printf '[]\n'
      ;;
    exact)
      if [[ "$repo" == example/nixcfg ]]; then
        sha=$FAKE_NIX_SHA
      elif [[ "$repo" == example/dsccfg ]]; then
        sha=$FAKE_DSC_SHA
      else
        exit 2
      fi
      printf '[{"title":"PHAROS-90: roll fleet to Pharos 9.8.7","url":"https://example.invalid/%s/pull/9","headRefName":"%s","headRefOid":"%s","baseRefName":"main"}]\n' \
        "$repo" "$FAKE_BRANCH" "$sha"
      ;;
    nix-exact)
      if [[ "$repo" == example/nixcfg ]]; then
        printf '[{"title":"PHAROS-90: roll fleet to Pharos 9.8.7","url":"https://example.invalid/%s/pull/9","headRefName":"%s","headRefOid":"%s","baseRefName":"main"}]\n' \
          "$repo" "$FAKE_BRANCH" "$FAKE_NIX_SHA"
      else
        printf '[]\n'
      fi
      ;;
    wrong-title)
      if [[ "$repo" == example/nixcfg ]]; then sha=$FAKE_NIX_SHA; else sha=$FAKE_DSC_SHA; fi
      printf '[{"title":"PHAROS-90: unrelated title","url":"https://example.invalid/%s/pull/8","headRefName":"%s","headRefOid":"%s","baseRefName":"main"}]\n' \
        "$repo" "$FAKE_BRANCH" "$sha"
      ;;
    wrong-base)
      if [[ "$repo" == example/nixcfg ]]; then sha=$FAKE_NIX_SHA; else sha=$FAKE_DSC_SHA; fi
      printf '[{"title":"PHAROS-90: roll fleet to Pharos 9.8.7","url":"https://example.invalid/%s/pull/8","headRefName":"%s","headRefOid":"%s","baseRefName":"other"}]\n' \
        "$repo" "$FAKE_BRANCH" "$sha"
      ;;
    wrong-branch)
      if [[ "$repo" == example/nixcfg ]]; then sha=$FAKE_NIX_SHA; else sha=$FAKE_DSC_SHA; fi
      printf '[{"title":"PHAROS-90: roll fleet to Pharos 9.8.7","url":"https://example.invalid/%s/pull/8","headRefName":"stale-branch","headRefOid":"%s","baseRefName":"main"}]\n' \
        "$repo" "$sha"
      ;;
    wrong-head)
      printf '[{"title":"PHAROS-90: roll fleet to Pharos 9.8.7","url":"https://example.invalid/%s/pull/8","headRefName":"%s","headRefOid":"0000000000000000000000000000000000000000","baseRefName":"main"}]\n' \
        "$repo" "$FAKE_BRANCH"
      ;;
    duplicate)
      if [[ "$repo" == example/nixcfg ]]; then sha=$FAKE_NIX_SHA; else sha=$FAKE_DSC_SHA; fi
      printf '[{"title":"PHAROS-90: roll fleet to Pharos 9.8.7","url":"https://example.invalid/%s/pull/8","headRefName":"%s","headRefOid":"%s","baseRefName":"main"},{"title":"PHAROS-90: roll fleet to Pharos 9.8.7","url":"https://example.invalid/%s/pull/9","headRefName":"%s","headRefOid":"%s","baseRefName":"main"}]\n' \
        "$repo" "$FAKE_BRANCH" "$sha" "$repo" "$FAKE_BRANCH" "$sha"
      ;;
    *)
      exit 2
      ;;
  esac
  exit 0
fi
if [[ "$1 $2" == 'pr create' ]]; then
  repo=''
  while [[ $# -gt 0 ]]; do
    if [[ $1 == --repo ]]; then
      repo=$2
      break
    fi
    shift
  done
  if [[ -n "${FAKE_GH_FAIL_REPO:-}" && "$repo" == "$FAKE_GH_FAIL_REPO" ]]; then
    exit 42
  fi
  printf '%s\n' "$repo" >>"$FAKE_GH_STATE"
  if [[ -n "${FAKE_GH_MUTATE_BRANCH_REPO:-}" && "$repo" == "$FAKE_GH_MUTATE_BRANCH_REPO" ]]; then
    if [[ "$repo" == example/nixcfg ]]; then
      root=$NIXCFG_ROOT
    else
      root=$DSCCFG_ROOT
    fi
    git -C "$root" push -q --force origin "main:refs/heads/$FAKE_BRANCH"
  fi
  if [[ -n "${FAKE_GH_CREATE_THEN_FAIL_REPO:-}" && "$repo" == "$FAKE_GH_CREATE_THEN_FAIL_REPO" ]]; then
    exit 44
  fi
  printf 'https://example.invalid/%s/pull/1\n' "$repo"
  exit 0
fi
if [[ "$1 $2" == 'pr close' ]]; then
  if [[ -n "${FAKE_GH_FAIL_CLOSE_URL:-}" && "$3" == "$FAKE_GH_FAIL_CLOSE_URL" ]]; then
    exit 43
  fi
  exit 0
fi
if [[ "$1 $2" == 'pr view' ]]; then
  if [[ -n "${FAKE_GH_FAIL_CLOSE_URL:-}" && "$3" == "$FAKE_GH_FAIL_CLOSE_URL" ]]; then
    printf 'OPEN\n'
  else
    printf 'CLOSED\n'
  fi
  exit 0
fi
if [[ "$1 $2" == 'pr comment' ]]; then
  exit 0
fi
exit 1
EOF
chmod +x "$fake_bin/gh"
real_git=$(command -v git)
cat >"$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

root=''
if [[ ${1:-} == -C ]]; then
  root=$2
fi
if [[ -n "${FAKE_GIT_DELETE_NOOP_REPO:-}" && "$*" == *' push origin --delete '* ]]; then
  if [[ "$FAKE_GIT_DELETE_NOOP_REPO" == example/nixcfg && "$root" == "$NIXCFG_ROOT" ]] ||
    [[ "$FAKE_GIT_DELETE_NOOP_REPO" == example/dsccfg && "$root" == "$DSCCFG_ROOT" ]]; then
    exit 0
  fi
fi
exec "$FAKE_REAL_GIT" "$@"
EOF
chmod +x "$fake_bin/git"

write_nixcfg_files() {
  local root=$1
  local path
  local -a paths=(
    pharos-release.json
    hosts/csb0/docker/compose-spec.nix
    hosts/csb1/docker/compose-spec.nix
    hosts/csb1/docker/janus/managed-service-production/readiness.sh
    hosts/hsb0/docker/compose-spec.nix
    hosts/hsb1/docker/compose-spec.nix
    hosts/hsb8/docker/compose-spec.nix
    hosts/hsb9/docker/compose-spec.nix
  )
  for path in "${paths[@]}"; do
    mkdir -p "$root/$(dirname "$path")"
    printf 'old\n' >"$root/$path"
  done
  printf '{"reference":"ghcr.io/inspr-at/pharos/pharosd:1.0.0@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}\n' \
    >"$root/pharos-release.json"
  printf 'base\n' >"$root/unrelated.txt"
}

write_dsccfg_files() {
  local root=$1
  mkdir -p "$root/hosts/dsc0/docker"
  printf '{"reference":"ghcr.io/inspr-at/pharos/pharosd:1.0.0@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}\n' \
    >"$root/pharos-release.json"
  printf 'old\n' >"$root/hosts/dsc0/docker/docker-compose.yml"
}

make_pair() {
  local name=$1
  local changed=${2:-both}
  local pair="$fixture_root/$name"
  local root
  mkdir -p "$pair"
  for repo in nix dsc; do
    root="$pair/$repo"
    git init -q --bare "$pair/$repo.git"
    git init -q -b main "$root"
    git -C "$root" config user.name 'Fixture'
    git -C "$root" config user.email 'fixture@example.invalid'
    git -C "$root" remote add origin "$pair/$repo.git"
  done
  write_nixcfg_files "$pair/nix"
  write_dsccfg_files "$pair/dsc"
  if [[ "$changed" == nix ]]; then
    printf '{"reference":"%s"}\n' "$fixture_reference" >"$pair/dsc/pharos-release.json"
  elif [[ "$changed" == dsc ]]; then
    printf '{"reference":"%s"}\n' "$fixture_reference" >"$pair/nix/pharos-release.json"
  fi
  git -C "$pair/nix" add .
  git -C "$pair/nix" commit -qm base
  git -C "$pair/dsc" add .
  git -C "$pair/dsc" commit -qm base
  git -C "$pair/nix" push -q -u origin main
  git -C "$pair/dsc" push -q -u origin main
  if [[ "$changed" == both || "$changed" == nix ]]; then
    printf '{"reference":"%s"}\n' "$fixture_reference" >"$pair/nix/pharos-release.json"
  fi
  if [[ "$changed" == both || "$changed" == dsc ]]; then
    printf '{"reference":"%s"}\n' "$fixture_reference" >"$pair/dsc/pharos-release.json"
  fi
  printf '%s\n' "$pair"
}

prepare_pair() {
  local pair=$1
  local run_id=$2
  local expected_nix_changed=${3:-true}
  local expected_dsc_changed=${4:-true}
  local output="$pair/prepare-output"
  : >"$output"
  GITHUB_RUN_ID="$run_id" GITHUB_OUTPUT="$output" \
    "$prepare" 9.8.7 "$pair/nix" "$pair/dsc" >/dev/null
  # shellcheck disable=SC1090
  source "$output"
  [[ "$nix_changed" == "$expected_nix_changed" ]]
  [[ "$dsc_changed" == "$expected_dsc_changed" ]]
  [[ "$nix_branch" == 'automation/pharos-release-9.8.7' ]]
  [[ "$dsc_branch" == "$nix_branch" ]]
  [[ "$nix_sha" == "$(git -C "$pair/nix" rev-parse HEAD)" ]]
  [[ "$dsc_sha" == "$(git -C "$pair/dsc" rev-parse HEAD)" ]]
  [[ -z "$(git -C "$pair/nix" status --porcelain --untracked-files=no)" ]]
  [[ -z "$(git -C "$pair/dsc" status --porcelain --untracked-files=no)" ]]
}

validate_pair_fixture() {
  local pair=$1
  local expected_nix_sha=$2
  local expected_dsc_sha=$3
  local inject_failure=${4:-false}
  [[ -z "$(git -C "$pair/nix" status --porcelain --untracked-files=no)" ]] || return 1
  [[ -z "$(git -C "$pair/dsc" status --porcelain --untracked-files=no)" ]] || return 1
  [[ "$(git -C "$pair/nix" rev-parse HEAD)" == "$expected_nix_sha" ]] || return 1
  [[ "$(git -C "$pair/dsc" rev-parse HEAD)" == "$expected_dsc_sha" ]] || return 1
  [[ "$inject_failure" == false ]] || return 42
}

publish_pair() {
  local pair=$1
  local fail_repo=${2:-}
  local list_mode=${3:-empty}
  local fail_close_url=${4:-}
  local create_then_fail_repo=${5:-}
  local mutate_branch_repo=${6:-}
  local include_foreign=${7:-false}
  local delete_noop_repo=${8:-}
  local output="$pair/publish-output"
  : >"$output"
  : >"$pair/gh-state"
  PATH="$fake_bin:$PATH" \
    FAKE_GH_LOG="$pair/gh-log" \
    FAKE_GH_FAIL_REPO="$fail_repo" \
    FAKE_GH_FAIL_CLOSE_URL="$fail_close_url" \
    FAKE_GH_CREATE_THEN_FAIL_REPO="$create_then_fail_repo" \
    FAKE_GH_LIST_MODE="$list_mode" \
    FAKE_GH_MUTATE_BRANCH_REPO="$mutate_branch_repo" \
    FAKE_GH_INCLUDE_FOREIGN="$include_foreign" \
    FAKE_GH_STATE="$pair/gh-state" \
    FAKE_GIT_DELETE_NOOP_REPO="$delete_noop_repo" \
    FAKE_REAL_GIT="$real_git" \
    FAKE_NIX_SHA="$nix_sha" \
    FAKE_DSC_SHA="$dsc_sha" \
    FAKE_BRANCH="$nix_branch" \
    VERSION=9.8.7 \
    NIXCFG_ROOT="$pair/nix" \
    DSCCFG_ROOT="$pair/dsc" \
    NIXCFG_REPOSITORY=example/nixcfg \
    DSCCFG_REPOSITORY=example/dsccfg \
    NIX_CHANGED="$nix_changed" \
    DSC_CHANGED="$dsc_changed" \
    NIX_BRANCH="$nix_branch" \
    DSC_BRANCH="$dsc_branch" \
    NIX_SHA="$nix_sha" \
    DSC_SHA="$dsc_sha" \
    GITHUB_OUTPUT="$output" \
    "$publish" >/dev/null
}

select_pair() {
  local pair=$1
  local list_mode=${2:-exact}
  local requested_reference=${3:-$fixture_reference}
  local output="$pair/select-output"
  : >"$output"
  [[ -e "$pair/gh-state" ]] || : >"$pair/gh-state"
  if ! PATH="$fake_bin:$PATH" \
    FAKE_GH_LOG="$pair/gh-log" \
    FAKE_GH_LIST_MODE="$list_mode" \
    FAKE_GH_STATE="$pair/gh-state" \
    FAKE_NIX_SHA="$nix_sha" \
    FAKE_DSC_SHA="$dsc_sha" \
    FAKE_BRANCH="$nix_branch" \
    FAKE_REAL_GIT="$real_git" \
    NIXCFG_REPOSITORY=example/nixcfg \
    DSCCFG_REPOSITORY=example/dsccfg \
    "$select_existing" \
    9.8.7 \
    "$requested_reference" \
    "$pair/nix" \
    "$pair/dsc" \
    "$output" >/dev/null; then
    return 1
  fi
  # shellcheck disable=SC1090
  source "$output"
}

success_pair=$(make_pair success)
base_nix_sha=$(git -C "$success_pair/nix" rev-parse HEAD)
base_dsc_sha=$(git -C "$success_pair/dsc" rev-parse HEAD)
if validate_pair_fixture "$success_pair" "$base_nix_sha" "$base_dsc_sha"; then
  printf 'pharos_release_proposals=failed reason=dirty_regression_fixture_not_dirty\n' >&2
  exit 1
fi
prepare_pair "$success_pair" 1001
validate_pair_fixture "$success_pair" "$nix_sha" "$dsc_sha"
publish_pair "$success_pair"
[[ "$(git --git-dir="$success_pair/nix.git" rev-parse "refs/heads/$nix_branch")" == "$nix_sha" ]]
[[ "$(git --git-dir="$success_pair/dsc.git" rev-parse "refs/heads/$dsc_branch")" == "$dsc_sha" ]]
grep -Fq 'pr create --repo example/nixcfg' "$success_pair/gh-log"
grep -Fq 'pr create --repo example/dsccfg' "$success_pair/gh-log"
grep -Fq 'pr comment https://example.invalid/example/dsccfg/pull/1' "$success_pair/gh-log"
grep -Fxq 'nix_url=https://example.invalid/example/nixcfg/pull/1' "$success_pair/publish-output"
grep -Fxq 'dsc_url=https://example.invalid/example/dsccfg/pull/1' "$success_pair/publish-output"

first_nix_sha=$nix_sha
first_dsc_sha=$dsc_sha
first_branch=$nix_branch
for repo in nix dsc; do
  git -C "$success_pair/$repo" switch -q main
  git -C "$success_pair/$repo" branch -D "$first_branch" >/dev/null
  printf 'main advanced after proposal\n' >"$success_pair/$repo/main-advanced.txt"
  git -C "$success_pair/$repo" add main-advanced.txt
  git -C "$success_pair/$repo" commit -qm main-advanced
  git -C "$success_pair/$repo" push -q origin main
done
: >"$success_pair/gh-log"
select_pair "$success_pair" exact
[[ "$reused" == true ]]
[[ "$nix_changed" == true && "$dsc_changed" == true ]]
[[ "$nix_branch" == "$first_branch" && "$dsc_branch" == "$first_branch" ]]
[[ "$nix_sha" == "$first_nix_sha" && "$dsc_sha" == "$first_dsc_sha" ]]
publish_pair "$success_pair" '' exact
if grep -Fq 'pr create' "$success_pair/gh-log"; then
  printf 'pharos_release_proposals=failed reason=advanced_main_recreated_proposals\n' >&2
  exit 1
fi
[[ "$(git --git-dir="$success_pair/nix.git" rev-parse "refs/heads/$first_branch")" == "$first_nix_sha" ]]
[[ "$(git --git-dir="$success_pair/dsc.git" rev-parse "refs/heads/$first_branch")" == "$first_dsc_sha" ]]

selector_scope_pair=$(make_pair selector-out-of-scope)
prepare_pair "$selector_scope_pair" 1015
printf 'out of proposal scope\n' >"$selector_scope_pair/nix/unrelated.txt"
git -C "$selector_scope_pair/nix" add unrelated.txt
git -C "$selector_scope_pair/nix" commit -qm out-of-scope
nix_sha=$(git -C "$selector_scope_pair/nix" rev-parse HEAD)
git -C "$selector_scope_pair/nix" push -q origin "$nix_branch"
git -C "$selector_scope_pair/dsc" push -q origin "$dsc_branch"
git -C "$selector_scope_pair/nix" switch -q main
git -C "$selector_scope_pair/dsc" switch -q main
if select_pair "$selector_scope_pair" exact \
  >"$selector_scope_pair/stdout" 2>"$selector_scope_pair/stderr"; then
  printf 'pharos_release_proposals=failed reason=out_of_scope_existing_selected\n' >&2
  exit 1
fi
if ! grep -Fxq 'pharos_release_existing=failed reason=proposal_path_out_of_scope repo=nix path=unrelated.txt' \
  "$selector_scope_pair/stderr"; then
  cat "$selector_scope_pair/stderr" >&2
  exit 1
fi

selector_reference_pair=$(make_pair selector-reference)
prepare_pair "$selector_reference_pair" 1016
git -C "$selector_reference_pair/nix" push -q origin "$nix_branch"
git -C "$selector_reference_pair/dsc" push -q origin "$dsc_branch"
git -C "$selector_reference_pair/nix" switch -q main
git -C "$selector_reference_pair/dsc" switch -q main
other_reference='ghcr.io/inspr-at/pharos/pharosd:9.8.7@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
if select_pair "$selector_reference_pair" exact "$other_reference" \
  >"$selector_reference_pair/stdout" 2>"$selector_reference_pair/stderr"; then
  printf 'pharos_release_proposals=failed reason=wrong_reference_existing_selected\n' >&2
  exit 1
fi
grep -Fxq 'pharos_release_existing=failed reason=proposal_reference_mismatch repo=nix' \
  "$selector_reference_pair/stderr"

selector_identity_pair=$(make_pair selector-identity)
prepare_pair "$selector_identity_pair" 1017
git -C "$selector_identity_pair/nix" push -q origin "$nix_branch"
git -C "$selector_identity_pair/dsc" push -q origin "$dsc_branch"
git -C "$selector_identity_pair/nix" switch -q main
git -C "$selector_identity_pair/dsc" switch -q main
select_pair "$selector_identity_pair" wrong-title
[[ "$reused" == false ]]
for mutation in \
  'wrong-base:proposal_identity_mismatch' \
  'wrong-branch:proposal_identity_mismatch' \
  'wrong-head:proposal_head_mismatch' \
  'duplicate:duplicate_proposals'; do
  IFS=: read -r mode reason <<<"$mutation"
  if select_pair "$selector_identity_pair" "$mode" \
    >"$selector_identity_pair/$mode.stdout" 2>"$selector_identity_pair/$mode.stderr"; then
    printf 'pharos_release_proposals=failed reason=selector_identity_mutant mode=%s\n' "$mode" >&2
    exit 1
  fi
  grep -Fq "pharos_release_existing=failed reason=$reason repo=nix" \
    "$selector_identity_pair/$mode.stderr"
done

selector_missing_pair=$(make_pair selector-missing-release)
prepare_pair "$selector_missing_pair" 1018
git -C "$selector_missing_pair/nix" checkout -q main -- pharos-release.json
printf 'allowed non-release change\n' >"$selector_missing_pair/nix/hosts/csb0/docker/compose-spec.nix"
git -C "$selector_missing_pair/nix" add pharos-release.json hosts/csb0/docker/compose-spec.nix
git -C "$selector_missing_pair/nix" commit -qm missing-release-change
nix_sha=$(git -C "$selector_missing_pair/nix" rev-parse HEAD)
git -C "$selector_missing_pair/nix" push -q origin "$nix_branch"
git -C "$selector_missing_pair/dsc" push -q origin "$dsc_branch"
git -C "$selector_missing_pair/nix" switch -q main
git -C "$selector_missing_pair/dsc" switch -q main
if select_pair "$selector_missing_pair" exact \
  >"$selector_missing_pair/stdout" 2>"$selector_missing_pair/stderr"; then
  printf 'pharos_release_proposals=failed reason=missing_release_change_selected\n' >&2
  exit 1
fi
grep -Fxq 'pharos_release_existing=failed reason=proposal_missing_release_change repo=nix' \
  "$selector_missing_pair/stderr"

selector_incomplete_pair=$(make_pair selector-incomplete)
prepare_pair "$selector_incomplete_pair" 1019
git -C "$selector_incomplete_pair/nix" push -q origin "$nix_branch"
git -C "$selector_incomplete_pair/nix" switch -q main
git -C "$selector_incomplete_pair/dsc" switch -q main
if select_pair "$selector_incomplete_pair" nix-exact \
  >"$selector_incomplete_pair/stdout" 2>"$selector_incomplete_pair/stderr"; then
  printf 'pharos_release_proposals=failed reason=selector_incomplete_pair_accepted\n' >&2
  exit 1
fi
grep -Fxq 'pharos_release_existing=failed reason=existing_pair_incomplete repo=dsc' \
  "$selector_incomplete_pair/stderr"

selector_dirty_pair=$(make_pair selector-dirty-aligned nix)
prepare_pair "$selector_dirty_pair" 1020 true false
git -C "$selector_dirty_pair/nix" push -q origin "$nix_branch"
git -C "$selector_dirty_pair/nix" switch -q main
printf 'dirty aligned main\n' >"$selector_dirty_pair/dsc/hosts/dsc0/docker/docker-compose.yml"
if select_pair "$selector_dirty_pair" nix-exact \
  >"$selector_dirty_pair/stdout" 2>"$selector_dirty_pair/stderr"; then
  printf 'pharos_release_proposals=failed reason=dirty_aligned_main_accepted\n' >&2
  exit 1
fi
grep -Fxq 'pharos_release_existing=failed reason=main_checkout_not_clean repo=dsc' \
  "$selector_dirty_pair/stderr"

selector_divergent_pair=$(make_pair selector-divergent-aligned nix)
prepare_pair "$selector_divergent_pair" 1021 true false
git -C "$selector_divergent_pair/nix" push -q origin "$nix_branch"
git -C "$selector_divergent_pair/nix" switch -q main
printf 'divergent aligned main\n' >"$selector_divergent_pair/dsc/divergent.txt"
git -C "$selector_divergent_pair/dsc" add divergent.txt
git -C "$selector_divergent_pair/dsc" commit -qm divergent-aligned
if select_pair "$selector_divergent_pair" nix-exact \
  >"$selector_divergent_pair/stdout" 2>"$selector_divergent_pair/stderr"; then
  printf 'pharos_release_proposals=failed reason=divergent_aligned_main_accepted\n' >&2
  exit 1
fi
grep -Fxq 'pharos_release_existing=failed reason=main_checkout_not_clean repo=dsc' \
  "$selector_divergent_pair/stderr"

selector_type_pair=$(make_pair selector-type-change)
prepare_pair "$selector_type_pair" 1022
rm "$selector_type_pair/nix/unrelated.txt"
ln -s pharos-release.json "$selector_type_pair/nix/unrelated.txt"
git -C "$selector_type_pair/nix" add unrelated.txt
git -C "$selector_type_pair/nix" commit -qm type-change-out-of-scope
nix_sha=$(git -C "$selector_type_pair/nix" rev-parse HEAD)
git -C "$selector_type_pair/nix" push -q origin "$nix_branch"
git -C "$selector_type_pair/dsc" push -q origin "$dsc_branch"
git -C "$selector_type_pair/nix" switch -q main
git -C "$selector_type_pair/dsc" switch -q main
if select_pair "$selector_type_pair" exact \
  >"$selector_type_pair/stdout" 2>"$selector_type_pair/stderr"; then
  printf 'pharos_release_proposals=failed reason=type_change_out_of_scope_selected\n' >&2
  exit 1
fi
grep -Fxq 'pharos_release_existing=failed reason=proposal_path_out_of_scope repo=nix path=unrelated.txt' \
  "$selector_type_pair/stderr"

divergent_pair=$(make_pair divergent-base)
printf 'unrelated non-main commit\n' >"$divergent_pair/nix/unrelated.txt"
git -C "$divergent_pair/nix" add unrelated.txt
git -C "$divergent_pair/nix" commit -qm divergent-base
divergent_branch=automation/pharos-release-9.8.7
if GITHUB_RUN_ID=1008 GITHUB_OUTPUT="$divergent_pair/prepare-output" \
  "$prepare" 9.8.7 "$divergent_pair/nix" "$divergent_pair/dsc" \
  >"$divergent_pair/stdout" 2>"$divergent_pair/stderr"; then
  printf 'pharos_release_proposals=failed reason=divergent_base_accepted\n' >&2
  exit 1
fi
grep -Fxq 'pharos_release_candidates=failed reason=base_not_origin_main repo=nix' \
  "$divergent_pair/stderr"
if git -C "$divergent_pair/nix" show-ref --verify --quiet "refs/heads/$divergent_branch" ||
  git -C "$divergent_pair/dsc" show-ref --verify --quiet "refs/heads/$divergent_branch" ||
  git --git-dir="$divergent_pair/nix.git" show-ref --verify --quiet "refs/heads/$divergent_branch" ||
  git --git-dir="$divergent_pair/dsc.git" show-ref --verify --quiet "refs/heads/$divergent_branch"; then
  printf 'pharos_release_proposals=failed reason=divergent_base_left_candidate\n' >&2
  exit 1
fi

unexpected_pair=$(make_pair unexpected-path nix)
printf 'changed outside allow-list\n' >"$unexpected_pair/nix/unrelated.txt"
if GITHUB_OUTPUT="$unexpected_pair/prepare-output" \
  "$prepare" 9.8.7 "$unexpected_pair/nix" "$unexpected_pair/dsc" \
  >"$unexpected_pair/stdout" 2>"$unexpected_pair/stderr"; then
  printf 'pharos_release_proposals=failed reason=unexpected_path_accepted\n' >&2
  exit 1
fi
grep -Fxq 'pharos_release_candidates=failed reason=unexpected_change repo=nix path=unrelated.txt' \
  "$unexpected_pair/stderr"

prestaged_pair=$(make_pair prestaged nix)
git -C "$prestaged_pair/nix" add pharos-release.json
if GITHUB_OUTPUT="$prestaged_pair/prepare-output" \
  "$prepare" 9.8.7 "$prestaged_pair/nix" "$prestaged_pair/dsc" \
  >"$prestaged_pair/stdout" 2>"$prestaged_pair/stderr"; then
  printf 'pharos_release_proposals=failed reason=prestaged_change_accepted\n' >&2
  exit 1
fi
grep -Fxq 'pharos_release_candidates=failed reason=pre_staged_changes repo=nix' \
  "$prestaged_pair/stderr"

tracked_dirty_pair=$(make_pair tracked-dirty nix)
rm "$tracked_dirty_pair/nix/unrelated.txt"
if GITHUB_OUTPUT="$tracked_dirty_pair/prepare-output" \
  "$prepare" 9.8.7 "$tracked_dirty_pair/nix" "$tracked_dirty_pair/dsc" \
  >"$tracked_dirty_pair/stdout" 2>"$tracked_dirty_pair/stderr"; then
  printf 'pharos_release_proposals=failed reason=tracked_dirty_accepted\n' >&2
  exit 1
fi
grep -Fxq 'pharos_release_candidates=failed reason=tracked_tree_not_clean repo=nix' \
  "$tracked_dirty_pair/stderr"

validation_pair=$(make_pair validation-failure)
prepare_pair "$validation_pair" 1002
if validate_pair_fixture "$validation_pair" "$nix_sha" "$dsc_sha" true; then
  publish_pair "$validation_pair"
fi

publish_dirty_pair=$(make_pair publish-dirty)
prepare_pair "$publish_dirty_pair" 1012
printf 'dirty after validation\n' >"$publish_dirty_pair/nix/unrelated.txt"
if publish_pair "$publish_dirty_pair" >"$publish_dirty_pair/stdout" 2>"$publish_dirty_pair/stderr"; then
  printf 'pharos_release_proposals=failed reason=publish_dirty_accepted\n' >&2
  exit 1
fi
grep -Fxq 'pharos_release_publish=failed reason=unvalidated_commit repo=nix' \
  "$publish_dirty_pair/stderr"
if git --git-dir="$publish_dirty_pair/nix.git" show-ref --verify --quiet "refs/heads/$nix_branch" ||
  git --git-dir="$publish_dirty_pair/dsc.git" show-ref --verify --quiet "refs/heads/$dsc_branch"; then
  printf 'pharos_release_proposals=failed reason=publish_dirty_left_branch\n' >&2
  exit 1
fi

publish_head_pair=$(make_pair publish-head-mismatch)
prepare_pair "$publish_head_pair" 1023
expected_nix_sha=$nix_sha
git -C "$publish_head_pair/nix" switch -q main
if publish_pair "$publish_head_pair" >"$publish_head_pair/stdout" 2>"$publish_head_pair/stderr"; then
  printf 'pharos_release_proposals=failed reason=publish_head_mismatch_accepted\n' >&2
  exit 1
fi
grep -Fxq 'pharos_release_publish=failed reason=unvalidated_commit repo=nix' \
  "$publish_head_pair/stderr"
[[ "$expected_nix_sha" != "$(git -C "$publish_head_pair/nix" rev-parse HEAD)" ]]
if git --git-dir="$publish_head_pair/nix.git" show-ref --verify --quiet "refs/heads/$nix_branch" ||
  git --git-dir="$publish_head_pair/dsc.git" show-ref --verify --quiet "refs/heads/$dsc_branch"; then
  printf 'pharos_release_proposals=failed reason=publish_head_mismatch_left_branch\n' >&2
  exit 1
fi
if git --git-dir="$validation_pair/nix.git" show-ref --verify --quiet "refs/heads/$nix_branch" ||
  git --git-dir="$validation_pair/dsc.git" show-ref --verify --quiet "refs/heads/$dsc_branch"; then
  printf 'pharos_release_proposals=failed reason=validation_failure_published\n' >&2
  exit 1
fi

partial_pair=$(make_pair partial-failure)
prepare_pair "$partial_pair" 1003
if publish_pair "$partial_pair" example/nixcfg; then
  printf 'pharos_release_proposals=failed reason=partial_failure_accepted\n' >&2
  exit 1
fi
if git --git-dir="$partial_pair/nix.git" show-ref --verify --quiet "refs/heads/$nix_branch" ||
  git --git-dir="$partial_pair/dsc.git" show-ref --verify --quiet "refs/heads/$dsc_branch"; then
  printf 'pharos_release_proposals=failed reason=partial_branch_survived\n' >&2
  exit 1
fi
grep -Fq 'pr close https://example.invalid/example/dsccfg/pull/1' "$partial_pair/gh-log"
grep -Fq 'pr view https://example.invalid/example/dsccfg/pull/1' "$partial_pair/gh-log"

create_then_fail_pair=$(make_pair create-then-fail)
prepare_pair "$create_then_fail_pair" 1011
if publish_pair \
  "$create_then_fail_pair" \
  '' \
  empty \
  '' \
  example/dsccfg \
  >"$create_then_fail_pair/stdout" 2>"$create_then_fail_pair/stderr"; then
  printf 'pharos_release_proposals=failed reason=create_then_fail_accepted\n' >&2
  exit 1
fi
grep -Fxq 'pharos_release_publish=failed reason=partial_pair_cleaned' \
  "$create_then_fail_pair/stderr"
grep -Fq 'pr close https://example.invalid/example/dsccfg/pull/1' \
  "$create_then_fail_pair/gh-log"
grep -Fq 'pr view https://example.invalid/example/dsccfg/pull/1' \
  "$create_then_fail_pair/gh-log"
if git --git-dir="$create_then_fail_pair/nix.git" show-ref --verify --quiet "refs/heads/$nix_branch" ||
  git --git-dir="$create_then_fail_pair/dsc.git" show-ref --verify --quiet "refs/heads/$dsc_branch"; then
  printf 'pharos_release_proposals=failed reason=create_then_fail_left_branch\n' >&2
  exit 1
fi

cleanup_failure_pair=$(make_pair cleanup-failure)
prepare_pair "$cleanup_failure_pair" 1009
set +e
publish_pair \
  "$cleanup_failure_pair" \
  example/nixcfg \
  empty \
  https://example.invalid/example/dsccfg/pull/1 \
  >"$cleanup_failure_pair/stdout" 2>"$cleanup_failure_pair/stderr"
cleanup_status=$?
set -e
if [[ $cleanup_status -ne 70 ]]; then
  printf 'pharos_release_proposals=failed reason=cleanup_failure_accepted\n' >&2
  exit 1
fi
grep -Fxq 'pharos_release_cleanup=failed action=close_pr repo=dsc' \
  "$cleanup_failure_pair/stderr"
grep -Fxq 'pharos_release_cleanup=failed action=verify_pr_closed repo=dsc' \
  "$cleanup_failure_pair/stderr"
grep -Fxq 'pharos_release_publish=failed reason=cleanup_incomplete' \
  "$cleanup_failure_pair/stderr"
if grep -Fq 'reason=partial_pair_cleaned' "$cleanup_failure_pair/stderr"; then
  printf 'pharos_release_proposals=failed reason=cleanup_failure_claimed_clean\n' >&2
  exit 1
fi
if git --git-dir="$cleanup_failure_pair/nix.git" show-ref --verify --quiet "refs/heads/$nix_branch" ||
  git --git-dir="$cleanup_failure_pair/dsc.git" show-ref --verify --quiet "refs/heads/$dsc_branch"; then
  printf 'pharos_release_proposals=failed reason=cleanup_failure_left_remote_branch\n' >&2
  exit 1
fi
grep -Fq 'pr close https://example.invalid/example/dsccfg/pull/1' "$cleanup_failure_pair/gh-log"
grep -Fq 'pr view https://example.invalid/example/dsccfg/pull/1' "$cleanup_failure_pair/gh-log"

foreign_pair=$(make_pair cleanup-foreign-pr)
prepare_pair "$foreign_pair" 1024
if publish_pair \
  "$foreign_pair" \
  example/nixcfg \
  empty \
  '' \
  '' \
  '' \
  true \
  >"$foreign_pair/stdout" 2>"$foreign_pair/stderr"; then
  printf 'pharos_release_proposals=failed reason=foreign_cleanup_failure_accepted\n' >&2
  exit 1
fi
grep -Fq 'pr close https://example.invalid/example/dsccfg/pull/1' "$foreign_pair/gh-log"
if grep -Fq 'pull/foreign' "$foreign_pair/gh-log"; then
  printf 'pharos_release_proposals=failed reason=foreign_pr_touched\n' >&2
  exit 1
fi

delete_noop_pair=$(make_pair cleanup-delete-noop)
prepare_pair "$delete_noop_pair" 1025
set +e
publish_pair \
  "$delete_noop_pair" \
  example/nixcfg \
  empty \
  '' \
  '' \
  '' \
  false \
  example/dsccfg \
  >"$delete_noop_pair/stdout" 2>"$delete_noop_pair/stderr"
delete_noop_status=$?
set -e
[[ $delete_noop_status -eq 70 ]]
grep -Fxq 'pharos_release_cleanup=failed action=verify_branch_absent repo=dsc' \
  "$delete_noop_pair/stderr"
grep -Fxq 'pharos_release_publish=failed reason=cleanup_incomplete' \
  "$delete_noop_pair/stderr"
git --git-dir="$delete_noop_pair/dsc.git" show-ref --verify --quiet "refs/heads/$dsc_branch"

mismatch_pair=$(make_pair cleanup-head-mismatch)
prepare_pair "$mismatch_pair" 1013
mismatch_main=$(git -C "$mismatch_pair/dsc" rev-parse main)
set +e
publish_pair \
  "$mismatch_pair" \
  '' \
  empty \
  '' \
  example/dsccfg \
  example/dsccfg \
  >"$mismatch_pair/stdout" 2>"$mismatch_pair/stderr"
mismatch_status=$?
set -e
[[ $mismatch_status -eq 70 ]]
grep -Fxq 'pharos_release_cleanup=failed action=branch_head_mismatch repo=dsc' \
  "$mismatch_pair/stderr"
grep -Fxq 'pharos_release_publish=failed reason=cleanup_incomplete' \
  "$mismatch_pair/stderr"
[[ "$(git --git-dir="$mismatch_pair/dsc.git" rev-parse "refs/heads/$dsc_branch")" == "$mismatch_main" ]]
if git --git-dir="$mismatch_pair/nix.git" show-ref --verify --quiet "refs/heads/$nix_branch"; then
  printf 'pharos_release_proposals=failed reason=mismatch_cleanup_left_exact_branch\n' >&2
  exit 1
fi

collision_pair=$(make_pair branch-collision)
prepare_pair "$collision_pair" 1010
git -C "$collision_pair/nix" push -q origin \
  "$nix_sha:refs/heads/$nix_branch"
if publish_pair "$collision_pair" >"$collision_pair/stdout" 2>"$collision_pair/stderr"; then
  printf 'pharos_release_proposals=failed reason=branch_collision_accepted\n' >&2
  exit 1
fi
grep -Fxq 'pharos_release_publish=failed reason=branch_collision repo=nix' \
  "$collision_pair/stderr"
[[ "$(git --git-dir="$collision_pair/nix.git" rev-parse "refs/heads/$nix_branch")" == "$nix_sha" ]]
if git --git-dir="$collision_pair/dsc.git" show-ref --verify --quiet "refs/heads/$dsc_branch" ||
  grep -Fq 'pr create' "$collision_pair/gh-log"; then
  printf 'pharos_release_proposals=failed reason=branch_collision_mutated_other_repo\n' >&2
  exit 1
fi

incomplete_pair=$(make_pair incomplete-existing)
prepare_pair "$incomplete_pair" 1014
if publish_pair "$incomplete_pair" '' nix-exact \
  >"$incomplete_pair/stdout" 2>"$incomplete_pair/stderr"; then
  printf 'pharos_release_proposals=failed reason=incomplete_existing_accepted\n' >&2
  exit 1
fi
grep -Fxq 'pharos_release_publish=failed reason=existing_pair_incomplete' \
  "$incomplete_pair/stderr"
if git --git-dir="$incomplete_pair/nix.git" show-ref --verify --quiet "refs/heads/$nix_branch" ||
  git --git-dir="$incomplete_pair/dsc.git" show-ref --verify --quiet "refs/heads/$dsc_branch"; then
  printf 'pharos_release_proposals=failed reason=incomplete_existing_published\n' >&2
  exit 1
fi

for mutation in \
  'wrong-base:stale_existing_proposal' \
  'wrong-branch:stale_existing_proposal' \
  'wrong-head:stale_existing_proposal' \
  'duplicate:duplicate_existing_proposals'; do
  IFS=: read -r mode reason <<<"$mutation"
  stale_pair=$(make_pair "publish-$mode")
  prepare_pair "$stale_pair" 1004
  if publish_pair "$stale_pair" '' "$mode" \
    >"$stale_pair/stdout" 2>"$stale_pair/stderr"; then
    printf 'pharos_release_proposals=failed reason=publisher_identity_mutant mode=%s\n' "$mode" >&2
    exit 1
  fi
  grep -Fq "pharos_release_publish=failed reason=$reason repo=nix" "$stale_pair/stderr"
  if git --git-dir="$stale_pair/nix.git" show-ref --verify --quiet "refs/heads/$nix_branch" ||
    git --git-dir="$stale_pair/dsc.git" show-ref --verify --quiet "refs/heads/$dsc_branch" ||
    grep -Fq 'pr create' "$stale_pair/gh-log"; then
    printf 'pharos_release_proposals=failed reason=publisher_identity_mutated mode=%s\n' "$mode" >&2
    exit 1
  fi
done

wrong_title_pair=$(make_pair publish-wrong-title)
prepare_pair "$wrong_title_pair" 1026
publish_pair "$wrong_title_pair" '' wrong-title
grep -Fq 'pr create --repo example/nixcfg' "$wrong_title_pair/gh-log"
grep -Fq 'pr create --repo example/dsccfg' "$wrong_title_pair/gh-log"

existing_pair=$(make_pair exact-reuse)
prepare_pair "$existing_pair" 1005
publish_pair "$existing_pair" '' exact
grep -Fxq 'nix_url=https://example.invalid/example/nixcfg/pull/9' "$existing_pair/publish-output"
grep -Fxq 'dsc_url=https://example.invalid/example/dsccfg/pull/9' "$existing_pair/publish-output"
if grep -Fq 'pr create' "$existing_pair/gh-log" ||
  git --git-dir="$existing_pair/nix.git" show-ref --verify --quiet "refs/heads/$nix_branch" ||
  git --git-dir="$existing_pair/dsc.git" show-ref --verify --quiet "refs/heads/$dsc_branch"; then
  printf 'pharos_release_proposals=failed reason=exact_reuse_republished\n' >&2
  exit 1
fi

nix_only_pair=$(make_pair nix-only nix)
prepare_pair "$nix_only_pair" 1006 true false
publish_pair "$nix_only_pair"
[[ "$(git --git-dir="$nix_only_pair/nix.git" rev-parse "refs/heads/$nix_branch")" == "$nix_sha" ]]
if git --git-dir="$nix_only_pair/dsc.git" show-ref --verify --quiet "refs/heads/$dsc_branch"; then
  printf 'pharos_release_proposals=failed reason=aligned_repo_published\n' >&2
  exit 1
fi
grep -Fq 'pr create --repo example/nixcfg' "$nix_only_pair/gh-log"
if grep -Fq 'pr create --repo example/dsccfg' "$nix_only_pair/gh-log"; then
  printf 'pharos_release_proposals=failed reason=aligned_repo_created_pr\n' >&2
  exit 1
fi
grep -Fq 'The validated dsccfg main commit is already aligned to this release.' "$nix_only_pair/gh-log"
grep -Fxq 'nix_url=https://example.invalid/example/nixcfg/pull/1' "$nix_only_pair/publish-output"
grep -Fxq 'dsc_url=' "$nix_only_pair/publish-output"
git -C "$nix_only_pair/nix" switch -q main
select_pair "$nix_only_pair" empty
[[ "$reused" == true && "$nix_changed" == true && "$dsc_changed" == false ]]
[[ "$nix_sha" == "$(git --git-dir="$nix_only_pair/nix.git" rev-parse "refs/heads/$nix_branch")" ]]
[[ "$dsc_sha" == "$(git -C "$nix_only_pair/dsc" rev-parse main)" ]]

dsc_only_pair=$(make_pair dsc-only dsc)
prepare_pair "$dsc_only_pair" 1007 false true
publish_pair "$dsc_only_pair"
[[ "$(git --git-dir="$dsc_only_pair/dsc.git" rev-parse "refs/heads/$dsc_branch")" == "$dsc_sha" ]]
if git --git-dir="$dsc_only_pair/nix.git" show-ref --verify --quiet "refs/heads/$nix_branch"; then
  printf 'pharos_release_proposals=failed reason=aligned_nix_repo_published\n' >&2
  exit 1
fi
grep -Fq 'pr create --repo example/dsccfg' "$dsc_only_pair/gh-log"
if grep -Fq 'pr create --repo example/nixcfg' "$dsc_only_pair/gh-log"; then
  printf 'pharos_release_proposals=failed reason=aligned_nix_repo_created_pr\n' >&2
  exit 1
fi
grep -Fq 'The validated nixcfg main commit is already aligned to this release.' "$dsc_only_pair/gh-log"
grep -Fxq 'nix_url=' "$dsc_only_pair/publish-output"
grep -Fxq 'dsc_url=https://example.invalid/example/dsccfg/pull/1' "$dsc_only_pair/publish-output"
git -C "$dsc_only_pair/dsc" switch -q main
select_pair "$dsc_only_pair" empty
[[ "$reused" == true && "$nix_changed" == false && "$dsc_changed" == true ]]
[[ "$nix_sha" == "$(git -C "$dsc_only_pair/nix" rev-parse main)" ]]
[[ "$dsc_sha" == "$(git --git-dir="$dsc_only_pair/dsc.git" rev-parse "refs/heads/$dsc_branch")" ]]

printf 'pharos_release_proposals=passed\n'
