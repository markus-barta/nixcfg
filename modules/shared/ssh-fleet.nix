# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                        Fleet SSH Configuration                              ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Declarative SSH config for all fleet hosts.
#
# 🔴 MagicDNS is OFF by deliberate, permanent decision — its DNS interception was
# breaking agent/API sessions. `*.ts.barta.cm` resolves to NOTHING. This file used
# to lean on those names for every "fallback" and every `-ts` alias, so `ssh csb0`
# failed outright and every LAN alias died the moment you left the LAN (OPS-146).
# Do not reintroduce them.
#
# Routes that actually work:
# - Home hosts     -> LAN address (on-LAN only)
# - Cloud hosts    -> cs0/cs1.barta.cm over public DNS, port 2222 (works anywhere)
# - Anything, off-LAN -> tailnet IP: `tailscale status`, then `ssh mba@100.64.x.y`
#   (cloud keeps -p 2222). IPs are deliberately NOT hardcoded here — read them live.
#
# Usage:
#   ssh hsb0         # LAN
#   ssh hsb0-lan     # LAN, explicit
#   ssh csb0         # cloud via public DNS, from anywhere
#
{
  lib,
  ...
}:
{
  # Force-manage ~/.ssh/config (overwrite any pre-existing manual file)
  home.file.".ssh/config".force = lib.mkDefault true;

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;

    settings = {
      # ═══════════════════════════════════════════════════════════
      # GLOBAL DEFAULTS
      # Replaces Home Manager's enableDefaultConfig with our own values
      # ═══════════════════════════════════════════════════════════
      "*" = {
        forwardAgent = false;
        addKeysToAgent = "no";
        compression = false;
        serverAliveInterval = 0; # Default: disabled (prevents drops during long ops like nixos-rebuild)
        serverAliveCountMax = 3;
        hashKnownHosts = false;
        userKnownHostsFile = "~/.ssh/known_hosts";
        controlMaster = "no";
        controlPath = "~/.ssh/master-%r@%n:%p";
        controlPersist = "no";
      };
      # ═══════════════════════════════════════════════════════════
      # SHARED NON-HOST CONFIG
      # (Per-host Git SSH keys are in each host's home.nix)
      # ═══════════════════════════════════════════════════════════

      "traefik.barta.cm" = {
        hostname = "traefik.barta.cm";
        user = "mba";
      };

      # ═══════════════════════════════════════════════════════════
      # HOME NETWORK HOSTS (192.168.1.0/24) - LAN only; off-LAN use tailnet IP
      # ═══════════════════════════════════════════════════════════

      "hsb0" = {
        hostname = "192.168.1.99";
        user = "mba";
      };
      "hsb0-lan" = {
        hostname = "192.168.1.99";
        user = "mba";
      };
      "hsb0-markus" = {
        hostname = "192.168.1.99";
        user = "markus";
      };
      "hsb0-markus-lan" = {
        hostname = "hsb0.lan";
        user = "markus";
      };
      "hsb0-markus-ip" = {
        hostname = "192.168.1.99";
        user = "markus";
      };

      "hsb1" = {
        hostname = "192.168.1.101";
        user = "mba";
      };
      "hsb1-lan" = {
        hostname = "192.168.1.101";
        user = "mba";
      };
      "hsb1-markus" = {
        hostname = "192.168.1.101";
        user = "markus";
      };
      "hsb1-markus-lan" = {
        hostname = "hsb1.lan";
        user = "markus";
      };
      "hsb1-markus-ip" = {
        hostname = "192.168.1.101";
        user = "markus";
      };

      "hsb8" = {
        hostname = "192.168.1.100";
        user = "mba";
      };
      "hsb8-lan" = {
        hostname = "192.168.1.100";
        user = "mba";
      };
      "hsb8-markus" = {
        hostname = "192.168.1.100";
        user = "markus";
      };
      "hsb8-markus-lan" = {
        hostname = "hsb8.lan";
        user = "markus";
      };
      "hsb8-markus-ip" = {
        hostname = "192.168.1.100";
        user = "markus";
      };

      # hsb9 = parents-in-law (Mac mini Late 2009), live at .200 since 2026-05-31.
      # Reachable on that LAN only; from here use its tailnet IP.
      "hsb9" = {
        hostname = "192.168.1.200";
        user = "mba";
      };
      "hsb9-lan" = {
        hostname = "192.168.1.200";
        user = "mba";
      };
      "hsb9-markus" = {
        hostname = "192.168.1.200";
        user = "markus";
      };
      "hsb9-markus-lan" = {
        hostname = "hsb9.lan";
        user = "markus";
      };
      "hsb9-markus-ip" = {
        hostname = "192.168.1.200";
        user = "markus";
      };

      # hsb2 (Pi Zero W, .95) retired 2026-06-14 — aliases removed 2026-08-07
      # with its Headscale node (OPS-59). History: flake.nix + hsb1/ir-bridge.nix.

      # ═══════════════════════════════════════════════════════════
      # CLOUD HOSTS - public DNS on :2222 (no LAN); works from anywhere
      # ═══════════════════════════════════════════════════════════

      "csb0" = {
        hostname = "cs0.barta.cm";
        user = "mba";
        port = 2222; # Non-standard SSH port
      };
      "csb0-markus" = {
        hostname = "cs0.barta.cm";
        user = "markus";
        port = 2222;
      };
      "csb0-markus-ip" = {
        hostname = "89.58.63.96";
        user = "markus";
        port = 2222;
      };

      "csb1" = {
        hostname = "cs1.barta.cm";
        user = "mba";
        port = 2222; # Non-standard SSH port
      };
      "csb1-markus" = {
        hostname = "cs1.barta.cm";
        user = "markus";
        port = 2222;
      };
      "csb1-markus-ip" = {
        hostname = "152.53.64.166";
        user = "markus";
        port = 2222;
      };

      # ═══════════════════════════════════════════════════════════
      # BONELIO HETZNER HOSTS (public IPs, per-customer ed25519 key)
      # Matched the former work repo's staging helper (context retired June 2026)
      # ═══════════════════════════════════════════════════════════

      "bonelio-staging" = {
        hostname = "91.99.190.56";
        user = "root";
        identityFile = "~/.ssh/bp_bonelio_ed25519";
      };
    };
  };
}
