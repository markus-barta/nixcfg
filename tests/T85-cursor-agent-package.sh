#!/usr/bin/env bash
# NIX-514 — the Cursor CLI is one hash-pinned Nix package. Unguarded Home
# Manager harnesses install it; on guarded mbp2607 it reaches PATH only through
# the guard shims, and those, paimos-agentd and Pi's CURSOR_AGENT_PATH all run
# that same store path — no imperative
# ~/.local/share/cursor-agent copy is referenced. `just update-ai-clis` bumps
# the pin through scripts/update-cursor-agent.sh. NIX-516: $out/bin is
# wrapper.sh, which passes --disable-auto-update without moving argv[2], and
# check-auto-update.mjs fails a bump whose bundle no longer guards every
# automatic update behind that option; both are exercised here on fixtures.
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
wrapper_template="$repo_root/pkgs/cursor-agent/wrapper.sh"
auto_update_check="$repo_root/pkgs/cursor-agent/check-auto-update.mjs"
# shellcheck disable=SC2016 # literal Nix and bundle text, not expansions
grep -Fq 'substitute ${./wrapper.sh} "$out/bin/cursor-agent"' "$package_file" ||
  fail 'the package no longer installs wrapper.sh as bin/cursor-agent'
# shellcheck disable=SC2016 # literal Nix and bundle text, not expansions
grep -Fq '${./check-auto-update.mjs} "$out/share/cursor-agent"' "$package_file" ||
  fail 'installCheck no longer runs check-auto-update.mjs on the bundle'
grep -Fq -- '--disable-auto-update' "$wrapper_template" || fail 'wrapper.sh no longer passes --disable-auto-update'

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

# NIX-516 — the auto-update check must fail closed. Fixture bundles are the
# vendor's shapes, reduced to the lines the check reads.
node_bin=$(command -v node || true)
if [ -z "$node_bin" ]; then
  node_bin="$(cd "$repo_root" && nix build --no-link --print-out-paths --inputs-from . nixpkgs#nodejs)/bin/node"
fi
# shellcheck disable=SC2016 # literal Nix and bundle text, not expansions
option_line='addOption(new f.c$("--disable-auto-update","Disable auto-updates").default(!1).hideHelp())'
guard_expr='null!==(tt=o.disableAutoUpdate)&&void 0!==tt&&tt||"static"===yo.channel||setTimeout((()=>{(0,D.updateCursorAgent)({dashboardClient:Rn,showProgress:!1,channel:yo.channel,isAutoUpdate:!0,product:"agent-cli"})}),2e3)'
# As in the bundle, the guard follows a sequence comma.
guarded_call="yo=o.configProvider.get(),$guard_expr"
explicit_call='yield(0,o.updateCursorAgent)({dashboardClient:e,showProgress:!0,channel:i.channel,isAutoUpdate:!1,product:t})'
# The updater's module: its export entry and definition; the minifier reuses
# the local name for a shadowed variable, which is not a call.
update_module='"./src/commands/update-core.ts"(e,t,n){n.d(t,{shouldDoUpdate:()=>p,updateCursorAgent:()=>m});function m(e){let m=!1;return m=!0,{success:m}}}'
bundle_case() { # <name> <index.js> <chat.js> [<update module>]: writes a fixture bundle, prints its directory
  mkdir -p "$fixture_dir/bundle-$1"
  printf '%s\n' "$2" >"$fixture_dir/bundle-$1/index.js"
  printf '%s\n' "$3" >"$fixture_dir/bundle-$1/7470.index.js"
  printf '%s\n' "${4-$update_module}" >"$fixture_dir/bundle-$1/5211.index.js"
  printf '%s\n' "$fixture_dir/bundle-$1"
}
"$node_bin" "$auto_update_check" "$(bundle_case good "$option_line" "$guarded_call;$explicit_call")" >/dev/null ||
  fail 'auto-update check rejects a guarded bundle'
expect_rejected() { # <name> <index.js> <chat.js> <reason> [<update module>]
  if "$node_bin" "$auto_update_check" "$(bundle_case "$1" "$2" "$3" "${5-$update_module}")" >/dev/null 2>&1; then
    fail "auto-update check accepts $4"
  fi
}
expect_rejected inverted "$option_line" "${guarded_call/&&tt||/&&!tt||};$explicit_call" 'an inverted guard'
expect_rejected no-automatic "$option_line" "$explicit_call" 'a bundle without its automatic update'
expect_rejected ungated-true "$option_line" "$guarded_call;(0,q.updateCursorAgent)({isAutoUpdate:true})" 'an ungated isAutoUpdate:true'
expect_rejected unknown-value "$option_line" "$guarded_call;(0,q.updateCursorAgent)({isAutoUpdate:x})" 'an unclassified isAutoUpdate value'
# shellcheck disable=SC2016 # literal Nix and bundle text, not expansions
expect_rejected no-option 'addOption(new f.c$("--endless-retries"))' "$guarded_call" 'a bundle without the option'
expect_rejected two-options "$option_line;$option_line" "$guarded_call" 'a duplicated option definition'
expect_rejected direct-call "$option_line" "$guarded_call;q.updateCursorAgent({isAutoUpdate:!0})" 'an ungated direct call'
expect_rejected variable-argument "$option_line" "$guarded_call;(0,q.updateCursorAgent)(options)" 'a call without an object literal'
expect_rejected negated-guard "$option_line" "yo=o.configProvider.get(),!$guard_expr;$explicit_call" 'a negated guard'
expect_rejected optional-call "$option_line" "$guarded_call;q.updateCursorAgent?.({isAutoUpdate:!1})" 'an optional call'
expect_rejected computed-call "$option_line" "$guarded_call;q[\"updateCursorAgent\"]({isAutoUpdate:!1})" 'a computed call'
expect_rejected alias "$option_line" "$guarded_call;const f=q.updateCursorAgent;f({isAutoUpdate:!0})" 'an alias'
expect_rejected spread "$option_line" "$guarded_call;(0,o.updateCursorAgent)({isAutoUpdate:!1,...options})" 'a spread argument'
expect_rejected duplicate-key "$option_line" "$guarded_call;(0,o.updateCursorAgent)({isAutoUpdate:!1,isAutoUpdate:!0})" 'a duplicated isAutoUpdate'
expect_rejected local-call "$option_line" "$guarded_call" 'a call of the local binding inside its module' \
  '"./src/commands/update-core.ts"(e,t,n){n.d(t,{shouldDoUpdate:()=>p,updateCursorAgent:()=>m});function m(e){return 1}function p(){return m({isAutoUpdate:!0})}}'
expect_rejected no-export "$option_line" "$guarded_call" 'a bundle without the updater export' 'var nothing=1'

# NIX-516 — the wrapper keeps argv[2] and each name. Fake launchers print
# their name and arguments.
mkdir -p "$fixture_dir/libexec" "$fixture_dir/bin"
for name in cursor-agent agent; do
  # shellcheck disable=SC2016 # literal Nix and bundle text, not expansions
  printf '#!/usr/bin/env bash\nIFS="|"; printf "%%s|%%s\\n" "${0##*/}" "$*"\n' >"$fixture_dir/libexec/$name"
  chmod +x "$fixture_dir/libexec/$name"
done
sed -e "s#@shell@#$(command -v bash)#" -e "s#@libexec@#$fixture_dir/libexec#" "$wrapper_template" >"$fixture_dir/bin/cursor-agent"
chmod +x "$fixture_dir/bin/cursor-agent"
ln -s cursor-agent "$fixture_dir/bin/agent"
expect_argv() { # <expected> <name> [args...]
  local expected=$1 name=$2 got
  shift 2
  got=$("$fixture_dir/bin/$name" "$@")
  [ "$got" = "$expected" ] || fail "wrapper: $name $* -> $got, expected $expected"
}
# The flag goes first where argv[2] is absent or an option.
expect_argv 'cursor-agent|--disable-auto-update' cursor-agent
expect_argv 'cursor-agent|--disable-auto-update|--print|--output-format|stream-json|hi there' cursor-agent --print --output-format stream-json 'hi there'
expect_argv 'cursor-agent|--disable-auto-update|--model|gpt|acp' cursor-agent --model gpt acp
expect_argv 'agent|--disable-auto-update|-p|hi' agent -p hi
# Chat commands no raw parser reads take it after their name.
expect_argv 'cursor-agent|resume|--disable-auto-update|chat-1' cursor-agent resume chat-1
expect_argv 'agent|ls|--disable-auto-update' agent ls
expect_argv 'cursor-agent|sandbox|--disable-auto-update|run' cursor-agent sandbox run
# Words the raw parsers read, prompts and unknown words pass unchanged.
for words in 'persist|list' 'persist|--help' 'persist|attach|s1' 'acp' 'agent|acp' 'help|bedrock' 'bedrock|--help' 'fix the bug' '--cursor-persist-restore|0123456789abcdef0123456789abcdef|s1' 'update' 'models'; do
  IFS='|' read -r -a argv <<<"$words"
  expect_argv "cursor-agent|$words" cursor-agent "${argv[@]}"
done
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
  for name in cursor-agent agent; do
    [ "$(readlink "$package_out/libexec/cursor-agent/$name")" = ../../share/cursor-agent/cursor-agent ] ||
      fail "libexec link $name does not reach the vendor launcher"
  done
  "$package_out/share/cursor-agent/node" "$auto_update_check" "$package_out/share/cursor-agent" >/dev/null ||
    fail 'realised bundle fails the auto-update check'
  codesign --verify --strict "$package_out/share/cursor-agent/node" || fail 'vendor node signature broken in the store'
  codesign --verify --strict "$package_out/share/cursor-agent/cursorsandbox" || fail 'vendor sandbox helper signature broken in the store'
fi

printf 'T85 passed: Cursor CLI %s is one pinned package for every harness and consumer\n' "$pinned"
