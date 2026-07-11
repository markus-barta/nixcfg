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
        ]
        [
          host
          applySecretName
          rollbackSecretName
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
          "@APPLY_SECRET_NAME@"
          "@ROLLBACK_SECRET_NAME@"
        ]
        [
          host
          "${janusPackage}/bin/janusd"
          cfg.applySecretRef
          cfg.rollbackSecretRef
          applySecretName
          rollbackSecretName
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
    ];

    environment.systemPackages = [
      janusPackage
      review
    ];

    environment.etc."janus/pharos-deploy/secretspec.toml".text = ''
      [project]
      name = "pharos-deploy"
      revision = "1.0"

      [profiles.${host}]
      ${applySecretName} = { description = "Guarded Pharos apply on ${host}", required = true }
      ${rollbackSecretName} = { description = "Guarded Pharos rollback on ${host}", required = true }
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
    '';

    systemd.tmpfiles.rules = [
      "d /var/lib/janus 0700 root root -"
      "d /var/lib/janus/secrets 0700 root root -"
      "d /var/lib/janus/secrets/pharos-deploy 0700 root root -"
      "d /var/lib/janus/secrets/pharos-deploy/${host} 0700 root root -"
      "d /var/lib/pharos-guarded-deploy 0700 root root -"
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
  };
}
