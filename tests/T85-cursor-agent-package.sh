#!/usr/bin/env bash
# NIX-514 — the Cursor CLI is one hash-pinned Nix package. Unguarded Home
# Manager harnesses install it; on guarded mbp2607 it reaches PATH only through
# the guard shims, and those, paimos-agentd and Pi's CURSOR_AGENT_PATH all run
# that same store path — no imperative
# ~/.local/share/cursor-agent copy is referenced. `just update-ai-clis` bumps
# the pin through scripts/update-cursor-agent.sh. NIX-516: $out/bin always
# passes --disable-auto-update, so running the package never re-creates that
# imperative copy, and a vendor release that drops the flag fails the bump.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  printf 'T85 failed: %s\n' "$*" >&2
  exit 1
}

package_file="$repo_root/pkgs/cursor-agent/default.nix"
sources_file="$repo_root/pkgs/cursor-agent/sources.json"
update_script="$repo_root/scripts/update-cursor-agent.sh"

pinned=$(jq -er '.version' "$sources_file") || fail 'sources.json has no version'
printf '%s\n' "$pinned" | grep -Eq '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9a-f]{7,40}$' ||
  fail "pinned release has an unexpected format: $pinned"
jq -e '.assets["aarch64-darwin"] | .os == "darwin" and .arch == "arm64" and (.hash | startswith("sha256-"))' \
  "$sources_file" >/dev/null || fail 'aarch64-darwin asset is not pinned by sha256'
# shellcheck disable=SC2016 # Match the literal Nix interpolation contract.
grep -Fq 'https://downloads.cursor.com/lab/${version}/${asset.os}/${asset.arch}/agent-cli-package.tar.gz' "$package_file" ||
  fail 'package does not fetch the official versioned vendor tarball'
grep -Fq 'sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];' "$package_file" || fail 'binary provenance is not declared'
grep -Fq 'dontFixup = true;' "$package_file" || fail 'vendor-signed binaries must stay byte-identical'
grep -Fq -- '--add-flags --disable-auto-update' "$package_file" ||
  fail 'the package no longer disables the vendor background updater'
grep -Fq 'isAutoUpdate:!0' "$package_file" ||
  fail 'installCheck no longer verifies that every automatic update is gated'

# No Nix value may point at the imperative vendor install any more (comments
# that explain the migration are fine).
if grep -rnE '\.local/(share/cursor-agent|bin/(cursor-agent|agent)\b)' \
  "$repo_root/hosts" "$repo_root/modules" "$repo_root/lib" --include='*.nix' |
  grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'; then
  fail 'a Nix file still references the imperative Cursor install'
fi

package_version=$(cd "$repo_root" && nix eval --raw '.#packages.aarch64-darwin.cursor-agent.version')
[ "$package_version" = "$pinned" ] || fail "evaluated package version $package_version != pin $pinned"
package_out=$(cd "$repo_root" && nix eval --raw '.#packages.aarch64-darwin.cursor-agent.outPath')
cursor_exe="$package_out/bin/cursor-agent"

# Unguarded hosts get the package on PATH. On a guarded host the shadow-bin
# launchers own `cursor-agent`/`agent`, and the package must stay OUT of the
# profile: a fish login shell resolves ~/.nix-profile/bin ahead of the guard
# directory (the first NIX-514 switch exposed Cursor unguarded exactly so).
for home in 'markus@mbp2607' 'mba@mbp2606' 'mailina@mbp2606'; do
  packages=$(cd "$repo_root" && nix eval --json ".#homeConfigurations.\"$home\".config.home.packages")
  in_profile=$(printf '%s' "$packages" | jq --arg p "$package_out" 'index($p) != null')
  guarded=$(cd "$repo_root" && nix eval --json ".#homeConfigurations.\"$home\".config.uzumaki.agentBrowserGuard.envOnlyPrograms" |
    jq 'has("cursor-agent") or has("agent")')
  if [ "$guarded" = true ]; then
    [ "$in_profile" = false ] || fail "$home installs Cursor into the profile, ahead of its guard launcher"
  else
    [ "$in_profile" = true ] || fail "$home does not install the pinned Cursor package"
  fi
  cursor_env=$(cd "$repo_root" && nix eval --raw ".#homeConfigurations.\"$home\".config.home.sessionVariables.CURSOR_AGENT_PATH")
  [ "$cursor_env" = "$cursor_exe" ] || fail "$home CURSOR_AGENT_PATH is not the pinned package: $cursor_env"
done

guard=$(cd "$repo_root" && nix eval --json '.#homeConfigurations."markus@mbp2607".config.uzumaki.agentBrowserGuard.envOnlyPrograms')
for name in cursor-agent agent; do
  target=$(printf '%s' "$guard" | jq -er --arg n "$name" '.[$n]') || fail "guard shim $name is missing"
  [ "$target" = "$cursor_exe" ] || fail "guard shim $name does not exec the pinned package: $target"
done
agentd_cursor=$(cd "$repo_root" && nix eval --raw '.#homeConfigurations."markus@mbp2607".config.uzumaki.paimosAgentd.cursorPath')
[ "$agentd_cursor" = "$cursor_exe" ] || fail "paimos-agentd cursorPath is not the pinned package: $agentd_cursor"
grep -Fq 'fish login shells resolve ahead of the guard launcher' "$repo_root/modules/uzumaki/agent-browser-guard.nix" ||
  fail 'the guard no longer asserts that launcher names stay out of home.packages'

# The update step: offline --check against installer fixtures, never a write.
[ -x "$update_script" ] || fail 'update script is not executable'
grep -Fq -- '-./scripts/update-cursor-agent.sh' "$repo_root/justfile" ||
  fail 'just update-ai-clis does not run the Cursor pin step (error-tolerant)'
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/t85.XXXXXX")
trap 'rm -rf "$fixture_dir"' EXIT
before=$(shasum -a 256 "$sources_file")
# Mimics the vendor installer line; ${OS}/${ARCH} stay literal like upstream.
installer_fixture() {
  # shellcheck disable=SC2016 # literal installer text, not an expansion
  printf 'DOWNLOAD_URL="https://downloads.cursor.com/lab/%s/${OS}/${ARCH}/agent-cli-package.tar.gz"\n' "$1"
}
installer_fixture "$pinned" >"$fixture_dir/current.sh"
installer_fixture 2099.01.01-abcdef1 >"$fixture_dir/newer.sh"
printf 'echo nothing to see\n' >"$fixture_dir/broken.sh"
CURSOR_INSTALL_URL="file://$fixture_dir/current.sh" "$update_script" --check | grep -Fq "pin $pinned is current" ||
  fail '--check does not report a current pin'
if CURSOR_INSTALL_URL="file://$fixture_dir/newer.sh" "$update_script" --check >"$fixture_dir/out" 2>&1; then
  fail '--check exits 0 although the vendor release is newer'
fi
grep -Fq 'is behind vendor 2099.01.01-abcdef1' "$fixture_dir/out" || fail '--check does not name the newer release'
if CURSOR_INSTALL_URL="file://$fixture_dir/broken.sh" "$update_script" --check >"$fixture_dir/out" 2>&1; then
  fail '--check accepts an installer without a release'
fi
if CURSOR_INSTALL_URL="file://$fixture_dir/newer.sh" "$update_script" >"$fixture_dir/out" 2>&1; then
  fail 'test hooks must be refused outside --check'
fi
[ "$(shasum -a 256 "$sources_file")" = "$before" ] || fail 'the update script wrote sources.json during checks'

current_system=$(nix eval --impure --raw --expr builtins.currentSystem)
if [ "$current_system" = aarch64-darwin ]; then
  cd "$repo_root"
  nix build '.#packages.aarch64-darwin.cursor-agent' --no-link
  [ "$("$cursor_exe" --version)" = "$pinned" ] || fail 'realised cursor-agent version mismatch'
  [ "$("$package_out/bin/agent" --version)" = "$pinned" ] || fail 'realised agent alias version mismatch'
  grep -Fq -- '--disable-auto-update' "$cursor_exe" || fail 'realised wrapper does not pass --disable-auto-update'
  [ "$(readlink "$package_out/bin/agent")" = cursor-agent ] || fail 'agent alias bypasses the wrapper'
  codesign --verify --strict "$package_out/share/cursor-agent/node" || fail 'vendor node signature broken in the store'
  codesign --verify --strict "$package_out/share/cursor-agent/cursorsandbox" || fail 'vendor sandbox helper signature broken in the store'
fi

printf 'T85 passed: Cursor CLI %s is one pinned package for every harness and consumer\n' "$pinned"
