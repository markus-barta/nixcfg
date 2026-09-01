#!/usr/bin/env bash
# shellcheck disable=SC2016 # Workflow expressions and shell assertions are matched literally.
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash %s is too old -- set -e does not abort on a failing [[ ]], so this test would FALSELY PASS. Run under bash 5: nix run nixpkgs#bash -- %s\n' \
    "${0##*/}" "$BASH_VERSION" "$0" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d)
fake_bin="$fixture/bin"
mkdir -p "$fake_bin" "$fixture/remotes"

cleanup() {
  find "$fixture" -type f -delete
  find "$fixture" -type l -delete
  find "$fixture" -depth -type d -exec rmdir '{}' \;
}
trap cleanup EXIT

active_paths=(
  pharos-release.json
  hosts/csb0/docker/compose-spec.nix
  hosts/csb1/docker/compose-spec.nix
  hosts/csb1/docker/janus/managed-service-production/readiness.sh
  hosts/hsb0/docker/compose-spec.nix
  hosts/hsb1/docker/compose-spec.nix
  hosts/hsb8/docker/compose-spec.nix
  hosts/hsb9/docker/compose-spec.nix
)

copy_active_release_files() {
  local target=$1
  local path
  mkdir -p "$target"
  for path in "${active_paths[@]}"; do
    mkdir -p "$target/$(dirname "$path")"
    cp "$repo_root/$path" "$target/$path"
  done
  printf 'fixture\n' >"$target/unrelated.txt"
}

init_repo() {
  local name=$1
  local root="$fixture/$name"
  local remote="$fixture/remotes/${name}.git"
  copy_active_release_files "$root"
  git -C "$root" init --initial-branch=main >/dev/null
  git -C "$root" config user.name 'Markus Barta'
  git -C "$root" config user.email 'markus@barta.com'
  git -C "$root" add .
  git -C "$root" -c commit.gpgSign=false commit -m initial >/dev/null
  git init --bare --initial-branch=main "$remote" >/dev/null
  git -C "$root" remote add origin "$remote"
  git -C "$root" push -u origin main >/dev/null
  printf '%s\n' "$root"
}

cat >"$fake_bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_GH_LOG"
case "${1:-} ${2:-}" in
  'pr list')
    printf '%s\n' "${FAKE_PR_JSON:-[]}"
    ;;
  'pr create')
    if [[ "${FAKE_GH_MODE:-}" == create-fails ]]; then
      exit 1
    fi
    printf '%s\n' 'https://example.invalid/example/nixcfg/pull/1'
    ;;
  *)
    printf 'fake_gh=failed args=%s\n' "$*" >&2
    exit 1
    ;;
esac
SH
chmod +x "$fake_bin/gh"

digest="sha256:$(printf 'a%.0s' {1..64})"
active_scheme=$(jq -r .version_scheme "$repo_root/pharos-release.json")
active_sequence=$(jq -r .release_sequence "$repo_root/pharos-release.json")
if [[ "$active_scheme" == legacy ]]; then
  stored_first=$(jq -r .migration_anchor.first_calendar_version "$repo_root/pharos-release.json")
  if [[ "$stored_first" == null ]]; then
    version=26.09.02.03.04.05
  else
    version=$stored_first
  fi
  sequence=1
  first_version=$version
else
  version=$(
    python3 - "$(jq -r .version "$repo_root/pharos-release.json")" <<'PY'
import datetime as dt
import sys

fields = [int(part) for part in sys.argv[1].split(".")]
current = dt.datetime(2000 + fields[0], *fields[1:]) + dt.timedelta(seconds=1)
print(f"{current.year % 100:02d}.{current:%m.%d.%H.%M.%S}")
PY
  )
  sequence=$((active_sequence + 1))
  first_version=$(jq -r .migration_anchor.first_calendar_version "$repo_root/pharos-release.json")
fi
reference="ghcr.io/inspr-at/pharos/pharosd:${version}@${digest}"
IFS=. read -r release_year release_month release_day release_hour release_minute release_second <<<"$version"
cargo_version="$((2000 + 10#$release_year)).$((10#$release_month * 100 + 10#$release_day)).$((10#$release_hour * 10000 + 10#$release_minute * 100 + 10#$release_second))"
branch="automation/pharos-release-${version}"
release_set="$fixture/release-set.json"
jq -n \
  --arg version "$version" \
  --arg cargo_version "$cargo_version" \
  --arg first_version "$first_version" \
  --argjson sequence "$sequence" \
  --arg digest "$digest" \
  --arg reference "$reference" \
  '{
    schema: "inspr.pharos.release-set.v1",
    schema_version: 1,
    version_scheme: "inspr-calendar-v1",
    version: $version,
    release_channel: "stable",
    release_sequence: $sequence,
    migration_anchor: {
      last_legacy_version: "0.2.0",
      last_legacy_release_sequence: 0,
      first_calendar_version: $first_version,
      first_calendar_release_sequence: 1
    },
    cargo_version: $cargo_version,
    source_commit: ("a" * 40),
    source_lock_digest: ("sha256:" + ("d" * 64)),
    sha_reference: ("ghcr.io/inspr-at/pharos/pharosd:sha-" + ("a" * 40) + "@" + $digest),
    tag: ("v" + $version),
    image: "ghcr.io/inspr-at/pharos/pharosd",
    digest: $digest,
    reference: $reference,
    artifacts: [
      {
        coordinate: {
          class: "oci-index",
          version_reference: $reference,
          source_reference: ("ghcr.io/inspr-at/pharos/pharosd:sha-" + ("a" * 40) + "@" + $digest)
        },
        digest: $digest
      },
      {coordinate: {class: "oci-image", platform: "linux/amd64"}, digest: ("sha256:" + ("e" * 64))},
      {coordinate: {class: "spdx-sbom", filename: "pharos.spdx.json"}, digest: ("sha256:" + ("f" * 64))}
    ],
    attestations: {
      signature: {
        coordinate: ("ghcr.io/inspr-at/pharos/pharosd:sha256-" + ($digest | sub("^sha256:"; "")) + ".sig@sha256:" + ("1" * 64)),
        digest: ("sha256:" + ("1" * 64))
      },
      provenance: {
        coordinate: ("ghcr.io/inspr-at/pharos/pharosd@sha256:" + ("2" * 64)),
        manifest_digest: ("sha256:" + ("2" * 64)),
        layer_digest: ("sha256:" + ("3" * 64)),
          predicate_type: "https://slsa.dev/provenance/v1"
      },
      sbom: {
        coordinate: ("ghcr.io/inspr-at/pharos/pharosd@sha256:" + ("2" * 64)),
        manifest_digest: ("sha256:" + ("2" * 64)),
        layer_digest: ("sha256:" + ("4" * 64)),
        predicate_type: "https://spdx.dev/Document"
      }
    },
    legacy_rollback: {
      version_scheme: "legacy",
      version: "0.2.0",
      release_channel: "stable",
      release_sequence: 0,
      source_commit: "5c8bd1fbd2271a5c157ca239ec2d98b66b201e19",
      tag: "v0.2.0",
      image: "ghcr.io/inspr-at/pharos/pharosd",
      digest: "sha256:a00b9dc078ce4930e50f47da684409468c6996dba64338926ad790c1e1d1b74b",
      reference: "ghcr.io/inspr-at/pharos/pharosd:0.2.0@sha256:a00b9dc078ce4930e50f47da684409468c6996dba64338926ad790c1e1d1b74b"
    }
  }' >"$release_set"
legacy_release_set="$fixture/legacy-release-set.json"
cp "$repo_root/pharos-release.json" "$legacy_release_set"

# A changed active fleet becomes one clean, exact nixcfg candidate.
prepare_root=$(init_repo prepare)
"$repo_root/scripts/update-pharos-release.sh" --root "$prepare_root" "$release_set" >/dev/null
prepare_output="$fixture/prepare-output"
GITHUB_OUTPUT="$prepare_output" \
  "$repo_root/scripts/prepare-pharos-release-candidates.sh" "$release_set" "$prepare_root" >/dev/null
prepare_sha=$(git -C "$prepare_root" rev-parse HEAD)
grep -Fxq 'nix_changed=true' "$prepare_output"
grep -Fxq "nix_branch=${branch}" "$prepare_output"
grep -Fxq "nix_sha=${prepare_sha}" "$prepare_output"
[[ "$(git -C "$prepare_root" branch --show-current)" == "$branch" ]]
[[ -z "$(git -C "$prepare_root" status --porcelain --untracked-files=no)" ]]
while IFS= read -r path; do
  [[ " ${active_paths[*]} " == *" $path "* ]] || {
    printf 'pharos_release_proposals_test=failed reason=inactive_path_prepared path=%s\n' "$path" >&2
    exit 1
  }
done < <(git -C "$prepare_root" diff --name-only origin/main...HEAD)
git -C "$prepare_root" diff --name-only origin/main...HEAD | grep -Fxq pharos-release.json
if git -C "$prepare_root" diff --name-only origin/main...HEAD | grep -Eiq 'dsccfg|dsc0'; then
  printf 'pharos_release_proposals_test=failed reason=retired_dsc0_prepared\n' >&2
  exit 1
fi

# Unexpected tracked changes remain a hard failure.
unexpected_root=$(init_repo unexpected)
printf 'changed\n' >>"$unexpected_root/unrelated.txt"
if GITHUB_OUTPUT="$fixture/unexpected-output" \
  "$repo_root/scripts/prepare-pharos-release-candidates.sh" "$release_set" "$unexpected_root" \
  >"$fixture/unexpected-stdout" 2>"$fixture/unexpected-stderr"; then
  printf 'pharos_release_proposals_test=failed reason=unexpected_path_accepted\n' >&2
  exit 1
fi
grep -Fq 'reason=unexpected_change repo=nix path=unrelated.txt' "$fixture/unexpected-stderr"

# With no matching proposal, selection asks the workflow to prepare one.
select_none_root=$(init_repo select-none)
select_none_output="$fixture/select-none-output"
FAKE_GH_LOG="$fixture/select-none-gh-log" FAKE_PR_JSON='[]' PATH="$fake_bin:$PATH" \
  NIXCFG_REPOSITORY=example/nixcfg \
  "$repo_root/scripts/select-pharos-release-candidates.sh" \
  "$release_set" "$select_none_root" "$select_none_output" >/dev/null
grep -Fxq 'reused=false' "$select_none_output"

# An exact existing nixcfg proposal is fetched, scope-checked, and reused.
git -C "$prepare_root" push -u origin "$branch" >/dev/null
select_exact_root="$fixture/select-exact"
git clone --branch main "$(git -C "$prepare_root" remote get-url origin)" "$select_exact_root" >/dev/null
select_exact_output="$fixture/select-exact-output"
proposal_json=$(jq -cn \
  --arg title "PHAROS-90: roll fleet to Pharos ${version}" \
  --arg url 'https://example.invalid/example/nixcfg/pull/1' \
  --arg branch "$branch" \
  --arg sha "$prepare_sha" \
  '[{title:$title,url:$url,headRefName:$branch,headRefOid:$sha,baseRefName:"main"}]')
FAKE_GH_LOG="$fixture/select-exact-gh-log" FAKE_PR_JSON="$proposal_json" PATH="$fake_bin:$PATH" \
  NIXCFG_REPOSITORY=example/nixcfg \
  "$repo_root/scripts/select-pharos-release-candidates.sh" \
  "$release_set" "$select_exact_root" "$select_exact_output" >/dev/null
grep -Fxq 'reused=true' "$select_exact_output"
grep -Fxq 'nix_changed=true' "$select_exact_output"
grep -Fxq "nix_sha=${prepare_sha}" "$select_exact_output"
grep -Fxq 'nix_url=https://example.invalid/example/nixcfg/pull/1' "$select_exact_output"

# Publication pushes and opens only the validated personal-fleet proposal.
publish_root=$(init_repo publish)
"$repo_root/scripts/update-pharos-release.sh" --root "$publish_root" "$release_set" >/dev/null
publish_prepared_output="$fixture/publish-prepared-output"
GITHUB_OUTPUT="$publish_prepared_output" \
  "$repo_root/scripts/prepare-pharos-release-candidates.sh" "$release_set" "$publish_root" >/dev/null
publish_sha=$(git -C "$publish_root" rev-parse HEAD)
publish_output="$fixture/publish-output"
FAKE_GH_LOG="$fixture/publish-gh-log" FAKE_PR_JSON='[]' PATH="$fake_bin:$PATH" \
  RELEASE_METADATA="$release_set" \
  NIXCFG_ROOT="$publish_root" \
  NIXCFG_REPOSITORY=example/nixcfg \
  NIX_CHANGED=true \
  NIX_BRANCH="$branch" \
  NIX_SHA="$publish_sha" \
  GITHUB_OUTPUT="$publish_output" \
  "$repo_root/scripts/publish-pharos-release-candidates.sh" >/dev/null
grep -Fxq 'nix_url=https://example.invalid/example/nixcfg/pull/1' "$publish_output"
grep -Fq 'pr create --repo example/nixcfg' "$fixture/publish-gh-log"
[[ "$(git --git-dir="$fixture/remotes/publish.git" rev-parse "refs/heads/$branch")" == "$publish_sha" ]]
if grep -Eiq 'dsccfg|dsc0' "$fixture/publish-gh-log"; then
  printf 'pharos_release_proposals_test=failed reason=retired_dsc0_published\n' >&2
  exit 1
fi

# A pre-existing automation branch is never overwritten or adopted implicitly.
collision_root=$(init_repo collision)
"$repo_root/scripts/update-pharos-release.sh" --root "$collision_root" "$release_set" >/dev/null
collision_prepared_output="$fixture/collision-prepared-output"
GITHUB_OUTPUT="$collision_prepared_output" \
  "$repo_root/scripts/prepare-pharos-release-candidates.sh" "$release_set" "$collision_root" >/dev/null
collision_sha=$(git -C "$collision_root" rev-parse HEAD)
git -C "$collision_root" push -u origin "$branch" >/dev/null
if FAKE_GH_LOG="$fixture/collision-gh-log" FAKE_PR_JSON='[]' PATH="$fake_bin:$PATH" \
  RELEASE_METADATA="$release_set" \
  NIXCFG_ROOT="$collision_root" \
  NIXCFG_REPOSITORY=example/nixcfg \
  NIX_CHANGED=true \
  NIX_BRANCH="$branch" \
  NIX_SHA="$collision_sha" \
  GITHUB_OUTPUT="$fixture/collision-output" \
  "$repo_root/scripts/publish-pharos-release-candidates.sh" \
  >"$fixture/collision-stdout" 2>"$fixture/collision-stderr"; then
  printf 'pharos_release_proposals_test=failed reason=branch_collision_accepted\n' >&2
  exit 1
fi
grep -Fxq 'pharos_release_publish=failed reason=branch_collision repo=nix' \
  "$fixture/collision-stderr"
[[ "$(git --git-dir="$fixture/remotes/collision.git" rev-parse "refs/heads/$branch")" == "$collision_sha" ]]
if grep -Fq 'pr create' "$fixture/collision-gh-log"; then
  printf 'pharos_release_proposals_test=failed reason=branch_collision_opened_pr\n' >&2
  exit 1
fi

# If PR creation fails after the push, the exact automation branch is removed.
cleanup_root=$(init_repo cleanup)
"$repo_root/scripts/update-pharos-release.sh" --root "$cleanup_root" "$release_set" >/dev/null
cleanup_prepared_output="$fixture/cleanup-prepared-output"
GITHUB_OUTPUT="$cleanup_prepared_output" \
  "$repo_root/scripts/prepare-pharos-release-candidates.sh" "$release_set" "$cleanup_root" >/dev/null
cleanup_sha=$(git -C "$cleanup_root" rev-parse HEAD)
if FAKE_GH_LOG="$fixture/cleanup-gh-log" FAKE_GH_MODE=create-fails FAKE_PR_JSON='[]' PATH="$fake_bin:$PATH" \
  RELEASE_METADATA="$release_set" \
  NIXCFG_ROOT="$cleanup_root" \
  NIXCFG_REPOSITORY=example/nixcfg \
  NIX_CHANGED=true \
  NIX_BRANCH="$branch" \
  NIX_SHA="$cleanup_sha" \
  GITHUB_OUTPUT="$fixture/cleanup-output" \
  "$repo_root/scripts/publish-pharos-release-candidates.sh" \
  >"$fixture/cleanup-stdout" 2>"$fixture/cleanup-stderr"; then
  printf 'pharos_release_proposals_test=failed reason=failed_publish_accepted\n' >&2
  exit 1
fi
grep -Fxq 'pharos_release_publish=failed reason=incomplete_proposal_cleaned' \
  "$fixture/cleanup-stderr"
if git --git-dir="$fixture/remotes/cleanup.git" show-ref --verify --quiet "refs/heads/$branch"; then
  printf 'pharos_release_proposals_test=failed reason=failed_publish_left_branch\n' >&2
  exit 1
fi

# An already aligned main is a no-op and never invokes GitHub.
unchanged_root=$(init_repo unchanged)
unchanged_sha=$(git -C "$unchanged_root" rev-parse HEAD)
unchanged_output="$fixture/unchanged-output"
legacy_version=$(jq -r .version "$legacy_release_set")
legacy_branch="automation/pharos-release-${legacy_version}"
FAKE_GH_LOG="$fixture/unchanged-gh-log" PATH="$fake_bin:$PATH" \
  RELEASE_METADATA="$legacy_release_set" \
  NIXCFG_ROOT="$unchanged_root" \
  NIXCFG_REPOSITORY=example/nixcfg \
  NIX_CHANGED=false \
  NIX_BRANCH="$legacy_branch" \
  NIX_SHA="$unchanged_sha" \
  GITHUB_OUTPUT="$unchanged_output" \
  "$repo_root/scripts/publish-pharos-release-candidates.sh" >/dev/null
grep -Fxq 'nix_url=' "$unchanged_output"
[[ ! -e "$fixture/unchanged-gh-log" ]]

# The workflow keeps cryptographic verification and a side-effect-free dry run.
workflow="$repo_root/.github/workflows/pharos-release-rollout.yml"
grep -Fq 'cosign verify "ghcr.io/inspr-at/pharos/pharosd@${DIGEST}"' "$workflow"
grep -Fq 'cosign verify-blob' "$workflow"
grep -Fq 'release-set.sigstore.json' "$workflow"
grep -Fq 'allow_rollback:' "$workflow"
grep -Fq 'scripts/pharos-release-metadata.py rollback' "$workflow"
grep -Fq -- '--certificate-identity "https://github.com/inspr-at/pharos/.github/workflows/release.yml@refs/tags/${TAG}"' "$workflow"
grep -Fq "if: github.event_name == 'workflow_dispatch' && inputs.dry_run == true" "$workflow"
grep -Fq "if: github.event_name != 'workflow_dispatch' || inputs.dry_run != true" "$workflow"
if grep -Eiq 'dsccfg|dsc0' \
  "$workflow" \
  "$repo_root/scripts/prepare-pharos-release-candidates.sh" \
  "$repo_root/scripts/select-pharos-release-candidates.sh" \
  "$repo_root/scripts/publish-pharos-release-candidates.sh"; then
  printf 'pharos_release_proposals_test=failed reason=retired_dsc0_coordination_present\n' >&2
  exit 1
fi

printf 'pharos_release_proposals_test=passed\n'
