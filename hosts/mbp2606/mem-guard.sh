#!/bin/bash
# OPS-341: fast memory guard on mbp2606, user mba (packaged by hosts/mbp2606/mem-guard.nix).
# The Mac ran out of application memory on 2026-10-15 15:44 during an aithema browser-test burst; the OPS
# night-levels loop samples only every 180 s and missed it.
# Every 10 s: read the system-wide free percentage (memory_pressure -Q).
#   < WARN (20 %): log a WARN line (rate-limited to one per minute).
#   < KILL (10 %): SIGTERM the most recently started test browser, one per cycle, and log it. A test browser is a
#                  process of this user whose executable is Google Chrome's main binary or chrome-headless-shell,
#                  whose arguments contain /ci.noindex/aithema-runs/ and that is not a --type= helper. The choice is
#                  re-checked right before the signal. Never another user, never any other process.
# An unreadable memory reading never leads to a kill.
# Log: ~/ci.noindex/mem-guard.log (one line per event + a heartbeat every 10 min).
# Single instance: the script re-executes itself under /usr/bin/lockf, a kernel lock on ~/ci.noindex/mem-guard.lock
# that is held for the guard's lifetime and released on any exit (no stale lock, no pid reuse problem). A second copy
# exits at once. mba's crontab starts it every minute (installed by Home Manager), so after a reboot the guard is back
# within a minute. ~/ci.noindex/mem-guard.pid is informational (OPS watchers read it).
# Stop for maintenance: kill "$(cat ~/ci.noindex/mem-guard.pid)" (cron restarts it; remove the "# OPS-341 mem-guard"
# crontab line to keep it off).
# shellcheck disable=SC2009 # ps|grep is deliberate: candidates come from the full command line, which pgrep cannot
# combine with the executable and helper checks below.
set -u
# cron's PATH is /usr/bin:/bin; sysctl lives in /usr/sbin.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
WARN=${WARN:-20}
KILL=${KILL:-10}
DIR=$HOME/ci.noindex
LOG=$DIR/mem-guard.log
LOCKF=$DIR/mem-guard.lock
PIDF=$DIR/mem-guard.pid
mkdir -p "$DIR" || exit 1

if [ "${MEM_GUARD_LOCKED:-}" != 1 ]; then
  # -t 0: give up at once if another guard holds the lock; -s: silent; -k: keep the lock file.
  exec /usr/bin/lockf -s -k -t 0 "$LOCKF" /usr/bin/env MEM_GUARD_LOCKED=1 /bin/bash "$0" "$@"
fi

say() { echo "$(date '+%F %T') $*" >>"$LOG"; }
echo $$ >"$PIDF"
trap '[ "$(cat "$PIDF" 2>/dev/null)" = $$ ] && rm -f "$PIDF"' EXIT

# Free percentage as an integer 0-100, or nothing when memory_pressure fails or prints something unexpected.
free_pct() {
  local out raw
  out=$(memory_pressure -Q 2>/dev/null) || return 1
  raw=$(printf '%s\n' "$out" | sed -n 's/^System-wide memory free percentage: \([0-9][0-9]*\)%$/\1/p' | head -1)
  [[ "$raw" =~ ^[0-9]+$ ]] && [ "$raw" -le 100 ] || return 1
  echo "$raw"
}

# True when $1 is a test browser main process of this user (see the header).
is_test_browser() {
  local exe args
  exe=$(ps -o comm= -p "$1" 2>/dev/null) || return 1
  args=$(ps -o command= -p "$1" 2>/dev/null) || return 1
  case "$exe" in
  */"Google Chrome.app/Contents/MacOS/Google Chrome" | */chrome-headless-shell) ;;
  *) return 1 ;;
  esac
  case "$args" in *--type=*) return 1 ;; esac
  case "$args" in */ci.noindex/aithema-runs/*) return 0 ;; esac
  return 1
}

# Elapsed time ([[dd-]hh:]mm:ss) of $1 in seconds.
age_s() {
  ps -o etime= -p "$1" 2>/dev/null | awk '{
    d = 0; t = $1
    if (index(t, "-")) { split(t, a, "-"); d = a[1]; t = a[2] }
    n = split(t, p, ":"); s = 0
    for (i = 1; i <= n; i++) s = s * 60 + p[i]
    print d * 86400 + s }'
}

# PID of the most recently started test browser, or nothing.
newest_test_browser() {
  local pid age best="" best_age=""
  for pid in $(ps -U "$(id -u)" -o pid=,command= | grep -F '/ci.noindex/aithema-runs/' | awk '{print $1}'); do
    is_test_browser "$pid" || continue
    age=$(age_s "$pid")
    [[ "$age" =~ ^[0-9]+$ ]] || continue
    if [ -z "$best_age" ] || [ "$age" -lt "$best_age" ]; then
      best=$pid
      best_age=$age
    fi
  done
  echo "$best"
}

count_test_browsers() {
  local pid n=0
  for pid in $(ps -U "$(id -u)" -o pid=,command= | grep -F '/ci.noindex/aithema-runs/' | awk '{print $1}'); do
    is_test_browser "$pid" && n=$((n + 1))
  done
  echo "$n"
}

say "START pid $$ warn<${WARN}% kill<${KILL}% (OPS-341)"
lastwarn=0
lastbeat=0
while sleep 10; do
  now=$(date +%s)
  if ! mf=$(free_pct); then
    say "WARN memory_pressure unreadable; no action"
    continue
  fi
  if [ $((now - lastbeat)) -ge 600 ]; then
    say "beat free=${mf}% swap=$(sysctl -n vm.swapusage | awk '{print $6}')"
    lastbeat=$now
  fi
  if [ "$mf" -lt "$KILL" ]; then
    victim=$(newest_test_browser)
    if [ -n "$victim" ] && is_test_browser "$victim"; then
      run=$(ps -o command= -p "$victim" | grep -oE 'aithema-runs/[^/ ]+' | head -1)
      kill -TERM "$victim" 2>/dev/null && say "KILL free=${mf}% SIGTERM test browser pid $victim ($run)"
    else
      say "CRIT free=${mf}% below ${KILL}% but no test browser to stop"
    fi
  elif [ "$mf" -lt "$WARN" ] && [ $((now - lastwarn)) -ge 60 ]; then
    say "WARN free=${mf}% (test browsers: $(count_test_browsers))"
    lastwarn=$now
  fi
done
