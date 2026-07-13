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
  janusPackage = inputs.janus.packages.${pkgs.system}.janus-engine;
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
          "@JANUSD@"
          "@APPLY_SECRET_REF@"
          "@ROLLBACK_SECRET_REF@"
          "@UPDATE_SECRET_REF@"
          "@APPLY_SECRET_NAME@"
          "@ROLLBACK_SECRET_NAME@"
          "@UPDATE_SECRET_NAME@"
        ]
        [
          host
          "${janusPackage}/bin/janusd"
          cfg.applySecretRef
          cfg.rollbackSecretRef
          cfg.updateSecretRef
          applySecretName
          rollbackSecretName
          updateSecretName
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
    ];

    environment.systemPackages = [
      janusPackage
      review
      actionAgent
    ];

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
