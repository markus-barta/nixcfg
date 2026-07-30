# csb1's half of the mutual poller watch — OPS-107.
#
# csb0 watches the three Home Assistant instances; csb1 watches HAUSV. Neither
# watched the other, so a stopped poller was indistinguishable from "all quiet".
# This unit closes the csb1 → csb0 direction; ops-alerts on csb0 closes the other.
#
# DELIBERATELY SEPARATE from hausv-alerts. That poller is mature, hardened and
# pinned by tests/T34-hausv-alerts.sh; bolting an unrelated fleet concern into it
# would mean editing working product monitoring for something orthogonal. This is
# a second, tiny unit with one job, and it reuses csb1's existing
# WATCHTOWER_NOTIFICATION_URL so no new secret is introduced.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  fleetLib = import ../../modules/shared/fleet-alerts/lib.nix { inherit pkgs lib; };

  # csb0's ops-alerts runs every 15 min; two missed runs before we call it stopped.
  peers = [
    {
      name = "csb0";
      address = "100.64.0.8";
      port = 9107;
      maxAgeSeconds = 35 * 60;
    }
  ];

  poller = fleetLib.mkPoller {
    name = "fleet-peer-watch";
    checks = ./peer-watch-checks.py;
    substitutions = {
      PEERS_JSON = builtins.toJSON peers;
      NOTIFICATION_ENV = config.age.secrets.csb1-watchtower-env.path;
    };
  };
in
{
  nixcfg.fleetAlerts.heartbeat = {
    enable = true;
    statePath = "/var/lib/hausv-alerts/state.json";
    tailnetAddress = "100.64.0.4";
  };

  systemd.services.fleet-peer-watch = {
    description = "Watch csb0's alert poller so its silence cannot go unnoticed (OPS-107)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.python3}/bin/python3 ${poller}/checks.py";
      StateDirectory = "fleet-peer-watch";
      StateDirectoryMode = "0700";
      # Matches hausv-alerts: 0 = clean, 1 = problems found; 2 = undeliverable,
      # which must fail the unit so it shows in systemctl --failed.
      SuccessExitStatus = [
        0
        1
      ];
      # No EnvironmentFile: the poller reads only the one key it needs out of the
      # operator-channel file, rather than inheriting the whole environment. Same
      # rule tests/T34-hausv-alerts.sh enforces for hausv-alerts.
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

  systemd.timers.fleet-peer-watch = {
    description = "Recurring peer-poller watch (OPS-107)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "12m";
      OnUnitActiveSec = "10m";
      RandomizedDelaySec = "45s";
      Unit = "fleet-peer-watch.service";
    };
  };
}
