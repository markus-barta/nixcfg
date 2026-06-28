#!/usr/bin/env bash
#
# janus-engine-pin-check.sh - detect drift between csb1's staged Janus engine
# compose pin and the latest published rust-engine release.
#
# Usage:
#   ./scripts/janus-engine-pin-check.sh          # human report
#   ./scripts/janus-engine-pin-check.sh --quiet  # print only on drift
#
# Exit codes:
#   0 - staged pin matches latest release tag and digest
#   1 - drift detected
#   2 - usage / environment error
#
set -euo pipefail

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
RESET=$'\033[0m'

MODE="report"
case "${1:-}" in
"") ;;
--quiet) MODE="quiet" ;;
-h | --help)
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
  ;;
*)
  echo "${RED}error:${RESET} unknown arg '$1' (try --help)" >&2
  exit 2
  ;;
esac

for cmd in awk curl python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "${RED}error:${RESET} required command not found: $cmd" >&2
    exit 2
  fi
done

github_api() {
  local path="$1"
  local url="https://api.github.com/repos/${JANUS_REPO}${path}"
  local args=(
    -fsSL
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )

  if [[ -n "${JANUS_ENGINE_GITHUB_TOKEN:-}" ]]; then
    args+=(-H "Authorization: Bearer ${JANUS_ENGINE_GITHUB_TOKEN}")
  fi

  curl "${args[@]}" "$url"
}

ghcr_manifest_digest() {
  local image_repo="$1"
  local tag="$2"
  local image_path token status digest
  local headers_file="$tmpdir/manifest.headers"
  local body_file="$tmpdir/manifest.body"

  if [[ ! "$image_repo" =~ ^ghcr\.io/(.+)$ ]]; then
    echo "${RED}error:${RESET} only ghcr.io image repos are supported: $image_repo" >&2
    return 2
  fi
  image_path="${BASH_REMATCH[1]}"

  if ! token="$(
    curl -fsSL "https://ghcr.io/token?service=ghcr.io&scope=repository:${image_path}:pull" |
      python3 -c 'import json, sys; print(json.load(sys.stdin)["token"])'
  )"; then
    echo "${RED}error:${RESET} could not get GHCR pull token for $image_repo" >&2
    return 2
  fi

  if ! status="$(
    curl -sS -L \
      -o "$body_file" \
      -D "$headers_file" \
      -w "%{http_code}" \
      -H "Authorization: Bearer ${token}" \
      -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
      "https://ghcr.io/v2/${image_path}/manifests/${tag}"
  )"; then
    echo "${RED}error:${RESET} could not read GHCR manifest for ${image_repo}:${tag}" >&2
    return 2
  fi

  if [[ "$status" != "200" ]]; then
    echo "${RED}error:${RESET} GHCR manifest request for ${image_repo}:${tag} returned HTTP $status" >&2
    sed -n '1,12p' "$body_file" >&2
    return 2
  fi

  digest="$(awk 'tolower($1) == "docker-content-digest:" { gsub("\r", "", $2); print $2; exit }' "$headers_file")"
  if [[ -z "$digest" || ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "${RED}error:${RESET} GHCR manifest for ${image_repo}:${tag} did not return a valid digest" >&2
    return 2
  fi

  echo "$digest"
}

REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO" || ! -f "$REPO/hosts/csb1/docker/docker-compose.yml" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

COMPOSE_FILE="${JANUS_ENGINE_STAGED_COMPOSE_FILE:-$REPO/hosts/csb1/docker/docker-compose.yml}"
JANUS_REPO="${JANUS_ENGINE_RELEASE_REPO:-markus-barta/janus}"
IMAGE_REPO="${JANUS_ENGINE_IMAGE_REPO:-ghcr.io/markus-barta/janus/janus-engine}"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "${RED}error:${RESET} compose file not found: $COMPOSE_FILE" >&2
  exit 2
fi

compose_image="$(
  awk '
      /^  janus-engine-staged:/ { in_service = 1; next }
      in_service && /^  [A-Za-z0-9_.-]+:/ { exit }
      in_service && /^[[:space:]]+image:/ {
        sub(/^[[:space:]]+image:[[:space:]]*/, "")
        print
        exit
      }
    ' "$COMPOSE_FILE"
)"

if [[ -z "$compose_image" ]]; then
  echo "${RED}error:${RESET} could not find janus-engine-staged image in $COMPOSE_FILE" >&2
  exit 2
fi

if [[ ! "$compose_image" =~ ^([^[:space:]@:]+(/[^[:space:]@:]+)+):(rust-engine-v[^@[:space:]]+)@(sha256:[0-9a-f]{64})$ ]]; then
  echo "${RED}error:${RESET} staged image is not a rust-engine digest pin: $compose_image" >&2
  exit 2
fi

pinned_image_repo="${BASH_REMATCH[1]}"
pinned_tag="${BASH_REMATCH[3]}"
pinned_digest="${BASH_REMATCH[4]}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
release_json_file="$tmpdir/releases.json"

if ! github_api "/releases?per_page=50" >"$release_json_file"; then
  echo "${RED}error:${RESET} could not read releases from $JANUS_REPO" >&2
  exit 2
fi

if ! latest_tag="$(
  python3 - "$release_json_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    releases = json.load(handle)

if not isinstance(releases, list):
    sys.exit(1)

candidates = [
    release
    for release in releases
    if not release.get("draft")
    and not release.get("prerelease")
    and release.get("tag_name", "").startswith("rust-engine-v")
]
candidates.sort(key=lambda release: release.get("published_at") or "")

if candidates:
    print(candidates[-1]["tag_name"])
PY
)"; then
  echo "${RED}error:${RESET} could not parse releases from $JANUS_REPO" >&2
  exit 2
fi

if [[ -z "$latest_tag" || "$latest_tag" == "null" ]]; then
  echo "${RED}error:${RESET} no published rust-engine-v* release found in $JANUS_REPO" >&2
  exit 2
fi

latest_digest="$(ghcr_manifest_digest "$IMAGE_REPO" "$latest_tag")"

if [[ -z "$latest_digest" || ! "$latest_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "${RED}error:${RESET} could not resolve GHCR digest for ${IMAGE_REPO}:${latest_tag}" >&2
  exit 2
fi

digest_hex="${latest_digest#sha256:}"
if ! python3 - "$release_json_file" "$latest_tag" "$digest_hex" <<'PY'; then
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    releases = json.load(handle)

tag = sys.argv[2]
digest_hex = sys.argv[3]
release = next((item for item in releases if item.get("tag_name") == tag), None)
if not release:
    sys.exit(1)

asset_names = [asset.get("name", "") for asset in release.get("assets", [])]
sys.exit(0 if any(digest_hex in name for name in asset_names) else 1)
PY
  echo "${RED}error:${RESET} latest release $latest_tag has no SBOM asset naming digest $latest_digest" >&2
  exit 2
fi

latest_image="${IMAGE_REPO}:${latest_tag}@${latest_digest}"

if [[ "$pinned_image_repo" == "$IMAGE_REPO" && "$pinned_tag" == "$latest_tag" && "$pinned_digest" == "$latest_digest" ]]; then
  if [[ "$MODE" != "quiet" ]]; then
    echo "${GREEN}ok:${RESET} janus-engine-staged pin matches latest release"
    echo "  pinned: $compose_image"
    echo "  latest: $latest_image"
  fi
  exit 0
fi

echo "${YELLOW}drift:${RESET} janus-engine-staged pin differs from latest rust-engine release" >&2
echo "  pinned: $compose_image" >&2
echo "  latest: $latest_image" >&2
exit 1
