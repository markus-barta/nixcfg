# OPS-309: internet-only renewal; runtime credentials never enter the store.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  notifications = config.nixcfg.ibGatewaySession.alert;
  runtime = pkgs.runCommand "lg-devmode-renew" { } ''
    mkdir -p "$out"
    cp ${./lg-devmode-renew.py} "$out/renew.py"
    cp ${../../modules/shared/fleet-alerts/engine.py} "$out/engine.py"
    cp ${../../modules/ib-gateway-session/notification_delivery.py} "$out/notification_delivery.py"
  '';
in
{
  age.secrets.hsb0-lg-devmode-token = {
    file = ../../secrets/hsb0-lg-devmode-token.age;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  systemd.services.lg-devmode-renew = {
    description = "Renew LG beamer webOS Developer Mode session (OPS-309)";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    environment = {
      LG_DEVMODE_CURL = "${pkgs.curl}/bin/curl";
      LG_DEVMODE_DOCKER = "${config.virtualisation.docker.package}/bin/docker";
    };
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = "${pkgs.python3}/bin/python3 ${runtime}/renew.py --renew";
      LoadCredential = [
        "token:${config.age.secrets.hsb0-lg-devmode-token.path}"
      ]
      ++ lib.optional (
        notifications.destinationFile != null
      ) "destinations.json:${toString notifications.destinationFile}"
      ++ lib.optional (
        notifications.notificationEnvFile != null
      ) "notification-env:${toString notifications.notificationEnvFile}";
      StateDirectory = "lg-devmode-renew";
      StateDirectoryMode = "0700";
      UMask = "0077";
      # 21 minutes of backoff, four bounded requests, a check and notifications.
      TimeoutStartSec = "25min";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      LimitCORE = 0;
    };
  };

  systemd.timers.lg-devmode-renew = {
    description = "Daily LG Developer Mode session renewal";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "1h";
      Persistent = true;
      Unit = "lg-devmode-renew.service";
    };
  };
}
