# Offline module-contract evaluation only; no inputs fetched or derivations built.
let
  lib = {
    max = a: b: if a > b then a else b;
    mkOption = value: value;
    mkEnableOption = _: { default = false; };
    mkIf = condition: value: if condition then value else { };
    escapeShellArg = value: value;
    types = {
      package = null;
      bool = null;
      str = null;
      port = null;
      ints = {
        positive = null;
        between = _: _: null;
      };
      nullOr = kind: { check = value: value == null || kind.check value; };
      strMatching = pattern: {
        check = value: builtins.isString value && builtins.match pattern value != null;
      };
      listOf = _: null;
      enum = _: null;
    };
    hm.dag.entryBetween =
      _: _: value:
      value;
  };
  pkgs =
    builtins.listToAttrs (
      map
        (name: {
          inherit name;
          value = name;
        })
        [
          "colima"
          "coreutils"
          "curl"
          "git"
          "gh"
          "nix"
          "openssh"
          "python3"
          "systemd"
          "util-linux"
        ]
    )
    // {
      writeText = name: value: {
        outPath = "/fixture/" + name;
        text = value;
        __toString = self: self.outPath;
      };
      writeShellApplication = value: value // { outPath = "/fixture/runner"; };
    };
  defaults = options: builtins.mapAttrs (_: value: value.default) options;
  executor =
    host:
    import ../modules/hausnetz-cd {
      inherit lib pkgs;
      config = {
        nix.package = "selected-nix";
        networking.hostName = host;
        inspr.hausnetzCd = (defaults (executor "hsb0").options.inspr.hausnetzCd) // {
          enable = true;
        };
      };
    };
  orchestrator = import ../hosts/mbp2607/hausnetz-cd.nix {
    inherit lib pkgs;
    config = {
      nix.package = "selected-nix";
      home.homeDirectory = "/fixture/home";
      home.profileDirectory = "/fixture/profile";
      services.ciVm.package = "/fixture/ci-vm";
      inspr.hausnetzCdOrchestrator = defaults orchestrator.options.inspr.hausnetzCdOrchestrator;
    };
  };
  host = import ../hosts/hsb0/configuration.nix {
    pkgs = { };
    lib = { };
    config = { };
    inputs = {
      hausnetz.nixosModules.default = "/fixture/hausnetz-module";
      inspr-modules.nixosModules.ssh-authorized = "/fixture/ssh-module";
    };
  };
  home = import ../hosts/mbp2607/home.nix {
    pkgs = { };
    lib = { };
    config.inspr.hausnetzCdOrchestrator.acceptancePackage = "/fixture/runner";
    inputs = { };
  };
  live = import ../hosts/mbp2607/hausnetz-cd.nix {
    inherit lib pkgs;
    config = {
      nix.package = "selected-nix";
      home.homeDirectory = "/fixture/home";
      home.profileDirectory = "/fixture/profile";
      services.ciVm.package = "/fixture/ci-vm";
      inspr.hausnetzCdOrchestrator =
        (defaults live.options.inspr.hausnetzCdOrchestrator) // home.inspr.hausnetzCdOrchestrator;
    };
  };
in
assert builtins.elem "f /run/hsb0-deploy.lock 0644 root root -"
  (executor "hsb0").config.systemd.tmpfiles.rules;
{
  executorDefaults = defaults (executor "hsb0").options.inspr.hausnetzCd;
  executorRunner =
    let
      runner = builtins.head (executor "hsb0").config.environment.systemPackages;
    in
    {
      inherit (runner) text runtimeInputs;
      settings = runner.derivationArgs.passthru.settings.text;
      entrypoint = runner.derivationArgs.passthru.entrypoint.text;
    };
  executorTmpfiles = (executor "hsb0").config.systemd.tmpfiles.rules;
  hostAssertion = (builtins.head (executor "hsb0").config.assertions).assertion;
  otherHostAssertion = (builtins.head (executor "hsb8").config.assertions).assertion;
  hostSettings = host.inspr.hausnetzCd;
  hostImports = map toString host.imports;
  homeImports = map toString home.imports;
  homeSettings = home.inspr.hausnetzCdOrchestrator;
  adapterRunner =
    let
      runner = builtins.elemAt orchestrator.config.home.packages 1;
    in
    {
      inherit (runner) text runtimeInputs;
      settings = runner.derivationArgs.passthru.settings.text;
      entrypoint = runner.derivationArgs.passthru.entrypoint.text;
    };
  liveAgent = live.config.launchd.agents.hausnetz-cd;
  liveSettings = (builtins.head live.config.home.packages).derivationArgs.passthru.settings.text;
  liveAdapterSettings =
    (builtins.elemAt live.config.home.packages 1).derivationArgs.passthru.settings.text;
  homeAlarmTicket = home.inspr.hausnetzCdOrchestrator.alarmTicket;
  homeReleaseTicket = home.inspr.hausnetzCdOrchestrator.releaseTicket;
  alarmTicketChecks =
    let
      check = orchestrator.options.inspr.hausnetzCdOrchestrator.alarmTicket.type.check;
    in
    {
      valid = map check [
        null
        "OPS-705"
        "HN3-0"
        "AB-123"
      ];
      invalid = map check [
        "ops-705"
        "OPS-1\n"
        "A-1"
        "OPS-"
        "OPS-1;id"
        705
      ];
    };
  orchestratorDefaults =
    builtins.removeAttrs (defaults orchestrator.options.inspr.hausnetzCdOrchestrator)
      [ "acceptancePackage" ];
  agent = orchestrator.config.launchd.agents.hausnetz-cd;
  orchestratorRunner =
    let
      runner = builtins.head orchestrator.config.home.packages;
    in
    {
      inherit (runner) text runtimeInputs;
      settings = runner.derivationArgs.passthru.settings.text;
      entrypoint = runner.derivationArgs.passthru.entrypoint.text;
    };
}
