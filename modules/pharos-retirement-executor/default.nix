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
