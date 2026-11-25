# OPS-158: observation only. The local Git history is runtime data, never a remote mirror.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  repo = "/home/mba/home-config";
  nodered = "/home/mba/docker/mounts/nodered/data";
  homeassistant = "/home/mba/docker/mounts/homeassistant";
  runtime = "/run/hsb1-home-config";
  command = pkgs.writeShellScriptBin "hsb1-home-config" ''
    export PATH=${
      lib.makeBinPath [
        pkgs.git
        pkgs.gitleaks
      ]
    }
    exec ${pkgs.python3}/bin/python3 /etc/hsb1-home-config/snapshot.py "$@"
  '';
  fleetLib = import ../../modules/shared/fleet-alerts/lib.nix { inherit pkgs lib; };
  witness = fleetLib.mkPoller {
    name = "home-config-watch";
    checks = ./home-config-watch.py;
    substitutions.NOTIFICATION_ENV = config.age.secrets.hsb1-tailnet-watch-env.path;
  };
  historySandbox = {
    Type = "oneshot";
    User = "root";
    Group = "home-config";
    UMask = "0027";
    RuntimeDirectory = "hsb1-home-config";
    RuntimeDirectoryMode = "0700";
    RuntimeDirectoryPreserve = true;
    Nice = 19;
    IOSchedulingClass = "idle";
    ProtectSystem = "strict";
    ProtectHome = "read-only";
    ReadWritePaths = [
      repo
      runtime
    ];
    InaccessiblePaths = [
      "-/run/agenix"
      "-/run/secrets"
      "-/root"
    ];
    PrivateNetwork = true;
    IPAddressDeny = "any";
    RestrictAddressFamilies = [ "AF_UNIX" ];
    PrivateTmp = true;
    PrivateDevices = true;
    NoNewPrivileges = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    LockPersonality = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
  };
in
{
  users.groups.home-config.members = [ "mba" ];
  programs.git = {
    enable = true;
    # mba can inspect this root-owned, group-readable repository without Git's
    # dubious-ownership refusal. Trust exactly this path, never a wildcard.
    config.safe.directory = [ repo ];
  };
  # Covered already: restic's /home:/backup/home:ro bind and /backup/home input.
  systemd.tmpfiles.rules = [ "d ${repo} 2750 root home-config - -" ];
  environment.etc = {
    "hsb1-home-config/snapshot.py".source = ./home-config-snapshot.py;
    "hsb1-home-config/gitleaks.toml".source = ./home-config-gitleaks.toml;
  };
  environment.systemPackages = [ command ];

  systemd.services.hsb1-home-config = {
    description = "Secret-gated local Node-RED and Home Assistant configuration history (OPS-158)";
    restartIfChanged = false;
    after = [ "systemd-tmpfiles-setup.service" ];
    unitConfig.RequiresMountsFor = [
      repo
      nodered
      homeassistant
    ];
    serviceConfig = historySandbox // {
      ExecStart = "${command}/bin/hsb1-home-config";
      # The worker enforces an eight-minute total budget (debounce <=120 s,
      # two scanner calls <=75 s each, bounded Git calls), with stop margin.
      TimeoutStartSec = "10min";
      ReadOnlyPaths = [
        nodered
        homeassistant
      ];
      CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
    };
  };

  systemd.paths.hsb1-home-config = {
    description = "Observe home automation configuration edits (OPS-158)";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      Unit = "hsb1-home-config.service";
      # Parent directories catch atomic replacement; the service waits for 20 s
      # of quiet in the allowlisted file metadata before it reads anything.
      PathChanged = [
        nodered
        "${nodered}/flows.json"
        "${nodered}/settings.js"
        "${nodered}/package.json"
        homeassistant
        "${homeassistant}/configuration.yaml"
        "${homeassistant}/automations.yaml"
        "${homeassistant}/scripts.yaml"
        "${homeassistant}/scenes.yaml"
        "${homeassistant}/customize.yaml"
        "${homeassistant}/themes"
        "${homeassistant}/blueprints"
        "${homeassistant}/packages"
        "${homeassistant}/.storage/core.area_registry"
        "${homeassistant}/.storage/core.floor_registry"
        "${homeassistant}/.storage/core.device_registry"
        "${homeassistant}/.storage/core.entity_registry"
        "${homeassistant}/.storage/core.label_registry"
        "${homeassistant}/.storage/lovelace"
        "${homeassistant}/.storage/lovelace_resources"
        "${homeassistant}/.storage/lovelace_dashboards"
      ];
    };
  };

  systemd.timers.hsb1-home-config = {
    description = "Catch nested/dashboard changes and missed home-config events (OPS-158)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitInactiveSec = "15min";
      AccuracySec = "30s";
      Unit = "hsb1-home-config.service";
    };
  };

  systemd.services.hsb1-home-config-gc = {
    description = "Bounded periodic maintenance of local configuration history (OPS-158)";
    restartIfChanged = false;
    unitConfig.RequiresMountsFor = [ repo ];
    serviceConfig = historySandbox // {
      ExecStart = "${command}/bin/hsb1-home-config --gc";
      TimeoutStartSec = "30min";
      CapabilityBoundingSet = [ ];
      InaccessiblePaths = historySandbox.InaccessiblePaths ++ [
        nodered
        homeassistant
      ];
    };
  };
  systemd.timers.hsb1-home-config-gc = {
    description = "Weekly local configuration history maintenance (OPS-158)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      RandomizedDelaySec = "1h";
      Persistent = true;
      Unit = "hsb1-home-config-gc.service";
    };
  };

  # Independent OPS-107 witness: even a killed or never-started snapshotter
  # cannot keep its own freshness marker healthy. Reuse hsb1's alert target.
  systemd.services.home-config-watch = {
    description = "Page when local configuration snapshots stop succeeding (OPS-158)";
    after = [
      "network-online.target"
      "agenix.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.python3}/bin/python3 ${witness}/checks.py";
      StateDirectory = "home-config-watch";
      StateDirectoryMode = "0700";
      SuccessExitStatus = [
        0
        1
      ];
      TimeoutStartSec = "60";
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      PrivateTmp = true;
      PrivateDevices = true;
      NoNewPrivileges = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
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
  systemd.timers.home-config-watch = {
    description = "Independent local configuration history freshness witness (OPS-158)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "10min";
      RandomizedDelaySec = "30s";
      Unit = "home-config-watch.service";
    };
  };
}
