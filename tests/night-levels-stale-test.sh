#!/bin/bash
# Usage: bash tests/night-levels-stale-test.sh .tmp/night-levels-stale.sh
# Pass the staleScript rendered by mbp2607-night-levels-eval.nix, never the loop.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
script=${1:?pass the rendered stale script path}
mkdir -p "$root/.tmp"
test_dir=$(mktemp -d "$root/.tmp/night-levels-stale-test.XXXXXXXX")

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_count() {
  local expected=$1 file=$2 count=0 line
  while IFS= read -r line; do count=$((count + 1)); done < "$file"
  [ "$count" -eq "$expected" ] || fail "$file: expected $expected calls, got $count"
}
expect_text() {
  local file=$1 text=$2 contents
  contents=$(< "$file")
  [[ "$contents" == *"$text"* ]] || fail "$file: missing $text"
}

# These are the only executables the watcher can use for MBX and launchctl.
cat > "$test_dir/mbx" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$NL_TEST_MESSAGES"
exit "${NL_TEST_MBX_RC:-0}"
STUB
cat > "$test_dir/launchctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$NL_TEST_KICKSTARTS"
exit "${NL_TEST_LAUNCHCTL_RC:-0}"
STUB
chmod +x "$test_dir/mbx" "$test_dir/launchctl"

new_case() {
  case_dir="$test_dir/$1"
  mkdir -p "$case_dir/home/.local/share/ops-qa/state"
  state="$case_dir/home/.local/share/ops-qa/state/night-levels-stale.state"
  heartbeat="$case_dir/heartbeat"
  : > "$case_dir/messages"
  : > "$case_dir/kickstarts"
  : > "$case_dir/log"
  mbx_rc=0
  launchctl_rc=0
}
fresh() { printf 'epoch=%s mbp2607=GREEN mbp2606=GREEN\n' "$(/bin/date +%s)" > "$heartbeat"; }
stale() { printf 'epoch=1 mbp2607=GREEN mbp2606=GREEN\n' > "$heartbeat"; }
run_watcher() {
  local rc=0
  HOME="$case_dir/home" NL_HEARTBEAT="$heartbeat" \
    MBX="$test_dir/mbx" LAUNCHCTL="$test_dir/launchctl" \
    NL_TEST_MESSAGES="$case_dir/messages" NL_TEST_KICKSTARTS="$case_dir/kickstarts" \
    NL_TEST_MBX_RC="$mbx_rc" NL_TEST_LAUNCHCTL_RC="$launchctl_rc" \
    /bin/bash "$script" >> "$case_dir/log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "watcher exited $rc"
}

new_case transitions
fresh; run_watcher
stale; run_watcher
run_watcher
fresh; run_watcher
expect_count 2 "$case_dir/messages"
expect_count 1 "$case_dir/kickstarts"
expect_text "$case_dir/messages" 'kickstart attempted (exit 0)'
expect_text "$case_dir/messages" 'heartbeat recovered'
expect_text "$case_dir/messages" 'maxload 12, maxruns 1, level UNKNOWN'
expect_text "$case_dir/kickstarts" "kickstart -k gui/$(/usr/bin/id -u)/org.nix-community.home.night-levels"
[ "$(< "$state")" = ok ] || fail 'recovery did not persist ok'
printf 'PASS: ok -> stale -> stale -> ok: 2 messages, 1 kickstart\n'

new_case missing-heartbeat
run_watcher; run_watcher
expect_count 1 "$case_dir/messages"
expect_count 1 "$case_dir/kickstarts"
[ "$(< "$state")" = stale ] || fail 'missing heartbeat was not stale'
printf 'PASS: missing heartbeat counts as stale, with no repeated attempt\n'

new_case malformed-heartbeat
printf 'epoch=invalid\n' > "$heartbeat"
run_watcher
expect_count 1 "$case_dir/messages"
[ "$(< "$state")" = stale ] || fail 'malformed heartbeat was not stale'
printf 'PASS: malformed heartbeat counts as stale\n'

new_case invalid-state
printf 'unexpected\n' > "$state"
fresh; run_watcher
expect_count 0 "$case_dir/messages"
printf 'unexpected\n' > "$state"
stale; run_watcher
expect_count 1 "$case_dir/messages"
expect_count 1 "$case_dir/kickstarts"
printf 'PASS: invalid previous state normalizes to ok\n'

new_case failures
stale
mbx_rc=7
launchctl_rc=9
run_watcher; run_watcher
expect_count 1 "$case_dir/messages"
expect_count 1 "$case_dir/kickstarts"
expect_text "$case_dir/log" 'launchctl kickstart -k night-levels exited 9'
expect_text "$case_dir/log" 'mbx send failed (exit 7)'
expect_text "$case_dir/messages" 'kickstart attempted (exit 9)'
printf 'PASS: failing mbx and launchctl still exit 0, with no repeated attempt\n'
printf 'Fixtures retained under %s\n' "$test_dir"
