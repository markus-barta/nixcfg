# OPS-223: page when the IR → Sony TV path on hsb1 is broken.
#
# 2026-09-21: the FLIRC failed USB enumeration after a reboot (bridge deaf for
# ~4 h) and, once replugged, the TV's own Sony API answered 404 to every IRCC
# until the TV was power-cycled. Nothing paged either time. This timer reads what
# the bridge cannot say for itself (unit gone, FLIRC node gone) plus the TV's API
# health, through the shared OPS-107 engine and hsb1's existing Telegram target
# (the tailnet-watch env file — no new secret).
{
  config,
  pkgs,
  lib,
  ...
}:
let
  fleetLib = import ../../modules/shared/fleet-alerts/lib.nix { inherit pkgs lib; };
  # Read the bridge's own unit environment so the two can never drift.
  bridgeEnv = config.systemd.services.ir-bridge.environment;
  poller = fleetLib.mkPoller {
    name = "ir-bridge-watch";
    checks = ./ir-bridge-watch.py;
    substitutions = {
      NOTIFICATION_ENV = config.age.secrets.hsb1-tailnet-watch-env.path;
      FLIRC_DEVICE = bridgeEnv.FLIRC_DEVICE;
      SONY_SYSTEM_URL = "http://${bridgeEnv.SONY_TV_IP}/sony/system";
    };
  };
in
{
  systemd.services.ir-bridge-watch = {
    description = "Page when the FLIRC → Sony TV path is broken (OPS-223)";
    after = [
      "network-online.target"
      "agenix.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.python3}/bin/python3 ${poller}/checks.py";
      StateDirectory = "ir-bridge-watch";
      StateDirectoryMode = "0700";
      # 0 = clean, 1 = problems found; 2 = undeliverable must fail the unit so
      # it shows in systemctl --failed. Same contract as tailnet-watch.
      SuccessExitStatus = [
        0
        1
      ];
      TimeoutStartSec = "60";
      PrivateTmp = true;
      # The FLIRC check is an existence test on the bridge's /dev/input/by-id
      # path, so /dev must be the real one — but nothing here opens a device.
      PrivateDevices = false;
      DevicePolicy = "closed";
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
    };
  };

  systemd.timers.ir-bridge-watch = {
    description = "Recurring IR bridge witness (OPS-223)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # A cold boot's USB enumeration took ~3 min on the failing port; the
      # engine's two-run confirmation absorbs the rest.
      OnBootSec = "5m";
      OnUnitActiveSec = "5m";
      RandomizedDelaySec = "20s";
      Unit = "ir-bridge-watch.service";
    };
  };
}
