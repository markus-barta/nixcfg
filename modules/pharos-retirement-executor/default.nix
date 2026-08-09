{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.inspr.pharosRetirementExecutor;
  owner = config.networking.hostName;
  stateDir = "/var/lib/pharos-retirement-executor";
  retireHelper = "${cfg.repoPath}/hosts/csb1/docker/janus/pharos-production/retire-host.sh";
  replace =
    file: from: to:
    builtins.replaceStrings from to (builtins.readFile file);
  executor = pkgs.writeShellApplication {
    name = "pharos-retirement-executor";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      curl
      docker
      findutils
      gawk
      git
      gnugrep
      gnused
      jq
      util-linux
    ];
    text =
      replace ./executor.sh
        [
          "@OWNER@"
          "@PHAROS_URL@"
          "@STATE_DIR@"
          "@REPO_PATH@"
          "@RETIRE_HELPER@"
        ]
        [
          owner
          cfg.pharosUrl
          stateDir
          cfg.repoPath
          retireHelper
        ];
  };
in
{
  options.inspr.pharosRetirementExecutor = {
    enable = lib.mkEnableOption "trusted Pharos host-retirement executor";
    pharosUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://100.64.0.4:8088";
      description = "Fixed tailnet URL used by the outbound retirement executor.";
    };
    repoPath = lib.mkOption {
      type = lib.types.str;
      default = "/home/mba/Code/nixcfg";
      description = "Reviewed nixcfg checkout containing the Janus retirement helper.";
    };
    tokenEnvironmentFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/agenix/pharos-beacon-${owner}-env";
      description = "Root-readable environment file containing the owner's existing PHAROS_TOKEN.";
    };
    janusEngineImage = lib.mkOption {
      type = lib.types.str;
      example = "ghcr.io/inspr-at/janus/janus-engine:rust-engine-v0.1.20@sha256:e1daef…";
      description = ''
        Pinned Janus engine image passed to the retirement helper as
        JANUS_ENGINE_IMAGE.

        PHAROS-199: the helper's fallback resolves this by parsing
        `hosts/<host>/docker/docker-compose.yml`, which OPS-122 deleted on
        2026-08-01 when the stack became Nix-rendered. With no file to read the
        helper failed `missing_engine_image` on every run, surfaced to the
        operator as the misleading "Janus unavailable". Set this from the same
        attribute that pins the container so the two can never drift.
      '';
    };
    pollSeconds = lib.mkOption {
      type = lib.types.ints.between 15 300;
      default = 30;
      description = "Polling cadence for host-retirement work.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.match "[a-z0-9][a-z0-9-]{0,62}" owner != null;
        message = "The Pharos retirement executor requires a valid owner host name";
      }
      {
        assertion = builtins.match "http://[0-9.]+:[0-9]+" cfg.pharosUrl != null;
        message = "inspr.pharosRetirementExecutor.pharosUrl must be a fixed HTTP address";
      }
      {
        assertion = builtins.match "/[A-Za-z0-9._/-]+" cfg.repoPath != null;
        message = "inspr.pharosRetirementExecutor.repoPath must be an absolute path";
      }
      {
        # PHAROS-199: an unset image silently falls back to parsing a
        # docker-compose.yml that no longer exists, which fails every
        # retirement as "Janus unavailable". Fail at eval instead.
        assertion = cfg.janusEngineImage != "";
        message =
          "inspr.pharosRetirementExecutor.janusEngineImage must be set to the pinned "
          + "Janus engine image (see hosts/<host>/docker/compose-spec.nix)";
      }
      {
        assertion = builtins.match "[^[:space:]]+@sha256:[0-9a-f]{64}" cfg.janusEngineImage != null;
        message =
          "inspr.pharosRetirementExecutor.janusEngineImage must be digest-pinned "
          + "(…@sha256:<64 hex>), so a moved tag cannot change what retires a credential";
      }
    ];

    environment.systemPackages = [ executor ];

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0700 root root -"
      "d ${stateDir}/runs 0700 root root -"
    ];

    systemd.services.pharos-retirement-executor = {
      description = "Execute reviewed Janus credential retirement for removed Pharos hosts";
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
      unitConfig.ConditionPathExists = cfg.tokenEnvironmentFile;
      restartIfChanged = false;
      stopIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${executor}/bin/pharos-retirement-executor";
        EnvironmentFile = cfg.tokenEnvironmentFile;
        # PHAROS-199: inherited by retire-host.sh, which otherwise falls back to
        # parsing a compose file the OPS-122 cutover removed.
        Environment = [ "JANUS_ENGINE_IMAGE=${cfg.janusEngineImage}" ];
        UMask = "0077";
        PrivateTmp = true;
        TimeoutStartSec = "1800";
      };
    };

    systemd.timers.pharos-retirement-executor = {
      description = "Poll Pharos for reviewed host-retirement work";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = "${toString cfg.pollSeconds}s";
        RandomizedDelaySec = "5s";
        Persistent = true;
        Unit = "pharos-retirement-executor.service";
      };
    };
  };
}
