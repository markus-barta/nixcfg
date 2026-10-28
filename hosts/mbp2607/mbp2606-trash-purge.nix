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
# Scope: the direct children of /Users/mba/.Trash with ctime older than 3 days (a move into the
# Trash sets ctime). Purging the Trash is permanent by definition.
#
# Two stages, so no race between a check and a delete matters: a run first deletes the batches
# that an earlier run moved into the private hold dir .ops489-hold at least 3 days ago (a batch
# is named by its run's epoch), then moves today's eligible entries into a new batch. Whatever
# took an old entry's name just before the move (Put Back, then a fresh item trashed under the
# same name) is held too and goes no sooner than 3 days later, so everything deleted spent more
# than 3 days in the Trash. Space comes back one weekly run after an entry qualifies. Deletes
# happen only from inside the hold, pinned with cd -P and checked with pwd -P, as is the Trash;
# nothing else writes into the hold. tests/T116 runs this script against a sandbox with stubbed
# ssh, date, find, mv and rm.
{ config, pkgs, ... }:
let
  purge = pkgs.writeShellScript "mbp2606-trash-purge" ''
    set -uo pipefail
    out=$(/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=20 -o HostKeyAlias=mbp2606.local \
      mba@mbp2606.lan 'bash -s' 2>&1 <<'REMOTE'
    set -uo pipefail
    T=/Users/mba/.Trash
    H=.ops489-hold
    HOLD_S=259200
    if [ ! -d "$T" ] || [ -L "$T" ]; then echo "no trash dir at $T"; exit 3; fi
    cd -P "$T" || exit 3
    if [ "$(pwd -P)" != "$T" ]; then echo "trash dir resolved elsewhere: $(pwd -P)"; exit 3; fi
    if [ -L "$H" ]; then echo "$H is a symlink"; exit 3; fi
    if [ ! -d "$H" ]; then mkdir "$H" || exit 3; fi
    free() { df -g /System/Volumes/Data | awk 'NR==2{print $4}'; }
    count() { find "$1" -mindepth 1 -maxdepth 1 -print0 | tr -dc '\000' | wc -c | tr -d ' '; }
    before=$(free)
    now=$(date +%s)
    batches=0 purged=0 failed=0
    # 1. From inside the hold: delete the batches an earlier run moved there at least 3 days ago.
    cd -P "$H" || exit 3
    if [ "$(pwd -P)" != "$T/$H" ]; then echo "hold dir resolved elsewhere: $(pwd -P)"; exit 3; fi
    for b in *; do
      # (pattern) form: a bare ")" would end the command substitution this heredoc sits in.
      case "$b" in ([1-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;; (*) continue ;; esac
      if [ $((now - b)) -lt "$HOLD_S" ]; then continue; fi
      n=$(count "./$b")
      if rm -rf -- "./$b"; then
        batches=$((batches + 1))
        purged=$((purged + n))
      else
        failed=$((failed + 1))
      fi
    done
    cd -P .. || exit 3
    if [ "$(pwd -P)" != "$T" ]; then echo "hold dir is no longer inside $T"; exit 3; fi
    # 2. Hold what was trashed more than 3 days ago; a run at least 3 days later deletes it.
    mkdir "$H/$now" || exit 3
    find . -mindepth 1 -maxdepth 1 -ctime +3 ! -name "$H" -exec mv -n -- {} "$H/$now/" \;
    rc=$?
    left=$(find . -mindepth 1 -maxdepth 1 ! -name "$H" -print0 | tr -dc '\000' | wc -c | tr -d ' ')
    if [ "$failed" != 0 ] && [ "$rc" = 0 ]; then rc=1; fi
    echo "held=$(count "$H/$now") purged=$purged batches=$batches failed=$failed rc=$rc left=$left df_free_before=''${before}GB df_free_after=$(free)GB (local snapshots may pin the space for up to 24 h)"
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
