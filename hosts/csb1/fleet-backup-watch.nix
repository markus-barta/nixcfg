# Fleet backup watch — OPS-485.
#
# Every host's restic job writes a status file its Pharos beacon reports as-is;
# pharosd pages `failed` at once, but nothing ages the file, so a job that stops
# running stays "healthy" forever. hsb8/hsb9 cannot send their own failure mail
# (no relay, OPS-137). This unit reads pharosd's persisted store on this host and
# pages when a backup has not succeeded within its schedule's limit, or reports a
# state pharosd does not page. Same OPS-107 engine, hardening and Telegram target
# as fleet-drift; no new credential.
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
    name = "fleet-backup-watch";
    checks = ./fleet-backup-watch-checks.py;
    substitutions = {
      STORE_PATH = storePath;
      NOTIFICATION_ENV = config.age.secrets.csb1-watchtower-env.path;
    };
  };
in
{
  systemd.services.fleet-backup-watch = {
    description = "Page when a fleet backup has not succeeded within its schedule (OPS-485)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.python3}/bin/python3 ${poller}/checks.py";
      StateDirectory = "fleet-backup-watch";
      StateDirectoryMode = "0700";
      SuccessExitStatus = [
        0
        1
      ];
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectHome = true;
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
      TimeoutStartSec = "90";
    };
  };

  systemd.timers.fleet-backup-watch = {
    description = "Recurring fleet backup watch (OPS-485)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "17m";
      OnUnitActiveSec = "1h";
      RandomizedDelaySec = "2m";
      Unit = "fleet-backup-watch.service";
    };
  };
}
