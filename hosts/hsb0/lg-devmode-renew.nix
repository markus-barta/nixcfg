# OPS-309: internet-only renewal; runtime credentials never enter the store.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  notifications = config.nixcfg.ibGatewaySession.alert;
  stateDirectory = "lg-devmode-renew";
  substitutions = {
    TOKEN_FILE = config.age.secrets.hsb0-lg-devmode-token.path;
    STATE_DIRECTORY = "/var/lib/${stateDirectory}";
    DESTINATIONS_FILE =
      if notifications.destinationFile == null then "" else toString notifications.destinationFile;
    NOTIFICATION_ENV_FILE =
      if notifications.notificationEnvFile == null then
        ""
      else
        toString notifications.notificationEnvFile;
    CURL_BIN = "${pkgs.curl}/bin/curl";
    DOCKER_BIN = "${config.virtualisation.docker.package}/bin/docker";
    # This binary belongs to the existing managed relay container, not the host.
    SENDMAIL_BIN = "/usr/sbin/sendmail";
  };
  keys = builtins.attrNames substitutions;
  safePath = path: lib.hasPrefix "/" path && !(builtins.elem ".." (lib.splitString "/" path));
  rendered = builtins.replaceStrings (map (key: ''"@${key}@"'') keys) (map (
    key: builtins.toJSON substitutions.${key}
  ) keys) (builtins.readFile ./lg-devmode-renew.py);
  renewalScript =
    assert lib.assertMsg (builtins.all (
      key:
      safePath substitutions.${key}
      || (
        builtins.elem key [
          "DESTINATIONS_FILE"
          "NOTIFICATION_ENV_FILE"
        ]
        && substitutions.${key} == ""
      )
    ) keys) "lg-devmode-renew: build-time paths must be absolute and contain no traversal";
    assert lib.assertMsg (builtins.all (
      key: !(lib.hasInfix "@${key}@" rendered)
    ) keys) "lg-devmode-renew: a build-time placeholder survived substitution";
    pkgs.writeText "lg-devmode-renew.py" rendered;
  runtime = pkgs.runCommand "lg-devmode-renew" { } ''
    mkdir -p "$out"
    cp ${renewalScript} "$out/renew.py"
    cp ${../../modules/shared/fleet-alerts/engine.py} "$out/engine.py"
    cp ${../../modules/ib-gateway-session/notification_delivery.py} "$out/notification_delivery.py"
  '';
  common = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    # Root reads fixed protected agenix paths with custody checks. Do not use
    # LoadCredential or ConditionPathExists: missing files must reach the
    # script, journal a credential-missing error, and exit distinctly (3).
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      UMask = "0077";
      # hsb0 is email-only: 4*20s renewal + (60+300+900)s backoff + 20s
      # check + 2*20s mail (one recovery + one failure) = 1400s; 400s margin.
      TimeoutStartSec = "30min";
      CapabilityBoundingSet = "";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectClock = true;
      ProtectHostname = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
      RestrictSUIDSGID = true;
      LockPersonality = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = "@system-service";
      LimitCORE = 0;
    };
  };
in
{
  age.secrets.hsb0-lg-devmode-token = {
    file = ../../secrets/hsb0-lg-devmode-token.age;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  systemd.services.lg-devmode-renew = common // {
    description = "Renew LG beamer webOS Developer Mode session (OPS-309)";
    serviceConfig = common.serviceConfig // {
      ExecStart = "${pkgs.python3}/bin/python3 ${runtime}/renew.py --renew";
      StateDirectory = stateDirectory;
      StateDirectoryMode = "0700";
    };
  };

  # Explicit operator check; shares the real transport and sandbox, has no timer
  # or state directory, and does not read the LG token or call the renewal API.
  systemd.services.lg-devmode-notify-test = common // {
    description = "Send one TEST LG Developer Mode alert (OPS-309)";
    serviceConfig = common.serviceConfig // {
      ExecStart = "${pkgs.python3}/bin/python3 ${runtime}/renew.py --test-notify";
      TimeoutStartSec = "1min";
    };
  };

  systemd.timers.lg-devmode-renew = {
    description = "Daily LG Developer Mode session renewal";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "1h";
      Persistent = true;
      Unit = "lg-devmode-renew.service";
    };
  };
}
