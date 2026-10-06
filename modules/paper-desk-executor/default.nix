# Host-local paper desk executor for hsb0 (OPS-266).
# Desks submit intents over the tailnet. The host enforces Stage-0 brakes and
# talks to the paper Gateway. No GitHub queue, no token, no agenix secret.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.nixcfg.paperDeskExecutor;
  stack = config.nixcfg.composeStack;
  docker = "${config.virtualisation.docker.package}/bin/docker";
  ledgerName = baseNameOf cfg.ownershipLedgerFile;
  ledgerDir = dirOf cfg.ownershipLedgerFile;
  tailnetPeer =
    peer:
    lib.match "100[.](6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])[.]([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])[.]([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])" peer
    != null;
  source = pkgs.runCommand "paper-desk-executor-source" { } ''
    mkdir -p "$out/client"
    cp ${./policy.mjs} "$out/policy.mjs"
    cp ${./security.mjs} "$out/security.mjs"
    cp ${./ib.mjs} "$out/ib.mjs"
    cp ${./state.mjs} "$out/state.mjs"
    cp ${./executor.mjs} "$out/executor.mjs"
    cp ${./server.mjs} "$out/server.mjs"
    cp ${./client/paper-intent.mjs} "$out/client/paper-intent.mjs"
  '';
  runArgs = [
    "run"
    "--name=paper-desk-executor"
    "--rm"
    "--network=host"
    "--read-only"
    "--cap-drop=ALL"
    "--security-opt=no-new-privileges:true"
    "--pids-limit=64"
    "--memory=256m"
    "--user=0:0"
    "--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=16m,mode=1777"
    "--mount=type=bind,src=${source},dst=/executor,readonly"
    "--mount=type=bind,src=/var/lib/paper-desk-executor,dst=/state"
    "--mount=type=bind,src=${ledgerDir},dst=/pusher-state,readonly"
    "--env=IB_DESK_ACCOUNT=DUR970597"
    "--env=IB_DESK_GATEWAY_HOST=100.64.0.6"
    "--env=IB_DESK_GATEWAY_PORT=${toString cfg.gatewayPort}"
    "--env=IB_DESK_OWNERSHIP_LEDGER=/pusher-state/${ledgerName}"
    "--env=IB_DESK_RECON_CLIENT_ID=${toString cfg.clientIds.recon}"
    "--env=IB_DESK_CLIENT_IDS=${builtins.toJSON cfg.clientIds}"
    "--env=IB_DESK_OWNERSHIP_CLIENT_IDS=${builtins.toJSON cfg.ownershipClientIds}"
    "--env=IB_DESK_KEEP=${builtins.toJSON cfg.keepSymbols}"
    "--env=PAPER_DESK_BIND=${cfg.listenAddress}"
    "--env=PAPER_DESK_PORT=${toString cfg.listenPort}"
    "--env=PAPER_DESK_ALLOW=${builtins.toJSON cfg.peerAllowlist}"
    "--env=PAPER_DESK_STATE_DIR=/state"
    "--entrypoint=node"
    cfg.image
    "/executor/server.mjs"
  ];
in
{
  options.nixcfg.paperDeskExecutor = {
    enable = lib.mkEnableOption "tailnet paper desk executor on hsb0";

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "100.64.0.6";
      description = "Tailnet address the executor binds. It must stay the hsb0 tailnet address.";
    };

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 8470;
      description = "TCP port on tailscale0. It is not opened on LAN or WAN.";
    };

    gatewayPort = lib.mkOption {
      type = lib.types.port;
      default = 4002;
      description = "Paper Gateway API port. Live port 4001 is refused.";
    };

    peerAllowlist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "100.64.0.9" # grok-amy-box
        "100.64.0.14" # mbp2607, OPS tests
      ];
      description = "Tailnet source addresses allowed to call the executor. Any other source receives 403.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "hsb0-joe-board-pusher:flat-net-reconcile-perf-202610010310";
      description = "Pinned local image used only for Node and @stoqey/ib. The pusher service is unchanged.";
    };

    ownershipLedgerFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/joe-board-pusher/family-history.json";
      description = "Read-only durable execution history used to attribute desk-owned positions.";
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
      description = "Client IDs whose orders each desk may cancel and flatten. KEEP symbols are excluded.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = stack.enable;
        message = "paperDeskExecutor requires nixcfg.composeStack";
      }
      {
        assertion = lib.hasAttr "ib-gateway" (stack.spec.services or { });
        message = "paperDeskExecutor requires the declared paper ib-gateway service";
      }
      {
        assertion =
          (stack.spec.services.ib-gateway.environment or [ ]) != [ ]
          && builtins.elem "TRADING_MODE=paper" stack.spec.services.ib-gateway.environment
          && !(lib.any (value: lib.hasInfix "4001" value) (stack.spec.services.ib-gateway.ports or [ ]));
        message = "paperDeskExecutor refuses a non-paper Gateway or any published live port 4001";
      }
      {
        assertion = cfg.gatewayPort == 4002;
        message = "paperDeskExecutor live port 4001 is refused; the Gateway port must be 4002";
      }
      {
        assertion = cfg.listenAddress == "100.64.0.6";
        message = "paperDeskExecutor listens only on the hsb0 tailnet address 100.64.0.6";
      }
      {
        assertion = cfg.listenPort == 8470;
        message = "paperDeskExecutor listens only on port 8470";
      }
      {
        assertion = !(lib.elem cfg.listenPort config.networking.firewall.allowedTCPPorts);
        message = "paperDeskExecutor port 8470 must not be open on every interface";
      }
      {
        assertion = cfg.peerAllowlist != [ ] && lib.all tailnetPeer cfg.peerAllowlist;
        message = "paperDeskExecutor peers must be tailnet addresses in 100.64.0.0/10";
      }
      {
        assertion =
          cfg.keepSymbols == [
            "SXR8"
            "TSLA"
          ];
        message = "paperDeskExecutor KEEP must remain exactly SXR8 and TSLA";
      }
      {
        assertion = ledgerDir == "/var/lib/joe-board-pusher" && ledgerName != "";
        message = "paperDeskExecutor ownership ledger must stay inside /var/lib/joe-board-pusher";
      }
      {
        assertion =
          lib.hasAttr "joe-board-pusher" (stack.spec.services or { })
          && stack.spec.services.joe-board-pusher.image == cfg.image;
        message = "paperDeskExecutor runtime image must match the existing pinned joe-board-pusher image";
      }
    ];

    users.groups.paper-desk-executor = { };
    users.users.paper-desk-executor = {
      isSystemUser = true;
      group = "paper-desk-executor";
      extraGroups = [ "docker" ];
    };

    # tailscale0 only. The process also binds 100.64.0.6, so LAN and WAN have no listener.
    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ cfg.listenPort ];

    systemd.tmpfiles.rules = [
      "d /var/lib/paper-desk-executor 0700 root root - -"
      "f /var/lib/paper-desk-executor/HALT 0600 root root - -"
    ];

    systemd.services.paper-desk-executor = {
      description = "Paper desk executor for tailnet intents on the hsb0 paper Gateway";
      wantedBy = [ "multi-user.target" ];
      after = [
        "docker.service"
        "compose-${stack.stackName}.service"
        "network-online.target"
        "tailscaled.service"
      ];
      wants = [
        "docker.service"
        "network-online.target"
      ];
      path = [
        config.virtualisation.docker.package
      ];
      serviceConfig = {
        Type = "simple";
        User = "paper-desk-executor";
        Group = "paper-desk-executor";
        SupplementaryGroups = [ "docker" ];
        ExecStartPre = lib.escapeShellArgs [
          "${pkgs.bash}/bin/bash"
          "-c"
          "${docker} rm -f paper-desk-executor >/dev/null 2>&1 || true"
        ];
        ExecStart = lib.escapeShellArgs ([ docker ] ++ runArgs);
        ExecStop = lib.escapeShellArgs [
          "${pkgs.bash}/bin/bash"
          "-c"
          "${docker} stop -t 20 paper-desk-executor >/dev/null 2>&1 || true"
        ];
        Restart = "on-failure";
        RestartSec = "10s";
        TimeoutStartSec = "90";
        TimeoutStopSec = "40";
        RuntimeDirectory = "paper-desk-executor";
        RuntimeDirectoryMode = "0700";
        UMask = "0077";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        SystemCallArchitectures = "native";
        Environment = [
          "HOME=/run/paper-desk-executor"
          "DOCKER_CONFIG=/run/paper-desk-executor"
        ];
      };
    };
  };
}
