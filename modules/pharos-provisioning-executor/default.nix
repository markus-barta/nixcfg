{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.inspr.pharosProvisioningExecutor;
  owner = config.networking.hostName;
  stateDir = "/var/lib/pharos-provisioning-executor";
  runtimeDir = "/run/pharos-provisioning-executor";
  contractDir = "${cfg.repoPath}/hosts/csb1/docker/janus/pharos-production";
  replace =
    file: from: to:
    builtins.replaceStrings from to (builtins.readFile file);
  bootstrapTemplate = pkgs.runCommand "pharos-managed-bootstrap-template" { } ''
    mkdir -p "$out"
    substitute ${./bootstrap/flake.nix} "$out/flake.nix" \
      --replace-fail '@NIXPKGS@' '${inputs.nixpkgs}' \
      --replace-fail '@DISKO@' '${inputs.disko}'
    substitute ${./bootstrap/configuration.nix} "$out/configuration.nix" \
      --replace-fail '@BEACON_IMAGE@' '${cfg.beaconImage}'
    cp ${./bootstrap/disk-config.nix} "$out/disk-config.nix"
  '';
  janusCredential = pkgs.writeShellApplication {
    name = "pharos-managed-janus-credential";
    runtimeInputs = with pkgs; [
      bash
      age
      coreutils
      docker
      findutils
      gawk
      git
      gnugrep
      gnused
      jq
      openssl
      python3
      util-linux
    ];
    text =
      replace ./janus-credential.sh
        [
          "@OWNER@"
          "@REPO_PATH@"
          "@CONTRACT_DIR@"
          "@SCOPE_ORGANIZATION@"
          "@SCOPE_PROJECT@"
          "@SCOPE_REPOSITORY@"
          "@SCOPE_ENVIRONMENT@"
        ]
        [
          owner
          cfg.repoPath
          contractDir
          cfg.scope.organization
          cfg.scope.project
          cfg.scope.repository
          cfg.scope.environment
        ];
  };
  executor = pkgs.writeShellApplication {
    name = "pharos-provisioning-executor";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.curl
      pkgs.findutils
      pkgs.gawk
      pkgs.git
      pkgs.gnugrep
      pkgs.gnused
      pkgs.jq
      pkgs.openssh
      pkgs.python3
      pkgs.util-linux
      inputs.nixos-anywhere.packages.${pkgs.stdenv.hostPlatform.system}.default
      janusCredential
    ];
    text =
      replace ./executor.sh
        [
          "@OWNER@"
          "@PHAROS_AGENT_URL@"
          "@PHAROS_PUBLIC_URL@"
          "@STATE_DIR@"
          "@RUNTIME_DIR@"
          "@REPO_PATH@"
          "@IDENTITY_FILE@"
          "@SSH_KEY_REF@"
          "@BOOTSTRAP_TEMPLATE@"
          "@PUBLIC_KEY_HELPER@"
          "@JANUS_HELPER@"
        ]
        [
          owner
          cfg.pharosAgentUrl
          cfg.pharosPublicUrl
          stateDir
          runtimeDir
          cfg.repoPath
          cfg.identityFile
          cfg.sshKeyRef
          "${bootstrapTemplate}"
          "${./public-key.sh}"
          "${janusCredential}/bin/pharos-managed-janus-credential"
        ];
  };
in
{
  options.inspr.pharosProvisioningExecutor = {
    enable = lib.mkEnableOption "trusted Pharos managed NixOS provisioning executor";
    pharosAgentUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://100.64.0.4:8088";
      description = "Fixed tailnet URL used for authenticated provisioning claims.";
    };
    pharosPublicUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://pharos.barta.cm";
      description = "HTTPS URL used by the newly installed beacon.";
    };
    repoPath = lib.mkOption {
      type = lib.types.str;
      default = "/home/mba/Code/nixcfg";
      description = "Reviewed nixcfg checkout containing the Janus production contract.";
    };
    tokenEnvironmentFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/agenix/pharos-beacon-${owner}-env";
      description = "Root-readable environment file containing the owner's existing PHAROS_TOKEN.";
    };
    identityFile = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Root-readable dedicated SSH private key used only by this executor.";
    };
    sshKeyRef = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Exact Hetzner SSH public-key name paired with identityFile.";
    };
    beaconImage = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/markus-barta/pharos/pharosd:0.1.58@sha256:8eb6bdecddce5951c696e35afacdf5acd70acde0ff08e947e413dbc2e4474666";
      description = "Immutable Pharos image used for the managed host beacon.";
    };
    pollSeconds = lib.mkOption {
      type = lib.types.ints.between 15 300;
      default = 30;
      description = "Polling cadence for managed provisioning work.";
    };
    scope = {
      organization = lib.mkOption {
        type = lib.types.str;
        default = "inspr";
      };
      project = lib.mkOption {
        type = lib.types.str;
        default = "pharos";
      };
      repository = lib.mkOption {
        type = lib.types.str;
        default = "nixcfg";
      };
      environment = lib.mkOption {
        type = lib.types.str;
        default = "production";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.match "[a-z0-9][a-z0-9-]{0,62}" owner != null;
        message = "The Pharos provisioning executor requires a valid owner host name";
      }
      {
        assertion = builtins.match "http://[0-9.]+:[0-9]+" cfg.pharosAgentUrl != null;
        message = "inspr.pharosProvisioningExecutor.pharosAgentUrl must be a fixed HTTP tailnet address";
      }
      {
        assertion = builtins.match "https://[^[:space:]]+" cfg.pharosPublicUrl != null;
        message = "inspr.pharosProvisioningExecutor.pharosPublicUrl must use HTTPS";
      }
      {
        assertion = builtins.match "/[A-Za-z0-9._/-]+" cfg.repoPath != null;
        message = "inspr.pharosProvisioningExecutor.repoPath must be an absolute path";
      }
      {
        assertion = builtins.match "/[A-Za-z0-9._/-]+" cfg.identityFile != null;
        message = "inspr.pharosProvisioningExecutor.identityFile must be an absolute path";
      }
      {
        assertion = builtins.match "[A-Za-z0-9][A-Za-z0-9_.@+-]{0,127}" cfg.sshKeyRef != null;
        message = "inspr.pharosProvisioningExecutor.sshKeyRef must be the exact provider key name";
      }
      {
        assertion =
          builtins.match "ghcr.io/[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}" cfg.beaconImage
          != null;
        message = "inspr.pharosProvisioningExecutor.beaconImage must be an immutable GHCR image";
      }
      {
        assertion = lib.all (value: builtins.match "[A-Za-z0-9][A-Za-z0-9_.-]{0,127}" value != null) [
          cfg.scope.organization
          cfg.scope.project
          cfg.scope.repository
          cfg.scope.environment
        ];
        message = "Pharos provisioning Janus scope components are invalid";
      }
    ];

    environment.systemPackages = [ executor ];

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0700 root root -"
      "d ${runtimeDir} 0700 root root -"
    ];

    systemd.services.pharos-provisioning-executor = {
      description = "Execute reviewed Pharos NixOS provisioning leases";
      after = [
        "docker.service"
        "network-online.target"
        "tailscaled.service"
      ];
      wants = [
        "docker.service"
        "network-online.target"
        "tailscaled.service"
      ];
      unitConfig = {
        ConditionPathExists = [
          cfg.tokenEnvironmentFile
          cfg.identityFile
        ];
      };
      restartIfChanged = false;
      stopIfChanged = false;
      environment.HOME = stateDir;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${executor}/bin/pharos-provisioning-executor";
        EnvironmentFile = cfg.tokenEnvironmentFile;
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = "read-only";
        ProtectSystem = "strict";
        ReadWritePaths = [
          stateDir
          runtimeDir
          "/run/lock"
          cfg.repoPath
        ];
        TimeoutStartSec = "7200";
      };
    };

    systemd.timers.pharos-provisioning-executor = {
      description = "Poll Pharos for reviewed managed provisioning work";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "45s";
        OnUnitActiveSec = "${toString cfg.pollSeconds}s";
        RandomizedDelaySec = "5s";
        Persistent = true;
        Unit = "pharos-provisioning-executor.service";
      };
    };
  };
}
