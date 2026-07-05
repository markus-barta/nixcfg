# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                   Fleet SSH Configuration with Tailscale Fallback           ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Declarative SSH config for all fleet hosts with automatic LAN→Tailscale fallback.
#
# Features:
# - Auto-fallback: Try LAN first (2s timeout), fallback to Tailscale
# - Explicit routes: Use -lan or -ts suffix to force specific route
# - Nicknames: Short aliases for long hostnames
# - Keep-alive: 60s ping to prevent connection timeout
#
# Usage:
#   ssh hsb0         # Auto: Try LAN, fallback to Tailscale
#   ssh hsb0-lan     # Force LAN only
#   ssh hsb0-ts      # Force Tailscale only
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
      # HOME NETWORK HOSTS (192.168.1.0/24) - LAN with TS fallback
      # ═══════════════════════════════════════════════════════════

      "hsb0" = {
        hostname = "192.168.1.99";
        user = "mba";
        proxyCommand = "sh -c 'if nc -z -w2 %h %p 2>/dev/null; then nc %h %p; else nc hsb0.ts.barta.cm %p; fi'";
      };
      "hsb0-lan" = {
        hostname = "192.168.1.99";
        user = "mba";
      };
      "hsb0-ts" = {
        hostname = "hsb0.ts.barta.cm";
        user = "mba";
      };
      "hsb0-markus" = {
        hostname = "192.168.1.99";
        user = "markus";
        proxyCommand = "sh -c 'if nc -z -w2 %h %p 2>/dev/null; then nc %h %p; else nc hsb0.ts.barta.cm %p; fi'";
      };
      "hsb0-markus-lan" = {
        hostname = "hsb0.lan";
        user = "markus";
      };
      "hsb0-markus-ip" = {
        hostname = "192.168.1.99";
        user = "markus";
      };
      "hsb0-markus-ts" = {
        hostname = "hsb0.ts.barta.cm";
        user = "markus";
      };

      "hsb1" = {
        hostname = "192.168.1.101";
        user = "mba";
        proxyCommand = "sh -c 'if nc -z -w2 %h %p 2>/dev/null; then nc %h %p; else nc hsb1.ts.barta.cm %p; fi'";
      };
      "hsb1-lan" = {
        hostname = "192.168.1.101";
        user = "mba";
      };
      "hsb1-ts" = {
        hostname = "hsb1.ts.barta.cm";
        user = "mba";
      };
      "hsb1-markus" = {
        hostname = "192.168.1.101";
        user = "markus";
        proxyCommand = "sh -c 'if nc -z -w2 %h %p 2>/dev/null; then nc %h %p; else nc hsb1.ts.barta.cm %p; fi'";
      };
      "hsb1-markus-lan" = {
        hostname = "hsb1.lan";
        user = "markus";
      };
      "hsb1-markus-ip" = {
        hostname = "192.168.1.101";
        user = "markus";
      };
      "hsb1-markus-ts" = {
        hostname = "hsb1.ts.barta.cm";
        user = "markus";
      };

      "hsb8" = {
        hostname = "192.168.1.100";
        user = "mba";
        proxyCommand = "sh -c 'if nc -z -w2 %h %p 2>/dev/null; then nc %h %p; else nc hsb8.ts.barta.cm %p; fi'";
      };
      "hsb8-lan" = {
        hostname = "192.168.1.100";
        user = "mba";
      };
      "hsb8-ts" = {
        hostname = "hsb8.ts.barta.cm";
        user = "mba";
      };
      "hsb8-markus" = {
        hostname = "192.168.1.100";
        user = "markus";
        proxyCommand = "sh -c 'if nc -z -w2 %h %p 2>/dev/null; then nc %h %p; else nc hsb8.ts.barta.cm %p; fi'";
      };
      "hsb8-markus-lan" = {
        hostname = "hsb8.lan";
        user = "markus";
      };
      "hsb8-markus-ip" = {
        hostname = "192.168.1.100";
        user = "markus";
      };
      "hsb8-markus-ts" = {
        hostname = "hsb8.ts.barta.cm";
        user = "markus";
      };

      # hsb9 = parents-in-law (Mac mini Late 2009). LAN .200 is the target at
      # parents-in-law; while still at jhw22 (.203) the TS fallback wins.
      "hsb9" = {
        hostname = "192.168.1.200";
        user = "mba";
        proxyCommand = "sh -c 'if nc -z -w2 %h %p 2>/dev/null; then nc %h %p; else nc hsb9.ts.barta.cm %p; fi'";
      };
      "hsb9-lan" = {
        hostname = "192.168.1.200";
        user = "mba";
      };
      "hsb9-ts" = {
        hostname = "hsb9.ts.barta.cm";
        user = "mba";
      };
      "hsb9-markus" = {
        hostname = "192.168.1.200";
        user = "markus";
        proxyCommand = "sh -c 'if nc -z -w2 %h %p 2>/dev/null; then nc %h %p; else nc hsb9.ts.barta.cm %p; fi'";
      };
      "hsb9-markus-lan" = {
        hostname = "hsb9.lan";
        user = "markus";
      };
      "hsb9-markus-ip" = {
        hostname = "192.168.1.200";
        user = "markus";
      };
      "hsb9-markus-ts" = {
        hostname = "hsb9.ts.barta.cm";
        user = "markus";
      };

      "hsb2" = {
        hostname = "192.168.1.95";
        user = "mba";
        proxyCommand = "sh -c 'if nc -z -w2 %h %p 2>/dev/null; then nc %h %p; else nc hsb2.ts.barta.cm %p; fi'";
      };
      "hsb2-lan" = {
        hostname = "192.168.1.95";
        user = "mba";
      };
      "hsb2-ts" = {
        hostname = "hsb2.ts.barta.cm";
        user = "mba";
      };

      "gpc0" = {
        hostname = "192.168.1.154";
        user = "mba";
        proxyCommand = "sh -c 'if nc -z -w2 %h %p 2>/dev/null; then nc %h %p; else nc gpc0.ts.barta.cm %p; fi'";
      };
      "gpc0-lan" = {
        hostname = "192.168.1.154";
        user = "mba";
      };
      "gpc0-ts" = {
        hostname = "gpc0.ts.barta.cm";
        user = "mba";
      };
      "gpc0-markus" = {
        hostname = "192.168.1.154";
        user = "markus";
        proxyCommand = "sh -c 'if nc -z -w2 %h %p 2>/dev/null; then nc %h %p; else nc gpc0.ts.barta.cm %p; fi'";
      };
      "gpc0-markus-lan" = {
        hostname = "gpc0.lan";
        user = "markus";
      };
      "gpc0-markus-ip" = {
        hostname = "192.168.1.154";
        user = "markus";
      };
      "gpc0-markus-ts" = {
        hostname = "gpc0.ts.barta.cm";
        user = "markus";
      };

      "miniserver-bp" = {
        hostname = "10.17.1.40";
        port = 2222;
        user = "mba";
        proxyCommand = "sh -c 'if nc -z -w2 %h %p 2>/dev/null; then nc %h %p; else nc miniserver-bp.ts.barta.cm %p; fi'";
      };
      "miniserver-bp-lan" = {
        hostname = "10.17.1.40";
        port = 2222;
        user = "mba";
      };
      "miniserver-bp-ts" = {
        hostname = "miniserver-bp.ts.barta.cm";
        port = 2222;
        user = "mba";
      };

      # Nickname: msbp → miniserver-bp (Tailscale: works from anywhere)
      "msbp" = {
        hostname = "miniserver-bp.ts.barta.cm";
        port = 2222;
        user = "mba";
      };
      "msbp-lan" = {
        hostname = "10.17.1.40";
        port = 2222;
        user = "mba";
      };
      "msbp-ts" = {
        hostname = "miniserver-bp.ts.barta.cm";
        port = 2222;
        user = "mba";
      };

      # ═══════════════════════════════════════════════════════════
      # CLOUD HOSTS - Tailscale only (no LAN)
      # ═══════════════════════════════════════════════════════════

      "csb0" = {
        hostname = "csb0.ts.barta.cm";
        user = "mba";
        port = 2222; # Non-standard SSH port
      };
      "csb0-ts" = {
        hostname = "csb0.ts.barta.cm";
        user = "mba";
        port = 2222;
      };
      "csb0-markus" = {
        hostname = "cs0.barta.cm";
        user = "markus";
        port = 2222;
      };
      "csb0-markus-ip" = {
        hostname = "85.235.65.226";
        user = "markus";
        port = 2222;
      };
      "csb0-markus-ts" = {
        hostname = "csb0.ts.barta.cm";
        user = "markus";
        port = 2222;
      };

      "csb1" = {
        hostname = "csb1.ts.barta.cm";
        user = "mba";
        port = 2222; # Non-standard SSH port
      };
      "csb1-ts" = {
        hostname = "csb1.ts.barta.cm";
        user = "mba";
        port = 2222;
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
      "csb1-markus-ts" = {
        hostname = "csb1.ts.barta.cm";
        user = "markus";
        port = 2222;
      };

      # dsc0 (Ocean) lives in the dsccfg fleet, not nixcfg — tailnet-only,
      # port 2222, and only authorizes the dedicated dsccfg deploy key.
      # identitiesOnly avoids "too many auth failures" from the default keys.
      "dsc0" = {
        hostname = "dsc0.ts.barta.cm";
        user = "mba";
        port = 2222;
        identityFile = "~/.ssh/dsccfg_deploy";
        identitiesOnly = true;
      };
      "dsc0-ts" = {
        hostname = "dsc0.ts.barta.cm";
        user = "mba";
        port = 2222;
        identityFile = "~/.ssh/dsccfg_deploy";
        identitiesOnly = true;
      };

      # ═══════════════════════════════════════════════════════════
      # BONELIO HETZNER HOSTS (public IPs, per-customer ed25519 key)
      # Matches `just ssh-staging` in ~/Code/bpnixcfg
      # ═══════════════════════════════════════════════════════════

      "bonelio-staging" = {
        hostname = "91.99.190.56";
        user = "root";
        identityFile = "~/.ssh/bp_bonelio_ed25519";
      };
    };
  };
}
