#!/bin/bash
# OPS-341: fast memory guard on mbp2606, user mba (packaged by hosts/mbp2606/mem-guard.nix).
# The Mac ran out of application memory at 15:44 during an
# aithema browser-test burst; the OPS night-levels loop samples only every 180 s and missed it.
# Every 10 s: read the system-wide free percentage (memory_pressure -Q).
#   < WARN (20 %): log a WARN line (rate-limited to one per minute).
#   < KILL (10 %): SIGTERM the NEWEST Chrome main process that belongs to an aithema test run
#                  (command line contains /ci.noindex/aithema-runs/), one per cycle, and log it. Test browsers only:
#                  never the ci GUI session, never another user, never anything outside aithema-runs.
# Log: ~/ci.noindex/mem-guard.log (one line per event + a heartbeat every 10 min). Single instance via a pid file.
# Started by mba's crontab every minute (installed by Home Manager); a second copy exits at once, so after a reboot
# the guard is back within a minute. Stop for maintenance: kill "$(cat ~/ci.noindex/mem-guard.pid)" (cron restarts it;
# remove the "# OPS-341 mem-guard" crontab line to keep it off).
# shellcheck disable=SC2009 # ps|grep is deliberate: the full command line picks Chrome main processes under
# aithema-runs and excludes --type= helpers, which pgrep alone cannot express.
set -u
# cron's PATH is /usr/bin:/bin; sysctl lives in /usr/sbin.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
mkdir -p "$HOME/ci.noindex"
WARN=${WARN:-20}
KILL=${KILL:-10}
LOG=$HOME/ci.noindex/mem-guard.log
PIDF=$HOME/ci.noindex/mem-guard.pid
if [ -s "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  echo "already running (pid $(cat "$PIDF"))"
  exit 0
fi
echo $$ >"$PIDF"
trap 'rm -f "$PIDF"' EXIT
say() { echo "$(date '+%F %T') $*" >>"$LOG"; }
say "START pid $$ warn<${WARN}% kill<${KILL}% (OPS-341)"
lastwarn=0
lastbeat=0
while sleep 10; do
  mf=$(memory_pressure -Q 2>/dev/null | awk -F': ' '/free percentage/{gsub("%","",$2); print $2+0}')
  now=$(date +%s)
  [[ "$mf" =~ ^[0-9]+$ ]] || {
    say "WARN memory_pressure unreadable"
    continue
  }
  if [ $((now - lastbeat)) -ge 600 ]; then
    say "beat free=${mf}% swap=$(sysctl -n vm.swapusage | awk '{print $6}')"
    lastbeat=$now
  fi
  if [ "$mf" -lt "$KILL" ]; then
    # Newest aithema test Chrome main process of this user (helpers die with it).
    victim=$(ps -U "$(id -u)" -o pid=,command= | grep -E '/ci\.noindex/aithema-runs/' |
      grep -E '(Google Chrome\.app/Contents/MacOS/Google Chrome|chrome-headless-shell) ' | grep -v -- '--type=' |
      sort -rn | head -1 | awk '{print $1}')
    if [ -n "$victim" ]; then
      run=$(ps -o command= -p "$victim" | grep -oE 'aithema-runs/[^/ ]+' | head -1)
      kill -TERM "$victim" 2>/dev/null && say "KILL free=${mf}% SIGTERM chrome pid $victim ($run)"
    else
      say "CRIT free=${mf}% below ${KILL}% but no aithema-runs Chrome to stop"
    fi
  elif [ "$mf" -lt "$WARN" ] && [ $((now - lastwarn)) -ge 60 ]; then
    say "WARN free=${mf}% (chromes in aithema-runs: $(ps -U "$(id -u)" -o command= | grep -E '/ci\.noindex/aithema-runs/' | grep -cv -- '--type='))"
    lastwarn=$now
  fi
done
