#!/bin/bash
# OPS-563: keep the system developer selection on the root-owned Xcode 27.1 bundle.
# CommandLineTools has no simctl, so Xcode test diagnostics failed with exit 72.
# CI jobs still choose their own DEVELOPER_DIR. This root LaunchDaemon only keeps
# the system fallback usable; Home Manager does not install or run it.
# Validate the whole bundle before switching, even when it is already selected.
# Keep the first prior selection for an operator rollback. A failed post-switch
# verification restores the selection read immediately before switching.
set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 022

# Preserve the initial launch context before macOS refreshes it during a spawn.
if [ "${CM_XCODE_GUARD_LOCKED:-}" = 1 ]; then
  LAUNCHD_SERVICE=${CM_XCODE_GUARD_SERVICE:-}
else
  LAUNCHD_SERVICE=${XPC_SERVICE_NAME:-}
fi
APP=/Library/Developer/Xcode-27.1.app
DEV=$APP/Contents/Developer
STATE=/var/db/cm.barta.xcode-guard
PRIOR=$STATE/prior-selection
LOG=/var/log/cm.barta.xcode-guard.log
LOCK=$STATE/lock
EXPECT_OWNER=0
FIND=/usr/bin/find
STAT=/usr/bin/stat
ENV=/usr/bin/env
SELECT=/usr/bin/xcode-select
BUILD=/usr/bin/xcodebuild
XCRUN=/usr/bin/xcrun
GIT=/usr/bin/git
CLANG=/usr/bin/clang
CODESIGN=/usr/bin/codesign
LOCKF=/usr/bin/lockf
BASH_TOOL=/bin/bash
MKDIR=/bin/mkdir
CHMOD=/bin/chmod
MKTEMP=/usr/bin/mktemp
MV=/bin/mv
DATE=/bin/date
TAIL=/usr/bin/tail
CAT=/bin/cat
RM=/bin/rm

# Root never consults test overrides, including the test permission and owner.
if [ "$EUID" -ne 0 ]; then
  APP=${XG_APP:-$APP}
  DEV=${XG_DEV:-$APP/Contents/Developer}
  STATE=${XG_STATE:-$STATE}
  PRIOR=${XG_PRIOR:-$STATE/prior-selection}
  LOG=${XG_LOG:-$LOG}
  LOCK=${XG_LOCK:-$STATE/lock}
  EXPECT_OWNER=${XG_EXPECT_OWNER:-0}
  FIND=${XG_FIND:-$FIND}
  STAT=${XG_STAT:-$STAT}
  ENV=${XG_ENV:-$ENV}
  SELECT=${XG_SELECT:-$SELECT}
  BUILD=${XG_BUILD:-$BUILD}
  XCRUN=${XG_XCRUN:-$XCRUN}
  GIT=${XG_GIT:-$GIT}
  CLANG=${XG_CLANG:-$CLANG}
  CODESIGN=${XG_CODESIGN:-$CODESIGN}
  LOCKF=${XG_LOCKF:-$LOCKF}
  BASH_TOOL=${XG_BASH:-$BASH_TOOL}
  MKDIR=${XG_MKDIR:-$MKDIR}
  CHMOD=${XG_CHMOD:-$CHMOD}
  MKTEMP=${XG_MKTEMP:-$MKTEMP}
  MV=${XG_MV:-$MV}
  DATE=${XG_DATE:-$DATE}
  TAIL=${XG_TAIL:-$TAIL}
  CAT=${XG_CAT:-$CAT}
  RM=${XG_RM:-$RM}
fi

MODE=${1:-}
case "$MODE" in --enforce | --check | --rollback) ;; *)
  printf 'Usage: %s --enforce|--check|--rollback\n' "$0" >&2
  exit 1
  ;;
esac
if [ "$#" -ne 1 ]; then
  printf 'Usage: %s --enforce|--check|--rollback\n' "$0" >&2
  exit 1
fi
if [ "$MODE" != --check ] && [ "$EUID" -ne 0 ] && [ "${XG_TEST:-}" != 1 ]; then
  printf 'FAIL enforce and rollback require root.\n' >&2
  exit 1
fi

# Keep tool diagnostics visible during an operator's dry run.
check_tool() {
  if [ "$MODE" = --check ]; then
    "$@" </dev/null
  else
    "$@" </dev/null 2>/dev/null
  fi
}
# XPC_SERVICE_NAME for system LaunchDaemons is unverified on the target host.
under_launchd() { [ "$LAUNCHD_SERVICE" = cm.barta.mbp2606.xcode-guard ]; }

# stat does not follow links on macOS. Reject links explicitly as well.
owned_safe() {
  local metadata owner permissions
  [ ! -L "$1" ] || return 1
  metadata=$(check_tool "$STAT" -f '%u %OLp' "$1") || return 1
  owner=${metadata%% *}
  permissions=${metadata#* }
  [[ "$permissions" =~ ^[0-7]+$ ]] || return 1
  [ "$owner" = "$EXPECT_OWNER" ] && [ $((8#$permissions & 022)) -eq 0 ]
}

log_safe() {
  [ ! -L "$LOG" ] && { [ ! -e "$LOG" ] || { [ -f "$LOG" ] && owned_safe "$LOG"; }; }
}

say() {
  local size tmp
  if [ "$MODE" = --check ]; then
    printf '%s\n' "$*"
    return 0
  fi
  log_safe || {
    printf 'FAIL unsafe log file.\n' >&2
    return 1
  }
  size=0
  if [ -f "$LOG" ]; then
    size=$("$STAT" -f '%z' "$LOG" </dev/null 2>/dev/null) || return 1
  fi
  if [ "$size" -gt 1048576 ]; then
    tmp=$("$MKTEMP" "$LOG.XXXXXXXX" </dev/null) || return 1
    # Preserve the inode: launchd also holds this log open for stdout/stderr.
    if ! "$TAIL" -n 1000 "$LOG" </dev/null >"$tmp" || ! "$CAT" "$tmp" </dev/null >"$LOG"; then
      "$RM" -f "$tmp" </dev/null
      printf 'FAIL log trimming failed.\n' >&2
      return 1
    fi
    "$RM" -f "$tmp" </dev/null || return 1
  fi
  printf '%s %s\n' "$("$DATE" -u '+%Y-%m-%dT%H:%M:%SZ' </dev/null)" "$*" >>"$LOG"
}

fail() {
  if [ "$MODE" != --check ] && ! under_launchd; then
    printf 'FAIL %s\n' "$*" >&2
  fi
  say "FAIL $*"
  return 1
}
report() { [ "$MODE" != --check ] || say "PASS $*"; }
# Read and change the system selection even from a shell that pins its own Xcode.
select_system() { check_tool "$ENV" -i PATH=/usr/bin:/bin "$SELECT" "$@"; }
system_tools_valid() {
  local simctl
  simctl=$(check_tool "$ENV" -i PATH=/usr/bin:/bin "$XCRUN" --find simctl) && [ "$simctl" = "$DEV/usr/bin/simctl" ] &&
    check_tool "$ENV" -i PATH=/usr/bin:/bin "$GIT" --version >/dev/null &&
    check_tool "$ENV" -i PATH=/usr/bin:/bin "$CLANG" --version >/dev/null
}

state_valid() {
  if [ -L "$STATE" ] || { [ -e "$STATE" ] && { [ ! -d "$STATE" ] || ! owned_safe "$STATE"; }; }; then
    fail 'state directory must be a real, owned directory without group/other write access'
    return 1
  fi
  if [ -L "$PRIOR" ] || { [ -e "$PRIOR" ] && { [ ! -f "$PRIOR" ] || ! owned_safe "$PRIOR"; }; }; then
    fail 'prior selection must be an owned regular non-symlink file without group/other write access'
    return 1
  fi
  if [ -L "$LOCK" ] || { [ -e "$LOCK" ] && { [ ! -f "$LOCK" ] || ! owned_safe "$LOCK"; }; }; then
    fail 'lock must be an owned regular non-symlink file without group/other write access'
    return 1
  fi
  report 'state, prior selection and lock are safe (missing state would be created mode 755)'
}

bundle_valid() {
  local path bad version failed=0 directories_ok=1
  local -a directories
  directories=("$APP/Contents" "$DEV" "$DEV/usr/bin")
  path=$APP
  while :; do
    directories[${#directories[@]}]=$path
    [ "$path" != / ] || break
    path=${path%/*}
    [ -n "$path" ] || path=/
  done
  for path in "${directories[@]}"; do
    if [ ! -d "$path" ] || ! owned_safe "$path"; then
      fail "check 1: $path: required bundle or parent directory is missing, symlinked, wrongly owned or writable"
      directories_ok=0
      failed=1
    fi
  done
  [ "$directories_ok" -eq 0 ] || report "check 1: $APP: required bundle directories and every parent up to / are safe"
  if ! bad=$(check_tool "$FIND" "$APP" -xdev \( ! -user "$EXPECT_OWNER" -o \( ! -type l \( -perm -g+w -o -perm -o+w -o -perm -4000 -o -perm -2000 -o -acl \) \) \) -print -quit); then
    fail "check 2: $APP: whole-bundle ownership/permissions scan failed"
    failed=1
  elif [ -n "$bad" ]; then
    fail "check 2: $bad: bundle entry has wrong ownership, group/other write, setuid/setgid or an ACL"
    failed=1
  else
    report 'check 2: whole-bundle ownership and permissions are safe'
  fi
  if [ -L "$DEV/usr/bin/simctl" ] || [ ! -f "$DEV/usr/bin/simctl" ] || [ ! -x "$DEV/usr/bin/simctl" ]; then
    fail 'check 3: simctl must be an executable regular non-symlink file'
    failed=1
  else
    report 'check 3: simctl is an executable regular file'
  fi
  if ! check_tool "$CODESIGN" --verify --deep --strict -R='anchor apple and identifier "com.apple.dt.Xcode"' "$APP" >/dev/null; then
    fail 'check 5: deep strict Apple Xcode signature verification failed'
    failed=1
  else
    report 'check 5: deep strict Apple Xcode signature verification passed'
  fi
  # Never run bundle code as root until checks 1, 2, 3 and 5 all pass.
  if [ "$failed" -ne 0 ]; then
    say 'check 4: not run because bundle validation failed'
    say 'check 6: not run because bundle validation failed'
    return 1
  fi
  # Clean environments prevent shell/CI settings from choosing another Xcode.
  if ! version=$(check_tool "$ENV" -i PATH=/usr/bin:/bin "DEVELOPER_DIR=$DEV" "$BUILD" -version) ||
    [ "$version" != $'Xcode 27.1\nBuild version 27A9275' ]; then
    fail 'check 4: xcodebuild must report exactly Xcode 27.1, build 27A9275'
    failed=1
  else
    report 'check 4: Xcode version and build match the pin'
  fi
  if ! check_tool "$ENV" -i PATH=/usr/bin:/bin "DEVELOPER_DIR=$DEV" "$BUILD" -license check >/dev/null; then
    fail 'check 6: Xcode license check failed'
    failed=1
  elif ! check_tool "$ENV" -i PATH=/usr/bin:/bin "DEVELOPER_DIR=$DEV" "$BUILD" -checkFirstLaunchStatus >/dev/null; then
    fail 'check 6: Xcode first-launch status check failed'
    failed=1
  else
    report 'check 6: Xcode license and first-launch status checks passed'
  fi
  return "$failed"
}

if [ "$MODE" != --check ]; then
  log_safe || {
    printf 'FAIL unsafe log file.\n' >&2
    exit 1
  }
  state_valid || exit 1
  if [ ! -d "$STATE" ]; then
    "$MKDIR" -m 755 "$STATE" </dev/null 2>/dev/null || {
      # Another starting copy may have created it before taking the lock.
      if [ ! -d "$STATE" ] || ! state_valid; then
        fail 'cannot create state directory'
        exit 1
      fi
    }
  fi
  # Same lifetime kernel lock as mem-guard.sh. EX_TEMPFAIL (75) means busy.
  if [ "${CM_XCODE_GUARD_LOCKED:-}" != 1 ]; then
    "$LOCKF" -s -k -t 0 "$LOCK" "$ENV" CM_XCODE_GUARD_LOCKED=1 "CM_XCODE_GUARD_SERVICE=$LAUNCHD_SERVICE" "$BASH_TOOL" "$0" "$@" </dev/null
    rc=$?
    if [ "$rc" -eq 75 ]; then
      if [ "$MODE" = --enforce ] && under_launchd; then
        exit 0
      fi
      printf 'FAIL busy: another xcode-guard holds the lock.\n' >&2
    elif [ "$rc" -ne 0 ]; then
      fail "locked guard exited $rc, see the line above"
    fi
    exit "$rc"
  fi
  state_valid || exit 1
fi

if [ "$MODE" = --rollback ]; then
  [ -f "$PRIOR" ] || {
    fail 'rollback refused: prior selection is missing'
    exit 1
  }
  previous=$("$CAT" "$PRIOR" </dev/null) || {
    fail 'cannot read prior selection'
    exit 1
  }
  if [[ "$previous" != /* ]] || [ ! -d "$previous" ]; then
    fail 'rollback refused: recorded developer directory does not exist'
    exit 1
  fi
  if ! select_system --switch "$previous" >/dev/null 2>&1 ||
    ! current=$(select_system -p 2>/dev/null) || [ "$current" != "$previous" ]; then
    fail 'rollback switch or verification failed; this does not unload the daemon'
    exit 1
  fi
  say 'PASS rollback restored prior selection; this does not unload the daemon' || exit 1
  printf 'Restored prior selection. This does not unload the daemon.\n'
  exit 0
fi

failed=0
state_valid || failed=1
if ! log_safe; then
  fail 'log must be an owned regular non-symlink file without group/other write access'
  failed=1
else
  report 'log path is safe'
fi
if ! current=$(select_system -p) || [[ "$current" != /* ]] || [ ! -d "$current" ]; then
  fail 'current developer selection is unreadable or its directory does not exist'
  failed=1
else
  report 'current developer selection is readable and its directory exists'
fi
bundle_failed=0
bundle_valid || {
  failed=1
  bundle_failed=1
}
if [ "$failed" -ne 0 ]; then
  if [ "$current" = "$DEV" ]; then
    if [ "$bundle_failed" -eq 1 ]; then
      fail 'ALERT selected Xcode is invalid; leaving selection unchanged for operator repair'
    else
      fail 'ALERT guard state, log or selection safety check failed; leaving selected Xcode unchanged for operator repair'
    fi
  fi
  [ "$MODE" != --check ] || say 'FAIL enforce would refuse; no selection or state changes made'
  exit 1
fi

if [ "$MODE" = --check ]; then
  if [ "$current" = "$DEV" ]; then
    system_tools_valid || {
      fail 'ALERT selected Xcode system simctl, git or clang verification failed; leaving selection unchanged for operator repair'
      exit 1
    }
    say 'PASS enforce would keep the already selected, valid Xcode'
  else
    say 'PASS enforce would preserve the first prior selection, switch to pinned Xcode and verify simctl, git and clang'
  fi
  exit 0
fi
# Validation can take minutes; preserve a manual selection made in that time.
if ! current=$(select_system -p 2>/dev/null) || [[ "$current" != /* ]] || [ ! -d "$current" ]; then
  fail 'current developer selection is unreadable or its directory does not exist; refusing to switch'
  exit 1
fi
if [ "$current" = "$DEV" ]; then
  system_tools_valid || {
    fail 'ALERT selected Xcode system simctl, git or clang verification failed; leaving selection unchanged for operator repair'
    exit 1
  }
  say 'valid pinned Xcode is already selected' || exit 1
  exit 0
fi
if [ ! -e "$PRIOR" ]; then
  tmp=$("$MKTEMP" "$STATE/prior-selection.XXXXXXXX" </dev/null) || {
    fail 'cannot create prior-selection temporary file'
    exit 1
  }
  if ! printf '%s\n' "$current" >"$tmp" || ! "$CHMOD" 644 "$tmp" </dev/null || ! "$MV" -n "$tmp" "$PRIOR" </dev/null; then
    "$RM" -f "$tmp" </dev/null
    fail 'cannot atomically record prior selection'
    exit 1
  fi
  # mv -n can succeed without moving when a destination already exists.
  "$RM" -f "$tmp" </dev/null || {
    fail 'cannot remove prior-selection temporary file'
    exit 1
  }
  if [ ! -f "$PRIOR" ] || ! owned_safe "$PRIOR"; then
    fail 'prior selection was not safely recorded'
    exit 1
  fi
fi
if select_system --switch "$DEV" >/dev/null 2>&1 &&
  selected=$(select_system -p 2>/dev/null) && [ "$selected" = "$DEV" ] &&
  system_tools_valid; then
  say 'PASS selected pinned Xcode and verified system simctl, git and clang' || exit 1
  exit 0
fi
if select_system --switch "$current" >/dev/null 2>&1 &&
  restored=$(select_system -p 2>/dev/null) && [ "$restored" = "$current" ]; then
  fail 'switch or verification failed; restored the selection read before switching'
else
  fail 'ALERT switch or verification failed AND restoration failed; operator repair required'
fi
exit 1
