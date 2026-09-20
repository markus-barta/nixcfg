# OPS-196: credentials stay on the consumer; only aggregate health is recorded.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  fleetLib = import ../../modules/shared/fleet-alerts/lib.nix { inherit pkgs lib; };
  poller = fleetLib.mkPoller {
    name = "mailbridge-watch";
    checks = ./mailbridge-watch.py;
    substitutions = {
      CONFIG = config.age.secrets.hsb1-turbogmailify-config.path;
      NOTIFICATION_ENV = config.age.secrets.hsb1-tailnet-watch-env.path;
      DOCKER = "${pkgs.docker}/bin/docker";
      CA_BUNDLE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      # Set once the replacement grant is obtained AFTER confirmed Production.
      # This is value-free evidence, never inferred from an access-token expiry.
      GRANT_ISSUED_AT = "";
    };
  };
in
{
  systemd.services.mailbridge-watch = {
    description = "Observe mail authorization and retained-mail queues (OPS-196)";
    after = [
      "network-online.target"
      "docker.service"
      "agenix.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.python3}/bin/python3 ${poller}/checks.py";
      StateDirectory = "mailbridge-watch";
      StateDirectoryMode = "0700";
      SuccessExitStatus = [
        0
        1
      ];
      TimeoutStartSec = "180";
      UMask = "0077";
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
    };
  };
  systemd.timers.mailbridge-watch = {
    description = "Check residue mail every five minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3m";
      OnUnitActiveSec = "5m";
      RandomizedDelaySec = "15s";
      Unit = "mailbridge-watch.service";
    };
  };
}
