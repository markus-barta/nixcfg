# Weekly purge of mbp2606's /Users/mba/.Trash (OPS-438 → OPS-489).
#
# Agents and CI cleanups on mbp2606 trash their workspaces (doctrine: trash, never rm), and
# nothing ever empties that Trash: 842 GB had piled up by 2026-10-22. Markus decided
# (Desk 1e427ba2): empty it now, then purge weekly whatever was trashed more than 3 days ago.
#
# It runs here and reaches mbp2606 over ssh because no agent on mbp2606 can do it: mba has
# no GUI launchd domain there (its LaunchAgents never load), and ci, which has one, cannot
# read mba's 0700 ~/.Trash. sshd has the disk access the Trash needs.
#
# Scope: only the direct children of /Users/mba/.Trash with ctime older than 3 days (a move
# into the Trash sets ctime). Purging the Trash is permanent by definition.
#
# The purge pins the Trash: it changes into it with cd -P, checks that the physical path is
# still /Users/mba/.Trash, and deletes only relative ./<name> paths. A .Trash swapped for a
# symlink cannot redirect a delete outside the Trash. Each entry is age-checked and removed in
# one find -exec.
#
# Accepted residuals: one pass, by Markus's decision (Desk 9741f4f4, 2026-10-28: "Keep one pass;
# I accept the residual races"):
# - an entry that is removed, and a fresh one trashed under the same name between its ctime
#   check and its rm, is deleted too;
# - a clock jump shifts the 3-day age.
# Either way, what is deleted is a direct child of the Trash.
# tests/T116 runs this script against a sandbox with stubbed ssh, find and rm.
{ config, pkgs, ... }:
let
  purge = pkgs.writeShellScript "mbp2606-trash-purge" ''
    set -uo pipefail
    out=$(/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=20 -o HostKeyAlias=mbp2606.local \
      mba@mbp2606.lan 'bash -s' 2>&1 <<'REMOTE'
    set -uo pipefail
    T=/Users/mba/.Trash
    if [ ! -d "$T" ] || [ -L "$T" ]; then echo "no trash dir at $T"; exit 3; fi
    cd -P "$T" || exit 3
    if [ "$(pwd -P)" != "$T" ]; then echo "trash dir resolved elsewhere: $(pwd -P)"; exit 3; fi
    free() { df -g /System/Volumes/Data | awk 'NR==2{print $4}'; }
    before=$(free)
    selected=$(find . -mindepth 1 -maxdepth 1 -ctime +3 -print0 | tr -dc '\000' | wc -c | tr -d ' ')
    # An entry whose rm fails is printed; find's own errors set rc.
    failed=$(find . -mindepth 1 -maxdepth 1 -ctime +3 ! -exec rm -rf {} \; -print0 | tr -dc '\000' | wc -c | tr -d ' ')
    rc=$?
    if [ "$failed" != 0 ] && [ "$rc" = 0 ]; then rc=1; fi
    echo "selected=$selected failed=$failed rc=$rc left=$(find . -mindepth 1 -maxdepth 1 -print0 | tr -dc '\000' | wc -c | tr -d ' ') df_free_before=''${before}GB df_free_after=$(free)GB (local snapshots may pin the space for up to 24 h)"
    exit $rc
    REMOTE
    )
    rc=$?
    echo "$(date '+%F %T') rc=$rc $out"
    exit $rc
  '';
in
{
  launchd.agents.mbp2606-trash-purge = {
    enable = true;
    config = {
      ProgramArguments = [ "${purge}" ];
      StartCalendarInterval = [
        {
          Weekday = 0; # Sunday
          Hour = 4;
          Minute = 30;
        }
      ];
      RunAtLoad = false;
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/mbp2606-trash-purge.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/mbp2606-trash-purge.log";
    };
  };
}
