# A service-owned runtime directory replaces the host-global /dev/shm files.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.stasysmo;
  directory = (import ./config.nix).daemon.linuxDir;
  daemon = import ./package.nix { inherit pkgs; };
  reader = import ./reader-package.nix {
    inherit lib pkgs cfg;
    snapshot = "${directory}/snapshot";
  };
in
{
  options.services.stasysmo = import ./options.nix {
    inherit lib;
    platform = "linux";
  };
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      daemon
      reader
    ];
    systemd.services.stasysmo-daemon = {
      description = "StaSysMo - prompt metrics sampler";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = 5;
        ExecStart = "${daemon}/bin/stasysmo-daemon ${toString cfg.daemon.interval} ${directory}";
        DynamicUser = true;
        RuntimeDirectory = "stasysmo";
        RuntimeDirectoryMode = "0755";
        ReadWritePaths = [ directory ];
        UMask = "0022";
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
      };
    };
  };
}
