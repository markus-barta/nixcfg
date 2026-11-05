#!/bin/bash
# OPS-563: exercise the guard on disposable local bundles, never the host Xcode.
# Run as an ordinary user on any Mac. Every Xcode command is a stub, including
# commands run through a clean environment. Temporary fixtures stay in TMPDIR
# for inspection; there is no recursive cleanup or privileged operation.
set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 022
if [ "$EUID" -eq 0 ]; then
  printf 'FAIL tests must run as non-root; no fixtures or guard were run.\n' >&2
  exit 1
fi
HERE=$(cd "${0%/*}" && pwd) || exit 1
GUARD=$HERE/xcode-guard.sh
ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/xcode-guard-test.XXXXXXXX") || exit 1
ROOT=$(cd "$ROOT" && pwd) || exit 1
passed=0
failed=0

die() {
  printf '  FAIL %s\n' "$*" >&2
  exit 1
}
equal() { [ "$1" = "$2" ] || die "$3"; }
contains() { /usr/bin/grep -Fq -- "$2" "$1" || die "$3"; }
absent() { [ ! -e "$1" ] && [ ! -L "$1" ] || die "$2"; }
expect_rc() {
  local wanted=$1 actual
  shift
  "$@" >"$CASE/output" 2>&1
  actual=$?
  [ "$actual" -eq "$wanted" ] || {
    /bin/cat "$CASE/output" >&2
    die "expected exit $wanted, got $actual"
  }
}
# Arguments also arrive through expect_rc's function dispatch.
# shellcheck disable=SC2120
guard() { /bin/bash "$GUARD" "$@"; }
selection() { /bin/cat "$CASE/current"; }
switches() { /usr/bin/wc -l <"$CASE/switches" | /usr/bin/tr -d ' '; }

fixture() {
  CASE=$ROOT/$1
  APP=$CASE/Xcode-27.1.app
  DEV=$APP/Contents/Developer
  OLD=$CASE/CommandLineTools
  OTHER=$CASE/OtherDeveloper
  /bin/mkdir -p "$DEV/usr/bin" "$OLD" "$OTHER" "$CASE/tools" || die 'mkdir fixture'
  printf '#!/bin/bash\nexit 0\n' >"$DEV/usr/bin/simctl"
  /bin/chmod 755 "$DEV/usr/bin/simctl" || die 'chmod simctl'
  printf '%s\n' "$OLD" >"$CASE/current"
  : >"$CASE/switches"
  : >"$CASE/calls"
  /bin/cat >"$CASE/tools/xcode-select" <<'STUB'
#!/bin/bash
base=$(cd "${0%/*}/.." && pwd) || exit 1
[ "$PATH" = /usr/bin:/bin ] && [ -z "${DEVELOPER_DIR+x}" ] || exit 2
case "$1" in
  -p) [ ! -f "$base/select-read-fail" ] || exit 1; /bin/cat "$base/current" ;;
  --switch)
    printf '%s\n' "$2" >> "$base/switches"
    if [ -f "$base/switch-fail" ] && [ "$2" = "$base/Xcode-27.1.app/Contents/Developer" ]; then
      exit 1
    fi
    if [ -f "$base/select-verify-fail" ] && [ "$2" = "$base/Xcode-27.1.app/Contents/Developer" ]; then
      printf '%s\n' "$base/OtherDeveloper" > "$base/current"
    else
      printf '%s\n' "$2" > "$base/current"
    fi ;;
  *) exit 2 ;;
esac
STUB
  /bin/cat >"$CASE/tools/xcodebuild" <<'STUB'
#!/bin/bash
base=$(cd "${0%/*}/.." && pwd) || exit 1
printf 'build\n' >> "$base/calls"
[ "$#" -eq 1 ] && [ "$1" = -version ] || exit 2
[ "$PATH" = /usr/bin:/bin ] || exit 2
[ "$DEVELOPER_DIR" = "$base/Xcode-27.1.app/Contents/Developer" ] || exit 2
[ -z "${XG_TEST:-}" ] || exit 2
if [ -f "$base/version-fail" ]; then
  printf 'Xcode 27.0\nBuild version 27A0000\n'
elif [ -f "$base/build-fail" ]; then
  printf 'Xcode 27.1\nBuild version 27A0000\n'
else
  printf 'Xcode 27.1\nBuild version 27A9275\n'
fi
STUB
  /bin/cat >"$CASE/tools/xcrun" <<'STUB'
#!/bin/bash
base=$(cd "${0%/*}/.." && pwd) || exit 1
printf 'xcrun\n' >> "$base/calls"
[ "$#" -eq 2 ] && [ "$1" = --find ] && [ "$2" = simctl ] || exit 2
[ "$PATH" = /usr/bin:/bin ] && [ -z "${DEVELOPER_DIR+x}" ] || exit 2
[ -z "${XG_TEST:-}" ] || exit 2
if [ -f "$base/xcrun-fail" ]; then
  printf '/wrong/simctl\n'
else
  printf '%s\n' "$base/Xcode-27.1.app/Contents/Developer/usr/bin/simctl"
fi
STUB
  /bin/cat >"$CASE/tools/codesign" <<'STUB'
#!/bin/bash
base=$(cd "${0%/*}/.." && pwd) || exit 1
printf 'codesign\n' >> "$base/calls"
[ "$#" -eq 4 ] && [ "$1" = --verify ] && [ "$2" = --deep ] && [ "$3" = --strict ] || exit 2
[ "$4" = "$base/Xcode-27.1.app" ] || exit 2
if [ -f "$base/slow" ]; then
  : > "$base/entered"
  /bin/sleep 2
fi
[ ! -f "$base/codesign-fail" ]
STUB
  /bin/chmod 755 "$CASE/tools/"* || die 'chmod tools'
  # Each subprocess gets only overrides pointing into this fixture. The real
  # lockf/stat/find exercise macOS semantics; the real select is never used.
  export XG_TEST=1 XG_APP="$APP" XG_STATE="$CASE/state" XG_LOG="$CASE/guard.log"
  export XG_EXPECT_OWNER="$EUID" XG_SELECT="$CASE/tools/xcode-select"
  export XG_BUILD="$CASE/tools/xcodebuild" XG_XCRUN="$CASE/tools/xcrun"
  export XG_CODESIGN="$CASE/tools/codesign"
  unset CM_XCODE_GUARD_LOCKED
}

switch_and_prior() {
  expect_rc 0 guard
  equal "$(selection)" "$DEV" 'first enforcement did not switch'
  equal "$(/bin/cat "$CASE/state/prior-selection")" "$OLD" 'prior was not recorded'
  equal "$(/usr/bin/stat -f %OLp "$CASE/state")" 755 'state mode is not 755'
  equal "$(/usr/bin/stat -f %OLp "$CASE/state/prior-selection")" 644 'prior mode is not 644'
  printf '%s\n' "$OTHER" >"$CASE/current"
  expect_rc 0 guard
  equal "$(selection)" "$DEV" 'second enforcement did not switch'
  equal "$(/bin/cat "$CASE/state/prior-selection")" "$OLD" 'first prior was overwritten'
}
idempotent() {
  printf '%s\n' "$DEV" >"$CASE/current"
  expect_rc 0 guard
  equal "$(switches)" 0 'already selected guard switched'
  absent "$CASE/state/prior-selection" 'already selected guard wrote a prior'
  equal "$(/usr/bin/wc -l <"$CASE/guard.log" | /usr/bin/tr -d ' ')" 1 'idempotent guard is noisy'
  contains "$CASE/calls" codesign 'already selected guard skipped validation'
}
reject_check() {
  expect_rc 1 guard
  equal "$(selection)" "$OLD" 'failed validation changed selection'
  equal "$(switches)" 0 'failed validation attempted switch'
  absent "$CASE/state/prior-selection" 'failed validation recorded prior'
  contains "$CASE/guard.log" "check $1:" 'failure reason not logged'
}
directory_permissions() {
  /bin/chmod g+w "$APP/Contents"
  reject_check 1
}
directory_symlink() {
  /bin/mv "$DEV/usr/bin" "$DEV/usr/real-bin" || die 'move bin'
  /bin/ln -s real-bin "$DEV/usr/bin" || die 'link bin'
  reject_check 1
}
directory_owner() {
  /bin/cat >"$CASE/tools/stat" <<'STUB'
#!/bin/bash
case "$3" in */Xcode-27.1.app) printf '0 755\n' ;; *) /usr/bin/stat "$@" ;; esac
STUB
  /bin/chmod 755 "$CASE/tools/stat"
  export XG_STAT="$CASE/tools/stat"
  reject_check 1
}
bundle_permissions() {
  : >"$DEV/unsafe"
  /bin/chmod o+w "$DEV/unsafe"
  reject_check 2
}
bundle_directory_permissions() {
  /bin/chmod g+w "$DEV/usr"
  reject_check 2
}
bundle_owner() {
  /bin/cat >"$CASE/tools/find" <<'STUB'
#!/bin/bash
# Simulate a foreign-owned descendant; changing ownership needs root.
printf 'foreign-owned-entry\n'
STUB
  /bin/chmod 755 "$CASE/tools/find"
  export XG_FIND="$CASE/tools/find"
  reject_check 2
}
find_failure() {
  export XG_FIND=/usr/bin/false
  reject_check 2
}
simctl_missing() {
  /bin/mv "$DEV/usr/bin/simctl" "$CASE/simctl.saved"
  reject_check 3
}
simctl_nonexec() {
  /bin/chmod 644 "$DEV/usr/bin/simctl"
  reject_check 3
}
simctl_symlink() {
  /bin/mv "$DEV/usr/bin/simctl" "$DEV/usr/bin/simctl-real"
  /bin/ln -s simctl-real "$DEV/usr/bin/simctl"
  reject_check 3
}
version_failure() {
  : >"$CASE/version-fail"
  reject_check 4
}
build_failure() {
  : >"$CASE/build-fail"
  reject_check 4
}
signature_failure() {
  : >"$CASE/codesign-fail"
  reject_check 5
}
selected_invalid() {
  printf '%s\n' "$DEV" >"$CASE/current"
  : >"$CASE/codesign-fail"
  expect_rc 1 guard
  equal "$(selection)" "$DEV" 'invalid selected bundle was switched back'
  equal "$(switches)" 0 'invalid selected bundle caused a switch'
  contains "$CASE/guard.log" ALERT 'invalid selected bundle did not log loudly'
}
verify_restore() {
  : >"$CASE/xcrun-fail"
  expect_rc 1 guard
  equal "$(selection)" "$OLD" 'xcrun failure did not restore selection'
  equal "$(switches)" 2 'expected target switch and restoration'
  # Recovery must use this run's selection, even with an older prior record.
  printf '%s\n' "$OTHER" >"$CASE/current"
  expect_rc 1 guard
  equal "$(selection)" "$OTHER" 'recovery used first prior instead of current selection'
}
select_verify_restore() {
  : >"$CASE/select-verify-fail"
  expect_rc 1 guard
  equal "$(selection)" "$OLD" 'selection verification failure did not restore'
}
switch_failure() {
  : >"$CASE/switch-fail"
  expect_rc 1 guard
  equal "$(selection)" "$OLD" 'switch failure changed selection'
  contains "$CASE/guard.log" restored 'switch failure did not attempt restoration'
}
check_readonly() {
  expect_rc 0 guard --check
  contains "$CASE/output" 'enforce would preserve' 'check did not describe switch'
  contains "$CASE/output" 'PASS check 5' 'check skipped signature validation'
  equal "$(selection)" "$OLD" 'check changed selection'
  equal "$(switches)" 0 'check attempted switch'
  absent "$CASE/state" 'check created state'
  absent "$CASE/guard.log" 'check created log'
  printf '%s\n' "$DEV" >"$CASE/current"
  expect_rc 0 guard --check
  contains "$CASE/output" 'already selected' 'check missed idempotent case'
  : >"$CASE/version-fail"
  expect_rc 1 guard --check
  contains "$CASE/output" 'FAIL check 4' 'check did not report failed version'
  contains "$CASE/output" 'PASS check 5' 'check stopped at first failure'
  absent "$CASE/state" 'failed check created state'
  absent "$CASE/guard.log" 'failed check created log'
}
check_all_failures() {
  /bin/chmod g+w "$APP/Contents"
  /bin/chmod 644 "$DEV/usr/bin/simctl"
  : >"$CASE/version-fail"
  : >"$CASE/codesign-fail"
  expect_rc 1 guard --check
  local n
  for n in 1 2 3 4 5; do contains "$CASE/output" "FAIL check $n:" 'check did not run all checks'; done
  absent "$CASE/state" 'check created state on failures'
}
rollback() {
  expect_rc 0 guard
  expect_rc 0 guard --rollback
  equal "$(selection)" "$OLD" 'rollback did not restore first selection'
  contains "$CASE/output" 'does not unload the daemon' 'rollback omitted daemon warning'
}
rollback_missing() {
  expect_rc 1 guard --rollback
  equal "$(switches)" 0 'missing prior caused switch'
}
rollback_symlink() {
  /bin/mkdir "$CASE/state"
  printf '%s\n' "$OTHER" >"$CASE/other-prior"
  /bin/ln -s "$CASE/other-prior" "$CASE/state/prior-selection"
  expect_rc 1 guard --rollback
  equal "$(switches)" 0 'symlinked prior caused switch'
}
rollback_directory_missing() {
  /bin/mkdir "$CASE/state"
  printf '%s\n' "$CASE/missing" >"$CASE/state/prior-selection"
  expect_rc 1 guard --rollback
  equal "$(switches)" 0 'nonexistent rollback target caused switch'
}
prior_wrong_owner() {
  /bin/mkdir "$CASE/state"
  printf '%s\n' "$OTHER" >"$CASE/state/prior-selection"
  /bin/cat >"$CASE/tools/stat" <<'STUB'
#!/bin/bash
case "$3" in */prior-selection) printf '0 644\n' ;; *) /usr/bin/stat "$@" ;; esac
STUB
  /bin/chmod 755 "$CASE/tools/stat"
  export XG_STAT="$CASE/tools/stat"
  expect_rc 1 guard --rollback
  equal "$(switches)" 0 'wrongly owned prior caused switch'
}
state_symlink() {
  /bin/mkdir "$CASE/other-state"
  /bin/ln -s "$CASE/other-state" "$CASE/state"
  expect_rc 1 guard
  equal "$(switches)" 0 'symlinked state caused switch'
}
state_writable() {
  /bin/mkdir -m 777 "$CASE/state"
  expect_rc 1 guard
  equal "$(switches)" 0 'writable state caused switch'
}
lock_symlink() {
  /bin/mkdir "$CASE/state"
  /bin/ln -s "$CASE/switches" "$CASE/state/lock"
  expect_rc 1 guard
  equal "$(switches)" 0 'symlinked lock caused switch'
}
log_symlink() {
  /bin/ln -s "$CASE/switches" "$CASE/guard.log"
  expect_rc 1 guard --check
  contains "$CASE/output" 'PASS check 5' 'unsafe log stopped check before bundle validation'
  expect_rc 1 guard
  equal "$(switches)" 0 'symlinked log was written'
}
nonroot_refused() {
  unset XG_TEST
  expect_rc 1 guard
  expect_rc 1 guard --rollback
  absent "$CASE/state" 'non-root refusal created state'
  absent "$CASE/guard.log" 'non-root refusal created log'
  equal "$(switches)" 0 'non-root enforce switched without test opt-in'
}
current_unreadable() {
  : >"$CASE/select-read-fail"
  expect_rc 1 guard --check
  contains "$CASE/output" 'PASS check 5' 'unreadable current selection skipped bundle checks'
  expect_rc 1 guard
  equal "$(switches)" 0 'unreadable current selection caused switch'
}
log_bounded() {
  /usr/bin/awk 'BEGIN { for (i=1;i<=20000;i++) print "2026-11-05T00:00:00Z prior guard event padding padding padding padding" }' >"$CASE/guard.log"
  printf '%s\n' "$DEV" >"$CASE/current"
  expect_rc 0 guard
  equal "$(/usr/bin/wc -l <"$CASE/guard.log" | /usr/bin/tr -d ' ')" 1001 'log did not retain last 1000 lines plus new line'
  /usr/bin/grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z valid pinned' "$CASE/guard.log" || die 'log missing ISO timestamp'
}
single_instance() {
  : >"$CASE/slow"
  # shellcheck disable=SC2119
  guard >"$CASE/first-output" 2>&1 &
  local first=$! n=0
  while [ ! -f "$CASE/entered" ] && [ "$n" -lt 100 ]; do
    /bin/sleep 0.05
    n=$((n + 1))
  done
  [ -f "$CASE/entered" ] || die 'first guard did not reach signature check'
  expect_rc 0 guard
  wait "$first" || die 'first guard failed'
  equal "$(switches)" 1 'overlapping guards both switched'
}
inherited_developer_dir() {
  export DEVELOPER_DIR=/deliberately/unrelated
  expect_rc 0 guard
  equal "$(selection)" "$DEV" 'inherited developer override affected verification'
}

for scenario in switch_and_prior idempotent directory_permissions directory_symlink directory_owner \
  bundle_permissions bundle_directory_permissions bundle_owner find_failure simctl_missing simctl_nonexec \
  simctl_symlink version_failure build_failure signature_failure selected_invalid verify_restore \
  select_verify_restore switch_failure check_readonly check_all_failures rollback rollback_missing \
  rollback_symlink rollback_directory_missing prior_wrong_owner state_symlink state_writable lock_symlink \
  log_symlink nonroot_refused current_unreadable log_bounded single_instance inherited_developer_dir; do
  (
    fixture "$scenario"
    "$scenario"
  )
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'PASS %s\n' "$scenario"
    passed=$((passed + 1))
  else
    printf 'FAIL %s\n' "$scenario"
    failed=$((failed + 1))
  fi
done
printf 'Summary: %s passed, %s failed (%s scenarios).\n' "$passed" "$failed" "$((passed + failed))"
printf 'Fixtures retained at %s\n' "$ROOT"
[ "$failed" -eq 0 ]
