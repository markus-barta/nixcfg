# JOED-20: disabled until the ingress contract, broker evidence and paper
# proof are approved. No live mode, IB client, order API or synthetic fallback.
# Paper proof procedure: hosts/hsb0/docs/RUNBOOK.md, JoeDesk Results producer.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixcfg.joeResultsProducer;
  source = import ./source.nix { inherit pkgs; };
  settings = pkgs.writeText "joe-results-producer.json" (
    builtins.toJSON {
      mode = "paper";
      inherit (cfg) endpoint keepSymbols;
      executorHealth = "http://127.0.0.1:8472/v1/health";
      capturePath = "/var/lib/paper-desk-executor/results-input.jsonl";
      stateDir = "/var/lib/joe-results-producer";
    }
  );
  hostsFile = pkgs.writeText "joe-results-hosts" ''
    127.0.0.1 localhost
    ${cfg.ingressAddress} ${cfg.ingressHost}
  '';
in
{
  options.nixcfg.joeResultsProducer = {
    enable = lib.mkEnableOption "paper-only JoeDesk Results v2 producer";
    endpoint = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Board origin plus /joe/inbox/results; same machine token as the household inbox.";
    };
    ingressAddress = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Pinned ingress IPv4 address, the only non-loopback destination allowed by systemd.";
    };
    ingressHost = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "TLS hostname bound to ingressAddress in this service's private hosts file; no DNS egress.";
    };
    keepSymbols = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "SXR8"
        "TSLA"
      ];
      description = "Full policy KEEP set. The protected floor cannot be removed.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.nixcfg.paperDeskExecutor.enable;
        message = "joeResultsProducer requires the paper executor";
      }
      {
        assertion =
          cfg.ingressHost != ""
          && cfg.endpoint == "https://${cfg.ingressHost}/joe/inbox/results"
          && builtins.match "[a-z0-9.-]+" cfg.ingressHost != null;
        message = "joeResultsProducer requires an exact HTTPS endpoint on its pinned lowercase ingressHost";
      }
      {
        assertion =
          builtins.match "(0|[1-9][0-9]{0,2})([.](0|[1-9][0-9]{0,2})){3}" cfg.ingressAddress != null
          && lib.all (part: builtins.fromJSON part <= 255) (lib.splitString "." cfg.ingressAddress);
        message = "joeResultsProducer requires a pinned ingress IPv4 address";
      }
      {
        assertion =
          lib.all (symbol: lib.elem symbol cfg.keepSymbols) [
            "SXR8"
            "TSLA"
          ]
          && lib.all (symbol: builtins.match "[A-Z0-9][A-Z0-9._-]{0,15}" symbol != null) cfg.keepSymbols;
        message = "joeResultsProducer KEEP requires the full SXR8/TSLA floor";
      }
    ];
    nixcfg.paperDeskExecutor.resultsCaptureEnabled = true;
    nixcfg.paperDeskExecutor.resultsKeepSymbols = cfg.keepSymbols;

    systemd.services.joe-results-producer = {
      description = "JoeDesk paper Results v2 producer (read-only executor access)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "time-sync.target"
        "compose-hsb0.service"
      ];
      wants = [
        "network-online.target"
        "time-sync.target"
      ];
      serviceConfig = {
        Type = "simple";
        Environment = [ "JOE_RESULTS_INGRESS_ORIGIN=https://${cfg.ingressHost}" ];
        # Same unprivileged identity as the executor container, with its state
        # mounted read-only here. No added groups, Docker socket or capabilities.
        User = "1000";
        Group = "1000";
        SupplementaryGroups = [ ];
        # systemd copies the existing raw household token before namespace
        # restrictions apply. The service cannot read the original secret dirs.
        LoadCredential = [ "joe-board-push-token:${config.age.secrets.joe-board-push-token.path}" ];
        ExecStart = "${pkgs.util-linux}/bin/flock --exclusive --nonblock /var/lib/joe-results-producer/writer.lock ${pkgs.nodejs}/bin/node ${source}/main.mjs ${settings}";
        Restart = "on-failure";
        RestartSec = 5;
        StateDirectory = "joe-results-producer";
        StateDirectoryMode = "0700";
        UMask = "0077";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        RestrictNamespaces = true;
        LockPersonality = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        RemoveIPC = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
        ];
        SocketBindDeny = [ "any" ];
        IPAddressDeny = [ "any" ];
        IPAddressAllow = [
          "127.0.0.1/32"
          "${cfg.ingressAddress}/32"
        ];
        BindReadOnlyPaths = [
          "/var/lib/paper-desk-executor"
          "${hostsFile}:/etc/hosts"
        ];
        InaccessiblePaths = [
          "-/run/agenix"
          "-/run/secrets"
          "-/var/run/docker.sock"
        ];
        ReadWritePaths = [ "/var/lib/joe-results-producer" ];
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];
        SystemCallArchitectures = "native";
        TasksMax = 32;
        MemoryMax = "384M";
      };
    };
  };
}
