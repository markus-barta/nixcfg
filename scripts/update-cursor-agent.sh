#!/usr/bin/env bash
#
# update-cursor-agent.sh — bump the pinned Cursor CLI package (NIX-514)
#
# Usage:
#   ./scripts/update-cursor-agent.sh          # Bump pkgs/cursor-agent/sources.json to the
#                                             # vendor's current release, then build + verify.
#   ./scripts/update-cursor-agent.sh --check  # Report only, never writes; exit 1 when behind.
#
# Called by `just update-ai-clis`. The release comes from the official installer
# (https://cursor.com/install) — the script `curl … | bash` would run — whose
# download URL embeds it. Every asset in sources.json is re-hashed before
# anything is written, and the host's asset must build and report the new
# version, or the previous pin is restored.
#
# Unlike the npm CLIs this is a repo change, not an in-place install: commit
# sources.json on a branch, merge, then `just switch` activates it. The guard
# shims, paimos-agentd and Pi (CURSOR_AGENT_PATH) all follow the same store path.
#
# Test hooks (--check only): CURSOR_AGENT_SOURCES (alternate sources.json) and
# CURSOR_INSTALL_URL (alternate installer, e.g. a file:// fixture).
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
sources=${CURSOR_AGENT_SOURCES:-$repo_root/pkgs/cursor-agent/sources.json}
installer_url=${CURSOR_INSTALL_URL:-https://cursor.com/install}

die() {
  printf 'cursor-agent: %s\n' "$*" >&2
  exit 1
}

mode=update
case "${1-}" in
"") ;;
--check) mode=check ;;
*)
  printf 'usage: %s [--check]\n' "${0##*/}" >&2
  exit 2
  ;;
esac
if [ "$mode" = update ] && [ -n "${CURSOR_AGENT_SOURCES-}${CURSOR_INSTALL_URL-}" ]; then
  die 'CURSOR_AGENT_SOURCES / CURSOR_INSTALL_URL are test hooks for --check only'
fi

for tool in curl jq nix; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found on PATH"
done
[ -f "$sources" ] || die "no pin file at $sources"
current=$(jq -er '.version' "$sources") || die "$sources has no version"

installer=$(curl -fsSL --max-time 30 "$installer_url") || die "cannot fetch the installer from $installer_url"
releases=$(
  printf '%s\n' "$installer" |
    grep -oE 'downloads\.cursor\.com/lab/[^/"]+/' |
    sed -e 's#^downloads\.cursor\.com/lab/##' -e 's#/$##' |
    sort -u
) || true
[ -n "$releases" ] || die 'the installer names no release (format changed?)'
[ "$(printf '%s\n' "$releases" | wc -l | tr -d ' ')" = 1 ] ||
  die "the installer names several releases: $(printf '%s ' "$releases")"
latest=$releases
printf '%s\n' "$latest" | grep -Eq '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9a-f]{7,40}$' ||
  die "unexpected release format: $latest"

if [ "$latest" = "$current" ]; then
  printf 'cursor-agent: pin %s is current\n' "$current"
  exit 0
fi
if [ "$mode" = check ]; then
  printf 'cursor-agent: pin %s is behind vendor %s (run: just update-ai-clis)\n' "$current" "$latest"
  exit 1
fi

# Release ids start with a date, so a plain sort orders them. Follow the vendor
# either way (like npm @latest), but say so when it moved backwards.
direction=bump
if [ "$(printf '%s\n%s\n' "$latest" "$current" | sort | head -n 1)" = "$latest" ]; then
  direction='vendor rolled back'
fi
printf 'cursor-agent: %s %s -> %s\n' "$direction" "$current" "$latest"

updated=$(jq --arg v "$latest" '.version = $v' "$sources")
for system in $(jq -r '.assets | keys[]' "$sources"); do
  os=$(jq -er --arg s "$system" '.assets[$s].os' "$sources")
  arch=$(jq -er --arg s "$system" '.assets[$s].arch' "$sources")
  url="https://downloads.cursor.com/lab/$latest/$os/$arch/agent-cli-package.tar.gz"
  hash=$(nix store prefetch-file --json --hash-type sha256 "$url" | jq -er '.hash') ||
    die "prefetch failed for $url — pin left at $current"
  updated=$(printf '%s\n' "$updated" | jq --arg s "$system" --arg h "$hash" '.assets[$s].hash = $h')
  printf '  %s %s\n' "$system" "$hash"
done

backup=$(mktemp "${TMPDIR:-/tmp}/cursor-agent-sources.XXXXXX")
trap 'rm -f "$backup"' EXIT
cp "$sources" "$backup"
printf '%s\n' "$updated" >"$sources.tmp"
mv "$sources.tmp" "$sources"

restore_and_die() {
  cp "$backup" "$sources"
  die "$* — pin restored to $current"
}

system=$(nix eval --impure --raw --expr 'builtins.currentSystem')
if jq -e --arg s "$system" '.assets | has($s)' "$sources" >/dev/null; then
  out=$(nix build --no-link --print-out-paths "$repo_root#packages.$system.cursor-agent") ||
    restore_and_die "build of $latest failed"
  built=$("$out/bin/cursor-agent" --version) || restore_and_die "$out/bin/cursor-agent --version failed"
  [ "$built" = "$latest" ] || restore_and_die "built CLI reports $built, expected $latest"
  printf 'cursor-agent: built and verified %s\n' "$out"
else
  printf 'cursor-agent: no %s asset pinned; hashes updated, build not verified here\n' "$system"
fi

printf 'cursor-agent: pin is now %s. Commit pkgs/cursor-agent/sources.json on a NIX branch,\n' "$latest"
printf '  merge it, then run: just switch. Until then the active CLI stays at %s.\n' "$current"
