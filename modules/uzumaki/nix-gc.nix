# NIX-603 — weekly dead-paths-only Nix garbage collection plus a low-space
# guard for macOS standalone Home Manager (opt-in per host).
#
# WHY
# ===
# On 2026-10-01 mbp2607's Nix store was 362 GB on disk, 247 GiB of its 291 GiB
# (85%) dead: 197,741 unreferenced paths, mostly ~16 MiB `-source` snapshots
# that every `nix develop` / `nix build` / `nix flake` run in a changing git
# tree creates, plus one 73 GiB `path:`-style copy of a checkout. Nothing ever
# collected them: NixOS hosts get `programs.nh.clean` from the shared hokage
# module (see modules/common.nix), macOS had no GC at all. Agents run
# thousands of flake commands, so the garbage comes back. OPS-245 has the log.
#
# WHY A USER LAUNCHD AGENT (and not nix.gc / min-free)
# ====================================================
# mbp2607 is standalone Home Manager, not nix-darwin, and /etc/nix/nix.conf is
# the installer default. Daemon-side settings (`min-free`/`max-free`) cannot be
# declared from Home Manager. What does work: the user can run `nix-store --gc`
# through the daemon (done five times on 2026-10-01 without a stall). So the
# declarative route is a pair of user launchd agents:
#
#   nix-gc          weekly, Sunday at `weeklyHour`, collects ALL dead paths
#   nix-gc-lowspace every 30 min, collects only when free space on the Data
#                   volume is below `minFreeGiB`, capped per run
#
# Dead paths only. There is deliberately no `--delete-older-than`: the live
# set was just 44 GiB, so deleting generations would save nothing and cost
# rollback.
#
# RULES THIS MODULE CANNOT ENFORCE
# ================================
# Anything run from OUTSIDE the store but linked against store paths breaks
# once its dependencies are collected (2026-10-01: a locally built `aeon` CLI
# copied into a worktree lost libresolv). Reference such tools through an
# out-link (`nix build -o <link>`, an indirect GC root), never a copy.
#
# OPERATE
# =======
#   status    launchctl list | grep nix-gc
#   run now   launchctl kickstart gui/$(id -u)/org.nix-community.home.nix-gc
#   pause     launchctl bootout   gui/$(id -u)/org.nix-community.home.nix-gc
#             (and ...nix-gc-lowspace); Home Manager re-loads them on the
#             next `home-manager switch`, so disable the option to keep them off
#   log       ~/Library/Logs/nix-gc.log (one line per real run)
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.uzumaki.nixGc;
  logFile = "${config.home.homeDirectory}/Library/Logs/nix-gc.log";

  gc = pkgs.writeShellApplication {
    name = "nix-gc-guarded";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      config.nix.package
    ];
    text = ''
      mode=''${1:-weekly}
      lock="''${TMPDIR:-/tmp}/nix-gc-guarded.lock"

      log() { printf '%s nix-gc[%s] %s\n' "$(date '+%F %T')" "$mode" "$*"; }

      # One run at a time: the weekly and the low-space agent must not queue
      # behind each other on nix's own GC lock. A lock older than 6 h is stale
      # (crash, reboot) and is taken over.
      if ! mkdir "$lock" 2>/dev/null; then
        if [ -n "$(find "$lock" -maxdepth 0 -mmin +360 2>/dev/null)" ]; then
          rmdir "$lock" 2>/dev/null || true
          mkdir "$lock" 2>/dev/null || { log "another run holds the lock; skipping"; exit 0; }
        else
          log "another run holds the lock; skipping"
          exit 0
        fi
      fi
      trap 'rmdir "$lock" 2>/dev/null || true' EXIT

      # Free space as macOS reports it for the Data volume (shared with the
      # Nix Store volume in one APFS container), in whole GiB.
      avail_kib=$(df --output=avail -k /System/Volumes/Data | tail -n 1 | tr -d ' ')
      free_gib=$(( avail_kib / 1048576 ))

      max_args=()
      case "$mode" in
        weekly)
          log "start; free=''${free_gib} GiB; all dead paths"
          ;;
        lowspace)
          # Stay silent when there is nothing to do: the log holds real runs only.
          if [ "$free_gib" -ge ${toString cfg.minFreeGiB} ]; then
            exit 0
          fi
          log "start; free=''${free_gib} GiB < ${toString cfg.minFreeGiB} GiB; cap ${toString cfg.lowSpaceMaxFreedGiB}G"
          max_args=(--max-freed "${toString cfg.lowSpaceMaxFreedGiB}G")
          ;;
        *)
          log "unknown mode '$mode' (expected weekly or lowspace)"
          exit 2
          ;;
      esac

      # `nix-store --gc` prints one line per deleted path; keep only its tail
      # (the "N store paths deleted, X MiB freed" summary) plus the exit code.
      summary=$(
        {
          nix-store --gc "''${max_args[@]}" 2>&1 && rc=0 || rc=$?
          echo "exit=$rc"
        } | tail -n 4 | tr '\n' ' '
      )
      log "finished: $summary"
    '';
  };
in
{
  options.uzumaki.nixGc = {
    enable = lib.mkEnableOption ''
      weekly dead-paths-only Nix GC plus a low-space guard (macOS standalone
      Home Manager, NIX-603). Enable it for exactly ONE user per Mac: the
      store is shared by every account on the machine'';

    minFreeGiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 100;
      description = "The low-space agent collects when free space on the Data volume drops below this many GiB.";
    };

    lowSpaceMaxFreedGiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = ''
        Cap per low-space run (`--max-freed`). The cap is only checked between
        store paths, so one very large path can overshoot it; the next 30 min
        tick continues if free space is still low.
      '';
    };

    weeklyHour = lib.mkOption {
      type = lib.types.ints.between 0 23;
      default = 4;
      description = "Hour (local time) of the Sunday run. If the Mac is asleep, launchd runs it at wake.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin;
        message = "uzumaki.nixGc is a macOS launchd feature (NIX-603); NixOS hosts get GC from programs.nh.clean in modules/common.nix.";
      }
    ];

    launchd.agents.nix-gc = {
      enable = true;
      config = {
        ProgramArguments = [
          "${gc}/bin/nix-gc-guarded"
          "weekly"
        ];
        StartCalendarInterval = [
          {
            Weekday = 0; # Sunday
            Hour = cfg.weeklyHour;
            Minute = 0;
          }
        ];
        ProcessType = "Background";
        LowPriorityIO = true;
        Nice = 10;
        StandardOutPath = logFile;
        StandardErrorPath = logFile;
      };
    };

    launchd.agents.nix-gc-lowspace = {
      enable = true;
      config = {
        ProgramArguments = [
          "${gc}/bin/nix-gc-guarded"
          "lowspace"
        ];
        StartInterval = 1800;
        ProcessType = "Background";
        LowPriorityIO = true;
        Nice = 10;
        StandardOutPath = logFile;
        StandardErrorPath = logFile;
      };
    };

    # launchd opens the log before the script runs, so create its parent first.
    home.activation.nixGcLogDirectory =
      lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ]
        ''
          run mkdir -p ${lib.escapeShellArg "${config.home.homeDirectory}/Library/Logs"}
        '';
  };
}
