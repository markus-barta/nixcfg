# Fleet drift watch — OPS-187.
#
# csb0 ran two weeks behind main and hsb8/hsb9 ~100 commits behind on 2026-08-21,
# silently. pharosd (on this host) already holds every beacon's nixcfg comparison;
# this unit reads its persisted store and pages when a host is persistently behind.
# Same OPS-107 engine, hardening and Telegram target as peer-watch / tailnet-watch.
# Needs OPS-186 (beacons must see the current evidence) to be truthful.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  fleetLib = import ../../modules/shared/fleet-alerts/lib.nix { inherit pkgs lib; };
  # pharosd's store: compose project csb1 → volume csb1_pharos_data, mounted at /data.
  storePath = "/var/lib/docker/volumes/csb1_pharos_data/_data/pharos.json";
  poller = fleetLib.mkPoller {
    name = "fleet-drift";
    checks = ./fleet-drift-checks.py;
    substitutions = {
      STORE_PATH = storePath;
      NIXCFG_CHECKOUT = "/home/mba/Code/nixcfg";
      GIT_BIN = "${pkgs.git}/bin/git";
      NOTIFICATION_ENV = config.age.secrets.csb1-watchtower-env.path;
    };
  };
in
{
  systemd.services.fleet-drift = {
    description = "Page when a fleet host runs a nixcfg generation persistently behind main (OPS-187)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.python3}/bin/python3 ${poller}/checks.py";
      StateDirectory = "fleet-drift";
      StateDirectoryMode = "0700";
      SuccessExitStatus = [
        0
        1
      ];
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectHome = "read-only"; # commit ages come from mba's nixcfg checkout (read-only)
      ProtectSystem = "strict";
      ReadOnlyPaths = [ storePath ];
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
      TimeoutStartSec = "120";
    };
  };

  systemd.timers.fleet-drift = {
    description = "Recurring fleet drift watch (OPS-187)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "15m";
      OnUnitActiveSec = "1h";
      RandomizedDelaySec = "2m";
      Unit = "fleet-drift.service";
    };
  };
}
