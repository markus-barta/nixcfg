#!/usr/bin/env bash
set -euo pipefail

if [[ ${BASH_VERSINFO[0]} -lt 4 ]]; then
  printf '%s: bash %s is too old; run under bash 5\n' "${0##*/}" "$BASH_VERSION" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
prepare="$repo_root/scripts/prepare-pharos-release-candidates.sh"
publish="$repo_root/scripts/publish-pharos-release-candidates.sh"
workflow="$repo_root/.github/workflows/pharos-release-rollout.yml"

bash -n "$prepare"
bash -n "$publish"

prepare_line=$(grep -n -m1 'Prepare clean local release candidates' "$workflow" | cut -d: -f1)
validate_line=$(grep -n -m1 'Validate the exact committed candidates' "$workflow" | cut -d: -f1)
publish_line=$(grep -n -m1 'Publish both validated proposals transactionally' "$workflow" | cut -d: -f1)
signature_line=$(grep -n -m1 'Verify the release signature and workflow identity' "$workflow" | cut -d: -f1)
update_line=$(grep -n -m1 'Prepare both repositories from the same digest' "$workflow" | cut -d: -f1)
if [[ -z "$signature_line" || -z "$update_line" || -z "$prepare_line" ||
  -z "$validate_line" || -z "$publish_line" ]] ||
  [[ "$signature_line" -ge "$update_line" || "$update_line" -ge "$prepare_line" ||
    "$prepare_line" -ge "$validate_line" || "$validate_line" -ge "$publish_line" ]]; then
  printf 'pharos_release_proposals=failed reason=workflow_order\n' >&2
  exit 1
fi
grep -Fq 'scripts/prepare-pharos-release-candidates.sh' "$workflow"
grep -Fq 'scripts/publish-pharos-release-candidates.sh' "$workflow"
grep -Fq 'tests/T32-managed-secret-production-preflight.sh' "$workflow"
grep -Fq 'Verify the release signature and workflow identity' "$workflow"
if grep -Eq 'git push|gh pr create' "$workflow"; then
  printf 'pharos_release_proposals=failed reason=untransactional_publish_in_workflow\n' >&2
  exit 1
fi

fixture_root=$(mktemp -d)
cleanup() {
  find "$fixture_root" -type f -delete
  find "$fixture_root" -type l -delete
  find "$fixture_root" -depth -type d -exec rmdir '{}' \;
}
trap cleanup EXIT

nix_changed=""
dsc_changed=""
nix_branch=""
dsc_branch=""
nix_sha=""
dsc_sha=""

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
    stale)
      printf '[{"title":"PHAROS-90: roll fleet to Pharos 9.8.7","url":"https://example.invalid/%s/pull/8","headRefName":"stale-branch","headRefOid":"0000000000000000000000000000000000000000","baseRefName":"main"}]\n' \
        "$repo"
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
  printf 'https://example.invalid/%s/pull/1\n' "$repo"
  exit 0
fi
if [[ "$1 $2" == 'pr comment' || "$1 $2" == 'pr close' ]]; then
  exit 0
fi
exit 1
EOF
chmod +x "$fake_bin/gh"

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
}

write_dsccfg_files() {
  local root=$1
  mkdir -p "$root/hosts/dsc0/docker"
  printf 'old\n' >"$root/pharos-release.json"
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
  git -C "$pair/nix" add .
  git -C "$pair/nix" commit -qm base
  git -C "$pair/dsc" add .
  git -C "$pair/dsc" commit -qm base
  git -C "$pair/nix" push -q -u origin main
  git -C "$pair/dsc" push -q -u origin main
  if [[ "$changed" == both || "$changed" == nix ]]; then
    printf 'new\n' >"$pair/nix/pharos-release.json"
  fi
  if [[ "$changed" == both || "$changed" == dsc ]]; then
    printf 'new\n' >"$pair/dsc/pharos-release.json"
  fi
  printf '%s\n' "$pair"
}

prepare_pair() {
  local pair=$1
  local run_id=$2
  local expected_nix_changed=${3:-true}
  local expected_dsc_changed=${4:-true}
  local output="$pair/prepare-output"
  GITHUB_RUN_ID="$run_id" GITHUB_OUTPUT="$output" \
    "$prepare" 9.8.7 "$pair/nix" "$pair/dsc" >/dev/null
  # shellcheck disable=SC1090
  source "$output"
  [[ "$nix_changed" == "$expected_nix_changed" ]]
  [[ "$dsc_changed" == "$expected_dsc_changed" ]]
  [[ "$nix_branch" == "automation/pharos-release-9.8.7-${run_id}" ]]
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
  local output="$pair/publish-output"
  : >"$output"
  PATH="$fake_bin:$PATH" \
    FAKE_GH_LOG="$pair/gh-log" \
    FAKE_GH_FAIL_REPO="$fail_repo" \
    FAKE_GH_LIST_MODE="$list_mode" \
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

validation_pair=$(make_pair validation-failure)
prepare_pair "$validation_pair" 1002
if validate_pair_fixture "$validation_pair" "$nix_sha" "$dsc_sha" true; then
  publish_pair "$validation_pair"
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

stale_pair=$(make_pair stale-reuse)
prepare_pair "$stale_pair" 1004
if publish_pair "$stale_pair" '' stale; then
  printf 'pharos_release_proposals=failed reason=stale_proposal_reused\n' >&2
  exit 1
fi
if git --git-dir="$stale_pair/nix.git" show-ref --verify --quiet "refs/heads/$nix_branch" ||
  git --git-dir="$stale_pair/dsc.git" show-ref --verify --quiet "refs/heads/$dsc_branch"; then
  printf 'pharos_release_proposals=failed reason=stale_reuse_published\n' >&2
  exit 1
fi
if grep -Fq 'pr create' "$stale_pair/gh-log"; then
  printf 'pharos_release_proposals=failed reason=stale_reuse_created_pr\n' >&2
  exit 1
fi

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

printf 'pharos_release_proposals=passed\n'
