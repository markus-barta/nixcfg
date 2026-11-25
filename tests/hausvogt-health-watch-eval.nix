# OPS-675: evaluate the host import and poller substitutions without builds.
let
  lib = import <nixpkgs/lib>;
  pkgs = {
    python3 = "/fixture/python3";
    writeText = _: text: text;
    runCommand =
      name: _: script:
      assert !(lib.hasInfix "@NOTIFICATION_ENV@" script);
      assert lib.hasInfix
        "NOTIFICATION_ENV = \"/run/credentials/hausvogt-health-watch.service/notification-env\""
        script;
      assert lib.hasInfix "HEALTH_URL = \"https://hausv.org/healthz\"" script;
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
  modulePath = ../hosts/csb1/hausvogt-health-watch.nix;
  imported = builtins.filter (path: path == modulePath) host.imports;
  evaluated = lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = imported ++ [
      {
        options = {
          systemd = lib.mkOption { type = lib.types.attrs; };
          age = lib.mkOption { type = lib.types.attrs; };
        };
        config.age.secrets.csb1-watchtower-env.path = "/fixture/notification-target";
      }
    ];
  };
in
assert builtins.length imported == 1;
{
  service = evaluated.config.systemd.services.hausvogt-health-watch;
  timer = evaluated.config.systemd.timers.hausvogt-health-watch;
}
