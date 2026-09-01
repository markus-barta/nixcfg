{ nixpkgsPath, runnerModulePath }:

let
  nixpkgsRoot = /. + nixpkgsPath;
  enabledRunnerModule = import (/. + runnerModulePath);
  evaluated = import (nixpkgsRoot + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [
      enabledRunnerModule
      (
        { lib, ... }:
        {
          options.age.secrets = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule {
                options.path = lib.mkOption {
                  type = lib.types.str;
                };
              }
            );
            default = { };
          };

          config = {
            _module.args.startRunnerSecretExists = true;
            age.secrets.csb1-start-github-runner.path = "/run/agenix/csb1-start-github-runner";
            users.users.mba = {
              isNormalUser = true;
              group = "users";
            };
            users.groups.users = { };
            users.groups.docker = { };
          };
        }
      )
    ];
  };
  config = evaluated.config;
in
{
  runner = {
    inherit (config.services.github-runners.csb1-start)
      enable
      extraLabels
      group
      name
      tokenFile
      url
      user
      ;
  };
  service = {
    inherit (config.systemd.services.github-runner-csb1-start.serviceConfig)
      InaccessiblePaths
      NoNewPrivileges
      User
      ;
  };
}
