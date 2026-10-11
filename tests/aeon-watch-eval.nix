# OPS-307: pure evaluation of csb1's imported module; no builds or secret reads.
{
  probeTenant ? null,
}:
let
  lib = import <nixpkgs/lib>;
  # Inert package paths exercise rendering without constructing derivations.
  pkgs = {
    docker = "/fixture/docker";
    python3 = "/fixture/python3";
    writeText = _: text: text;
    runCommand =
      name: _: script:
      assert !(lib.hasInfix "@DOCKER_BIN@" script);
      assert !(lib.hasInfix "@NOTIFICATION_ENV@" script);
      assert !(lib.hasInfix "@PROBE_TENANT@" script);
      assert !(lib.hasInfix "@WATCH_INTERVAL_SECONDS@" script);
      assert lib.hasInfix "DOCKER = \"/fixture/docker/bin/docker\"" script;
      assert lib.hasInfix "NOTIFICATION_ENV = \"/run/credentials/aeon-watch.service/notification-env\""
        script;
      assert lib.hasInfix "PROBE_TENANT = \"${cfg.aeonWatch.probeTenant}\"" script;
      assert lib.hasInfix "WATCH_INTERVAL_SECONDS = int(\"30\")" script;
      "/fixture/${name}";
  };
  host = import ../hosts/csb1/configuration.nix {
    inherit lib pkgs;
    inputs.inspr-modules.nixosModules = {
      ssh-authorized = { };
      routing-edge = { };
      aithema-workspace = { };
    };
    config = { };
  };
  modulePath = ../hosts/csb1/aeon-watch.nix;
  imported = builtins.filter (path: path == modulePath) host.imports;
  evaluated = lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = imported ++ [
      {
        options = {
          systemd = lib.mkOption { type = lib.types.attrs; };
          age = lib.mkOption { type = lib.types.attrs; };
        };
        config = {
          age.secrets.csb1-watchtower-env.path = "/fixture/notification-target";
        }
        // lib.optionalAttrs (probeTenant != null) { aeonWatch.probeTenant = probeTenant; };
      }
    ];
  };
  cfg = evaluated.config;
  # Force mkPoller's substitution path too: the stub never builds or writes.
  raw = import modulePath {
    inherit lib pkgs;
    config = cfg;
  };
in
assert builtins.length imported == 1;
{
  tenant = cfg.aeonWatch.probeTenant;
  service = cfg.systemd.services.aeon-watch;
  timer = cfg.systemd.timers.aeon-watch;
  rendered = raw.config.systemd.services.aeon-watch.serviceConfig.ExecStart;
}
