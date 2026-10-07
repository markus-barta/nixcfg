# OPS-272 — Amy/OPS text mailbox; tailnet peers identify callers without secrets.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.nixcfg.agentMailbox;
  stack = config.nixcfg.composeStack;
  peerAddresses = lib.attrNames cfg.peers;
  identities = lib.unique (lib.attrValues cfg.peers);
  tailnetAddress =
    address:
    lib.match "100[.](6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])[.]([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])[.]([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])" address
    != null;
  safeIdentity =
    identity:
    lib.match "[a-z][a-z0-9_-]{0,31}" identity != null
    && !(lib.elem identity [
      "constructor"
      "prototype"
      "__proto__"
    ]);
  portOpen =
    firewall:
    lib.elem cfg.listenPort (firewall.allowedTCPPorts or [ ])
    || lib.any (range: range.from <= cfg.listenPort && range.to >= cfg.listenPort) (
      firewall.allowedTCPPortRanges or [ ]
    );
  source = pkgs.runCommand "agent-mailbox-source" { } ''
    mkdir -p "$out"
    cp ${./server.mjs} "$out/server.mjs"
    cp ${./security.mjs} "$out/security.mjs"
    cp ${./state.mjs} "$out/state.mjs"
  '';
  peerRules =
    action:
    lib.concatMapStringsSep "\n" (
      peer:
      "iptables ${action} nixos-fw -i tailscale0 -s ${peer} -d ${cfg.listenAddress} -p tcp --dport ${toString cfg.listenPort} -j nixos-fw-accept"
    ) peerAddresses;
in
{
  options.nixcfg.agentMailbox = {
    enable = lib.mkEnableOption "tailnet agent mailbox on hsb0";
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "100.64.0.6";
      description = "hsb0 tailnet-only listen address in 100.64.0.0/10.";
    };
    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 8471;
      description = "Source-restricted TCP port; never opened on an entire interface.";
    };
    peers = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        "100.64.0.10" = "amy";
        "100.64.0.14" = "ops";
      };
      description = "Tailnet source IPv4 address to caller identity.";
    };
    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/agent-mailbox";
      description = "Private host state directory owned by UID/GID 1000.";
    };
    serviceSpec = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      internal = true;
      description = "Mailbox service merged into the host compose specification.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = stack.enable;
        message = "agentMailbox requires nixcfg.composeStack";
      }
      {
        assertion = tailnetAddress cfg.listenAddress && cfg.listenAddress == "100.64.0.6";
        message = "agentMailbox binds only the hsb0 tailnet address in 100.64.0.0/10";
      }
      {
        assertion =
          !(portOpen config.networking.firewall)
          && !(lib.any portOpen (lib.attrValues config.networking.firewall.interfaces));
        message = "agentMailbox requires source-specific firewall rules; its port must not be opened globally or on any entire interface";
      }
      {
        assertion =
          peerAddresses != [ ]
          && lib.length peerAddresses <= 32
          && lib.all tailnetAddress peerAddresses
          && lib.length identities >= 2
          && lib.all safeIdentity identities;
        message = "agentMailbox requires tailnet peers and at least two safe identities";
      }
      {
        assertion = cfg.stateDir == "/var/lib/agent-mailbox";
        message = "agentMailbox state must stay in /var/lib/agent-mailbox";
      }
      {
        assertion =
          config.nixcfg.paperDeskExecutor.enable
          && lib.hasAttr "joe-board-pusher" (stack.spec.services or { })
          && stack.spec.services.joe-board-pusher.image == config.nixcfg.paperDeskExecutor.image;
        message = "agentMailbox requires the same pinned local Node image as paperDeskExecutor";
      }
      {
        assertion = cfg.listenPort != config.nixcfg.paperDeskExecutor.listenPort;
        message = "agentMailbox port must be distinct from the paper executor";
      }
    ];

    nixcfg.composeStack = {
      autoUpdate.excludeFromPull = [ "agent-mailbox" ];
      extraRestartTriggers = [ source ];
    };
    nixcfg.agentMailbox.serviceSpec = {
      image = config.nixcfg.paperDeskExecutor.image;
      pull_policy = "never";
      container_name = "agent-mailbox";
      restart = "unless-stopped";
      network_mode = "host";
      user = "1000:1000";
      read_only = true;
      cap_drop = [ "ALL" ];
      security_opt = [ "no-new-privileges:true" ];
      pids_limit = 64;
      mem_limit = "256m";
      tmpfs = [ "/tmp:rw,noexec,nosuid,nodev,size=16m,mode=1777" ];
      volumes = [
        "${source}:/mailbox:ro"
        "${cfg.stateDir}:/state:rw"
      ];
      environment = [
        "AGENT_MAILBOX_BIND=${cfg.listenAddress}"
        "AGENT_MAILBOX_PORT=${toString cfg.listenPort}"
        "AGENT_MAILBOX_PEERS=${builtins.toJSON cfg.peers}"
        "AGENT_MAILBOX_STATE_DIR=/state"
      ];
      entrypoint = [ "node" ];
      command = [ "/mailbox/server.mjs" ];
      labels = [
        "traefik.enable=false"
        "com.centurylinklabs.watchtower.enable=false"
      ];
    };
    networking.firewall = {
      # Match the executor: raw PREROUTING runs before Tailscale's ts-input.
      extraCommands = ''
        iptables -t raw -N agent-mailbox-peers 2>/dev/null || true
        iptables -t raw -F agent-mailbox-peers
        ${lib.concatMapStringsSep "\n" (
          peer: "iptables -t raw -A agent-mailbox-peers -s ${peer} -j RETURN"
        ) peerAddresses}
        iptables -t raw -A agent-mailbox-peers -j DROP
        iptables -t raw -C PREROUTING -i tailscale0 -d ${cfg.listenAddress} -p tcp --dport ${toString cfg.listenPort} -j agent-mailbox-peers 2>/dev/null || \
          iptables -t raw -I PREROUTING -i tailscale0 -d ${cfg.listenAddress} -p tcp --dport ${toString cfg.listenPort} -j agent-mailbox-peers
        ${peerRules "-I"}
      '';
      extraStopCommands = ''
        iptables -t raw -D PREROUTING -i tailscale0 -d ${cfg.listenAddress} -p tcp --dport ${toString cfg.listenPort} -j agent-mailbox-peers 2>/dev/null || true
        iptables -t raw -F agent-mailbox-peers 2>/dev/null || true
        iptables -t raw -X agent-mailbox-peers 2>/dev/null || true
      '';
    };
    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 1000 1000 - -"
    ];
  };
}
