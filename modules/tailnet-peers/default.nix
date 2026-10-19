# OPS-384: shared host identity source for the two hsb0 desk services.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixcfg.tailnetPeers;
  notifier = config.nixcfg.ibGatewaySession.alert or { };
  staticPeers = config.nixcfg.agentMailbox.peers or { "100.64.0.14" = "ops"; };
  source = pkgs.runCommand "tailnet-peer-sync-source" { } ''
    mkdir -p "$out"
    cp ${./sync.py} "$out/sync.py"
    # Tool paths are build-time constants, never settings data (CodeQL py/command-line-injection).
    substituteInPlace "$out/sync.py" \
      --replace-fail '@tailscale@' '${pkgs.tailscale}/bin/tailscale' \
      --replace-fail '@iptablesRestore@' '${config.networking.firewall.package}/bin/iptables-restore' \
      --replace-fail '@iptablesSave@' '${config.networking.firewall.package}/bin/iptables-save' \
      --replace-fail '@docker@' '${config.virtualisation.docker.package}/bin/docker'
    cp ${../ib-gateway-session/notification_delivery.py} "$out/notification_delivery.py"
  '';
  settings = pkgs.writeText "tailnet-peer-sync.json" (
    builtins.toJSON {
      inherit (cfg) rules staleSeconds;
      address = "100.64.0.6";
      reserved = lib.unique (
        lib.attrNames staticPeers
        ++ config.nixcfg.paperDeskExecutor.peerAllowlist
        ++ config.nixcfg.paperDeskExecutor.adminPeerAllowlist
      );
    }
  );
  trigger = "${pkgs.systemd}/bin/systemctl --no-block start tailnet-peer-sync.service";
in
{
  options.nixcfg.tailnetPeers = {
    enable = lib.mkEnableOption "host-side paper desk tailnet identity admission";
    rules = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            tag = lib.mkOption { type = lib.types.strMatching "tag:[a-z0-9-]+"; };
            host = lib.mkOption {
              type = lib.types.nullOr (lib.types.strMatching "[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}");
              default = null;
            };
            identity = lib.mkOption { type = lib.types.strMatching "[a-z][a-z0-9_-]{0,31}"; };
          };
        }
      );
      default = [
        {
          tag = "tag:paper-desk";
          host = "grok-amy-box";
          identity = "amy";
        }
      ];
      description = "Each admission requires a tag and, when specified, an exact Tailscale HostName.";
    };
    staleSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "Grace for a peer absent from an otherwise valid status; tag removal revokes immediately.";
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          cfg.rules != [ ]
          && lib.length cfg.rules <= 32
          && lib.all (
            rule:
            !(lib.elem rule.identity [
              "constructor"
              "prototype"
              "__proto__"
            ])
          ) cfg.rules;
        message = "tailnetPeers requires bounded safe identity rules";
      }
      {
        assertion =
          (notifier.enable or false)
          && (notifier.transport or "none") == "email-agent-bus"
          && (notifier.destinationFile or null) != null;
        message = "tailnetPeers requires hsb0's existing managed email notification adapter";
      }
    ];
    networking.firewall.extraCommands = lib.mkAfter "${trigger} || true";
    # Both consumers use uid 1000; allow traversal to their owner-only snapshot.
    # Root owns the directory and state, so consumers cannot replace either file.
    systemd.tmpfiles.rules = [ "d /run/tailnet-peers 0710 root 1000 - -" ];
    systemd.services = {
      tailnet-peer-sync = {
        description = "Synchronize paper desk admission from tailnet tags (OPS-384)";
        after = [
          "tailscaled.service"
          "firewall.service"
        ];
        wantedBy = [ "tailscaled.service" ];
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          UMask = "0077";
          ExecStart = "${pkgs.python3}/bin/python3 ${source}/sync.py --config ${settings} --notification-config ${
            toString (notifier.destinationFile or "/missing")
          }";
          TimeoutStartSec = 90;
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = [
            "/run/tailnet-peers"
            "/run/lock"
          ];
          PrivateTmp = true;
        };
      };
    };
    systemd.timers.tailnet-peer-sync = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "15s";
        OnUnitActiveSec = "30s";
        AccuracySec = "1s";
        Unit = "tailnet-peer-sync.service";
      };
    };
  };
}
