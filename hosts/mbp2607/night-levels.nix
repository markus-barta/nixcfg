# Run the OPS-300 night-levels loop as markus's KeepAlive launchd agent (OPS-595).
# The hand-started loop died around 2026-11-05; nobody noticed until 2026-11-15.
# Every 180 s it measures both Macs, writes mbp2606's ~/.aeon-remote-policy and
# ~/.aeon-remote-maxruns, and updates LEAD's HOST-LEVEL.heartbeat. Level changes
# call /Users/markus/.aeon/lead/aeon/host-level.sh: that script and HOST-LEVEL
# belong to LEAD and stay outside nixcfg.
# Output stays in ~/.local/share/ops-qa/state/brake-night-levels.log. A separate
# five-minute check alerts mac-lead once when the heartbeat is
# over 900 s old (or missing/malformed), and once on recovery; its state and log
# are night-levels-stale.state and night-levels-stale.log in the same directory.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  home = config.home.homeDirectory;
  stateDir = "${home}/.local/share/ops-qa/state";
  stale = pkgs.writeShellScript "night-levels-stale" ''
    set -u
    heartbeat=''${NL_HEARTBEAT:-/Users/markus/.aeon/lead/aeon/HOST-LEVEL.heartbeat}
    state="$HOME/.local/share/ops-qa/state/night-levels-stale.state"
    MBX=''${MBX:-$HOME/.local/bin/mbx}
    LAUNCHCTL=''${LAUNCHCTL:-/bin/launchctl}
    log() { printf '%s %s\n' "$(/bin/date '+%F %T')" "$*"; }

    epoch=$(/usr/bin/awk '{
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^epoch=[0-9]+$/) {
          sub(/^epoch=/, "", $i); print $i; exit
        }
      }
    }' "$heartbeat" 2>/dev/null) || epoch=
    age=unknown
    current=stale
    if [ -n "$epoch" ]; then
      now=$(/bin/date +%s)
      age=$(/usr/bin/awk -v now="$now" -v epoch="$epoch" 'BEGIN { printf "%.0f", now - epoch }')
      if /usr/bin/awk -v age="$age" 'BEGIN { exit !(age <= 900) }'; then
        current=ok
      fi
    fi

    # Missing state starts as ok, so an already-stale heartbeat alerts once.
    previous=ok
    if [ -r "$state" ]; then
      IFS= read -r previous < "$state" || previous=ok
    fi
    case "$previous" in ok|stale) ;; *) previous=ok ;; esac
    [ "$previous" = "$current" ] && exit 0

    # Persist before sending: a failed mbx must not cause repeated alerts.
    if ! printf '%s\n' "$current" > "$state"; then
      log "cannot write state: $state"
      exit 0
    fi
    if [ "$current" = stale ]; then
      message="night-levels heartbeat stale: $age s (> 900 s). mbp2606's guard fallback: maxload 12, maxruns 1, level UNKNOWN. Check: launchctl print gui/$(/usr/bin/id -u)/org.nix-community.home.night-levels"
    else
      message="night-levels heartbeat recovered: $age s (<= 900 s). Check: launchctl print gui/$(/usr/bin/id -u)/org.nix-community.home.night-levels"
    fi
    log "$message"
    if [ "$current" = stale ]; then
      "$LAUNCHCTL" kickstart -k "gui/$(/usr/bin/id -u)/org.nix-community.home.night-levels"
      rc=$?
      log "launchctl kickstart -k night-levels exited $rc"
      message="$message; launchctl kickstart attempted (exit $rc)."
    fi
    if [ ! -x "$MBX" ]; then
      log "mbx is not executable: $MBX"
      exit 0
    fi
    "$MBX" send mac-lead -f night-levels-watch -t OPS-595 -m "$message" || log "mbx send failed (exit $?)"
    exit 0
  '';
in
{
  # launchd opens both logs before starting the agents; create their parent first.
  home.activation.nightLevelsStateDirectory =
    lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ]
      ''
        run mkdir -p ${lib.escapeShellArg stateDir}
      '';

  launchd.agents.night-levels = {
    enable = true;
    config = {
      ProgramArguments = [
        "/bin/bash"
        "${./files/night-levels/night-levels.sh}"
      ];
      EnvironmentVariables = {
        RED_LOAD = "28";
        NL_MAC_HEALTH = "${./files/night-levels/mac-health.sh}";
        NL_UNGUARDED = "${./files/night-levels/mbp2606-unguarded.sh}";
        HOME = home;
        PATH = "${config.home.profileDirectory}/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin:/usr/sbin:/sbin:/etc/profiles/per-user/markus/bin:/run/current-system/sw/bin";
      };
      KeepAlive = true;
      RunAtLoad = true;
      ThrottleInterval = 30;
      StandardOutPath = "${stateDir}/brake-night-levels.log";
      StandardErrorPath = "${stateDir}/brake-night-levels.log";
    };
  };

  launchd.agents.night-levels-stale = {
    enable = true;
    config = {
      ProgramArguments = [ "${stale}" ];
      EnvironmentVariables.HOME = home;
      StartInterval = 300;
      RunAtLoad = false;
      StandardOutPath = "${stateDir}/night-levels-stale.log";
      StandardErrorPath = "${stateDir}/night-levels-stale.log";
    };
  };
}
