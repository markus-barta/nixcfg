# OPS-675: alert-only health witness, independent of the legacy HAUSV monitor.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  fleetLib = import ../../modules/shared/fleet-alerts/lib.nix { inherit pkgs lib; };
  poller = fleetLib.mkPoller {
    name = "hausvogt-health-watch";
    checks = ./hausvogt-health-watch-checks.py;
    substitutions = {
      NOTIFICATION_ENV = "/run/credentials/hausvogt-health-watch.service/notification-env";
    };
  };
in
{
  systemd.services.hausvogt-health-watch = {
    description = "Watch the new Hausvogt public health contract (OPS-675)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.python3}/bin/python3 ${poller}/checks.py";
      StateDirectory = "hausvogt-health-watch";
      StateDirectoryMode = "0700";
      SuccessExitStatus = [
        0
        1
      ];
      DynamicUser = true;
      # Reuse the operator target without inheriting its complete environment.
      LoadCredential = [ "notification-env:${config.age.secrets.csb1-watchtower-env.path}" ];
      CapabilityBoundingSet = "";
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      NoNewPrivileges = true;
      LockPersonality = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
      SystemCallArchitectures = "native";
      TimeoutStartSec = "90";
    };
  };

  systemd.timers.hausvogt-health-watch = {
    description = "Recurring Hausvogt public health witness (OPS-675)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "5m";
      RandomizedDelaySec = "30s";
      Unit = "hausvogt-health-watch.service";
    };
  };
}
