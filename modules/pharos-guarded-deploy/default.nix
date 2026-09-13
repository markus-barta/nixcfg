{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.inspr.pharosGuardedDeploy;
  host = config.networking.hostName;
  hostUpper = lib.toUpper host;
  applySecretName = "PHAROS_APPLY_${hostUpper}";
  rollbackSecretName = "PHAROS_ROLLBACK_${hostUpper}";
  updateSecretName = "PHAROS_UPDATE_${hostUpper}";
  defaultJanusPackage = inputs.janus.packages.${pkgs.stdenv.hostPlatform.system}.janus-engine;
  janusPackage = cfg.janusPackage;
  configuredScope = cfg.exactScope != null;
  configuredRoles = cfg.roleAuthorization != null;
  configuredOperationReferences = cfg.operationReferences != null;
  scopeValue = field: if configuredScope then cfg.exactScope.${field} else "";
  roleValue = field: if configuredRoles then cfg.roleAuthorization.${field} else "";
  replace =
    file: from: to:
    builtins.replaceStrings from to (builtins.readFile file);

  applyRunner = pkgs.writeShellApplication {
    name = "pharos-guarded-apply";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      docker
      findutils
      gawk
      git
      gnugrep
      jq
      nix
      systemd
      util-linux
      zfs
    ];
    text =
      replace ./apply.sh
        [
          "@HOST@"
          "@ZFS_POOL@"
          "@REPO_URL@"
          "@BEACON_CONTAINER@"
          "@HOSTDASH_CONTAINER@"
        ]
        [
          host
          cfg.zfsPool
          cfg.repoUrl
          cfg.beaconContainer
          cfg.hostdashContainer
        ];
  };

  rollbackRunner = pkgs.writeShellApplication {
    name = "pharos-guarded-rollback";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      docker
      findutils
      gawk
      gnugrep
      jq
      systemd
      util-linux
      zfs
    ];
    text =
      replace ./rollback.sh
        [
          "@HOST@"
          "@ZFS_POOL@"
          "@BEACON_CONTAINER@"
          "@HOSTDASH_CONTAINER@"
        ]
        [
          host
          cfg.zfsPool
          cfg.beaconContainer
          cfg.hostdashContainer
        ];
  };

  systemUpdateRunner = pkgs.writeShellApplication {
    name = "pharos-guarded-system-update";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      docker
      findutils
      gawk
      git
      gnugrep
      jq
      nix
      systemd
      util-linux
      zfs
    ];
    text =
      replace ./system-update.sh
        [
          "@HOST@"
          "@ZFS_POOL@"
          "@REPO_URL@"
          "@BEACON_CONTAINER@"
          "@HOSTDASH_CONTAINER@"
          "@STATE_DIR@"
          "@REBOOT_TIMEOUT_SECONDS@"
        ]
        [
          host
          cfg.zfsPool
          cfg.repoUrl
          cfg.beaconContainer
          cfg.hostdashContainer
          "/var/lib/pharos-guarded-deploy"
          (toString cfg.rebootTimeoutSeconds)
        ];
  };

  bootstrap = pkgs.writeShellApplication {
    name = "pharos-guarded-deploy-bootstrap";
    runtimeInputs = with pkgs; [
      age
      coreutils
      openssl
    ];
    text =
      replace ./bootstrap.sh
        [
          "@HOST@"
          "@APPLY_SECRET_NAME@"
          "@ROLLBACK_SECRET_NAME@"
          "@UPDATE_SECRET_NAME@"
        ]
        [
          host
          applySecretName
          rollbackSecretName
          updateSecretName
        ];
  };

  review = pkgs.writeShellApplication {
    name = "pharos-guarded-deploy";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      gnused
      jq
    ];
    text =
      replace ./review.sh
        [
          "@HOST@"
          "@JANUSD_USE@"
          "@JANUSD_ADMIN@"
          "@SCOPE_ORGANIZATION@"
          "@SCOPE_PROJECT@"
          "@SCOPE_REPOSITORY@"
          "@SCOPE_ENVIRONMENT@"
          "@ROLE_BINDINGS_ROOT@"
          "@ROLE_AUDIT_FILE@"
          "@ROLE_POLICY_FILE@"
          "@USE_PRINCIPAL@"
          "@ADMIN_PRINCIPAL@"
          "@OPERATION_REFERENCE_HELPER@"
          "@ACTION_REQUEST_FILE@"
          "@STATE_DIR@"
          "@PROFILE_MANIFEST@"
          "@SECRET_MANIFEST@"
          "@METADATA@"
          "@APPLY_SECRET_REF@"
          "@ROLLBACK_SECRET_REF@"
          "@UPDATE_SECRET_REF@"
          "@APPLY_SECRET_NAME@"
          "@ROLLBACK_SECRET_NAME@"
          "@UPDATE_SECRET_NAME@"
        ]
        [
          host
          "${janusPackage}/bin/janusd-use"
          "${janusPackage}/bin/janusd-admin"
          (scopeValue "organization")
          (scopeValue "project")
          (scopeValue "repository")
          (scopeValue "environment")
          (roleValue "bindingsRoot")
          (roleValue "auditFile")
          (
            if configuredRoles && cfg.roleAuthorization.policyFile != null then
              cfg.roleAuthorization.policyFile
            else
              ""
          )
          (roleValue "usePrincipal")
          (roleValue "adminPrincipal")
          "${operationReference}/bin/pharos-guarded-operation-reference"
          "/var/lib/pharos-guarded-deploy/active-agent-request.json"
          "/var/lib/pharos-guarded-deploy"
          "/etc/janus/pharos-deploy/managed-commands.toml"
          "/etc/janus/pharos-deploy/secretspec.toml"
          "/etc/janus/pharos-deploy/metadata.toml"
          cfg.applySecretRef
          cfg.rollbackSecretRef
          cfg.updateSecretRef
          applySecretName
          rollbackSecretName
          updateSecretName
        ];
  };

  operationReference = pkgs.writeShellApplication {
    name = "pharos-guarded-operation-reference";
    runtimeInputs = with pkgs; [
      coreutils
      jq
      python3
    ];
    text =
      replace ./operation-reference.sh
        [
          "@OPERATION_REFERENCE_ROOT@"
          "@OPERATION_SCOPE_REF@"
          "@OPERATION_DOMAIN_SERVICE@"
          "@OPERATION_AUDIENCE_FINGERPRINT@"
          "@OPERATION_RELEASE_DIGEST@"
        ]
        [
          (if configuredOperationReferences then cfg.operationReferences.root else "")
          (if configuredOperationReferences then cfg.operationReferences.scopeRef else "")
          (if configuredOperationReferences then cfg.operationReferences.domainService else "")
          (if configuredOperationReferences then cfg.operationReferences.audienceFingerprint else "")
          (if configuredOperationReferences then cfg.operationReferences.releaseDigest else "")
        ];
  };

  roleBootstrap = pkgs.writeShellApplication {
    name = "pharos-guarded-role-bootstrap";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      jq
    ];
    text =
      replace ./bootstrap-roles.sh
        [
          "@JANUSD_ADMIN@"
          "@SCOPE_ORGANIZATION@"
          "@SCOPE_PROJECT@"
          "@SCOPE_REPOSITORY@"
          "@SCOPE_ENVIRONMENT@"
          "@ROLE_BINDINGS_ROOT@"
          "@ROLE_AUDIT_FILE@"
          "@ROLE_POLICY_FILE@"
          "@BOOTSTRAP_PRINCIPAL@"
          "@SECURITY_ADMIN_PRINCIPAL@"
          "@USE_PRINCIPAL@"
          "@ADMIN_PRINCIPAL@"
          "@SOURCE_REFERENCE@"
          "@BINDING_TTL_SECONDS@"
          "@OPERATION_REFERENCE_HELPER@"
        ]
        [
          "${janusPackage}/bin/janusd-admin"
          (scopeValue "organization")
          (scopeValue "project")
          (scopeValue "repository")
          (scopeValue "environment")
          (roleValue "bindingsRoot")
          (roleValue "auditFile")
          (
            if configuredRoles && cfg.roleAuthorization.policyFile != null then
              cfg.roleAuthorization.policyFile
            else
              ""
          )
          (roleValue "bootstrapPrincipal")
          (roleValue "securityAdminPrincipal")
          (roleValue "usePrincipal")
          (roleValue "adminPrincipal")
          (roleValue "sourceReference")
          (if configuredRoles then toString cfg.roleAuthorization.bindingTtlSeconds else "")
          "${operationReference}/bin/pharos-guarded-operation-reference"
        ];
  };

  actionAgent = pkgs.writeShellApplication {
    name = "pharos-host-action-agent";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      findutils
      jq
      util-linux
    ];
    text =
      replace ./action-agent.sh
        [
          "@HOST@"
          "@PHAROS_URL@"
          "@GUARDED_DEPLOY@"
          "@STATE_DIR@"
          "@BOOT_ID_FILE@"
          "@REBOOT_TIMEOUT_SECONDS@"
        ]
        [
          host
          cfg.pharosUrl
          "${review}/bin/pharos-guarded-deploy"
          "/var/lib/pharos-guarded-deploy"
          "/proc/sys/kernel/random/boot_id"
          (toString cfg.rebootTimeoutSeconds)
        ];
  };
in
{
  options.inspr.pharosGuardedDeploy = {
    enable = lib.mkEnableOption "target-local Janus-guarded Pharos deployments";
    janusPackage = lib.mkOption {
      type = lib.types.package;
      default = defaultJanusPackage;
      defaultText = lib.literalExpression "inputs.janus.packages.${pkgs.stdenv.hostPlatform.system}.janus-engine";
      description = ''
        Janus engine package used by the guarded wrapper. Enforced role
        bootstrapping requires Janus 0.1.37 or newer; the fleet default stays
        on the repository pin until each host declares and provisions roles.
      '';
    };
    applySecretRef = lib.mkOption {
      type = lib.types.str;
      description = "Deterministic Janus secret reference for the host apply capability.";
    };
    rollbackSecretRef = lib.mkOption {
      type = lib.types.str;
      description = "Deterministic Janus secret reference for the host rollback capability.";
    };
    updateSecretRef = lib.mkOption {
      type = lib.types.str;
      description = "Deterministic Janus secret reference for the guarded system-update capability.";
    };
    zfsPool = lib.mkOption {
      type = lib.types.str;
      default = "zroot";
    };
    repoUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/markus-barta/nixcfg.git";
    };
    beaconContainer = lib.mkOption {
      type = lib.types.str;
      default = "pharos-beacon";
    };
    hostdashContainer = lib.mkOption {
      type = lib.types.str;
      default = "${host}-home";
    };
    pharosUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://100.64.0.4:8088";
      description = "Fixed tailnet URL used by the outbound target-local action agent.";
    };
    tokenEnvironmentFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/agenix/pharos-beacon-${host}-env";
      description = "Root-readable environment file containing the existing per-host PHAROS_TOKEN.";
    };
    exactScope = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            organization = lib.mkOption { type = lib.types.str; };
            project = lib.mkOption { type = lib.types.str; };
            repository = lib.mkOption { type = lib.types.str; };
            environment = lib.mkOption { type = lib.types.str; };
          };
        }
      );
      default = null;
      description = ''
        Exact Janus scope for the guarded use and administration planes. An
        unset scope is retained for fleet compatibility but Janus refuses the
        guarded action at runtime.
      '';
    };
    roleAuthorization = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            bindingsRoot = lib.mkOption { type = lib.types.str; };
            auditFile = lib.mkOption { type = lib.types.str; };
            policyFile = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };
            bootstrapPrincipal = lib.mkOption { type = lib.types.str; };
            securityAdminPrincipal = lib.mkOption { type = lib.types.str; };
            usePrincipal = lib.mkOption { type = lib.types.str; };
            adminPrincipal = lib.mkOption { type = lib.types.str; };
            sourceReference = lib.mkOption { type = lib.types.str; };
            bindingTtlSeconds = lib.mkOption {
              type = lib.types.ints.between 3600 31622400;
            };
          };
        }
      );
      default = null;
      description = ''
        Enforced Janus role state and distinct principals for managed use and
        approval administration. Configuring this installs the manual
        pharos-guarded-role-bootstrap procedure; it never provisions a binding
        automatically. An unset contract is retained for fleet compatibility
        but Janus refuses the guarded action at runtime.
      '';
    };
    operationReferences = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            root = lib.mkOption { type = lib.types.str; };
            scopeRef = lib.mkOption { type = lib.types.str; };
            domainService = lib.mkOption { type = lib.types.str; };
            audienceFingerprint = lib.mkOption { type = lib.types.str; };
            releaseDigest = lib.mkOption { type = lib.types.str; };
          };
        }
      );
      default = null;
      description = ''
        Protected controller-prepared, single-use authoritative operation
        references for recorded role grants and guarded actions. The controller
        installs raw references at incoming/role-bootstrap/SOURCE/STEP.json or
        incoming/actions/LEASE/PHASE/ACTION/{approval,execute}.json beneath
        root. Bootstrap lineage is
        inspr397-guarded-role-bootstrap-v1|source=SOURCE|step=STEP. Action
        lineage is inspr397-guarded-action-v1|id=LEASE|host=HOST|ticket=TICKET|
        phase=PHASE|action=ACTION. Every component is thus bound to the signed
        opaque operation reference, and each nonce moves to consumed before
        use. When unset, recorded Janus commands continue to fail closed.
      '';
    };
    actionPollSeconds = lib.mkOption {
      type = lib.types.ints.between 10 300;
      default = 15;
      description = "Polling cadence for target-local guarded action leases.";
    };
    rebootTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.between 120 3600;
      default = 600;
      description = "Maximum time to await the scheduled reboot before resume becomes action-required.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.match "sec_[0-9a-f]{20}" cfg.applySecretRef != null;
        message = "inspr.pharosGuardedDeploy.applySecretRef must be an opaque Janus reference";
      }
      {
        assertion = builtins.match "sec_[0-9a-f]{20}" cfg.rollbackSecretRef != null;
        message = "inspr.pharosGuardedDeploy.rollbackSecretRef must be an opaque Janus reference";
      }
      {
        assertion = cfg.applySecretRef != cfg.rollbackSecretRef;
        message = "Pharos apply and rollback must use separate Janus capabilities";
      }
      {
        assertion = builtins.match "sec_[0-9a-f]{20}" cfg.updateSecretRef != null;
        message = "inspr.pharosGuardedDeploy.updateSecretRef must be an opaque Janus reference";
      }
      {
        assertion =
          !builtins.elem cfg.updateSecretRef [
            cfg.applySecretRef
            cfg.rollbackSecretRef
          ];
        message = "Pharos system update must use a separate Janus capability";
      }
      {
        assertion = builtins.match "http://[0-9.]+:[0-9]+" cfg.pharosUrl != null;
        message = "inspr.pharosGuardedDeploy.pharosUrl must be a fixed HTTP address";
      }
      {
        assertion = configuredScope == configuredRoles;
        message = "inspr.pharosGuardedDeploy exactScope and roleAuthorization must be configured together";
      }
      {
        assertion =
          !configuredScope
          || lib.all (value: builtins.match "[A-Za-z0-9][A-Za-z0-9_.-]{0,127}" value != null) [
            cfg.exactScope.organization
            cfg.exactScope.project
            cfg.exactScope.repository
            cfg.exactScope.environment
          ];
        message = "inspr.pharosGuardedDeploy exactScope components must be bounded identifiers";
      }
      {
        assertion =
          !configuredRoles
          || lib.all (value: builtins.match "/[A-Za-z0-9._/-]+" value != null) (
            [
              cfg.roleAuthorization.bindingsRoot
              cfg.roleAuthorization.auditFile
            ]
            ++ lib.optional (cfg.roleAuthorization.policyFile != null) cfg.roleAuthorization.policyFile
          );
        message = "inspr.pharosGuardedDeploy role authorization paths must be absolute and shell-safe";
      }
      {
        assertion =
          !configuredRoles
          || (
            builtins.length (
              lib.unique [
                cfg.roleAuthorization.bootstrapPrincipal
                cfg.roleAuthorization.securityAdminPrincipal
                cfg.roleAuthorization.usePrincipal
                cfg.roleAuthorization.adminPrincipal
              ]
            ) == 4
            && lib.all (value: builtins.match "[A-Za-z0-9][A-Za-z0-9@._:-]{0,127}" value != null) [
              cfg.roleAuthorization.bootstrapPrincipal
              cfg.roleAuthorization.securityAdminPrincipal
              cfg.roleAuthorization.usePrincipal
              cfg.roleAuthorization.adminPrincipal
            ]
          );
        message = "inspr.pharosGuardedDeploy role principals must be distinct bounded identifiers";
      }
      {
        assertion =
          !configuredRoles
          || (
            builtins.match "[A-Z][A-Z0-9]+-[0-9]+" cfg.roleAuthorization.sourceReference != null
            && builtins.stringLength cfg.roleAuthorization.sourceReference <= 32
          );
        message = "inspr.pharosGuardedDeploy role sourceReference must be a PPM issue key";
      }
      {
        assertion = !configuredOperationReferences || configuredRoles;
        message = "inspr.pharosGuardedDeploy operationReferences requires configured role authorization";
      }
      {
        assertion =
          !configuredOperationReferences
          || (
            builtins.match "/var/lib/pharos-guarded-deploy/[A-Za-z0-9._/-]+" cfg.operationReferences.root
            != null
            && !(lib.hasInfix ".." cfg.operationReferences.root)
            && !(lib.hasInfix "//" cfg.operationReferences.root)
            && !(lib.hasSuffix "/" cfg.operationReferences.root)
            && builtins.match "scp_[0-9a-f]{40}" cfg.operationReferences.scopeRef != null
            && builtins.match "[A-Za-z0-9][A-Za-z0-9._-]{0,127}" cfg.operationReferences.domainService != null
            && builtins.match "sha256:[0-9a-f]{64}" cfg.operationReferences.audienceFingerprint != null
            && builtins.match "sha256:[0-9a-f]{64}" cfg.operationReferences.releaseDigest != null
          );
        message = "inspr.pharosGuardedDeploy operation reference context must be exact and bounded";
      }
    ];

    environment.systemPackages = [
      janusPackage
      review
      actionAgent
    ]
    ++ lib.optional configuredRoles roleBootstrap;

    environment.etc."janus/pharos-deploy/secretspec.toml".text = ''
      [project]
      name = "pharos-deploy"
      revision = "1.0"

      [profiles.${host}]
      ${applySecretName} = { description = "Guarded Pharos apply on ${host}", required = true }
      ${rollbackSecretName} = { description = "Guarded Pharos rollback on ${host}", required = true }
      ${updateSecretName} = { description = "Guarded Pharos system update on ${host}", required = true }
    '';

    environment.etc."janus/pharos-deploy/metadata.toml".text = ''
      [defaults]
      owner = "platform"
      classification = "high_value"
      lifecycle = "active"
    '';

    environment.etc."janus/pharos-deploy/managed-commands.toml".text = ''
      [[profiles]]
      id = "profile.${applySecretName}"
      secret_ref = "${cfg.applySecretRef}"
      executor = "janus-run@${host}"
      destination = "pharos-deploy-${host}"
      env = "PHAROS_DEPLOY_CAPABILITY"
      binary = "${applyRunner}/bin/pharos-guarded-apply"
      allowed_args = []
      timeout_seconds = 3600
      max_stdout_bytes = 16384
      max_stderr_bytes = 16384

      [profiles.consumer]
      consumer_ref = "consumer.pharos_deploy_${host}"
      kind = "managed_command"
      owner = "platform"
      environment = "production"
      reload = "none"
      validation = ["pharos-beacon-applied"]
      supports_dual_value = false
      blast_radius = "single host ${host}"

      [[profiles]]
      id = "profile.${rollbackSecretName}"
      secret_ref = "${cfg.rollbackSecretRef}"
      executor = "janus-run@${host}"
      destination = "pharos-rollback-${host}"
      env = "PHAROS_DEPLOY_CAPABILITY"
      binary = "${rollbackRunner}/bin/pharos-guarded-rollback"
      allowed_args = []
      timeout_seconds = 900
      max_stdout_bytes = 16384
      max_stderr_bytes = 16384

      [profiles.consumer]
      consumer_ref = "consumer.pharos_rollback_${host}"
      kind = "managed_command"
      owner = "platform"
      environment = "production"
      reload = "none"
      validation = ["pharos-beacon-rollback"]
      supports_dual_value = false
      blast_radius = "single host ${host}"

      [[profiles]]
      id = "profile.${updateSecretName}"
      secret_ref = "${cfg.updateSecretRef}"
      executor = "janus-run@${host}"
      destination = "pharos-system-update-${host}"
      env = "PHAROS_DEPLOY_CAPABILITY"
      binary = "${systemUpdateRunner}/bin/pharos-guarded-system-update"
      allowed_args = []
      timeout_seconds = 7200
      max_stdout_bytes = 16384
      max_stderr_bytes = 16384

      [profiles.consumer]
      consumer_ref = "consumer.pharos_system_update_${host}"
      kind = "managed_command"
      owner = "platform"
      environment = "production"
      reload = "none"
      validation = ["backup", "all-host-eval", "target-build", "beacon-kernel"]
      supports_dual_value = false
      blast_radius = "single host ${host}"
    '';

    systemd.tmpfiles.rules = [
      "d /var/lib/janus 0700 root root -"
      "d /var/lib/janus/secrets 0700 root root -"
      "d /var/lib/janus/secrets/pharos-deploy 0700 root root -"
      "d /var/lib/janus/secrets/pharos-deploy/${host} 0700 root root -"
      "d /var/lib/pharos-guarded-deploy 0700 root root -"
      "d /var/lib/pharos-guarded-deploy/actions 0700 root root -"
      "d /var/lib/pharos-guarded-deploy/agent-runs 0700 root root -"
    ]
    ++ lib.optionals configuredRoles [
      "d ${cfg.roleAuthorization.bindingsRoot} 0700 root root -"
      "f ${cfg.roleAuthorization.auditFile} 0600 root root -"
    ]
    ++ lib.optionals configuredOperationReferences [
      "d ${cfg.operationReferences.root} 0700 root root -"
      "d ${cfg.operationReferences.root}/incoming 0700 root root -"
      "d ${cfg.operationReferences.root}/consumed 0700 root root -"
    ];

    systemd.services.pharos-guarded-deploy-bootstrap = {
      description = "Bootstrap target-local Janus capabilities for guarded Pharos deployment";
      wantedBy = [ "multi-user.target" ];
      after = [
        "local-fs.target"
        "sshd.service"
      ];
      requires = [ "sshd.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${bootstrap}/bin/pharos-guarded-deploy-bootstrap";
        RemainAfterExit = true;
        UMask = "0077";
      };
    };

    systemd.services.pharos-host-action-agent = {
      description = "Claim and execute target-local Janus-guarded Pharos actions";
      after = [
        "docker.service"
        "network-online.target"
        "pharos-guarded-deploy-bootstrap.service"
        "tailscaled.service"
      ];
      wants = [
        "docker.service"
        "network-online.target"
        "tailscaled.service"
      ];
      requires = [ "pharos-guarded-deploy-bootstrap.service" ];
      unitConfig.ConditionPathExists = cfg.tokenEnvironmentFile;
      environment =
        lib.optionalAttrs configuredScope {
          JANUS_SCOPE_ORGANIZATION = cfg.exactScope.organization;
          JANUS_SCOPE_PROJECT = cfg.exactScope.project;
          JANUS_SCOPE_REPOSITORY = cfg.exactScope.repository;
          JANUS_SCOPE_ENVIRONMENT = cfg.exactScope.environment;
        }
        // lib.optionalAttrs configuredRoles {
          JANUS_ROLE_AUTHORIZATION_MODE = "enforced";
          JANUS_ROLE_BINDINGS_ROOT = cfg.roleAuthorization.bindingsRoot;
          JANUS_ROLE_AUDIT_FILE = cfg.roleAuthorization.auditFile;
        }
        // lib.optionalAttrs (configuredRoles && cfg.roleAuthorization.policyFile != null) {
          JANUS_ROLE_POLICY_FILE = cfg.roleAuthorization.policyFile;
        };
      restartIfChanged = false;
      stopIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${actionAgent}/bin/pharos-host-action-agent";
        EnvironmentFile = cfg.tokenEnvironmentFile;
        UMask = "0077";
        PrivateTmp = true;
        TimeoutStartSec = "7500";
      };
    };

    systemd.timers.pharos-host-action-agent = {
      description = "Poll Pharos for guarded host actions";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "20s";
        OnUnitActiveSec = "${toString cfg.actionPollSeconds}s";
        RandomizedDelaySec = "3s";
        Persistent = true;
        Unit = "pharos-host-action-agent.service";
      };
    };
  };
}
