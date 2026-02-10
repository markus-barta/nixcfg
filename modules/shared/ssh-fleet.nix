# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                   Fleet SSH Configuration with Tailscale Fallback           ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Declarative SSH config for all fleet hosts with automatic LAN→Tailscale fallback.
#
# Features:
# - Auto-fallback: Try LAN first (2s timeout), fallback to Tailscale
# - Explicit routes: Use -lan or -ts suffix to force specific route
# - Nicknames: Short aliases for long hostnames (mbpw → mba-mbp-work)
# - Keep-alive: 60s ping to prevent connection timeout
#
# Usage:
#   ssh hsb0         # Auto: Try LAN, fallback to Tailscale
#   ssh hsb0-lan     # Force LAN only
#   ssh hsb0-ts      # Force Tailscale only
#   ssh mbpw         # Nickname → mba-mbp-work
#
{
  ...
}:
{
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;

    matchBlocks = {
      # ═══════════════════════════════════════════════════════════
      # GLOBAL DEFAULTS (keep-alive settings for all hosts)
      # ═══════════════════════════════════════════════════════════
      "*" = {
        serverAliveInterval = 60; # Send ping every 60s
        serverAliveCountMax = 3; # Disconnect after 3 failed pings (3min total)
      };
      # ═══════════════════════════════════════════════════════════
      # EXISTING MANUAL CONFIG (preserved from ~/.ssh/config)
      # ═══════════════════════════════════════════════════════════

      "github-bp" = {
        hostname = "github.com";
        user = "git";
        identityFile = "~/.ssh/id_ed25519_bytepoets";
      };

      "github.com" = {
        hostname = "github.com";
        user = "git";
        identityFile = "~/.ssh/id_rsa";
      };

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
        proxyCommand = "sh -c 'nc -w2 %h %p || nc hsb0.ts.barta.cm %p'";
      };
      "hsb0-lan" = {
        hostname = "192.168.1.99";
        user = "mba";
      };
      "hsb0-ts" = {
        hostname = "hsb0.ts.barta.cm";
        user = "mba";
      };

      "hsb1" = {
        hostname = "192.168.1.101";
        user = "mba";
        proxyCommand = "sh -c 'nc -w2 %h %p || nc hsb1.ts.barta.cm %p'";
      };
      "hsb1-lan" = {
        hostname = "192.168.1.101";
        user = "mba";
      };
      "hsb1-ts" = {
        hostname = "hsb1.ts.barta.cm";
        user = "mba";
      };

      "hsb8" = {
        hostname = "192.168.1.100";
        user = "mba";
        proxyCommand = "sh -c 'nc -w2 %h %p || nc hsb8.ts.barta.cm %p'";
      };
      "hsb8-lan" = {
        hostname = "192.168.1.100";
        user = "mba";
      };
      "hsb8-ts" = {
        hostname = "hsb8.ts.barta.cm";
        user = "mba";
      };

      "hsb2" = {
        hostname = "192.168.1.95";
        user = "mba";
        proxyCommand = "sh -c 'nc -w2 %h %p || nc hsb2.ts.barta.cm %p'";
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
        proxyCommand = "sh -c 'nc -w2 %h %p || nc gpc0.ts.barta.cm %p'";
      };
      "gpc0-lan" = {
        hostname = "192.168.1.154";
        user = "mba";
      };
      "gpc0-ts" = {
        hostname = "gpc0.ts.barta.cm";
        user = "mba";
      };

      "imac0" = {
        hostname = "192.168.1.150";
        user = "markus"; # Note: user is markus, not mba!
        proxyCommand = "sh -c 'nc -w2 %h %p || nc imac0.ts.barta.cm %p'";
      };
      "imac0-lan" = {
        hostname = "192.168.1.150";
        user = "markus";
      };
      "imac0-ts" = {
        hostname = "imac0.ts.barta.cm";
        user = "markus";
      };

      # ═══════════════════════════════════════════════════════════
      # PORTABLE HOST - Location-dependent (home network when docked)
      # ═══════════════════════════════════════════════════════════

      "mba-mbp-work" = {
        hostname = "192.168.1.197"; # When at home
        user = "mba";
        proxyCommand = "sh -c 'nc -w2 %h %p || nc mba-mbp-work.ts.barta.cm %p'";
      };
      "mba-mbp-work-lan" = {
        hostname = "192.168.1.197";
        user = "mba";
      };
      "mba-mbp-work-ts" = {
        hostname = "mba-mbp-work.ts.barta.cm";
        user = "mba";
      };

      # Nickname: mbpw → mba-mbp-work
      "mbpw" = {
        hostname = "mba-mbp-work";
      };
      "mbpw-lan" = {
        hostname = "192.168.1.197";
        user = "mba";
      };
      "mbpw-ts" = {
        hostname = "mba-mbp-work.ts.barta.cm";
        user = "mba";
      };

      # ═══════════════════════════════════════════════════════════
      # WORK NETWORK HOSTS (10.17.0.0/16 BYTEPOETS) - LAN with TS fallback
      # ═══════════════════════════════════════════════════════════

      "mba-imac-work" = {
        hostname = "10.17.1.7";
        user = "markus"; # Note: user is markus, not mba!
        proxyCommand = "sh -c 'nc -w2 %h %p || nc mba-imac-work.ts.barta.cm %p'";
      };
      "mba-imac-work-lan" = {
        hostname = "10.17.1.7";
        user = "markus";
      };
      "mba-imac-work-ts" = {
        hostname = "mba-imac-work.ts.barta.cm";
        user = "markus";
      };

      # Nickname: imacw → mba-imac-work
      "imacw" = {
        hostname = "mba-imac-work";
      };
      "imacw-lan" = {
        hostname = "10.17.1.7";
        user = "markus";
      };
      "imacw-ts" = {
        hostname = "mba-imac-work.ts.barta.cm";
        user = "markus";
      };

      "miniserver-bp" = {
        hostname = "10.17.1.40";
        user = "mba";
        proxyCommand = "sh -c 'nc -w2 %h %p || nc miniserver-bp.ts.barta.cm %p'";
      };
      "miniserver-bp-lan" = {
        hostname = "10.17.1.40";
        user = "mba";
      };
      "miniserver-bp-ts" = {
        hostname = "miniserver-bp.ts.barta.cm";
        user = "mba";
      };

      # Nickname: msbp → miniserver-bp
      "msbp" = {
        hostname = "miniserver-bp";
      };
      "msbp-lan" = {
        hostname = "10.17.1.40";
        user = "mba";
      };
      "msbp-ts" = {
        hostname = "miniserver-bp.ts.barta.cm";
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
    };
  };
}
