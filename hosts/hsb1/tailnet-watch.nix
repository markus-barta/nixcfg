# hsb1's tailnet witness — OPS-185 (second witness, home failure domain).
#
# csb1's witness (OPS-181) shares headscale's netcup failure domain: it catches
# the poisoned-map aftermath of 2026-08-21 but cannot page while that whole site
# is dark. hsb1 sits at home on a different provider, so this copy can. Same
# shared check file, same OPS-107 engine and hardening; its own agenix env
# (hsb1-tailnet-watch-env: WATCHTOWER_NOTIFICATION_URL, same Telegram target).
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
    checks = ../../modules/shared/fleet-alerts/tailnet-watch-checks.py;
    substitutions = {
      HOSTNAME = "hsb1";
      # The same binary tailscaled runs from, so CLI and daemon never disagree.
      TAILSCALE_BIN = "${config.services.tailscale.package}/bin/tailscale";
      NOTIFICATION_ENV = config.age.secrets.hsb1-tailnet-watch-env.path;
    };
  };
in
{
  age.secrets.hsb1-tailnet-watch-env = {
    file = ../../secrets/hsb1-tailnet-watch-env.age;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  systemd.services.tailnet-watch = {
    description = "Page when hsb1's tailnet view is persistently broken (OPS-185)";
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
    description = "Recurring tailnet witness (OPS-185)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10m";
      OnUnitActiveSec = "10m";
      RandomizedDelaySec = "45s";
      Unit = "tailnet-watch.service";
    };
  };
}
