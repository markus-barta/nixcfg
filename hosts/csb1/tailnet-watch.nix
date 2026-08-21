# csb1's tailnet witness — OPS-181.
#
# 2026-08-21: headscale on csb0 served an EMPTY DERP map after a failed scheduled
# refresh; every node lost its relay and nothing paged for ~57 minutes. The
# existing pollers watch services, not the mesh underneath them. This unit reads
# csb1's own `tailscale status --json` / `tailscale debug derp-map` and pages
# Telegram when that view is persistently broken.
#
# DELIBERATELY SEPARATE from hausv-alerts and peer-watch (mature, test-pinned).
# Same engine, same hardening, same reused WATCHTOWER_NOTIFICATION_URL — no new
# secret. Scope is this host's view only; see tailnet-watch-checks.py.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  fleetLib = import ../../modules/shared/fleet-alerts/lib.nix { inherit pkgs lib; };

  poller = fleetLib.mkPoller {
    name = "tailnet-watch";
    checks = ./tailnet-watch-checks.py;
    substitutions = {
      # The same binary tailscaled runs from, so CLI and daemon never disagree.
      TAILSCALE_BIN = "${config.services.tailscale.package}/bin/tailscale";
      NOTIFICATION_ENV = config.age.secrets.csb1-watchtower-env.path;
    };
  };
in
{
  systemd.services.tailnet-watch = {
    description = "Page when csb1's tailnet view is persistently broken (OPS-181)";
    after = [
      "network-online.target"
      "tailscaled.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.python3}/bin/python3 ${poller}/checks.py";
      StateDirectory = "tailnet-watch";
      StateDirectoryMode = "0700";
      # 0 = clean, 1 = problems found; 2 = undeliverable, which must fail the
      # unit so it shows in systemctl --failed. Same contract as peer-watch.
      SuccessExitStatus = [
        0
        1
      ];
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      # The tailscale CLI talks to tailscaled over this unix socket.
      ReadWritePaths = [ "/run/tailscale" ];
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

  systemd.timers.tailnet-watch = {
    description = "Recurring tailnet witness (OPS-181)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10m";
      OnUnitActiveSec = "10m";
      RandomizedDelaySec = "45s";
      Unit = "tailnet-watch.service";
    };
  };
}
