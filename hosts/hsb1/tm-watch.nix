# OPS-226: page BEFORE a Time Machine dataset fills, and when a Mac stops
# backing up.
#
# 2026-09-22 "Das Backup-Volume ist voll" on mbp2607: the ZFS quota counted
# snapshots, Samba advertised the same size to Time Machine, nothing paged.
# tm-pool.nix now pairs refquota (TM's cap) with quota (hard cap incl.
# snapshots); this timer watches both caps, the pool, smbd and each user's
# sparsebundle freshness through the shared OPS-107 engine and hsb1's
# existing Telegram target (the tailnet-watch env file — no new secret).
{
  config,
  pkgs,
  lib,
  ...
}:
let
  fleetLib = import ../../modules/shared/fleet-alerts/lib.nix { inherit pkgs lib; };
  zfsPkg = config.boot.zfs.package;
  poller = fleetLib.mkPoller {
    name = "tm-watch";
    checks = ./tm-watch.py;
    substitutions = {
      NOTIFICATION_ENV = config.age.secrets.hsb1-tailnet-watch-env.path;
      # The same zfs the system runs, so the CLI and the kernel module agree.
      ZFS_BIN = "${zfsPkg}/bin/zfs";
      ZPOOL_BIN = "${zfsPkg}/bin/zpool";
      # The witness validates the LIVE caps against the declared ones.
      CAPS_JSON = builtins.toJSON (import ./tm-caps.nix);
    };
  };
in
{
  systemd.services.tm-watch = {
    description = "Page before the Time Machine pool fills or a Mac stops backing up (OPS-226)";
    after = [
      "network-online.target"
      "zfs.target"
      "agenix.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.python3}/bin/python3 ${poller}/checks.py";
      StateDirectory = "tm-watch";
      StateDirectoryMode = "0700";
      # 0 = clean, 1 = problems found; 2 = undeliverable must fail the unit so
      # it shows in systemctl --failed. Same contract as tailnet-watch.
      SuccessExitStatus = [
        0
        1
      ];
      TimeoutStartSec = "90";
      PrivateTmp = true;
      # `zfs get` / `zpool list` / `zfs destroy <autosnap>` talk to the kernel
      # through /dev/zfs — that one node is allowed, nothing else in /dev is.
      PrivateDevices = false;
      DevicePolicy = "closed";
      DeviceAllow = [ "/dev/zfs rw" ];
      ProtectHome = true;
      # strict keeps /srv/tm read-only for us; the sparsebundle check only stats.
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

  systemd.timers.tm-watch = {
    description = "Recurring Time Machine target witness (OPS-226)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # 10 min: a Mac writing flat out (~100 MB/s) adds ~60G per interval,
      # well inside the 150G prune trigger. Pages still need two runs.
      OnBootSec = "5m";
      OnUnitActiveSec = "10m";
      RandomizedDelaySec = "30s";
      Unit = "tm-watch.service";
    };
  };
}
