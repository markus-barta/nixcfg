# NIX-498: project the published Aithema module from the actual csb1 host.
# Evaluation only: synthetic activation names a nonexistent outside-store path
# and never reads runtime configuration or builds/activates a NixOS system.
let
  flakeRef = builtins.getEnv "NIX498_FLAKE_REF";
  validFlakeRef = builtins.match "git\\+file://[^?]+\\?rev=[0-9a-f]{40}&shallow=1" flakeRef != null;
  flake =
    assert validFlakeRef;
    builtins.getFlake flakeRef;
  inherit (flake.inputs.nixpkgs) lib;
  host = flake.nixosConfigurations.csb1;
  # Exercise the published module's disabled contract independently of the
  # now-active production host and its host-owned restart triggers.
  disabledHost = lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      flake.inputs.inspr-modules.nixosModules.aithema-workspace
      {
        system.stateVersion = "25.11";
        services.inspr.aithemaWorkspace = {
          enable = false;
          package = flake.inputs.inspr-modules.packages.x86_64-linux.aithema-workspace;
        };
      }
    ];
  };
  cfg = disabledHost.config.services.inspr.aithemaWorkspace;
  serviceName = "aithema-workspace";
  syntheticConfig = "/run/nix498-fixture/aithema-workspace.json";

  extendHost =
    configFile:
    host.extendModules {
      modules = [
        (
          { lib, ... }:
          {
            services.inspr.aithemaWorkspace = {
              enable = lib.mkForce true;
              configFile = lib.mkForce configFile;
            };
          }
        )
      ];
    };

  enabled = extendHost syntheticConfig;
  enabledService = enabled.config.systemd.services.${serviceName};
  enabledServiceConfig = enabledService.serviceConfig;
  missingConfig = extendHost null;
  storeConfig = extendHost "${builtins.storeDir}/nix498-fixture/aithema-workspace.json";

  aithemaAssertionFailures =
    evaluated:
    map (item: item.message or "") (
      lib.filter (
        item: !item.assertion && lib.hasInfix "aithemaWorkspace" (item.message or "")
      ) evaluated.config.assertions
    );
in
{
  production = {
    enable = host.config.services.inspr.aithemaWorkspace.enable;
    configFile = host.config.services.inspr.aithemaWorkspace.configFile;
    hasService = builtins.hasAttr serviceName host.config.systemd.services;
  };
  disabled = {
    enable = cfg.enable;
    configFile = cfg.configFile;
    stateDirectory = cfg.stateDirectory;
    packageName = cfg.package.pname or cfg.package.name;
    packageVersion = cfg.package.version;
    packageSourceRevision = cfg.package.passthru.release.sourceRev;
    hasService = builtins.hasAttr serviceName disabledHost.config.systemd.services;
    hasUser = builtins.hasAttr cfg.user disabledHost.config.users.users;
    hasGroup = builtins.hasAttr cfg.group disabledHost.config.users.groups;
    hasStateDirectoryEffect =
      builtins.hasAttr serviceName disabledHost.config.systemd.services
      &&
        builtins.hasAttr "StateDirectory"
          disabledHost.config.systemd.services.${serviceName}.serviceConfig;
    hasCredentialEffect =
      builtins.hasAttr serviceName disabledHost.config.systemd.services
      &&
        builtins.hasAttr "LoadCredential"
          disabledHost.config.systemd.services.${serviceName}.serviceConfig;
  };

  enabled = {
    assertionFailures = aithemaAssertionFailures enabled;
    user = {
      isSystemUser = enabled.config.users.users.${cfg.user}.isSystemUser;
      group = enabled.config.users.users.${cfg.user}.group;
      home = enabled.config.users.users.${cfg.user}.home;
    };
    hasGroup = builtins.hasAttr cfg.group enabled.config.users.groups;
    service = {
      user = enabledServiceConfig.User;
      group = enabledServiceConfig.Group;
      dynamicUser = enabledServiceConfig.DynamicUser;
      stateDirectory = enabledServiceConfig.StateDirectory;
      stateDirectoryMode = enabledServiceConfig.StateDirectoryMode;
      workingDirectory = enabledServiceConfig.WorkingDirectory;
      readWritePaths = enabledServiceConfig.ReadWritePaths;
      loadCredential = enabledServiceConfig.LoadCredential;
      execStart = enabledServiceConfig.ExecStart;
      execStartPre = enabledServiceConfig.ExecStartPre;
      noNewPrivileges = enabledServiceConfig.NoNewPrivileges;
      protectHome = enabledServiceConfig.ProtectHome;
      protectSystem = enabledServiceConfig.ProtectSystem;
    };
  };

  rejected = {
    missingConfig = aithemaAssertionFailures missingConfig;
    storeConfig = aithemaAssertionFailures storeConfig;
  };
}
