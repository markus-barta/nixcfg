# Durable pull-based paper desk runner for hsb0.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.nixcfg.ibDeskRunner;
  stack = config.nixcfg.composeStack;
  source = pkgs.runCommand "ib-desk-runner-source" { } ''
    mkdir -p "$out"
    cp ${./policy.mjs} "$out/policy.mjs"
    cp ${./ib.mjs} "$out/ib.mjs"
    cp ${./runner.mjs} "$out/runner.mjs"
    cp ${./dry-run.mjs} "$out/dry-run.mjs"
  '';
  docker = "${config.virtualisation.docker.package}/bin/docker";
  commonArgs = [
    "run"
    "--rm"
    "--network=host"
    "--read-only"
    "--cap-drop=ALL"
    "--security-opt=no-new-privileges:true"
    "--pids-limit=64"
    "--memory=256m"
    "--user=0:0"
    "--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=16m,mode=1777"
    "--mount=type=bind,src=${source},dst=/runner,readonly"
    "--mount=type=bind,src=/var/lib/ib-desk-runner,dst=/state"
    "--mount=type=bind,src=${cfg.ownershipLedgerFile},dst=/pusher-state/execution-history.json,readonly"
    "--env=IB_DESK_ACCOUNT=DUR970597"
    "--env=IB_DESK_GATEWAY_HOST=100.64.0.6"
    "--env=IB_DESK_GATEWAY_PORT=4002"
    "--env=IB_DESK_STATE=/state/ledger.json"
    "--env=IB_DESK_AUDIT=/state/audit.jsonl"
    "--env=IB_DESK_LOCAL_HALT=/state/HALT"
    "--env=IB_DESK_OWNERSHIP_LEDGER=/pusher-state/execution-history.json"
    "--env=IB_DESK_RECON_CLIENT_ID=${toString cfg.clientIds.recon}"
    "--env=IB_DESK_CLIENT_IDS=${builtins.toJSON cfg.clientIds}"
    "--env=IB_DESK_OWNERSHIP_CLIENT_IDS=${builtins.toJSON cfg.ownershipClientIds}"
    "--env=IB_DESK_KEEP=${builtins.toJSON cfg.keepSymbols}"
    "--entrypoint=node"
  ];
  dockerCommand = args: lib.escapeShellArgs ([ docker ] ++ commonArgs ++ args);
  pollCommand = dockerCommand [
    "--mount=type=bind,src=%d/github-token,dst=/run/credentials/github-token,readonly"
    "--env=IB_DESK_GITHUB_TOKEN_FILE=/run/credentials/github-token"
    "--env=IB_DESK_GITHUB_REPOSITORY=${cfg.githubRepository}"
    cfg.image
    "/runner/runner.mjs"
    "poll"
  ];
  flattenCommand = dockerCommand [
    cfg.image
    "/runner/runner.mjs"
    "scheduled-flatten"
    "j"
  ];
in
{
  options.nixcfg.ibDeskRunner = {
    enable = lib.mkEnableOption "pull-based paper IB desk runner on hsb0";

    githubRepository = lib.mkOption {
      type = lib.types.str;
      default = "markus-barta/oc-workspace-shared";
      description = "Private GitHub repository whose issues are the authenticated intent queue.";
    };

    githubTokenFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/agenix/hsb0-ib-desk-runner-github-token";
      description = "Absolute path to a raw fine-grained GitHub token with Issues read/write on the private queue repository.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "hsb0-joe-board-pusher:flat-net-reconcile-perf-202610010310";
      description = "Existing immutable local image used only for Node and @stoqey/ib; the pusher service and pin are unchanged.";
    };

    ownershipLedgerFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/joe-board-pusher/family-history.json";
      description = "Read-only durable all-desk execution history used to attribute legacy desk-owned positions.";
    };

    keepSymbols = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "SXR8"
        "TSLA"
      ];
    };

    clientIds = lib.mkOption {
      type = lib.types.attrsOf lib.types.int;
      default = {
        recon = 700;
        joe = 701;
        j = 702;
        j5 = 703;
        joel = 704;
      };
      description = "Dedicated non-overlapping paper API client IDs.";
    };

    ownershipClientIds = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.int);
      default = {
        # Existing J-family IDs come from the durable pusher ownership policy.
        # New requests use the dedicated IDs above.
        j = [
          27
          28
          29
          50
          51
          52
          53
          54
          55
          56
          76
          78
          79
          80
          83
          702
        ];
        j5 = [ 703 ];
        joe = [
          22
          89
          90
          91
          119
          130
          131
          148
          151
          152
          701
        ];
        joel = [ 704 ];
      };
      description = "Client IDs whose executions/orders each desk may flatten; KEEP is always excluded.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = stack.enable;
        message = "ibDeskRunner requires nixcfg.composeStack";
      }
      {
        assertion = lib.hasAttr "ib-gateway" (stack.spec.services or { });
        message = "ibDeskRunner requires the declared paper ib-gateway service";
      }
      {
        assertion =
          (stack.spec.services.ib-gateway.environment or [ ]) != [ ]
          && builtins.elem "TRADING_MODE=paper" stack.spec.services.ib-gateway.environment
          && !(lib.any (value: lib.hasInfix "4001" value) (stack.spec.services.ib-gateway.ports or [ ]));
        message = "ibDeskRunner refuses a non-paper Gateway or any published live port 4001";
      }
      {
        assertion = cfg.keepSymbols == [
          "SXR8"
          "TSLA"
        ];
        message = "ibDeskRunner KEEP must remain exactly SXR8 and TSLA";
      }
      {
        assertion =
          lib.hasAttr "joe-board-pusher" (stack.spec.services or { })
          && stack.spec.services.joe-board-pusher.image == cfg.image;
        message = "ibDeskRunner runtime image must match the existing pinned joe-board-pusher image";
      }
    ];

    systemd.tmpfiles.rules = [
      "d /var/lib/ib-desk-runner 0700 root root - -"
      "f /var/lib/ib-desk-runner/HALT 0600 root root - -"
    ];

    systemd.services.ib-desk-runner = {
      description = "Poll authenticated GitHub paper desk intents and execute on hsb0";
      after = [
        "docker.service"
        "compose-${stack.stackName}.service"
        "network-online.target"
      ];
      wants = [
        "docker.service"
        "network-online.target"
      ];
      unitConfig.ConditionPathExists = cfg.githubTokenFile;
      serviceConfig = {
        Type = "oneshot";
        LoadCredential = "github-token:${cfg.githubTokenFile}";
        ExecStart = "${pkgs.util-linux}/bin/flock /var/lib/ib-desk-runner/runner.lock ${pollCommand}";
        TimeoutStartSec = "120";
        UMask = "0077";
        NoNewPrivileges = true;
      };
      path = [
        config.virtualisation.docker.package
        pkgs.util-linux
      ];
    };

    systemd.timers.ib-desk-runner = {
      description = "Poll for authenticated paper desk intents";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "1m";
        RandomizedDelaySec = "5s";
        Persistent = true;
        Unit = "ib-desk-runner.service";
      };
    };

    # Declarative successor to the ad-hoc joel-ib-paper-flatten-own.timer.
    # It derives J ownership from execution client IDs, never a symbol allowlist.
    systemd.services.joel-ib-paper-flatten-own = {
      description = "Flatten all paper J-owned positions and orders, excluding KEEP";
      after = [
        "docker.service"
        "compose-${stack.stackName}.service"
      ];
      wants = [ "docker.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.util-linux}/bin/flock /var/lib/ib-desk-runner/runner.lock ${flattenCommand}";
        TimeoutStartSec = "120";
        UMask = "0077";
        NoNewPrivileges = true;
      };
      path = [
        config.virtualisation.docker.package
        pkgs.util-linux
      ];
    };

    systemd.timers.joel-ib-paper-flatten-own = {
      description = "Weekday 21:50 Vienna paper J-owned flatten";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Mon..Fri *-*-* 21:50:00 Europe/Vienna";
        AccuracySec = "1min";
        # Never replay a missed EOD flatten on a weekend or later session.
        Persistent = false;
        Unit = "joel-ib-paper-flatten-own.service";
      };
    };
  };
}
