#!/usr/bin/env bash
set -euo pipefail

required=(
	VERSION
	NIXCFG_ROOT
	NIXCFG_REPOSITORY
	NIX_CHANGED
	NIX_BRANCH
	NIX_SHA
	GITHUB_OUTPUT
)
for name in "${required[@]}"; do
	if [[ -z "${!name:-}" ]]; then
		printf 'pharos_release_publish=failed reason=missing_input name=%s\n' "$name" >&2
		exit 1
	fi
done

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
	[[ ! "$NIX_SHA" =~ ^[0-9a-f]{40}$ ]]; then
	printf 'pharos_release_publish=failed reason=invalid_input\n' >&2
	exit 1
fi
if [[ "$NIX_BRANCH" != "automation/pharos-release-${VERSION}" ]]; then
	printf 'pharos_release_publish=failed reason=branch_mismatch\n' >&2
	exit 1
fi
if [[ "$NIX_CHANGED" != true && "$NIX_CHANGED" != false ]]; then
	printf 'pharos_release_publish=failed reason=invalid_change_flag\n' >&2
	exit 1
fi
if [[ "$(git -C "$NIXCFG_ROOT" rev-parse HEAD)" != "$NIX_SHA" ]] ||
	[[ -n "$(git -C "$NIXCFG_ROOT" status --porcelain --untracked-files=no)" ]]; then
	printf 'pharos_release_publish=failed reason=unvalidated_commit repo=nix\n' >&2
	exit 1
fi

if [[ "$NIX_CHANGED" == false ]]; then
	printf 'nix_url=\n' >>"$GITHUB_OUTPUT"
	printf 'pharos_release_publish=unchanged version=%s\n' "$VERSION"
	exit 0
fi

title="PHAROS-90: roll fleet to Pharos ${VERSION}"

existing_proposal() {
	local proposals
	local count
	local candidate
	local url
	local head_name
	local head_sha
	local base_name

	proposals=$(gh pr list \
		--repo "$NIXCFG_REPOSITORY" \
		--state open \
		--limit 100 \
		--json title,url,headRefName,headRefOid,baseRefName)
	count=$(jq --arg title "$title" '[.[] | select(.title == $title)] | length' <<<"$proposals")
	if [[ "$count" -gt 1 ]]; then
		printf 'pharos_release_publish=failed reason=duplicate_existing_proposals repo=nix\n' >&2
		return 1
	fi
	if [[ "$count" -eq 0 ]]; then
		return 0
	fi

	candidate=$(jq -r --arg title "$title" \
		'.[] | select(.title == $title) | [.url, .headRefName, .headRefOid, .baseRefName] | @tsv' \
		<<<"$proposals")
	IFS=$'\t' read -r url head_name head_sha base_name <<<"$candidate"
	if [[ "$head_name" != "$NIX_BRANCH" || "$head_sha" != "$NIX_SHA" || "$base_name" != main ]]; then
		printf 'pharos_release_publish=failed reason=stale_existing_proposal repo=nix\n' >&2
		return 1
	fi
	printf '%s\n' "$url"
}

nix_existing=$(existing_proposal)
if [[ -n "$nix_existing" ]]; then
	printf 'nix_url=%s\n' "$nix_existing" >>"$GITHUB_OUTPUT"
	printf 'pharos_release_publish=reused version=%s\n' "$VERSION"
	exit 0
fi

remote_ref=$(git -C "$NIXCFG_ROOT" ls-remote --heads origin "refs/heads/$NIX_BRANCH") || {
	printf 'pharos_release_publish=failed reason=branch_preflight_unavailable repo=nix\n' >&2
	exit 1
}
if [[ -n "$remote_ref" ]]; then
	printf 'pharos_release_publish=failed reason=branch_collision repo=nix\n' >&2
	exit 1
fi

nix_pr=""
published=false

cleanup_incomplete_proposal() {
	local exit_code=$?
	local cleanup_failed=false
	local proposals
	local discovered
	local pr
	local seen
	local state
	local status
	local remote_sha
	trap - EXIT
	if [[ "$published" == true ]]; then
		return 0
	fi
	set +e

	proposals=$(gh pr list \
		--repo "$NIXCFG_REPOSITORY" \
		--state open \
		--limit 100 \
		--json title,url,headRefName,headRefOid,baseRefName)
	status=$?
	if [[ $status -ne 0 ]]; then
		printf 'pharos_release_cleanup=failed action=discover_pr repo=nix\n' >&2
		cleanup_failed=true
		discovered=""
	else
		discovered=$(jq -r \
			--arg title "$title" \
			--arg branch "$NIX_BRANCH" \
			--arg sha "$NIX_SHA" \
			'.[] | select(.title == $title and .headRefName == $branch and .headRefOid == $sha and .baseRefName == "main") | .url' \
			<<<"$proposals")
	fi
	[[ -z "$nix_pr" ]] || discovered="${discovered:+${discovered}$'\n'}${nix_pr}"
	seen=$'\n'
	while IFS= read -r pr; do
		[[ -n "$pr" ]] || continue
		[[ "$seen" != *$'\n'"$pr"$'\n'* ]] || continue
		seen+="$pr"$'\n'
		if ! gh pr close "$pr" --comment 'Closing incomplete release proposal; publication did not finish.'; then
			printf 'pharos_release_cleanup=failed action=close_pr repo=nix\n' >&2
			cleanup_failed=true
		fi
		state=$(gh pr view "$pr" --json state --jq .state)
		status=$?
		if [[ $status -ne 0 || "$state" != CLOSED ]]; then
			printf 'pharos_release_cleanup=failed action=verify_pr_closed repo=nix\n' >&2
			cleanup_failed=true
		fi
	done <<<"$discovered"

	remote_ref=$(git -C "$NIXCFG_ROOT" ls-remote --heads origin "refs/heads/$NIX_BRANCH")
	status=$?
	if [[ $status -ne 0 ]]; then
		printf 'pharos_release_cleanup=failed action=discover_branch repo=nix\n' >&2
		cleanup_failed=true
	else
		remote_sha=$(awk 'NR == 1 { print $1 }' <<<"$remote_ref")
		if [[ -n "$remote_sha" && "$remote_sha" != "$NIX_SHA" ]]; then
			printf 'pharos_release_cleanup=failed action=branch_head_mismatch repo=nix\n' >&2
			cleanup_failed=true
		elif [[ -n "$remote_sha" ]]; then
			if ! git -C "$NIXCFG_ROOT" push origin --delete "$NIX_BRANCH"; then
				printf 'pharos_release_cleanup=failed action=delete_branch repo=nix\n' >&2
				cleanup_failed=true
			fi
			git -C "$NIXCFG_ROOT" ls-remote --exit-code --heads origin "refs/heads/$NIX_BRANCH" >/dev/null
			status=$?
			if [[ $status -ne 2 ]]; then
				printf 'pharos_release_cleanup=failed action=verify_branch_absent repo=nix\n' >&2
				cleanup_failed=true
			fi
		fi
	fi
	set -e
	if [[ "$cleanup_failed" == true ]]; then
		printf 'pharos_release_publish=failed reason=cleanup_incomplete\n' >&2
		exit 70
	fi
	printf 'pharos_release_publish=failed reason=incomplete_proposal_cleaned\n' >&2
	exit "$exit_code"
}
trap cleanup_incomplete_proposal EXIT

git -C "$NIXCFG_ROOT" push --set-upstream origin "$NIX_BRANCH"
nix_pr=$(
	gh pr create \
		--repo "$NIXCFG_REPOSITORY" \
		--base main \
		--head "$NIX_BRANCH" \
		--title "$title" \
		--body "Immutable Pharos ${VERSION} personal-fleet release proposal. This change does not deploy or restart any host."
)
[[ "$nix_pr" == https://* ]]

printf 'nix_url=%s\n' "$nix_pr" >>"$GITHUB_OUTPUT"
published=true
trap - EXIT
printf 'pharos_release_publish=passed version=%s\n' "$VERSION"
