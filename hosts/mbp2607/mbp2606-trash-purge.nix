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
# The purge pins the Trash: it changes into it and uses only relative paths, so a .Trash
# swapped for a symlink after the check cannot redirect a delete. A name can be refilled between
# any check and the delete (Put Back, then a fresh item trashed under the same name), so each
# entry is judged by inode (one stat gives inode and ctime), then renamed into a private
# quarantine inside the Trash, and deleted only if the renamed entry is that inode (a rename keeps
# it; APFS never reuses one). A fresh entry caught in the rename is put back.
# tests/T116 runs this script against a sandbox with stubbed ssh, find, mv and rm.
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
    inode() { ls -di -- "$1" 2>/dev/null | awk 'NR==1{print $1}'; }
    count() { find . -mindepth 1 -maxdepth 1 -print0 | tr -dc '\000' | wc -c | tr -d ' '; }
    before=$(free)
    Q=.ops489-purge-$$
    mkdir "$Q" || exit 3
    find . -mindepth 1 -maxdepth 1 -ctime +3 ! -name "$Q" -print0 >"$Q/list"
    rc=$?
    selected=0 purged=0 kept=0 failed=0
    while IFS= read -r -d "" e; do
      selected=$((selected + 1))
      i=$(inode "$e")
      if [ -z "$i" ] || [ -z "$(find . -mindepth 1 -maxdepth 1 -inum "$i" -ctime +3 ! -name "$Q" -print)" ]; then
        kept=$((kept + 1))
        continue
      fi
      if ! mv -n -- "$e" "$Q/$selected"; then
        failed=$((failed + 1))
        continue
      fi
      if [ "$(inode "$Q/$selected")" = "$i" ]; then
        if rm -rf -- "$Q/$selected"; then purged=$((purged + 1)); else failed=$((failed + 1)); fi
      else
        # BSD mv -n exits 0 when it skips, so look for what stayed behind.
        mv -n -- "$Q/$selected" "$e"
        if [ -e "$Q/$selected" ] || [ -L "$Q/$selected" ]; then
          echo "fresh entry kept as $Q/$selected: its name was taken again"
        fi
        kept=$((kept + 1))
      fi
    done <"$Q/list"
    rm -f -- "$Q/list"
    rmdir -- "$Q" 2>/dev/null || echo "$Q is not empty and stays in the Trash"
    if [ "$failed" != 0 ] && [ "$rc" = 0 ]; then rc=1; fi
    echo "selected=$selected purged=$purged kept=$kept failed=$failed rc=$rc left=$(count) df_free_before=''${before}GB df_free_after=$(free)GB (local snapshots may pin the space for up to 24 h)"
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
