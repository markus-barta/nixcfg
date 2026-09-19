#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  printf 'T86 failed: %s\n' "$*" >&2
  exit 1
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/t86.XXXXXX")
cleanup() {
  find "$tmp" -depth -type f -delete
  find "$tmp" -depth -type d -empty -delete
}
trap cleanup EXIT

mkdir -p "$tmp/bin" "$tmp/scripts" "$tmp/pkgs/cursor-agent"
cp "$repo_root/scripts/update-cursor-agent.sh" "$tmp/scripts/update-cursor-agent.sh"
cp "$repo_root/pkgs/cursor-agent/sources.json" "$tmp/pkgs/cursor-agent/sources.json"
cp "$tmp/pkgs/cursor-agent/sources.json" "$tmp/expected-sources.json"
chmod +x "$tmp/scripts/update-cursor-agent.sh"

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'DOWNLOAD_URL="https://downloads.cursor.com/lab/2099.01.01-abcdef1/${OS}/${ARCH}/agent-cli-package.tar.gz"'
EOF
cat >"$tmp/bin/nix" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$T86_NIX_LOG"
if [ "${1-}" = eval ]; then
  printf '%s\n' "$T86_SYSTEM"
  exit 0
fi
exit 99
EOF
chmod +x "$tmp/bin/curl" "$tmp/bin/nix"

export PATH="$tmp/bin:$PATH"
export T86_NIX_LOG="$tmp/nix.log"
export T86_SYSTEM=x86_64-linux
unset CURSOR_AGENT_SOURCES CURSOR_INSTALL_URL

update_script=$tmp/scripts/update-cursor-agent.sh
sources=$tmp/pkgs/cursor-agent/sources.json
lock_dir=$sources.lock
output=$tmp/output

assert_clean() {
  [ ! -e "$lock_dir" ] || fail "lock directory remains: $lock_dir"
  for temp_file in "$sources".tmp.*; do
    [ -e "$temp_file" ] || continue
    fail "temporary sources file remains: $temp_file"
  done
}

: >"$T86_NIX_LOG"
if "$update_script" >"$output" 2>&1; then
  fail 'unsupported host was accepted'
fi
grep -Fq 'unsupported current system x86_64-linux' "$output" || fail 'unsupported message omits the system'
grep -Fq 'pinned systems: aarch64-darwin' "$output" || fail 'unsupported message omits pinned systems'
cmp -s "$sources" "$tmp/expected-sources.json" || fail 'unsupported host changed sources.json'
if grep -Fq 'store prefetch-file' "$T86_NIX_LOG" || grep -Fq 'build' "$T86_NIX_LOG"; then
  fail 'unsupported host prefetched or built'
fi
assert_clean

: >"$T86_NIX_LOG"
mkdir "$lock_dir"
sleep 60 &
holder_pid=$!
printf '%s\n' "$holder_pid" >"$lock_dir/pid"
if "$update_script" >"$output" 2>&1; then
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  fail 'live lock was ignored'
fi
grep -Fq 'update lock held by PID' "$output" || fail 'live lock message is missing'
cmp -s "$sources" "$tmp/expected-sources.json" || fail 'live lock changed sources.json'
[ ! -s "$T86_NIX_LOG" ] || fail 'live lock allowed a nix operation'
kill "$holder_pid"
wait "$holder_pid" 2>/dev/null || true
rm -f "$lock_dir/pid"
rmdir "$lock_dir"
assert_clean

: >"$T86_NIX_LOG"
printf '%s\n' "$holder_pid" >"$tmp/stale-pid"
mkdir "$lock_dir"
cp "$tmp/stale-pid" "$lock_dir/pid"
if "$update_script" >"$output" 2>&1; then
  fail 'stale-lock case accepted unsupported host'
fi
grep -Fq 'unsupported current system x86_64-linux' "$output" || fail 'stale lock did not proceed to host refusal'
cmp -s "$sources" "$tmp/expected-sources.json" || fail 'stale lock changed sources.json'
grep -Fq 'eval --impure --raw --expr builtins.currentSystem' "$T86_NIX_LOG" || fail 'stale-lock case did not evaluate the system'
if grep -Fq 'store prefetch-file' "$T86_NIX_LOG" || grep -Fq 'build' "$T86_NIX_LOG"; then
  fail 'stale-lock case prefetched or built'
fi
assert_clean

printf 'T86 passed: Cursor CLI update locking and host safety are enforced offline\n'
