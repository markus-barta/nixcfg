# Offline module-contract evaluation only; no inputs fetched or derivations built.
let
  lib = {
    mkOption = value: value;
    mkEnableOption = _: { default = false; };
    mkIf = condition: value: if condition then value else { };
    escapeShellArg = value: value;
    types = {
      bool = null;
      str = null;
      nullOr = _: null;
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
          "coreutils"
          "curl"
          "git"
          "nix"
          "openssh"
          "python3"
          "systemd"
          "util-linux"
        ]
    )
    // {
      writeText = _: value: value;
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
    config = { };
    inputs = { };
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
    };
  executorTmpfiles = (executor "hsb0").config.systemd.tmpfiles.rules;
  hostAssertion = (builtins.head (executor "hsb0").config.assertions).assertion;
  otherHostAssertion = (builtins.head (executor "hsb8").config.assertions).assertion;
  hostSettings = host.inspr.hausnetzCd;
  hostImports = map toString host.imports;
  homeImports = map toString home.imports;
  orchestratorDefaults = defaults orchestrator.options.inspr.hausnetzCdOrchestrator;
  agent = orchestrator.config.launchd.agents.hausnetz-cd;
  orchestratorRunner =
    let
      runner = builtins.head orchestrator.config.home.packages;
    in
    {
      inherit (runner) text runtimeInputs;
    };
}
