# Poller heartbeat — OPS-107.
#
# WHY THIS EXISTS
# ===============
# csb0 watches the three Home Assistant instances and csb1 watches HAUSV. Neither
# watched the other, and neither watched itself, so if a poller stopped its
# silence was indistinguishable from "everything is fine". That is the same
# failure this fleet has now been bitten by three times: hsb8's Tesla integration
# dead four days, hsb1's Nix store wedged 16 days, hsb0's ncps-warmer failed three
# days -- all silent, all found by accident.
#
# WHAT IT IS
# ==========
# Each poller already stamps its state file every run, so the heartbeat needs no
# new data -- only a way for the peer to read the mtime. This exposes exactly that
# integer over the tailnet, and nothing else.
#
# Raw TCP, not HTTP: the payload is one number. A socket-activated one-liner beats
# a daemon and an HTTP stack for that.
#
# No credentials: the tailnet is authenticated at the network layer, so only fleet
# hosts can reach 100.64.0.0/10, and the firewall opens this port on tailscale0
# ONLY -- never on the public interface. csb0 and csb1 both face the internet.
#
# WHY THE PEER, NOT ITSELF
# ========================
# A host cannot detect its own death. csb0's freshness is therefore checked BY
# csb1 and vice versa, and each reports through its own already-working Telegram
# path. Residual gap, accepted: both cloud hosts down simultaneously pages nobody
# -- that needs a third party outside the estate.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixcfg.fleetAlerts.heartbeat;
in
{
  options.nixcfg.fleetAlerts.heartbeat = {
    enable = lib.mkEnableOption "poller heartbeat endpoint (OPS-107)";

    statePath = lib.mkOption {
      type = lib.types.str;
      description = "State file whose mtime is this host's heartbeat.";
    };

    tailnetAddress = lib.mkOption {
      type = lib.types.str;
      description = ''
        Tailnet IP to bind. Explicit rather than wildcard so the endpoint can
        never be served on the public interface. MagicDNS is permanently off
        fleet-wide, so this is an address, not a name -- re-check with
        `tailscale status` if a host is replaced.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9107;
      description = "Port for the heartbeat (9107 = OPS-107).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.sockets.fleet-heartbeat = {
      description = "Poller heartbeat socket (OPS-107)";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = "${cfg.tailnetAddress}:${toString cfg.port}";
        # tailscale0 may not exist yet when sockets.target is reached; FreeBind
        # lets the socket bind the address anyway instead of failing at boot.
        FreeBind = true;
        Accept = true;
      };
    };

    # Accept = true means systemd hands each connection's stdout to the client,
    # so printing the mtime is the entire protocol.
    systemd.services."fleet-heartbeat@" = {
      description = "Report this host's poller heartbeat (OPS-107)";
      serviceConfig = {
        StandardOutput = "socket";
        ExecStart = "${pkgs.writeShellScript "fleet-heartbeat" ''
          # Epoch seconds of the last poll, or 0 if the poller has never run.
          if [ -e ${lib.escapeShellArg cfg.statePath} ]; then
            ${pkgs.coreutils}/bin/stat -c %Y ${lib.escapeShellArg cfg.statePath}
          else
            echo 0
          fi
        ''}";
        # Read-only, single integer, no secrets in reach.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };
    };

    # tailscale0 only. Never the public interface -- these are internet-facing hosts.
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ cfg.port ];
  };
}
