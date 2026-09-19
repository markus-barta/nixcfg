#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'T86 failed: %s\n' "$*" >&2
  exit 1
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/t86.XXXXXX")
tmp=$(cd -- "$tmp" && pwd)
holder_pid=''
slow_build_pid=''
stop_holder() {
  if [ -n "$holder_pid" ]; then
    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
    holder_pid=''
  fi
}
stop_slow_build() {
  if [ -n "$slow_build_pid" ]; then
    kill "$slow_build_pid" 2>/dev/null || true
    slow_build_pid=''
  fi
}
cleanup() {
  stop_holder
  stop_slow_build
  find "$tmp" -depth -type f -delete
  find "$tmp" -depth -type l -delete
  find "$tmp" -depth -type d -empty -delete
}
trap cleanup EXIT

mkdir -p "$tmp/bin" "$tmp/scripts" "$tmp/pkgs/cursor-agent"
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cp "$repo_root/scripts/update-cursor-agent.sh" "$tmp/scripts/update-cursor-agent.sh"
cat >"$tmp/fixture-sources.json" <<'EOF'
{
  "version": "2098.01.01-deadbee",
  "assets": {
    "aarch64-darwin": {
      "os": "darwin",
      "arch": "arm64",
      "hash": "sha256-OLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLD"
    }
  }
}
EOF
cp "$tmp/fixture-sources.json" "$tmp/pkgs/cursor-agent/sources.json"
chmod 0644 "$tmp/pkgs/cursor-agent/sources.json"
chmod +x "$tmp/scripts/update-cursor-agent.sh"
mkdir "$tmp/tmp"
export TMPDIR="$tmp/tmp"

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'DOWNLOAD_URL="https://downloads.cursor.com/lab/2099.01.01-abcdef1/${OS}/${ARCH}/agent-cli-package.tar.gz"'
EOF
cat >"$tmp/bin/nix" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$T86_NIX_LOG"
case "${1-}" in
eval)
  printf '%s\n' "$T86_SYSTEM"
  ;;
store)
  printf '%s\n' '{"hash":"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}'
  ;;
build)
  [ "${T86_NIX_BUILD_FAIL-}" != 1 ] || exit 1
  if [ -n "${T86_NIX_BUILD_SLEEP-}" ]; then
    printf '%s\n' "$$" >"$T86_SLOW_BUILD_PID"
    exec sleep "$T86_NIX_BUILD_SLEEP"
  fi
  printf '%s\n' "$T86_OUT"
  ;;
*) exit 99 ;;
esac
EOF
cat >"$tmp/bin/bash" <<'EOF'
#!/bin/sh
exec /bin/bash "$@"
EOF
chmod +x "$tmp/bin/curl" "$tmp/bin/nix" "$tmp/bin/bash"

export PATH="$tmp/bin:$PATH"
export T86_NIX_LOG="$tmp/nix.log"
export T86_SYSTEM=x86_64-linux
export T86_NIX_BUILD_FAIL=0
export T86_OUT="$tmp/store/cursor-agent"
export T86_SLOW_BUILD_PID="$tmp/slow-build.pid"
unset CURSOR_AGENT_SOURCES CURSOR_INSTALL_URL

update_script=$tmp/scripts/update-cursor-agent.sh
sources=$tmp/pkgs/cursor-agent/sources.json
fixture=$tmp/fixture-sources.json
lock_dir=$sources.lock
output=$tmp/output
release=2099.01.01-abcdef1

reset_sources() {
  cp "$fixture" "$sources"
  chmod 0644 "$sources"
}

assert_no_temp_files() {
  for temp_file in "$sources".tmp.* "$TMPDIR"/cursor-agent-sources.*; do
    [ -e "$temp_file" ] || continue
    fail "temporary file remains: $temp_file"
  done
}

assert_clean() {
  [ ! -e "$lock_dir" ] && [ ! -L "$lock_dir" ] || fail "lock remains: $lock_dir"
  [ ! -e "$lock_dir.reclaim" ] || fail "reclaim guard remains: $lock_dir.reclaim"
  assert_no_temp_files
}

: >"$T86_NIX_LOG"
if "$update_script" >"$output" 2>&1; then
  fail 'unsupported host was accepted'
fi
grep -Fq 'unsupported current system x86_64-linux' "$output" || fail 'unsupported message omits the system'
grep -Fq 'pinned systems: aarch64-darwin' "$output" || fail 'unsupported message omits pinned systems'
cmp -s "$sources" "$fixture" || fail 'unsupported host changed sources.json'
if grep -Fq 'store prefetch-file' "$T86_NIX_LOG" || grep -Fq 'build' "$T86_NIX_LOG"; then
  fail 'unsupported host prefetched or built'
fi
assert_clean

reset_sources
jq 'del(.assets)' "$sources" >"$tmp/no-assets.json"
cp "$tmp/no-assets.json" "$sources"
cp "$sources" "$tmp/expected-no-assets.json"
: >"$T86_NIX_LOG"
if "$update_script" >"$output" 2>&1; then
  fail 'missing assets object was accepted'
fi
grep -Fq 'sources.json has no assets object' "$output" || fail 'missing assets message is unclear'
cmp -s "$sources" "$tmp/expected-no-assets.json" || fail 'missing assets changed sources.json'
if grep -Fq 'store prefetch-file' "$T86_NIX_LOG" || grep -Fq 'build' "$T86_NIX_LOG"; then
  fail 'missing assets prefetched or built'
fi
assert_clean
reset_sources

: >"$T86_NIX_LOG"
sleep 60 &
holder_pid=$!
ln -s "$holder_pid" "$lock_dir"
if "$update_script" >"$output" 2>&1; then
  fail 'live lock was ignored'
fi
grep -Fq "update lock held by PID $holder_pid" "$output" || fail 'live lock message is missing the PID'
grep -Fq "rm \"$lock_dir\"" "$output" || fail 'live lock message has no crash recovery command'
cmp -s "$sources" "$fixture" || fail 'live lock changed sources.json'
[ ! -s "$T86_NIX_LOG" ] || fail 'live lock allowed a nix operation'
[ "$(readlink "$lock_dir")" = "$holder_pid" ] || fail 'live holder lock was replaced'
stop_holder
rm -f "$lock_dir"
assert_clean

: >"$T86_NIX_LOG"
ln -s 1 "$lock_dir"
if "$update_script" >"$output" 2>&1; then
  fail 'PID 1 lock was ignored'
fi
grep -Fq 'update lock held by PID 1' "$output" || fail 'PID 1 lock message is missing the PID'
cmp -s "$sources" "$fixture" || fail 'PID 1 lock changed sources.json'
[ ! -s "$T86_NIX_LOG" ] || fail 'PID 1 lock allowed a nix operation'
[ "$(readlink "$lock_dir")" = 1 ] || fail 'PID 1 lock was replaced'
rm -f "$lock_dir"
assert_clean

: >"$T86_NIX_LOG"
mkdir "$lock_dir"
if "$update_script" >"$output" 2>&1; then
  fail 'directory lock was accepted'
fi
grep -Fq "update lock path $lock_dir is a directory" "$output" || fail 'directory lock message is unclear'
cmp -s "$sources" "$fixture" || fail 'directory lock changed sources.json'
[ -z "$(find "$lock_dir" -mindepth 1 -maxdepth 1 -type l -print -quit)" ] || fail 'directory lock left a stray symlink'
[ ! -s "$T86_NIX_LOG" ] || fail 'directory lock allowed a nix operation'
rmdir "$lock_dir"
assert_clean

: >"$T86_NIX_LOG"
elsewhere=$tmp/elsewhere
mkdir "$elsewhere"
ln -s "$elsewhere" "$lock_dir"
if "$update_script" >"$output" 2>&1; then
  fail 'directory symlink lock was accepted'
fi
grep -Fq "update lock path $lock_dir is a directory" "$output" || fail 'directory symlink lock message is unclear'
cmp -s "$sources" "$fixture" || fail 'directory symlink lock changed sources.json'
[ -z "$(find "$elsewhere" -mindepth 1 -maxdepth 1 -print -quit)" ] || fail 'directory symlink lock left a stray symlink'
[ -L "$lock_dir" ] || fail 'directory symlink lock was removed'
[ "$(readlink "$lock_dir")" = "$elsewhere" ] || fail 'directory symlink lock was replaced'
[ ! -s "$T86_NIX_LOG" ] || fail 'directory symlink lock allowed a nix operation'
rm -f "$lock_dir"
rmdir "$elsewhere"
assert_clean

: >"$T86_NIX_LOG"
ln -s 99999999 "$lock_dir"
mkdir "$lock_dir.reclaim"
if "$update_script" >"$output" 2>&1; then
  fail 'existing reclaim guard was ignored'
fi
grep -Fq "$lock_dir.reclaim exists; remove it once no update runs" "$output" || fail 'reclaim guard message is unclear'
cmp -s "$sources" "$fixture" || fail 'reclaim guard changed sources.json'
[ -d "$lock_dir.reclaim" ] || fail 'other reclaim guard was removed'
[ "$(readlink "$lock_dir")" = 99999999 ] || fail 'reclaim guard changed stale lock'
[ ! -s "$T86_NIX_LOG" ] || fail 'reclaim guard allowed a nix operation'
rmdir "$lock_dir.reclaim"
rm -f "$lock_dir"
assert_clean

: >"$T86_NIX_LOG"
ln -s 99999999 "$lock_dir"
if "$update_script" >"$output" 2>&1; then
  fail 'stale-lock case accepted unsupported host'
fi
grep -Fq 'unsupported current system x86_64-linux' "$output" || fail 'stale lock did not proceed to host refusal'
cmp -s "$sources" "$fixture" || fail 'stale lock changed sources.json'
grep -Fq 'eval --impure --raw --expr builtins.currentSystem' "$T86_NIX_LOG" || fail 'stale-lock case did not evaluate the system'
if grep -Fq 'store prefetch-file' "$T86_NIX_LOG" || grep -Fq 'build' "$T86_NIX_LOG"; then
  fail 'stale-lock case prefetched or built'
fi
assert_clean

reset_sources
export T86_SYSTEM=aarch64-darwin
export T86_NIX_BUILD_FAIL=1
: >"$T86_NIX_LOG"
if "$update_script" >"$output" 2>&1; then
  fail 'failed build was accepted'
fi
grep -Fq 'build of 2099.01.01-abcdef1 failed' "$output" || fail 'failed build message is missing'
grep -Fq 'bump not verified — pin restored to 2098.01.01-deadbee' "$output" || fail 'failed build did not restore the pin'
cmp -s "$sources" "$fixture" || fail 'failed build did not restore sources.json byte-for-byte'
grep -Fq 'store prefetch-file' "$T86_NIX_LOG" || fail 'restore case did not prefetch'
grep -Fq 'build --no-link --print-out-paths' "$T86_NIX_LOG" || fail 'restore case did not build'
assert_clean

reset_sources
mkdir -p "$T86_OUT/bin"
cat >"$T86_OUT/bin/cursor-agent" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '2099.01.01-notmatch'
EOF
chmod +x "$T86_OUT/bin/cursor-agent"
export T86_NIX_BUILD_FAIL=0
: >"$T86_NIX_LOG"
if "$update_script" >"$output" 2>&1; then
  fail 'version mismatch was accepted'
fi
grep -Fq 'built CLI reports 2099.01.01-notmatch, expected 2099.01.01-abcdef1' "$output" || fail 'version mismatch message is missing'
grep -Fq 'bump not verified — pin restored to 2098.01.01-deadbee' "$output" || fail 'version mismatch did not restore the pin'
cmp -s "$sources" "$fixture" || fail 'version mismatch did not restore sources.json byte-for-byte'
grep -Fq 'build --no-link --print-out-paths' "$T86_NIX_LOG" || fail 'version mismatch did not build'
assert_clean

reset_sources
cat >"$T86_OUT/bin/cursor-agent" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '2099.01.01-abcdef1'
EOF
chmod +x "$T86_OUT/bin/cursor-agent"
export T86_NIX_BUILD_FAIL=0
: >"$T86_NIX_LOG"
"$update_script" >"$output" 2>&1 || fail 'successful build was rejected'
grep -Fq 'built and verified' "$output" || fail 'success message is missing'
[ "$(jq -er '.version' "$sources")" = "$release" ] || fail 'success did not write the new version'
[ "$(jq -er '.assets["aarch64-darwin"].hash' "$sources")" = 'sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' ] ||
  fail 'success did not write the prefetched hash'
if mode=$(stat -f '%Lp' "$sources" 2>/dev/null); then
  :
else
  mode=$(stat -c '%a' "$sources")
fi
[ "$mode" = 644 ] || fail "success changed sources.json mode to $mode"
assert_clean

export T86_NIX_BUILD_FAIL=1
: >"$T86_NIX_LOG"
"$update_script" >"$output" 2>&1 || fail 'current pin was rejected'
grep -Fq "pin $release is current" "$output" || fail 'current pin message is missing'
[ ! -s "$T86_NIX_LOG" ] || fail 'current pin ran nix'
assert_clean

reset_sources
export T86_NIX_BUILD_FAIL=0
export T86_NIX_BUILD_SLEEP=2
: >"$T86_NIX_LOG"
rm -f "$T86_SLOW_BUILD_PID"
"$update_script" >"$output" 2>&1 &
update_pid=$!
attempts=0
while [ ! -s "$T86_SLOW_BUILD_PID" ]; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 50 ] || fail 'slow build did not start'
  sleep 0.1
done
slow_build_pid=$(<"$T86_SLOW_BUILD_PID")
kill -TERM "$update_pid"
if wait "$update_pid"; then
  fail 'TERM during build was accepted'
else
  update_status=$?
fi
[ "$update_status" = 143 ] || fail "TERM during build exited $update_status, expected 143"
stop_slow_build
unset T86_NIX_BUILD_SLEEP
cmp -s "$sources" "$fixture" || fail 'TERM during build did not restore sources.json byte-for-byte'
grep -Fq 'bump not verified — pin restored to 2098.01.01-deadbee' "$output" || fail 'TERM during build did not report restoration'
assert_clean

printf 'T86 passed: offline lock ownership, reclaim refusal, rollback, version verification, and TERM recovery are enforced\n'
