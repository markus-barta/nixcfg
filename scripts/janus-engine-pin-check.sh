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

for cmd in gh docker awk grep; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "${RED}error:${RESET} required command not found: $cmd" >&2
    exit 2
  fi
done

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

latest_tag="$(
  gh release list \
    --repo "$JANUS_REPO" \
    --limit 50 \
    --json tagName,isDraft,isPrerelease,publishedAt \
    --jq '[.[] | select((.isDraft | not) and (.isPrerelease | not) and (.tagName | startswith("rust-engine-v"))) ] | sort_by(.publishedAt) | last | .tagName'
)"

if [[ -z "$latest_tag" || "$latest_tag" == "null" ]]; then
  echo "${RED}error:${RESET} no published rust-engine-v* release found in $JANUS_REPO" >&2
  exit 2
fi

latest_digest="$(
  docker buildx imagetools inspect "${IMAGE_REPO}:${latest_tag}" |
    awk '/^Digest:/ { print $2; exit }'
)"

if [[ -z "$latest_digest" || ! "$latest_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "${RED}error:${RESET} could not resolve GHCR digest for ${IMAGE_REPO}:${latest_tag}" >&2
  exit 2
fi

digest_hex="${latest_digest#sha256:}"
if ! gh release view "$latest_tag" --repo "$JANUS_REPO" --json assets --jq '.assets[].name' |
  grep -q "$digest_hex"; then
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
