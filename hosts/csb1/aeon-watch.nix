# OPS-307: witness both real API traffic and the public DB authentication path.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  watchIntervalSeconds = 30;
  fleetLib = import ../../modules/shared/fleet-alerts/lib.nix { inherit pkgs lib; };
  poller = fleetLib.mkPoller {
    name = "aeon-watch";
    checks = ./aeon-watch-checks.py;
    substitutions = {
      DOCKER_BIN = "${pkgs.docker}/bin/docker";
      PROBE_TENANT = config.aeonWatch.probeTenant;
      WATCH_INTERVAL_SECONDS = toString watchIntervalSeconds;
    };
  };
in
{
  options.aeonWatch.probeTenant = lib.mkOption {
    type = lib.types.strMatching "[0-9a-f]{32}";
    default = "0000a0e7000040008000000000000307";
    description = "Nonexistent probe tenant UUID without dashes; use an empty tenant, never a production tenant.";
  };

  config = {
    systemd.services.aeon-watch = {
      description = "Watch aeon API 5xx rate and public authentication health (OPS-307)";
      after = [
        "network-online.target"
        "docker.service"
      ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.python3}/bin/python3 ${poller}/checks.py";
        StateDirectory = "aeon-watch";
        StateDirectoryMode = "0700";
        SuccessExitStatus = [
          0
          1
        ];
        DynamicUser = true;
        # Existing host-side Docker access pattern. The Traefik socket proxy is
        # on an internal container network with no host listener. Docker group
        # access still grants daemon control; the poller reads ps, logs and only
        # StartedAt and RestartCount via container inspect -f (never the environment).
        SupplementaryGroups = [ "docker" ];
        # Copy the existing target for this user, without granting root group
        # access or inheriting the entire notification environment.
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

    systemd.timers.aeon-watch = {
      description = "Recurring aeon API witness (OPS-307)";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "120s";
        OnUnitActiveSec = "${toString watchIntervalSeconds}s";
        AccuracySec = "1s";
        Unit = "aeon-watch.service";
      };
    };
  };
}
