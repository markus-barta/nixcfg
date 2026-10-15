# OPS-341 — fast memory guard for mbp2606 (user mba).
#
# On 2026-10-15 the Mac ran out of application memory during an aithema browser-test burst (tests run as mba over
# ssh under ~/ci.noindex/aithema-runs/). The guard samples memory every 10 s and stops the newest test Chrome below
# 10 % free; see ./mem-guard.sh.
#
# Why cron and not launchd: mba has no graphical session here (no gui/503 domain), so an mba LaunchAgent never
# loads (NIX-603), and the ci console user cannot signal mba's processes. cron (com.vix.cron, started on demand by
# launchd) runs user crontabs without a login session, so one marked line restarts the guard within a minute after
# a reboot. The script is single-instance via its pid file, so the per-minute call exits at once while a guard runs.
{ lib, ... }:

let
  marker = "# OPS-341 mem-guard";
  # $HOME is expanded by cron's /bin/sh; the stable ~/.local/bin path survives generation changes.
  cronLine = "* * * * * $HOME/.local/bin/mbp2606-mem-guard >/dev/null 2>&1 ${marker}";
in
{
  home.file.".local/bin/mbp2606-mem-guard" = {
    source = ./mem-guard.sh;
    executable = true;
  };

  # Keep exactly one marked line in mba's crontab; other non-empty lines are preserved as they are.
  home.activation.memGuardCron = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    current=$(/usr/bin/crontab -l 2>/dev/null || true)
    wanted=$( { printf '%s\n' "$current" | /usr/bin/awk -v m='${marker}' 'index($0, m) == 0 && NF > 0'; printf '%s\n' '${cronLine}'; } )
    if [ "$wanted" != "$current" ]; then
      printf '%s\n' "$wanted" | run /usr/bin/crontab -
      echo "OPS-341: mem-guard crontab line installed"
    fi
  '';
}
