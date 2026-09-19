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
# sources.json on a branch, merge, then `just switch` activates it. Update mode
# serializes writers with a sources.json lock and requires a pinned asset for
# the current host before it prefetches or writes. The guard shims, paimos-agentd
# and Pi (CURSOR_AGENT_PATH) all follow the same store path.
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

lock_dir=$sources.lock
reclaim_dir=$lock_dir.reclaim
reclaim_held=0
backup=''
backup_pending=''
temp=''
restore_temp=''
pin_written=0
pin_verified=0
current=''

finish() {
  trap '' INT TERM
  if [ "$pin_written" = 1 ] && [ "$pin_verified" != 1 ]; then
    if restore_temp=$(mktemp "${sources}.tmp.XXXXXX") &&
      cp "$backup" "$restore_temp" &&
      chmod 0644 "$restore_temp" &&
      mv "$restore_temp" "$sources"; then
      printf 'cursor-agent: bump not verified — pin restored to %s\n' "$current" >&2
      rm -f "$backup" 2>/dev/null || true
      backup=''
    else
      printf 'cursor-agent: bump not verified — could not restore pin %s; backup retained at %s\n' "$current" "$backup" >&2
      printf 'cursor-agent: recover with: git checkout -- pkgs/cursor-agent/sources.json\n' >&2
    fi
  fi
  if [ "$pin_verified" = 1 ]; then
    [ -z "$backup" ] || rm -f "$backup" 2>/dev/null || true
  fi
  [ -z "$backup_pending" ] || rm -f "$backup_pending" 2>/dev/null || true
  [ -z "$temp" ] || rm -f "$temp" 2>/dev/null || true
  [ -z "$restore_temp" ] || rm -f "$restore_temp" 2>/dev/null || true
  if [ "$(readlink "$lock_dir" 2>/dev/null || true)" = "$$" ]; then
    rm -f "$lock_dir" 2>/dev/null || true
  fi
  if [ "$reclaim_held" = 1 ]; then
    rmdir "$reclaim_dir" 2>/dev/null || true
    reclaim_held=0
  fi
}

acquire_lock() {
  trap finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [ -d "$lock_dir" ] && [ ! -L "$lock_dir" ]; then
    die "update lock path $lock_dir is a directory; remove the stray directory once no update runs"
  fi
  if ln -s "$$" "$lock_dir" 2>/dev/null; then
    if [ "$(readlink "$lock_dir" 2>/dev/null || true)" = "$$" ]; then
      return
    fi
    [ ! -L "$lock_dir/$$" ] || rm -f "$lock_dir/$$"
    die "update lock path $lock_dir is a directory; remove the stray directory once no update runs"
  fi

  lock_pid=$(readlink "$lock_dir" 2>/dev/null || true)
  case "$lock_pid" in
  '' | *[!0-9]*) die "cannot acquire update lock $lock_dir: target is not a numeric PID; remove the stray lock once no update runs" ;;
  esac
  if [ -e "$reclaim_dir" ] || [ -L "$reclaim_dir" ]; then
    die "cannot reclaim stale update lock $lock_dir: reclaim guard $reclaim_dir exists; remove it once no update runs"
  fi

  # Serialize stale-lock removal. If a normal writer wins after rm, this one
  # retry loses cleanly rather than claiming a lock that it does not own.
  mkdir "$reclaim_dir" 2>/dev/null || die "cannot create stale update lock reclaim guard $reclaim_dir"
  reclaim_held=1
  [ "$(readlink "$lock_dir" 2>/dev/null || true)" = "$lock_pid" ] ||
    die "cannot reclaim stale update lock $lock_dir"
  if ps -p "$lock_pid" >/dev/null 2>&1 || kill -0 "$lock_pid" 2>/dev/null; then
    die "update lock held by PID $lock_pid ($lock_dir); after a crash, remove it with: rm \"$lock_dir\" (only after no update is running)"
  fi
  rm -f "$lock_dir" || die "cannot reclaim stale update lock $lock_dir"
  if ln -s "$$" "$lock_dir" 2>/dev/null; then
    if [ "$(readlink "$lock_dir" 2>/dev/null || true)" != "$$" ]; then
      [ ! -L "$lock_dir/$$" ] || rm -f "$lock_dir/$$"
      die "update lock path $lock_dir is a directory; remove the stray directory once no update runs"
    fi
  else
    die "cannot acquire update lock $lock_dir"
  fi
  rmdir "$reclaim_dir" 2>/dev/null || die "cannot reclaim stale update lock $lock_dir"
  reclaim_held=0
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
if [ "$mode" = update ]; then
  acquire_lock
fi
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

system=$(nix eval --impure --raw --expr 'builtins.currentSystem')
if ! jq -e '.assets | type == "object"' "$sources" >/dev/null; then
  die "$sources has no assets object"
fi
if ! jq -e --arg s "$system" '.assets | has($s)' "$sources" >/dev/null; then
  pinned_systems=$(jq -r '.assets | keys | join(", ")' "$sources")
  die "unsupported current system $system; pinned systems: $pinned_systems"
fi

updated=$(jq --arg v "$latest" '.version = $v' "$sources")
for asset_system in $(jq -r '.assets | keys[]' "$sources"); do
  os=$(jq -er --arg s "$asset_system" '.assets[$s].os' "$sources")
  arch=$(jq -er --arg s "$asset_system" '.assets[$s].arch' "$sources")
  url="https://downloads.cursor.com/lab/$latest/$os/$arch/agent-cli-package.tar.gz"
  hash=$(nix store prefetch-file --json --hash-type sha256 "$url" | jq -er '.hash') ||
    die "prefetch failed for $url — pin left at $current"
  updated=$(printf '%s\n' "$updated" | jq --arg s "$asset_system" --arg h "$hash" '.assets[$s].hash = $h')
  printf '  %s %s\n' "$asset_system" "$hash"
done

# From here on the new pin is on disk. Anything short of a verified build —
# a failed step, set -e, or Ctrl+C during `nix build` — restores the old one.
backup_pending=$(mktemp "${TMPDIR:-/tmp}/cursor-agent-sources.XXXXXX")
cp "$sources" "$backup_pending"
backup=$backup_pending
backup_pending=''
temp=$(mktemp "${sources}.tmp.XXXXXX")
printf '%s\n' "$updated" >"$temp"
chmod 0644 "$temp"
pin_written=1
mv "$temp" "$sources"

out=$(nix build --no-link --print-out-paths "$repo_root#packages.$system.cursor-agent") ||
  die "build of $latest failed"
[ -n "$out" ] || die "build of $latest returned no store path"
built=$("$out/bin/cursor-agent" --version) || die "$out/bin/cursor-agent --version failed"
[ "$built" = "$latest" ] || die "built CLI reports $built, expected $latest"
printf 'cursor-agent: built and verified %s\n' "$out"
pin_verified=1

printf 'cursor-agent: pin is now %s. Commit pkgs/cursor-agent/sources.json on a NIX branch,\n' "$latest"
printf '  merge it, then run: just switch. Until then the switched-in CLI stays on the old pin.\n'
