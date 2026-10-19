{
  root,
  moduleOnly ? false,
}:
if moduleOnly then
  let
    # Legacy nix-instantiate + a cached nixpkgs/lib can run these without a
    # daemon, store writes, host evaluation or builds. Package stubs are inert.
    lib = import <nixpkgs/lib>;
    pkgs = {
      coreutils = "/fixture/coreutils";
      gawk = "/fixture/gawk";
      perl = "/fixture/perl";
      stdenv.hostPlatform.isDarwin = true;
      writeShellApplication = args: args // { outPath = "/fixture/guard"; };
      writeShellScript = _: text: { inherit text; };
    };
    evaluate =
      overrides:
      lib.evalModules {
        specialArgs = { inherit pkgs; };
        modules = [
          (root + "/modules/aeon-remote-guard")
          {
            options = {
              home.homeDirectory = lib.mkOption { type = lib.types.str; };
              home.packages = lib.mkOption { type = lib.types.listOf lib.types.attrs; };
              home.file = lib.mkOption { type = lib.types.attrs; };
              assertions = lib.mkOption { type = lib.types.listOf lib.types.attrs; };
            };
            config.home.homeDirectory = "/fixture/home";
            config.services.aeonRemoteGuard = {
              enable = true;
            }
            // overrides;
          }
        ];
      };
    evaluated = evaluate { };
    cfg = evaluated.config.services.aeonRemoteGuard;
    guard = builtins.head evaluated.config.home.packages;
    custom = evaluate {
      maxRunsFile = "/fixture/custom budget";
      leaseDir = "/fixture/custom leases";
      defaultMaxRuns = 3;
      reservationTtlSeconds = 45;
      budgetFile = "/fixture/joint budget";
      allowUnknownLane = false;
      unitsTotal = 6;
      unitsNewMax = 4;
      unitsFinishingReserve = 2;
      aeonNewMax = 3;
      aitNewMax = 2;
      opsNewMax = 2;
      browserMax = 2;
      unitsNewMaxDuringBrowser = 3;
      yellowUnitsNewMax = 2;
      yellowBrowserMax = 1;
      redUnitsNewMax = 1;
      redBrowserMax = 1;
      finishWindowSeconds = 60;
      recentRoundLimit = 8;
    };
    customGuard = builtins.head custom.config.home.packages;
    rejects = overrides: builtins.any (a: !a.assertion) (evaluate overrides).config.assertions;
  in
  {
    checks = {
      jointBudgetPath = cfg.budgetFile == "/fixture/home/.aeon-remote-budget";
      unknownLaneDefault = cfg.allowUnknownLane;
      relativeJointBudgetRejected = rejects { budgetFile = "relative"; };
      customJointBudgetPinned = lib.hasInfix "readonly guard_budget_file='/fixture/joint budget'" customGuard.text;
      unknownLanePinned = lib.hasInfix "readonly guard_allow_unknown_lane=false" customGuard.text;
      unitsTotalDefault = cfg.unitsTotal == 4;
      unitsTotalPinned = lib.hasInfix "readonly guard_units_total=6" customGuard.text;
      unitsTotalNegativeRejected = !evaluated.options.services.aeonRemoteGuard.unitsTotal.type.check (-1);
      unitsNewMaxDefault = cfg.unitsNewMax == 3;
      unitsNewMaxPinned = lib.hasInfix "readonly guard_units_new_max=4" customGuard.text;
      unitsNewMaxNegativeRejected =
        !evaluated.options.services.aeonRemoteGuard.unitsNewMax.type.check (-1);
      unitsFinishingReserveDefault = cfg.unitsFinishingReserve == 1;
      unitsFinishingReservePinned = lib.hasInfix "readonly guard_units_finishing_reserve=2" customGuard.text;
      unitsFinishingReserveNegativeRejected =
        !evaluated.options.services.aeonRemoteGuard.unitsFinishingReserve.type.check (-1);
      aeonNewMaxDefault = cfg.aeonNewMax == 2;
      aeonNewMaxPinned = lib.hasInfix "readonly guard_aeon_new_max=3" customGuard.text;
      aeonNewMaxNegativeRejected = !evaluated.options.services.aeonRemoteGuard.aeonNewMax.type.check (-1);
      aitNewMaxDefault = cfg.aitNewMax == 1;
      aitNewMaxPinned = lib.hasInfix "readonly guard_ait_new_max=2" customGuard.text;
      aitNewMaxNegativeRejected = !evaluated.options.services.aeonRemoteGuard.aitNewMax.type.check (-1);
      opsNewMaxDefault = cfg.opsNewMax == 1;
      opsNewMaxPinned = lib.hasInfix "readonly guard_ops_new_max=2" customGuard.text;
      opsNewMaxNegativeRejected = !evaluated.options.services.aeonRemoteGuard.opsNewMax.type.check (-1);
      browserMaxDefault = cfg.browserMax == 1;
      browserMaxPinned = lib.hasInfix "readonly guard_browser_max=2" customGuard.text;
      browserMaxNegativeRejected = !evaluated.options.services.aeonRemoteGuard.browserMax.type.check (-1);
      unitsNewMaxDuringBrowserDefault = cfg.unitsNewMaxDuringBrowser == 2;
      unitsNewMaxDuringBrowserPinned = lib.hasInfix "readonly guard_units_new_max_during_browser=3" customGuard.text;
      unitsNewMaxDuringBrowserNegativeRejected =
        !evaluated.options.services.aeonRemoteGuard.unitsNewMaxDuringBrowser.type.check (-1);
      yellowUnitsNewMaxDefault = cfg.yellowUnitsNewMax == 1;
      yellowUnitsNewMaxPinned = lib.hasInfix "readonly guard_yellow_units_new_max=2" customGuard.text;
      yellowUnitsNewMaxNegativeRejected =
        !evaluated.options.services.aeonRemoteGuard.yellowUnitsNewMax.type.check (-1);
      yellowBrowserMaxDefault = cfg.yellowBrowserMax == 0;
      yellowBrowserMaxPinned = lib.hasInfix "readonly guard_yellow_browser_max=1" customGuard.text;
      yellowBrowserMaxNegativeRejected =
        !evaluated.options.services.aeonRemoteGuard.yellowBrowserMax.type.check (-1);
      redUnitsNewMaxDefault = cfg.redUnitsNewMax == 0;
      redUnitsNewMaxPinned = lib.hasInfix "readonly guard_red_units_new_max=1" customGuard.text;
      redUnitsNewMaxNegativeRejected =
        !evaluated.options.services.aeonRemoteGuard.redUnitsNewMax.type.check (-1);
      redBrowserMaxDefault = cfg.redBrowserMax == 0;
      redBrowserMaxPinned = lib.hasInfix "readonly guard_red_browser_max=1" customGuard.text;
      redBrowserMaxNegativeRejected =
        !evaluated.options.services.aeonRemoteGuard.redBrowserMax.type.check (-1);
      finishWindowSecondsDefault = cfg.finishWindowSeconds == 1800;
      finishWindowSecondsPinned = lib.hasInfix "readonly guard_finish_window_seconds=60" customGuard.text;
      finishWindowSecondsNegativeRejected =
        !evaluated.options.services.aeonRemoteGuard.finishWindowSeconds.type.check (-1);
      recentRoundLimitDefault = cfg.recentRoundLimit == 128;
      recentRoundLimitPinned = lib.hasInfix "readonly guard_recent_round_limit=8" customGuard.text;
      recentRoundLimitNegativeRejected =
        !evaluated.options.services.aeonRemoteGuard.recentRoundLimit.type.check (-1);
      defaultMaxRuns = cfg.defaultMaxRuns == 1;
      defaultTtl = cfg.reservationTtlSeconds == 120;
      defaultBudgetPath = cfg.maxRunsFile == "/fixture/home/.aeon-remote-maxruns";
      defaultLeasePath = cfg.leaseDir == "/fixture/home/.aeon-remote-leases";
      defaultDisabled = !evaluated.options.services.aeonRemoteGuard.enable.default;
      positiveMaxRuns = !evaluated.options.services.aeonRemoteGuard.defaultMaxRuns.type.check 0;
      positiveTtl = !evaluated.options.services.aeonRemoteGuard.reservationTtlSeconds.type.check 0;
      validAssertions = builtins.all (a: a.assertion) evaluated.config.assertions;
      relativeBudgetRejected = rejects { maxRunsFile = "relative"; };
      relativeLeaseRejected = rejects { leaseDir = "relative"; };
      perlDependency = builtins.elem "/fixture/perl" guard.runtimeInputs;
      homePinned = lib.hasInfix "readonly guard_home=/fixture/home" guard.text;
      productionLoadPinned = lib.hasInfix "unset AEON_REMOTE_GUARD_LOAD" guard.text;
      customBudgetPinned = lib.hasInfix "readonly guard_max_runs_file='/fixture/custom budget'" customGuard.text;
      customLeasesPinned = lib.hasInfix "readonly guard_lease_dir='/fixture/custom leases'" customGuard.text;
      customMaxRunsPinned = lib.hasInfix "readonly guard_default_max_runs=3" customGuard.text;
      customTtlPinned = lib.hasInfix "readonly guard_reservation_ttl_seconds=45" customGuard.text;
      hookReservations =
        lib.hasInfix ''exec "/fixture/guard/bin/aeon-remote-guard" reserve "$run_id"''
          evaluated.config.home.file."${cfg.repo}/hooks/pre-receive".source.text;
    };
  }
else
  let
    flake = builtins.getFlake (toString root);
    host = flake.homeConfigurations."mba@mbp2606";
    cfg = host.config.services.aeonRemoteGuard;
    hookPath = "${cfg.repo}/hooks/pre-receive";
    hook = host.config.home.file.${hookPath};
  in
  {
    checks = {
      enabled = cfg.enable;
      defaultDisabled = !host.options.services.aeonRemoteGuard.enable.default;
      repo = cfg.repo == "${host.config.home.homeDirectory}/aeon-remote.git";
      hold = cfg.holdFile == "${host.config.home.homeDirectory}/.hold-mbp2606";
      policy = cfg.policyFile == "${host.config.home.homeDirectory}/.aeon-remote-policy";
      maxRunsFile = cfg.maxRunsFile == "${host.config.home.homeDirectory}/.aeon-remote-maxruns";
      defaultMaxRuns = cfg.defaultMaxRuns == 1;
      leaseDir = cfg.leaseDir == "${host.config.home.homeDirectory}/.aeon-remote-leases";
      jointBudgetPath = cfg.budgetFile == "${host.config.home.homeDirectory}/.aeon-remote-budget";
      unknownLaneDefault = cfg.allowUnknownLane;
      unitsTotal = cfg.unitsTotal == 4;
      unitsNewMax = cfg.unitsNewMax == 3;
      unitsFinishingReserve = cfg.unitsFinishingReserve == 1;
      aeonNewMax = cfg.aeonNewMax == 2;
      aitNewMax = cfg.aitNewMax == 1;
      opsNewMax = cfg.opsNewMax == 1;
      browserMax = cfg.browserMax == 1;
      unitsNewMaxDuringBrowser = cfg.unitsNewMaxDuringBrowser == 2;
      yellowUnitsNewMax = cfg.yellowUnitsNewMax == 1;
      yellowBrowserMax = cfg.yellowBrowserMax == 0;
      redUnitsNewMax = cfg.redUnitsNewMax == 0;
      redBrowserMax = cfg.redBrowserMax == 0;
      finishWindowSeconds = cfg.finishWindowSeconds == 1800;
      recentRoundLimit = cfg.recentRoundLimit == 128;
      reservationTtl = cfg.reservationTtlSeconds == 120;
      assertions = builtins.all (a: a.assertion) host.config.assertions;
      positiveMaxRuns = !(host.options.services.aeonRemoteGuard.defaultMaxRuns.type.check 0);
      positiveTtl = !(host.options.services.aeonRemoteGuard.reservationTtlSeconds.type.check 0);
      maxload = cfg.defaultMaxLoad == 12;
      stale = cfg.staleSeconds == 900;
      package = builtins.any (p: (p.name or "") == "aeon-remote-guard") host.config.home.packages;
      hook = hook.enable && hook.executable && hook.source != null;
      target = hook.target == "aeon-remote.git/hooks/pre-receive";
    };
    hookSource = toString hook.source;
  }
