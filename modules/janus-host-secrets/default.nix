{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  cfg = config.inspr.janusHostSecrets;
  refPattern = prefix: "${prefix}_[a-z0-9_]{8,80}";
  validRef = prefix: value: builtins.match (refPattern prefix) value != null;
  configFile = pkgs.writeText "janus-host-executor-config.json" (
    builtins.toJSON {
      schema = "inspr.janus.host-executor-config.v1";
      schema_version = 1;
      host_ref = cfg.hostRef;
      scope_ref = cfg.scopeRef;
      owner_uid = 0;
      minimum_revocation_epoch = cfg.minimumRevocationEpoch;
      retired = cfg.retired;
      producer_keys = map (key: {
        key_id = key.keyId;
        public_key = key.publicKey;
      }) cfg.producerKeys;
      revoked_envelope_refs = cfg.revokedEnvelopeRefs;
      slots = map (slot: {
        service_ref = slot.serviceRef;
        slot_ref = slot.slotRef;
        secret_ref = slot.secretRef;
        declaration_fingerprint = slot.declarationFingerprint;
        minimum_generation = slot.minimumGeneration;
        rollback_window_seconds = slot.rollbackWindowSeconds;
      }) cfg.slots;
    }
  );
  agentConfigFile = pkgs.writeText "janus-managed-host-agent-config.json" (
    builtins.toJSON {
      schema = "inspr.janus.managed-host-agent-config.v1";
      schema_version = 1;
      host_ref = cfg.hostRef;
      pharos_origin = cfg.agent.pharosOrigin;
      janus_origin = cfg.agent.janusOrigin;
      token_file = cfg.agent.tokenFile;
      docker_executable = "${cfg.agent.dockerPackage}/bin/docker";
      compose_project = cfg.agent.composeProject;
      poll_interval_seconds = cfg.agent.pollIntervalSeconds;
      profiles = map (profile: {
        service_ref = profile.serviceRef;
        slot_ref = profile.slotRef;
        delivery_profile_ref = profile.deliveryProfileRef;
        reload_profile_ref = profile.reloadProfileRef;
        health_profile_ref = profile.healthProfileRef;
        compose_file = profile.composeFile;
        compose_service = profile.composeService;
        container_name = profile.containerName;
      }) cfg.agent.profiles;
    }
  );
in
{
  options.inspr.janusHostSecrets = {
    enable = lib.mkEnableOption "host-bound Janus ciphertext cache and private runtime restore";

    package = lib.mkOption {
      type = lib.types.package;
      default = inputs.janus.packages.${pkgs.stdenv.hostPlatform.system}.janus-engine;
      description = "Immutable Janus package containing janus-host-executor.";
    };

    hostRef = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Opaque enrolled host reference.";
    };

    scopeRef = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Exact opaque Janus scope reference.";
    };

    minimumRevocationEpoch = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Declarative floor rejecting envelopes from compromised or retired epochs.";
    };

    retired = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Fail closed and remove runtime plaintext for a retired host.";
    };

    producerKeys = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            keyId = lib.mkOption {
              type = lib.types.str;
              description = "Opaque Janus envelope signing-key reference.";
            };
            publicKey = lib.mkOption {
              type = lib.types.str;
              description = "Base64 Ed25519 public verification key.";
            };
          };
        }
      );
      default = [ ];
      description = "Bounded Janus producer verification-key registry.";
    };

    revokedEnvelopeRefs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Explicitly revoked opaque envelope references.";
    };

    slots = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            serviceRef = lib.mkOption {
              type = lib.types.str;
              description = "Opaque declared managed-service reference.";
            };
            slotRef = lib.mkOption {
              type = lib.types.str;
              description = "Opaque declared secret-slot reference.";
            };
            secretRef = lib.mkOption {
              type = lib.types.str;
              description = "Opaque Janus secret reference.";
            };
            declarationFingerprint = lib.mkOption {
              type = lib.types.str;
              description = "Exact declaration fingerprint accepted by this host.";
            };
            minimumGeneration = lib.mkOption {
              type = lib.types.ints.positive;
              default = 1;
              description = "Monotonic generation floor preventing downgrade.";
            };
            rollbackWindowSeconds = lib.mkOption {
              type = lib.types.ints.positive;
              default = 900;
              description = "Bounded previous-ciphertext rollback window.";
            };
          };
        }
      );
      default = [ ];
      description = "Closed host/service/slot allowlist; runtime paths are derived, not configurable.";
    };

    beforeUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "docker.service" ];
      description = "Exact service managers blocked until private runtime materialization succeeds.";
    };

    agent = {
      enable = lib.mkEnableOption "fixed managed-service install, reload, and health agent";

      pharosOrigin = lib.mkOption {
        type = lib.types.str;
        default = "https://pharos.barta.cm";
        description = "Exact Pharos HTTPS origin.";
      };

      janusOrigin = lib.mkOption {
        type = lib.types.str;
        default = "https://vault.barta.cm";
        description = "Exact Janus HTTPS origin.";
      };

      tokenFile = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Root-readable host-ref agent bearer-token file.";
      };

      dockerPackage = lib.mkOption {
        type = lib.types.package;
        default = pkgs.docker;
        description = "Pinned Docker CLI used for fixed Compose and inspect actions.";
      };

      composeProject = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Fixed Compose project containing every declared managed profile.";
      };

      pollIntervalSeconds = lib.mkOption {
        type = lib.types.ints.between 2 300;
        default = 5;
        description = "Bounded interval for value-free Pharos leases.";
      };

      profiles = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              serviceRef = lib.mkOption { type = lib.types.str; };
              slotRef = lib.mkOption { type = lib.types.str; };
              deliveryProfileRef = lib.mkOption { type = lib.types.str; };
              reloadProfileRef = lib.mkOption { type = lib.types.str; };
              healthProfileRef = lib.mkOption { type = lib.types.str; };
              composeFile = lib.mkOption { type = lib.types.str; };
              composeService = lib.mkOption { type = lib.types.str; };
              containerName = lib.mkOption { type = lib.types.str; };
            };
          }
        );
        default = [ ];
        description = "Closed value-free mapping from reviewed profile refs to fixed Compose targets.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = validRef "host" cfg.hostRef;
        message = "inspr.janusHostSecrets.hostRef must be an opaque host reference";
      }
      {
        assertion = builtins.match "scp_[0-9a-f]{40}" cfg.scopeRef != null;
        message = "inspr.janusHostSecrets.scopeRef must be an exact opaque scope reference";
      }
      {
        assertion =
          cfg.producerKeys != [ ]
          && lib.length cfg.producerKeys <= 8
          && lib.all (
            key: validRef "key" key.keyId && builtins.match "[A-Za-z0-9+/]{43}" key.publicKey != null
          ) cfg.producerKeys;
        message = "inspr.janusHostSecrets requires one to eight valid Ed25519 producer keys";
      }
      {
        assertion =
          cfg.slots != [ ]
          && lib.length cfg.slots <= 128
          && lib.all (
            slot:
            validRef "svc" slot.serviceRef
            && validRef "slot" slot.slotRef
            && validRef "sec" slot.secretRef
            && validRef "decl" slot.declarationFingerprint
            && slot.rollbackWindowSeconds >= 60
            && slot.rollbackWindowSeconds <= 86400
          ) cfg.slots;
        message = "inspr.janusHostSecrets requires a bounded valid declared slot allowlist";
      }
      {
        assertion = lib.all (validRef "env") cfg.revokedEnvelopeRefs;
        message = "inspr.janusHostSecrets.revokedEnvelopeRefs must contain only opaque envelope references";
      }
      {
        assertion =
          !cfg.agent.enable
          || (
            builtins.match "https://[^/?#]+" cfg.agent.pharosOrigin != null
            && builtins.match "https://[^/?#]+" cfg.agent.janusOrigin != null
            && lib.hasPrefix "/" cfg.agent.tokenFile
            && builtins.match "[a-z0-9_.-]{1,96}" cfg.agent.composeProject != null
            && cfg.agent.profiles != [ ]
            && lib.length cfg.agent.profiles <= 128
            && lib.all (
              profile:
              validRef "svc" profile.serviceRef
              && validRef "slot" profile.slotRef
              && validRef "delivery" profile.deliveryProfileRef
              && validRef "reload" profile.reloadProfileRef
              && validRef "health" profile.healthProfileRef
              && lib.hasPrefix "/" profile.composeFile
              && builtins.match "[a-z0-9_.-]{1,96}" profile.composeService != null
              && builtins.match "[a-z0-9_.-]{1,96}" profile.containerName != null
            ) cfg.agent.profiles
          );
        message = "inspr.janusHostSecrets.agent requires exact HTTPS origins, a private token file, and closed Compose profiles";
      }
      {
        assertion = !cfg.agent.enable || !(lib.elem "docker.service" cfg.beforeUnits);
        message = "inspr.janusHostSecrets.agent requires Docker to start independently; gate exact consumer units instead of docker.service";
      }
    ];

    systemd.services.janus-host-secret-restore = {
      description = "Restore host-bound Janus service secrets from ciphertext";
      wantedBy = [ "multi-user.target" ];
      requiredBy = cfg.beforeUnits;
      before = cfg.beforeUnits;
      after = [ "local-fs.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
        Group = "root";
        UMask = "0077";
        StateDirectory = "janus-host-executor";
        StateDirectoryMode = "0700";
        RuntimeDirectory = [
          "janus-host-executor"
          "janus-managed"
        ];
        RuntimeDirectoryMode = "0700";
        ExecStartPre = "${pkgs.coreutils}/bin/install -m 0400 -o root -g root ${configFile} /run/janus-host-executor/config.json";
        ExecStart = "${cfg.package}/bin/janus-host-executor restore";
        ReadOnlyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
        ReadWritePaths = [
          "/var/lib/janus-host-executor"
          "/run/janus-host-executor"
          "/run/janus-managed"
        ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = [ "AF_UNIX" ];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        CapabilityBoundingSet = "";
        SystemCallArchitectures = "native";
      };
    };

    systemd.services.janus-managed-host-agent = lib.mkIf cfg.agent.enable {
      description = "Install and verify declared Janus managed-service secrets";
      wantedBy = [ "multi-user.target" ];
      requires = [
        "docker.service"
        "janus-host-secret-restore.service"
      ];
      after = [
        "docker.service"
        "janus-host-secret-restore.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        User = "root";
        Group = "root";
        UMask = "0077";
        RuntimeDirectory = "janus-managed-agent";
        RuntimeDirectoryMode = "0700";
        ExecStartPre = "${pkgs.coreutils}/bin/install -m 0400 -o root -g root ${agentConfigFile} /run/janus-managed-agent/config.json";
        ExecStart = "${cfg.package}/bin/janus-managed-host-agent";
        Restart = "on-failure";
        RestartSec = "5s";
        ReadOnlyPaths = [
          "/etc/ssh/ssh_host_ed25519_key"
          cfg.agent.tokenFile
        ]
        ++ map (profile: profile.composeFile) cfg.agent.profiles;
        ReadWritePaths = [
          "/var/lib/janus-host-executor"
          "/run/janus-host-executor"
          "/run/janus-managed"
          "/run/janus-managed-agent"
          "/run/docker.sock"
        ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        CapabilityBoundingSet = "";
        SystemCallArchitectures = "native";
      };
    };
  };
}
