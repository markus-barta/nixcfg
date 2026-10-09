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
  environment = [
    "IB_DESK_ACCOUNT=DUR970597"
    "IB_DESK_GATEWAY_HOST=100.64.0.6"
    "IB_DESK_GATEWAY_PORT=${toString cfg.gatewayPort}"
    "IB_DESK_OWNERSHIP_LEDGER=/pusher-state/${ledgerName}"
    "IB_DESK_CLIENT_IDS=${builtins.toJSON cfg.clientIds}"
    "IB_DESK_OWNERSHIP_CLIENT_IDS=${builtins.toJSON cfg.ownershipClientIds}"
    "PAPER_DESK_BIND=${cfg.listenAddress}"
    "PAPER_DESK_PORT=${toString cfg.listenPort}"
    "PAPER_DESK_ALLOW=${builtins.toJSON cfg.peerAllowlist}"
    "PAPER_DESK_STATE_DIR=/state"
    "PAPER_DESK_BLOCK_ON_INIT_DAY=${lib.boolToString cfg.blockOnInitDay}"
  ];
  peerRules =
    action:
    lib.concatMapStringsSep "\n" (
      peer:
      "iptables ${action} nixos-fw -i tailscale0 -s ${peer} -d ${cfg.listenAddress} -p tcp --dport ${toString cfg.listenPort} -j nixos-fw-accept"
    ) cfg.peerAllowlist;
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
        "100.64.0.10" # grok-amy-box (node 21 after the 2026-10-07 rebuild; was .9)
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

    serviceSpec = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      internal = true;
      description = "Executor service merged into the host compose specification.";
    };

    blockOnInitDay = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Optional paper-only ledger initialization-day brake.";
    };

    clientIds = lib.mkOption {
      type = lib.types.attrsOf lib.types.int;
      default = {
        recon = 700;
        executor = 705;
      };
      description = "Distinct recon and shared placing client IDs; desk ownership is enforced by orderRef.";
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
        j2 = [ 706 ];
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
        assertion =
          cfg.clientIds.recon > 0
          && cfg.clientIds.executor > 0
          && cfg.clientIds.recon != cfg.clientIds.executor
          && !(lib.elem cfg.clientIds.executor (lib.concatLists (lib.attrValues cfg.ownershipClientIds)))
          && !(lib.elem cfg.clientIds.recon (lib.concatLists (lib.attrValues cfg.ownershipClientIds)))
          &&
            lib.length (lib.unique (lib.concatLists (lib.attrValues cfg.ownershipClientIds)))
            == lib.length (lib.concatLists (lib.attrValues cfg.ownershipClientIds));
        message = "paperDeskExecutor shared client must be distinct from recon and legacy ownership IDs";
      }
      {
        assertion =
          !(lib.elem cfg.listenPort (
            config.networking.firewall.interfaces.tailscale0.allowedTCPPorts or [ ]
          ));
        message = "paperDeskExecutor requires source-specific firewall rules on tailscale0";
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

    # Clear the former service account's supplementary membership on upgrades;
    # merely removing its declaration can leave it behind with mutableUsers.
    users.groups.paper-desk-executor = { };
    users.users.paper-desk-executor = {
      isSystemUser = true;
      group = "paper-desk-executor";
      extraGroups = lib.mkForce [ ];
    };

    # Root manages compose; the app has no docker socket or docker-group user.
    nixcfg.composeStack = {
      autoUpdate.excludeFromPull = [ "paper-desk-executor" ];
      extraRestartTriggers = [ source ];
    };
    nixcfg.paperDeskExecutor.serviceSpec = {
      image = cfg.image;
      pull_policy = "never";
      container_name = "paper-desk-executor";
      restart = "unless-stopped";
      # Required for tailnet-only bind and the tailnet-bound paper Gateway.
      network_mode = "host";
      user = "1000:1000";
      read_only = true;
      cap_drop = [ "ALL" ];
      security_opt = [ "no-new-privileges:true" ];
      pids_limit = 64;
      mem_limit = "256m";
      tmpfs = [ "/tmp:rw,noexec,nosuid,nodev,size=16m,mode=1777" ];
      volumes = [
        "${source}:/executor:ro"
        "/var/lib/paper-desk-executor:/state:rw"
        "${ledgerDir}:/pusher-state:ro"
      ];
      inherit environment;
      entrypoint = [ "node" ];
      command = [ "/executor/server.mjs" ];
      labels = [
        "traefik.enable=false"
        "com.centurylinklabs.watchtower.enable=false"
      ];
    };

    networking.firewall = {
      # Tailscale's ts-input can accept peers before nixos-fw is reached.
      # Restrict this one port in raw PREROUTING as well as the Nix filter.
      extraCommands = ''
        iptables -t raw -N paper-desk-peers 2>/dev/null || true
        iptables -t raw -F paper-desk-peers
        ${lib.concatMapStringsSep "\n" (
          peer: "iptables -t raw -A paper-desk-peers -s ${peer} -j RETURN"
        ) cfg.peerAllowlist}
        iptables -t raw -A paper-desk-peers -j DROP
        iptables -t raw -C PREROUTING -i tailscale0 -d ${cfg.listenAddress} -p tcp --dport ${toString cfg.listenPort} -j paper-desk-peers 2>/dev/null || \
          iptables -t raw -I PREROUTING -i tailscale0 -d ${cfg.listenAddress} -p tcp --dport ${toString cfg.listenPort} -j paper-desk-peers
        ${peerRules "-I"}
      '';
      extraStopCommands = ''
        iptables -t raw -D PREROUTING -i tailscale0 -d ${cfg.listenAddress} -p tcp --dport ${toString cfg.listenPort} -j paper-desk-peers 2>/dev/null || true
        iptables -t raw -F paper-desk-peers 2>/dev/null || true
        iptables -t raw -X paper-desk-peers 2>/dev/null || true
      '';
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/paper-desk-executor 0700 1000 1000 - -"
      "f /var/lib/paper-desk-executor/HALT 0600 1000 1000 - -"
      # Repair ownership when upgrading the former root-owned ledger.
      "Z /var/lib/paper-desk-executor - 1000 1000 - -"
      "z /var/lib/paper-desk-executor/HALT 0600 1000 1000 - -"
      "z /var/lib/paper-desk-executor/ledger.json 0600 1000 1000 - -"
      "z /var/lib/paper-desk-executor/audit.jsonl 0600 1000 1000 - -"
    ];
  };
}
