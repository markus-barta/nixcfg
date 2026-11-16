# Independent watch for the garage Telegram bot (Node-RED on csb0) — OPS-604.
# Sending can still work after its long-polling receiver silently stops (OPS-603).
{
  config,
  pkgs,
  lib,
  ...
}:
let
  fleetLib = import ../../modules/shared/fleet-alerts/lib.nix { inherit pkgs lib; };
  poller = fleetLib.mkPoller {
    name = "garage-bot-watch";
    checks = ./garage-bot-watch-checks.py;
    substitutions = {
      NOTIFICATION_ENV = config.age.secrets.csb1-watchtower-env.path;
    };
  };
in
{
  systemd.services.garage-bot-watch = {
    description = "Page when the garage Telegram bot stops polling on csb0 (OPS-604)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.python3}/bin/python3 ${poller}/checks.py";
      StateDirectory = "garage-bot-watch";
      StateDirectoryMode = "0700";
      SuccessExitStatus = [
        0
        1
      ];
      # Read only WATCHTOWER_NOTIFICATION_URL via the engine, never EnvironmentFile.
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
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

  systemd.timers.garage-bot-watch = {
    description = "Recurring garage Telegram bot polling watch (OPS-604)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5m";
      OnUnitActiveSec = "5m";
      AccuracySec = "1s";
      Unit = "garage-bot-watch.service";
    };
  };
}
