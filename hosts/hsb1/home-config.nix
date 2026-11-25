# OPS-158: observation only. The local Git history is runtime data, never a remote mirror.
{ pkgs, lib, ... }:
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
  systemd.tmpfiles.rules = [ "d ${repo} 0750 root home-config - -" ];
  environment.etc = {
    "hsb1-home-config/snapshot.py".source = ./home-config-snapshot.py;
    "hsb1-home-config/gitleaks.toml".source = ./home-config-gitleaks.toml;
  };
  environment.systemPackages = [ command ];

  systemd.services.hsb1-home-config = {
    description = "Secret-gated local Node-RED and Home Assistant configuration history (OPS-158)";
    unitConfig.RequiresMountsFor = [
      repo
      nodered
      homeassistant
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "home-config";
      ExecStart = "${command}/bin/hsb1-home-config";
      UMask = "0027";
      RuntimeDirectory = "hsb1-home-config";
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = true;
      TimeoutStartSec = "5min";
      Nice = 19;
      IOSchedulingClass = "idle";
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ReadOnlyPaths = [
        nodered
        homeassistant
      ];
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
      CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      LockPersonality = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
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
        "${homeassistant}/.storage"
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
}
