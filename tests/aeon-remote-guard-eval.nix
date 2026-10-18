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
    };
    customGuard = builtins.head custom.config.home.packages;
    rejects = overrides: builtins.any (a: !a.assertion) (evaluate overrides).config.assertions;
  in
  {
    checks = {
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
