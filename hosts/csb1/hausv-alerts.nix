# HAUSV-406 / NIX-332: external, transition-based operations monitoring.
{
  config,
  pkgs,
  ...
}:

let
  poller = "${pkgs.python3}/bin/python3 ${./hausv-alerts-poll.py}";
  commonServiceConfig = {
    Type = "oneshot";
    User = "root";
    Group = "root";
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectHome = true;
    ProtectSystem = "strict";
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
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
in
{
  assertions = [
    {
      assertion = config.age.secrets.csb1-watchtower-env.path == "/run/agenix/csb1-watchtower-env";
      message = "HAUSV alerts require the reviewed csb1 operator-channel path";
    }
  ];

  systemd.services.hausv-alerts = {
    description = "Check HAUSV snapshot freshness, health and critical application signals";
    after = [
      "docker.service"
      "network-online.target"
    ];
    wants = [
      "docker.service"
      "network-online.target"
    ];
    path = [
      pkgs.docker
      pkgs.systemd
    ];
    serviceConfig = commonServiceConfig // {
      ExecStart = poller;
      StateDirectory = "hausv-alerts";
      StateDirectoryMode = "0700";
      SuccessExitStatus = [
        0
        1
      ];
    };
  };

  systemd.timers.hausv-alerts = {
    description = "Recurring HAUSV operations alarm check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10m";
      OnUnitActiveSec = "5m";
      RandomizedDelaySec = "30s";
      Unit = "hausv-alerts.service";
    };
  };

  # Manual live proof only. It sends two clearly labelled test messages and
  # never changes application, snapshot, backup, or monitor state.
  systemd.services.hausv-alerts-delivery-probe = {
    description = "Send a manual HAUSV operator-channel alarm and recovery probe";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = commonServiceConfig // {
      ExecStart = "${poller} --delivery-probe";
    };
  };
}
