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
ROOT=$(cd "$ROOT" && pwd -P) || exit 1
passed=0
failed=0
skipped=0

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
  APP=$CASE/Library/Developer/Xcode-27.1.app
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
    if [ -f "$base/restore-fail" ] && [ "$2" != "$base/Library/Developer/Xcode-27.1.app/Contents/Developer" ]; then
      exit 1
    fi
    if [ -f "$base/switch-fail" ] && [ "$2" = "$base/Library/Developer/Xcode-27.1.app/Contents/Developer" ]; then
      exit 1
    fi
    if [ -f "$base/select-verify-fail" ] && [ "$2" = "$base/Library/Developer/Xcode-27.1.app/Contents/Developer" ]; then
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
[ "$PATH" = /usr/bin:/bin ] || exit 2
[ "$DEVELOPER_DIR" = "$base/Library/Developer/Xcode-27.1.app/Contents/Developer" ] || exit 2
[ -z "${XG_TEST:-}" ] || exit 2
case "$*" in
  '-license check') [ ! -f "$base/license-fail" ]; exit $? ;;
  -checkFirstLaunchStatus) [ ! -f "$base/first-launch-fail" ]; exit $? ;;
  -version) [ "$#" -eq 1 ] || exit 2 ;;
  *) exit 2 ;;
esac
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
  printf '%s\n' "$base/Library/Developer/Xcode-27.1.app/Contents/Developer/usr/bin/simctl"
fi
STUB
  /bin/cat >"$CASE/tools/codesign" <<'STUB'
#!/bin/bash
base=$(cd "${0%/*}/.." && pwd) || exit 1
printf 'codesign\n' >> "$base/calls"
[ "$#" -eq 5 ] && [ "$1" = --verify ] && [ "$2" = --deep ] && [ "$3" = --strict ] || exit 2
[ "$4" = '-R=anchor apple and identifier "com.apple.dt.Xcode"' ] || exit 2
[ "$5" = "$base/Library/Developer/Xcode-27.1.app" ] || exit 2
if [ -f "$base/slow" ]; then
  : > "$base/entered"
  /bin/sleep 2
fi
if [ -f "$base/reselect" ]; then
  /bin/cat "$base/reselect" > "$base/current"
fi
if [ -f "$base/codesign-fail" ]; then
  printf 'codesign: verification rejected\n' >&2
  exit 1
fi
STUB
  # Only system ancestors outside the fixture need simulated safe ownership.
  # Fixture parents and bundle entries still use real stat/find permissions.
  /bin/cat >"$CASE/tools/stat-safe-ancestors" <<'STUB'
#!/bin/bash
base=$(cd "${0%/*}/.." && pwd -P) || exit 1
if [ "$1" = -f ] && [ "$2" = '%u %OLp' ]; then
  case "$base" in "$3"/*) printf '%s 755\n' "$EUID"; exit 0 ;; esac
  if [ "$3" = / ]; then printf '%s 755\n' "$EUID"; exit 0; fi
fi
exec /usr/bin/stat "$@"
STUB
  /bin/cat >"$CASE/tools/git" <<'STUB'
#!/bin/bash
base=$(cd "${0%/*}/.." && pwd) || exit 1
tool=${0##*/}
printf '%s\n' "$tool" >> "$base/calls"
[ "$#" -eq 1 ] && [ "$1" = --version ] || exit 2
[ "$PATH" = /usr/bin:/bin ] && [ -z "${DEVELOPER_DIR+x}" ] || exit 2
[ -z "${XG_TEST:-}" ] || exit 2
[ ! -f "$base/$tool-fail" ]
STUB
  /bin/cp "$CASE/tools/git" "$CASE/tools/clang" || die 'copy clang stub'
  /bin/chmod 755 "$CASE/tools/"* || die 'chmod tools'
  # Each subprocess gets only overrides pointing into this fixture. The real
  # lockf/stat/find exercise macOS semantics; the real select is never used.
  export XG_TEST=1 XG_APP="$APP" XG_STATE="$CASE/state" XG_LOG="$CASE/guard.log"
  export XG_EXPECT_OWNER="$EUID" XG_SELECT="$CASE/tools/xcode-select"
  export XG_BUILD="$CASE/tools/xcodebuild" XG_XCRUN="$CASE/tools/xcrun"
  export XG_GIT="$CASE/tools/git" XG_CLANG="$CASE/tools/clang"
  export XG_CODESIGN="$CASE/tools/codesign" XG_STAT="$CASE/tools/stat-safe-ancestors"
  unset CM_XCODE_GUARD_LOCKED CM_XCODE_GUARD_SERVICE
  unset XPC_SERVICE_NAME
}

switch_and_prior() {
  expect_rc 0 guard --enforce
  equal "$(selection)" "$DEV" 'first enforcement did not switch'
  equal "$(/bin/cat "$CASE/state/prior-selection")" "$OLD" 'prior was not recorded'
  equal "$(/usr/bin/stat -f %OLp "$CASE/state")" 755 'state mode is not 755'
  equal "$(/usr/bin/stat -f %OLp "$CASE/state/prior-selection")" 644 'prior mode is not 644'
  printf '%s\n' "$OTHER" >"$CASE/current"
  expect_rc 0 guard --enforce
  equal "$(selection)" "$DEV" 'second enforcement did not switch'
  equal "$(/bin/cat "$CASE/state/prior-selection")" "$OLD" 'first prior was overwritten'
}
idempotent() {
  printf '%s\n' "$DEV" >"$CASE/current"
  expect_rc 0 guard --enforce
  equal "$(switches)" 0 'already selected guard switched'
  absent "$CASE/state/prior-selection" 'already selected guard wrote a prior'
  equal "$(/usr/bin/wc -l <"$CASE/guard.log" | /usr/bin/tr -d ' ')" 1 'idempotent guard is noisy'
  contains "$CASE/calls" codesign 'already selected guard skipped validation'
  local tool
  for tool in xcrun git clang; do
    contains "$CASE/calls" "$tool" 'already selected guard skipped system tool verification'
  done
}
reject_check() {
  expect_rc 1 guard --enforce
  equal "$(selection)" "$OLD" 'failed validation changed selection'
  equal "$(switches)" 0 'failed validation attempted switch'
  absent "$CASE/state/prior-selection" 'failed validation recorded prior'
  contains "$CASE/guard.log" "check $1:" 'failure reason not logged'
  case "$1" in 1 | 2 | 3 | 5)
    if /usr/bin/grep -Fxq build "$CASE/calls"; then die 'unsafe bundle code ran'; fi
    contains "$CASE/guard.log" 'check 4: not run' 'version check was not reported as not run'
    contains "$CASE/guard.log" 'check 6: not run' 'readiness check was not reported as not run'
    ;;
  esac
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
case "$3" in */Xcode-27.1.app) printf '0 755\n' ;; *) "${0%/*}/stat-safe-ancestors" "$@" ;; esac
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
  # The fixture is user-owned. Use real find to reject it when root is required.
  export XG_EXPECT_OWNER=0
  expect_rc 1 guard --check
  contains "$CASE/output" 'FAIL check 2:' 'real find missed non-root ownership'
  contains "$CASE/output" "check 2: $APP:" 'owner failure omitted offending path'
  equal "$(switches)" 0 'wrong-owner check attempted switch'
  absent "$CASE/state" 'wrong-owner check created state'
}
bundle_setuid() {
  /bin/chmod u+s "$DEV/usr/bin/simctl" || die 'setuid fixture'
  if [ "$(/usr/bin/stat -f '%OMp%OLp' "$DEV/usr/bin/simctl")" != 4755 ]; then
    # Some sandboxes strip these bits despite chmod succeeding. Do not claim
    # the real find predicate ran when the fixture lacks the bit.
    printf '  SKIP filesystem or sandbox stripped setuid from fixture (%%OMp%%OLp checked)\n'
    exit 77
  fi
  reject_check 2
  contains "$CASE/guard.log" "$DEV/usr/bin/simctl:" 'setuid failure omitted path'
}
bundle_setgid() {
  /bin/chmod g+s "$DEV/usr/bin/simctl" || die 'setgid fixture'
  if [ "$(/usr/bin/stat -f '%OMp%OLp' "$DEV/usr/bin/simctl")" != 2755 ]; then
    printf '  SKIP filesystem or sandbox stripped setgid from fixture (%%OMp%%OLp checked)\n'
    exit 77
  fi
  reject_check 2
  contains "$CASE/guard.log" "$DEV/usr/bin/simctl:" 'setgid failure omitted path'
}
bundle_acl() {
  : >"$DEV/acl-entry"
  /bin/chmod +a "$(/usr/bin/id -un) allow write" "$DEV/acl-entry" || die 'ACL fixture'
  reject_check 2
  contains "$CASE/guard.log" "$DEV/acl-entry:" 'ACL failure omitted path'
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
  expect_rc 1 guard --check
  contains "$CASE/output" 'codesign: verification rejected' 'dry run hid signature diagnostic'
  if /usr/bin/grep -Fxq build "$CASE/calls"; then die 'signature failure ran bundle code'; fi
}
license_failure() {
  : >"$CASE/license-fail"
  reject_check 6
  printf '%s\n' "$DEV" >"$CASE/current"
  expect_rc 1 guard --enforce
  equal "$(selection)" "$DEV" 'selected Xcode license failure changed selection'
  contains "$CASE/guard.log" ALERT 'selected license failure omitted ALERT'
}
first_launch_failure() {
  : >"$CASE/first-launch-fail"
  reject_check 6
  printf '%s\n' "$DEV" >"$CASE/current"
  expect_rc 1 guard --enforce
  equal "$(selection)" "$DEV" 'selected Xcode first-launch failure changed selection'
  contains "$CASE/guard.log" ALERT 'selected first-launch failure omitted ALERT'
}
selected_invalid() {
  printf '%s\n' "$DEV" >"$CASE/current"
  : >"$CASE/codesign-fail"
  expect_rc 1 guard --enforce
  equal "$(selection)" "$DEV" 'invalid selected bundle was switched back'
  equal "$(switches)" 0 'invalid selected bundle caused a switch'
  contains "$CASE/guard.log" ALERT 'invalid selected bundle did not log loudly'
}
selected_tools_invalid() {
  printf '%s\n' "$DEV" >"$CASE/current"
  local tool
  for tool in xcrun git clang; do
    : >"$CASE/$tool-fail"
    expect_rc 1 guard --enforce
    equal "$(selection)" "$DEV" 'selected tool failure changed selection'
    equal "$(switches)" 0 'selected tool failure attempted switch'
    absent "$CASE/state/prior-selection" 'selected tool failure recorded prior'
    contains "$CASE/guard.log" 'ALERT selected Xcode system simctl, git or clang verification failed' 'selected tool failure omitted ALERT'
    expect_rc 1 guard --check
    contains "$CASE/output" ALERT 'selected tool dry run omitted ALERT'
    /bin/rm -f "$CASE/$tool-fail"
  done
}
lockf_failure_logged() {
  export XG_LOCKF=/usr/bin/false
  expect_rc 1 guard --enforce
  contains "$CASE/guard.log" 'lockf or locked guard failed with exit 1' 'lockf failure omitted log'
  equal "$(switches)" 0 'lockf failure switched'
}
selected_guard_invalid() {
  printf '%s\n' "$DEV" >"$CASE/current"
  /bin/mkdir -m 777 "$CASE/state"
  expect_rc 1 guard --check
  contains "$CASE/output" 'ALERT guard state, log or selection safety check failed' 'unsafe state blamed selected Xcode'
  /bin/chmod 755 "$CASE/state"
  /bin/ln -s "$CASE/switches" "$CASE/guard.log"
  expect_rc 1 guard --check
  contains "$CASE/output" 'ALERT guard state, log or selection safety check failed' 'unsafe log blamed selected Xcode'
  equal "$(switches)" 0 'guard safety failure switched'
}
verify_restore() {
  : >"$CASE/xcrun-fail"
  expect_rc 1 guard --enforce
  equal "$(selection)" "$OLD" 'xcrun failure did not restore selection'
  equal "$(switches)" 2 'expected target switch and restoration'
  # Recovery must use this run's selection, even with an older prior record.
  printf '%s\n' "$OTHER" >"$CASE/current"
  expect_rc 1 guard --enforce
  equal "$(selection)" "$OTHER" 'recovery used first prior instead of current selection'
}
select_verify_restore() {
  : >"$CASE/select-verify-fail"
  expect_rc 1 guard --enforce
  equal "$(selection)" "$OLD" 'selection verification failure did not restore'
}
git_verify_restore() {
  : >"$CASE/git-fail"
  expect_rc 1 guard --enforce
  equal "$(selection)" "$OLD" 'git failure did not restore selection'
  equal "$(switches)" 2 'git failure did not attempt restoration'
  contains "$CASE/calls" git 'post-switch git not called'
}
clang_verify_restore() {
  : >"$CASE/clang-fail"
  expect_rc 1 guard --enforce
  equal "$(selection)" "$OLD" 'clang failure did not restore selection'
  equal "$(switches)" 2 'clang failure did not attempt restoration'
  contains "$CASE/calls" clang 'post-switch clang not called'
}
restore_failure() {
  : >"$CASE/xcrun-fail"
  : >"$CASE/restore-fail"
  expect_rc 1 guard --enforce
  equal "$(selection)" "$DEV" 'fixture did not leave failed restoration selected'
  equal "$(switches)" 2 'restoration not attempted'
  contains "$CASE/guard.log" 'ALERT switch or verification failed AND restoration failed' 'restore failure omitted ALERT'
}
refreshed_prior() {
  printf '%s\n' "$OTHER" >"$CASE/reselect"
  expect_rc 0 guard --enforce
  equal "$(/bin/cat "$CASE/state/prior-selection")" "$OTHER" 'prior did not use refreshed selection'
  equal "$(selection)" "$DEV" 'refreshed selection did not switch'
}
refreshed_restore() {
  printf '%s\n' "$OTHER" >"$CASE/reselect"
  : >"$CASE/xcrun-fail"
  expect_rc 1 guard --enforce
  equal "$(selection)" "$OTHER" 'restoration did not use refreshed selection'
}
refreshed_missing() {
  printf '%s\n' "$CASE/missing" >"$CASE/reselect"
  expect_rc 1 guard --enforce
  equal "$(switches)" 0 'missing refreshed selection caused switch'
  absent "$CASE/state/prior-selection" 'missing refreshed selection recorded prior'
}
switch_failure() {
  : >"$CASE/switch-fail"
  expect_rc 1 guard --enforce
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
  : >"$CASE/license-fail"
  expect_rc 1 guard --check
  local n
  for n in 1 2 3 5; do contains "$CASE/output" "FAIL check $n:" 'check skipped a validation check'; done
  for n in 4 6; do contains "$CASE/output" "check $n: not run" 'unsafe bundle check was not reported as not run'; done
  if /usr/bin/grep -Fxq build "$CASE/calls"; then die 'failed dry run executed bundle code'; fi
  absent "$CASE/state" 'check created state on failures'
}
rollback() {
  expect_rc 0 guard --enforce
  expect_rc 0 guard --rollback
  equal "$(selection)" "$OLD" 'rollback did not restore first selection'
  contains "$CASE/output" 'does not unload the daemon' 'rollback omitted daemon warning'
}
rollback_missing() {
  local actual
  guard --rollback >"$CASE/output" 2>"$CASE/stderr"
  actual=$?
  equal "$actual" 1 'missing prior rollback succeeded'
  contains "$CASE/stderr" 'rollback refused: prior selection is missing' 'non-terminal rollback hid stderr'
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
case "$3" in */prior-selection) printf '0 644\n' ;; *) "${0%/*}/stat-safe-ancestors" "$@" ;; esac
STUB
  /bin/chmod 755 "$CASE/tools/stat"
  export XG_STAT="$CASE/tools/stat"
  expect_rc 1 guard --rollback
  equal "$(switches)" 0 'wrongly owned prior caused switch'
}
state_symlink() {
  /bin/mkdir "$CASE/other-state"
  /bin/ln -s "$CASE/other-state" "$CASE/state"
  expect_rc 1 guard --enforce
  equal "$(switches)" 0 'symlinked state caused switch'
}
state_writable() {
  /bin/mkdir -m 777 "$CASE/state"
  expect_rc 1 guard --enforce
  equal "$(switches)" 0 'writable state caused switch'
}
lock_symlink() {
  /bin/mkdir "$CASE/state"
  /bin/ln -s "$CASE/switches" "$CASE/state/lock"
  expect_rc 1 guard --enforce
  equal "$(switches)" 0 'symlinked lock caused switch'
}
log_symlink() {
  /bin/ln -s "$CASE/switches" "$CASE/guard.log"
  expect_rc 1 guard --check
  contains "$CASE/output" 'PASS check 5' 'unsafe log stopped check before bundle validation'
  expect_rc 1 guard --enforce
  equal "$(switches)" 0 'symlinked log was written'
}
nonroot_refused() {
  unset XG_TEST
  expect_rc 1 guard --enforce
  expect_rc 1 guard --rollback
  absent "$CASE/state" 'non-root refusal created state'
  absent "$CASE/guard.log" 'non-root refusal created log'
  equal "$(switches)" 0 'non-root enforce switched without test opt-in'
}
current_unreadable() {
  : >"$CASE/select-read-fail"
  expect_rc 1 guard --check
  contains "$CASE/output" 'PASS check 5' 'unreadable current selection skipped bundle checks'
  expect_rc 1 guard --enforce
  equal "$(switches)" 0 'unreadable current selection caused switch'
}
log_bounded() {
  /usr/bin/awk 'BEGIN { for (i=1;i<=20000;i++) print "2026-11-05T00:00:00Z prior guard event padding padding padding padding" }' >"$CASE/guard.log"
  printf '%s\n' "$DEV" >"$CASE/current"
  local inode
  inode=$(/usr/bin/stat -f %i "$CASE/guard.log")
  expect_rc 0 guard --enforce
  equal "$(/usr/bin/stat -f %i "$CASE/guard.log")" "$inode" 'log trim replaced inode'
  equal "$(/usr/bin/wc -l <"$CASE/guard.log" | /usr/bin/tr -d ' ')" 1001 'log did not retain last 1000 lines plus new line'
  /usr/bin/grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z valid pinned' "$CASE/guard.log" || die 'log missing ISO timestamp'
}
single_instance() {
  : >"$CASE/slow"
  # shellcheck disable=SC2119
  guard --enforce >"$CASE/first-output" 2>&1 &
  local first=$! n=0
  while [ ! -f "$CASE/entered" ] && [ "$n" -lt 100 ]; do
    /bin/sleep 0.05
    n=$((n + 1))
  done
  [ -f "$CASE/entered" ] || die 'first guard did not reach signature check'
  expect_rc 75 guard --enforce
  contains "$CASE/output" busy 'busy manual enforce omitted diagnostic'
  wait "$first" || die 'first guard failed'
  equal "$(switches)" 1 'overlapping guards both switched'
}
busy_refused() {
  /bin/mkdir "$CASE/state" || die 'mkdir state'
  printf '%s\n' "$OLD" >"$CASE/state/prior-selection"
  # Hold the real lock separately so rollback cannot race an enforcer's finish.
  # shellcheck disable=SC2016 # The child shell expands its own positional arg.
  /usr/bin/lockf -k -t 0 "$CASE/state/lock" /bin/bash -c ': >"$1"; /bin/sleep 3' bash "$CASE/entered" &
  local holder=$! n=0 actual
  while [ ! -f "$CASE/entered" ] && [ "$n" -lt 100 ]; do
    /bin/sleep 0.02
    n=$((n + 1))
  done
  [ -f "$CASE/entered" ] || die 'lock holder did not start'
  expect_rc 75 guard --enforce
  contains "$CASE/output" busy 'interactive enforce busy omitted diagnostic'
  guard --rollback >"$CASE/output" 2>"$CASE/stderr"
  actual=$?
  wait "$holder" || die 'lock holder failed'
  equal "$actual" 75 'busy rollback did not exit non-zero'
  contains "$CASE/stderr" busy 'busy rollback omitted stderr diagnostic'
  equal "$(switches)" 0 'busy guard attempted switch'
}
usage_errors() {
  expect_rc 1 guard
  contains "$CASE/output" Usage 'bare invocation omitted usage'
  expect_rc 1 guard --unknown
  contains "$CASE/output" Usage 'unknown argument omitted usage'
  expect_rc 1 guard enforce
  expect_rc 1 guard --enforce extra
  expect_rc 1 guard --check extra
  expect_rc 1 guard --rollback extra
  absent "$CASE/state" 'usage error created state'
  absent "$CASE/guard.log" 'usage error created log'
  equal "$(switches)" 0 'usage error attempted switch'
}
prior_temp_cleanup() {
  export XG_MV=/usr/bin/false
  expect_rc 1 guard --enforce
  equal "$(switches)" 0 'prior write failure switched'
  equal "$(/usr/bin/find "$CASE/state" -name 'prior-selection.*' -print)" '' 'prior temp leaked after failed move'
}
log_temp_cleanup() {
  /usr/bin/awk 'BEGIN { for (i=1;i<=20000;i++) print "prior guard event padding padding padding padding padding padding" }' >"$CASE/guard.log"
  export XG_TAIL=/usr/bin/false
  expect_rc 1 guard --enforce
  equal "$(/usr/bin/find "$CASE" -name 'guard.log.*' -print)" '' 'log temp leaked after failed trim'
}
inherited_developer_dir() {
  export DEVELOPER_DIR=/deliberately/unrelated
  expect_rc 0 guard --enforce
  equal "$(selection)" "$DEV" 'inherited developer override affected verification'
}

parent_permissions() {
  /bin/chmod g+w "$CASE/Library/Developer"
  reject_check 1
}
ancestor_permissions() {
  /bin/chmod o+w "$CASE/Library"
  reject_check 1
}
parent_symlink() {
  /bin/mv "$CASE/Library/Developer" "$CASE/Library/real-developer" || die 'move parent'
  /bin/ln -s real-developer "$CASE/Library/Developer" || die 'link parent'
  reject_check 1
}
ancestor_owner() {
  /bin/cat >"$CASE/tools/stat" <<'STUB'
#!/bin/bash
case "$3" in */Library) printf '0 755\n' ;; *) "${0%/*}/stat-safe-ancestors" "$@" ;; esac
STUB
  /bin/chmod 755 "$CASE/tools/stat"
  export XG_STAT="$CASE/tools/stat"
  reject_check 1
}
root_permissions() {
  /bin/cat >"$CASE/tools/stat" <<'STUB'
#!/bin/bash
case "$3" in /) printf '%s 775\n' "$EUID" ;; *) "${0%/*}/stat-safe-ancestors" "$@" ;; esac
STUB
  /bin/chmod 755 "$CASE/tools/stat"
  export XG_STAT="$CASE/tools/stat"
  reject_check 1
}
bundle_symlink_owner() {
  /bin/ln -s usr/bin/simctl "$DEV/link"
  /bin/cat >"$CASE/tools/find" <<'STUB'
#!/bin/bash
args=("$@")
# Run real find with a different owner only on symlinks. A blanket ! -type l
# exemption would miss this user-owned link; write-bit checks must exempt it.
for ((i=0; i<${#args[@]}; i++)); do
  if [ "${args[$i]}" = -user ]; then
    args[$((i + 1))]=0
    break
  fi
done
# Split only the replacement predicate, preserving the other quoted arguments.
/usr/bin/find "${args[@]:0:$((i - 1))}" -type l ! -user "${args[@]:$((i + 1))}"
STUB
  /bin/chmod 755 "$CASE/tools/find"
  export XG_FIND="$CASE/tools/find"
  reject_check 2
  contains "$CASE/guard.log" "$DEV/link:" 'wrongly owned symlink was exempted'
}
safe_bundle_symlink() {
  /bin/ln -s usr/bin/simctl "$DEV/link"
  expect_rc 0 guard --enforce
  equal "$(selection)" "$DEV" 'safe owned symlink was rejected for write bits'
}
launchd_busy_quiet() {
  # Simulate lock contention without launching another process.
  /bin/cat >"$CASE/tools/lockf" <<'STUB'
#!/bin/bash
exit 75
STUB
  /bin/chmod 755 "$CASE/tools/lockf"
  export XG_LOCKF="$CASE/tools/lockf"
  # macOS rewrites a synthetic XPC_SERVICE_NAME during executable startup.
  # Source in a subshell to simulate launchd's initial context. The lock stub
  # exits before re-exec, so the sourced guard never uses this test's $0.
  # shellcheck disable=SC2329 # Invoked indirectly through expect_rc.
  launchd_guard() (
    export XPC_SERVICE_NAME=cm.barta.mbp2606.xcode-guard
    # shellcheck disable=SC1090 # The guard path is fixed above.
    . "$GUARD" "$@"
  )
  expect_rc 0 launchd_guard --enforce
  equal "$(/bin/cat "$CASE/output")" '' 'launchd lock contention was noisy'
  absent "$CASE/guard.log" 'launchd contention wrote a log'
  equal "$(switches)" 0 'launchd contention switched'
  expect_rc 75 launchd_guard --rollback
  contains "$CASE/output" busy 'launchd rollback contention was silently accepted'
}

launchd_failure_once() {
  printf '%s\n' "$DEV" >"$CASE/current"
  : >"$CASE/codesign-fail"
  # Source only the parent, preserving the script path for its real re-exec.
  /bin/bash -c 'XPC_SERVICE_NAME=cm.barta.mbp2606.xcode-guard; . "$0" --enforce' "$GUARD" >>"$CASE/guard.log" 2>&1
  equal "$?" 1 'launchd invalid bundle succeeded'
  equal "$(/usr/bin/grep -c 'FAIL check 5:' "$CASE/guard.log")" 1 'launchd duplicated FAIL through stderr'
  equal "$(/usr/bin/grep -c 'ALERT selected Xcode is invalid' "$CASE/guard.log")" 1 'launchd duplicated ALERT through stderr'
  equal "$(switches)" 0 'launchd invalid bundle switched'
}

for scenario in parent_permissions selected_tools_invalid lockf_failure_logged selected_guard_invalid launchd_failure_once ancestor_permissions parent_symlink ancestor_owner root_permissions bundle_symlink_owner safe_bundle_symlink launchd_busy_quiet switch_and_prior idempotent directory_permissions directory_symlink directory_owner \
  bundle_permissions bundle_directory_permissions bundle_owner bundle_setuid bundle_setgid bundle_acl find_failure simctl_missing simctl_nonexec \
  simctl_symlink version_failure build_failure signature_failure license_failure first_launch_failure selected_invalid verify_restore \
  git_verify_restore clang_verify_restore restore_failure refreshed_prior refreshed_restore refreshed_missing \
  select_verify_restore switch_failure check_readonly check_all_failures rollback rollback_missing \
  rollback_symlink rollback_directory_missing prior_wrong_owner state_symlink state_writable lock_symlink \
  log_symlink nonroot_refused current_unreadable log_bounded single_instance busy_refused usage_errors \
  prior_temp_cleanup log_temp_cleanup inherited_developer_dir; do
  (
    fixture "$scenario"
    "$scenario"
  )
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'PASS %s\n' "$scenario"
    passed=$((passed + 1))
  elif [ "$rc" -eq 77 ]; then
    printf 'SKIP %s\n' "$scenario"
    skipped=$((skipped + 1))
  else
    printf 'FAIL %s\n' "$scenario"
    failed=$((failed + 1))
  fi
done
printf 'Summary: %s passed, %s failed, %s skipped (%s scenarios).\n' "$passed" "$failed" "$skipped" "$((passed + failed + skipped))"
printf 'Fixtures retained at %s\n' "$ROOT"
[ "$failed" -eq 0 ]
