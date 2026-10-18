# OPS-331: evaluate the real module with inert package paths; no builds or hosts.
{
  reconRetentionHours ? null,
  resultsHealthPort ? null,
  clientIds ? null,
  ownershipClientIds ? null,
  marketDataClientId ? null,
  bookClientId ? null,
  tailnetContract ? false,
}:
let
  lib = import <nixpkgs/lib>;
  evaluated = lib.evalModules {
    specialArgs.pkgs = {
      runCommand =
        name: _: _:
        "/fixture/${name}";
      writeText = name: _: "/fixture/${name}";
      coreutils = "/fixture/coreutils";
      util-linux = "/fixture/util-linux";
      python3 = "/fixture/python3";
      tailscale = "/fixture/tailscale";
      iptables = "/fixture/iptables";
      systemd = "/fixture/systemd";
    };
    modules = [
      ../modules/paper-desk-executor/default.nix
      ../modules/agent-mailbox/default.nix
      {
        options = {
          assertions = lib.mkOption { type = lib.types.listOf lib.types.attrs; };
          networking.firewall = {
            package = lib.mkOption {
              type = lib.types.str;
              default = "/fixture/firewall-backend";
            };
            allowedTCPPorts = lib.mkOption {
              type = lib.types.listOf lib.types.port;
              default = [ ];
            };
            interfaces = lib.mkOption {
              type = lib.types.attrs;
              default = { };
            };
            extraCommands = lib.mkOption { type = lib.types.lines; };
            extraStopCommands = lib.mkOption { type = lib.types.lines; };
          };
          virtualisation = lib.mkOption { type = lib.types.attrs; };
          nixcfg.ibGatewaySession = lib.mkOption { type = lib.types.attrs; };
          users = lib.mkOption { type = lib.types.attrs; };
          systemd = {
            tmpfiles.rules = lib.mkOption { type = lib.types.listOf lib.types.str; };
            timers = lib.mkOption { type = lib.types.attrs; };
            services = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule {
                  freeformType = lib.types.attrs;
                  options.postStart = lib.mkOption {
                    type = lib.types.lines;
                    default = "";
                  };
                }
              );
            };
          };
          nixcfg.composeStack = {
            enable = lib.mkOption { type = lib.types.bool; };
            spec = lib.mkOption { type = lib.types.attrs; };
            autoUpdate.excludeFromPull = lib.mkOption { type = lib.types.listOf lib.types.str; };
            extraRestartTriggers = lib.mkOption { type = lib.types.listOf lib.types.str; };
          };
        };
        config = {
          nixcfg.agentMailbox.enable = true;
          nixcfg.paperDeskExecutor = {
            enable = true;
          }
          // lib.optionalAttrs (reconRetentionHours != null) { inherit reconRetentionHours; }
          // lib.optionalAttrs (resultsHealthPort != null) { inherit resultsHealthPort; }
          // lib.optionalAttrs (clientIds != null) { inherit clientIds; }
          // lib.optionalAttrs (ownershipClientIds != null) { inherit ownershipClientIds; }
          // lib.optionalAttrs (marketDataClientId != null) { inherit marketDataClientId; }
          // lib.optionalAttrs (bookClientId != null) { inherit bookClientId; };
          nixcfg.composeStack = {
            enable = true;
            spec.services = {
              ib-gateway = {
                environment = [ "TRADING_MODE=paper" ];
                ports = [ "100.64.0.6:4002:4002" ];
              };
              joe-board-pusher.image = "hsb0-joe-board-pusher:flat-net-reconcile-perf-202610010310";
            };
          };
          virtualisation.docker.package = "/fixture/docker";
          nixcfg.ibGatewaySession.alert = {
            enable = true;
            transport = "email-agent-bus";
            destinationFile = "/fixture/notification-config";
          };
          networking.firewall.allowedTCPPorts = [ ];
        };
      }
    ];
  };
  cfg = evaluated.config;
  failed = builtins.filter (item: !item.assertion) cfg.assertions;
in
assert lib.assertMsg (failed == [ ]) (lib.concatMapStringsSep "; " (item: item.message) failed);
if tailnetContract then
  {
    executor = cfg.nixcfg.paperDeskExecutor.serviceSpec;
    mailbox = cfg.nixcfg.agentMailbox.serviceSpec;
    sync = cfg.systemd.services.tailnet-peer-sync;
    timer = cfg.systemd.timers.tailnet-peer-sync;
    serviceNames = builtins.attrNames cfg.systemd.services;
    firewallStop = cfg.networking.firewall.extraStopCommands;
    firewall = cfg.networking.firewall.extraCommands;
    staticExecutor = cfg.nixcfg.paperDeskExecutor.peerAllowlist;
    staticMailbox = cfg.nixcfg.agentMailbox.peers;
    rules = cfg.nixcfg.tailnetPeers.rules;
  }
else
  {
    inherit (cfg.nixcfg.paperDeskExecutor) reconRetentionHours resultsHealthPort;
    retentionEnvironment = builtins.filter (
      item: lib.hasPrefix "PAPER_DESK_RECON_RETENTION_HOURS=" item
    ) cfg.nixcfg.paperDeskExecutor.serviceSpec.environment;
  }
