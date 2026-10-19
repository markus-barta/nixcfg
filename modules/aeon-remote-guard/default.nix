# OPS-300 — admission for mba's remote-test pushes on the shared Mac.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.aeonRemoteGuard;
  home = config.home.homeDirectory;
  guard = pkgs.writeShellApplication {
    name = "aeon-remote-guard";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.perl
    ];
    text = ''
      unset AEON_REMOTE_GUARD_LOAD
      readonly guard_home=${lib.escapeShellArg home}
      readonly guard_hold_file=${lib.escapeShellArg cfg.holdFile}
      readonly guard_policy_file=${lib.escapeShellArg cfg.policyFile}
      readonly guard_max_runs_file=${lib.escapeShellArg cfg.maxRunsFile}
      readonly guard_lease_dir=${lib.escapeShellArg cfg.leaseDir}
      readonly guard_default_max_runs=${toString cfg.defaultMaxRuns}
      readonly guard_reservation_ttl_seconds=${toString cfg.reservationTtlSeconds}
      readonly guard_default_max_load=${lib.escapeShellArg (toString cfg.defaultMaxLoad)}
      readonly guard_stale_seconds=${toString cfg.staleSeconds}
      readonly guard_units_total=${toString cfg.unitsTotal}
      readonly guard_units_new_max=${toString cfg.unitsNewMax}
      readonly guard_units_finishing_reserve=${toString cfg.unitsFinishingReserve}
      readonly guard_aeon_new_max=${toString cfg.aeonNewMax}
      readonly guard_ait_new_max=${toString cfg.aitNewMax}
      readonly guard_ops_new_max=${toString cfg.opsNewMax}
      readonly guard_browser_max=${toString cfg.browserMax}
      readonly guard_units_new_max_during_browser=${toString cfg.unitsNewMaxDuringBrowser}
      readonly guard_yellow_units_new_max=${toString cfg.yellowUnitsNewMax}
      readonly guard_yellow_browser_max=${toString cfg.yellowBrowserMax}
      readonly guard_red_units_new_max=${toString cfg.redUnitsNewMax}
      readonly guard_finish_window_seconds=${toString cfg.finishWindowSeconds}
      readonly guard_recent_round_limit=${toString cfg.recentRoundLimit}
      readonly guard_budget_file=${lib.escapeShellArg cfg.budgetFile}
      readonly guard_allow_unknown_lane=${lib.boolToString cfg.allowUnknownLane}
      ${builtins.readFile ./guard.sh}
    '';
  };
  hook = pkgs.writeShellScript "aeon-remote-pre-receive" (
    lib.replaceStrings [ "@guard@" ] [ "${guard}/bin/aeon-remote-guard" ] (
      builtins.readFile ./pre-receive.sh
    )
  );
in
{
  options.services.aeonRemoteGuard = {
    enable = lib.mkEnableOption "host-side admission for remote-test pushes on macOS";
    repo = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "${home}/aeon-remote.git";
      description = "Existing bare repository under the managed home; only its pre-receive hook is managed.";
    };
    holdFile = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "${home}/.hold-mbp2606";
      description = "Refuse remote runs while this path exists.";
    };
    policyFile = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "${home}/.aeon-remote-policy";
      description = "OPS watch policy: block=<0|1> maxload=<number> level=<GREEN|YELLOW|RED> epoch=<unix>.";
    };
    defaultMaxLoad = lib.mkOption {
      type = lib.types.number;
      default = 12;
      description = "Maximum 1-minute load when no valid fresh policy is available.";
    };
    maxRunsFile = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "${home}/.aeon-remote-maxruns";
      description = "OPS run budget: maxruns=<0-9> epoch=<unix>; stale or invalid input uses defaultMaxRuns.";
    };
    defaultMaxRuns = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Run budget when no valid fresh OPS budget is available.";
    };
    leaseDir = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "${home}/.aeon-remote-leases";
      description = "Run reservations and adopted pid leases; the persistent kernel lock is adjacent at <leaseDir>.lock.";
    };
    reservationTtlSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = "Lifetime of reservations without a client pid; also the start window during which a run directory counts.";
    };
    budgetFile = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "${home}/.aeon-remote-budget";
      description = "OPS joint-budget override: whitelisted cap key=value tokens and epoch=<unix> on one line; invalid/stale files use pinned defaults.";
    };
    allowUnknownLane = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Admit legacy callers without a lane; harness-install will disable this after migrating callers.";
    };
    unitsTotal = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = "Maximum live joint units across all lanes.";
    };
    unitsNewMax = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 3;
      description = "Maximum new units across all lanes.";
    };
    unitsFinishingReserve = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 1;
      description = "Maximum simultaneous finishing units for a previously active round.";
    };
    aeonNewMax = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 2;
      description = "Maximum new units in the aeon lane.";
    };
    aitNewMax = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 1;
      description = "Maximum new units in the ait lane.";
    };
    opsNewMax = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 1;
      description = "Maximum new units in the ops lane.";
    };
    browserMax = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 1;
      description = "Maximum browser units across all lanes and phases.";
    };
    unitsNewMaxDuringBrowser = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 2;
      description = "Maximum new units while any browser unit is live, including the browser.";
    };
    yellowUnitsNewMax = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 1;
      description = "Additional new-unit cap under a fresh YELLOW policy.";
    };
    yellowBrowserMax = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = "Additional browser cap under a fresh YELLOW policy.";
    };
    redUnitsNewMax = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = "Additional new-unit cap under a fresh RED policy.";
    };
    finishWindowSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1800;
      description = "Maximum age of proof a round held a live unit for finishing admission.";
    };
    recentRoundLimit = lib.mkOption {
      type = lib.types.ints.positive;
      default = 128;
      description = "Bound on the recent-round history stored under the lease directory.";
    };
    staleSeconds = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 900;
      description = "Maximum age in seconds of a policy from the OPS watch.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin;
        message = "services.aeonRemoteGuard requires macOS (sysctl vm.loadavg).";
      }
      {
        assertion = cfg.defaultMaxLoad >= 0;
        message = "services.aeonRemoteGuard.defaultMaxLoad must be nonnegative.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.repo;
        message = "services.aeonRemoteGuard.repo must be an absolute path.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.holdFile;
        message = "services.aeonRemoteGuard.holdFile must be an absolute path.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.policyFile;
        message = "services.aeonRemoteGuard.policyFile must be an absolute path.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.maxRunsFile;
        message = "services.aeonRemoteGuard.maxRunsFile must be an absolute path.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.budgetFile;
        message = "services.aeonRemoteGuard.budgetFile must be an absolute path.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.leaseDir;
        message = "services.aeonRemoteGuard.leaseDir must be an absolute path.";
      }
      {
        assertion = lib.hasPrefix "${home}/" cfg.repo;
        message = "services.aeonRemoteGuard.repo must be under home.homeDirectory for home.file.";
      }
    ];
    home.packages = [ guard ];
    # Link one executable file into the real hooks directory, not the directory
    # itself. Git follows this symlink; HM preserves the other bare-repo files.
    home.file."${cfg.repo}/hooks/pre-receive" = {
      source = hook;
      executable = true;
    };
  };
}
