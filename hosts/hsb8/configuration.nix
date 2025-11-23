# hsb8 server - Parents' home automation server
{
  pkgs,
  lib,
  inputs,
  ...
}:
let
  # ============================================================================
  # LOCATION CONFIGURATION
  # ============================================================================
  # Set location before deploying:
  # - "jhw22" = Markus' home (192.168.1.5 gateway, uses miniserver99 DNS)
  # - "ww87"  = Parents' home (192.168.1.1 gateway, runs local AdGuard DNS)
  location = "jhw22"; # <-- CHANGE THIS WHEN MOVING MACHINE

  # Location-specific network settings
  gatewayIP =
    if location == "jhw22" then
      "192.168.1.5" # Markus' home: Fritz!Box
    else
      "192.168.1.1"; # Parents' home: Router

  dnsServers =
    if location == "jhw22" then
      [
        "192.168.1.99" # Markus' home: miniserver99 (AdGuard Home)
        "1.1.1.1" # Cloudflare fallback
      ]
    else
      [
        "127.0.0.1" # Parents' home: Local AdGuard Home
        "1.1.1.1" # Cloudflare fallback
      ];

  # AdGuard Home enabled only at parents' home
  enableAdGuard = location == "ww87";
in
{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.zfs.nix
  ];

  # Validate location setting
  assertions = [
    {
      assertion = location == "jhw22" || location == "ww87";
      message = "location must be either 'jhw22' (Markus home) or 'ww87' (Parents home). Current: ${location}";
    }
  ];

  # Network configuration with location-specific settings
  networking = {
    defaultGateway = gatewayIP;
    nameservers = dnsServers;
    search = if location == "ww87" then [ "local" ] else [ "lan" ];

    # Static IP: 192.168.1.100 (same at both locations)
    interfaces.enp2s0f0 = {
      ipv4.addresses = [
        {
          address = "192.168.1.100";
          prefixLength = 24;
        }
      ];
    };

    # Tell NetworkManager to not manage this interface (it's statically configured)
    networkmanager.unmanaged = [ "enp2s0f0" ];

    # Explicitly disable DHCP on this interface
    useDHCP = false;
    interfaces.enp2s0f0.useDHCP = false;

    # Firewall configuration
    firewall = {
      enable = true;
      allowedTCPPorts = [
        80 # HTTP
        443 # HTTPS
        8883 # MQTT
      ]
      ++ lib.optionals enableAdGuard [
        53 # DNS (AdGuard Home)
        3000 # AdGuard Home web interface
      ];
      allowedUDPPorts = [
        443 # HTTPS
      ]
      ++ lib.optionals enableAdGuard [
        53 # DNS (AdGuard Home)
        67 # DHCP (AdGuard Home - if enabled)
      ];
    };
  };

  # AdGuard Home - DNS and DHCP server with ad-blocking (only at parents' home)
  # Based on miniserver99's proven configuration
  # Web interface: http://192.168.1.100:3000
  services.adguardhome = lib.mkIf enableAdGuard {
    enable = true;
    host = "0.0.0.0";
    port = 3000;
    mutableSettings = false; # Use declarative configuration
    settings = {
      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = 53;
        # Use Cloudflare DNS as upstream
        bootstrap_dns = [
          "1.1.1.1"
          "1.0.0.1"
        ];
        upstream_dns = [
          "1.1.1.1"
          "1.0.0.1"
        ];
        # Enable DNS cache
        cache_size = 4194304; # 4MB
        cache_ttl_min = 0;
        cache_ttl_max = 0;
        cache_optimistic = true;
      };

      rewrites = [ ];

      # Admin user with password 'admin' (bcrypt hash)
      user_rules = [ ];

      users = [
        {
          name = "admin";
          password = "$2y$05$6tWeTokm6nLLq7nTIpeQn.J9ln.4CWK9HDyhJzY.w6qAk4CmEpUNy";
        }
      ];

      dhcp = {
        enabled = false; # TODO: Enable when ready to be DHCP server
        interface_name = "enp2s0f0";
        dhcpv4 = {
          gateway_ip = "192.168.1.1";
          subnet_mask = "255.255.255.0";
          range_start = "192.168.1.201";
          range_end = "192.168.1.254";
          lease_duration = 86400; # 24 hours
          icmp_timeout_msec = 1000;

          # Add DHCP Option 15 (domain name)
          # Format: "option_code type value"
          # See: https://github.com/AdguardTeam/AdGuardHome/wiki/DHCP
          options = [
            "15 text local"
          ];

          # Static DHCP leases would be managed via agenix (when DHCP enabled)
          # See preStart script below for implementation
          static_leases = [ ];
        };
      };

      # Filtering settings
      filtering = {
        protection_enabled = true;
        filtering_enabled = true;
      };

      # Query log settings
      querylog = {
        enabled = true;
        interval = "2160h"; # 90 days
        size_memory = 1000;
      };

      # Statistics
      statistics = {
        enabled = true;
        interval = "2160h"; # 90 days
      };
    };
  };

  # Static DHCP Leases Management (when AdGuard DHCP is enabled at parents' home)
  # Leases are stored encrypted in git and decrypted at system activation
  # Based on miniserver99's proven implementation
  # systemd.services.adguardhome.preStart = lib.mkIf (enableAdGuard && config.services.adguardhome.settings.dhcp.enabled) (lib.mkAfter ''
  #   leases_dir="/var/lib/private/AdGuardHome/data"
  #   leases_file="$leases_dir/leases.json"
  #   install -d "$leases_dir"
  #
  #   # Read static leases from agenix-decrypted JSON file
  #   static_leases_file="/run/agenix/static-leases-msww87"
  #
  #   if [ ! -f "$static_leases_file" ]; then
  #     echo "ERROR: Static leases file not found at $static_leases_file"
  #     exit 1
  #   fi
  #
  #   if ! ${pkgs.jq}/bin/jq empty "$static_leases_file" 2>/dev/null; then
  #     echo "ERROR: Invalid JSON in static leases file: $static_leases_file"
  #     exit 1
  #   fi
  #
  #   tmp="$(mktemp)"
  #   if [ -f "$leases_file" ]; then
  #     ${pkgs.jq}/bin/jq --argjson static "$(cat "$static_leases_file")" '
  #       def normalize_mac($mac): ($mac | ascii_downcase);
  #       def static_entries: $static | map(.mac |= normalize_mac(.));
  #       def without_static($list):
  #         ($list // [])
  #         | map(
  #             (.mac | ascii_downcase) as $m
  #             | (.static // false) as $is_static
  #             | (static_entries | map(.mac) | index($m)) as $idx
  #             | select($idx == null and ($is_static | not))
  #           );
  #       def build_static:
  #         static_entries | map(. + {static: true, expires: ""});
  #       {version: (.version // 1), leases: without_static(.leases) + build_static}
  #     ' "$leases_file" > "$tmp"
  #   else
  #     ${pkgs.jq}/bin/jq --argjson static "$(cat "$static_leases_file")" '
  #       {version: 1, leases: ($static | map(. + {static: true, expires: ""}))}
  #     ' <<< '{}' > "$tmp"
  #   fi
  #
  #   mv "$tmp" "$leases_file"
  #   echo "✓ Loaded $(${pkgs.jq}/bin/jq '[.leases[] | select(.static == true)] | length' "$leases_file") static DHCP leases"
  # '');

  # ============================================================================
  # SSH KEY CONFIGURATION - Override hokage defaults
  # ============================================================================
  # The hokage server-home module auto-injects external SSH keys (omega@*).
  # We use lib.mkForce to REPLACE (not append) with our own keys only.
  #
  # Security Policy:
  # - hsb8: Only mba (Markus) + gb (Gerhard/father) keys
  # - NO external access (omega/Yubikey) on personal/family servers
  # ============================================================================

  users.users.mba = {
    openssh.authorizedKeys.keys = lib.mkForce [
      # Markus' SSH key
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H1iVXWYKnHkxQsS7tGsZq3SoHxlVccd+kroMC/DhC4MWwVnJInWwDpo/bz7LiLuh+1Bmq04PswD78EiHVVQ+O7Ckk32heWrywD2vufihukhKRTy5zl6uodb5+oa8PBholTnw09d3M0gbsVKfLEi4NDlgPJiiQsIU00ct/y42nI0s1wXhYn/Oudfqh0yRfGvv2DZowN+XGkxQQ5LSCBYYabBK/W9imvqrxizttw02h2/u3knXcsUpOEhcWJYHHn/0mw33tl6a093bT2IfFPFb3LE2KxUjVqwIYz8jou8cb0F/1+QJVKtqOVLMvDBMqyXAhCkvwtEz13KEyt" # mba@markus
    ];
  };

  users.users.gb = {
    openssh.authorizedKeys.keys = lib.mkForce [
      # Gerhard's (father) SSH key
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDAwgtI71qYnLJnq0PPs/PWR0O+0zvEQfT7QYaHbrPUdILnK5jqZTj6o02kyfce6JLk+xyYhI596T6DD9But943cKFY/cYG037EjlECq+LXdS7bRsb8wYdc8vjcyF21Ol6gSJdT3noAzkZnqnucnvd7D1lae2ZVw7km6GQvz5XQGS/LQ38JpPZ2JYb0ufT3Z1vgigq9GqhCU6C7NdUslJJJ1Lj4JfPqQTbS1ihZqMe3SQ+ctfmHNYniUkd5Potu7wLMG1OJDL13BXu/M5IihgerZ3QuPb2VPQkb37oxKfquMKveYL9bt4fmK+7+CRHJnzFB45HfG5PiTKsyjuPR5A1N3U5Os+9Wrav9YrqDHWjCaFI1EIY4HRM/kRufD+0ncvvXpsp4foS9DAhK5g3OObRlKgPEc4hkD7hC2KBXUt7Kyg6SLL89gD42qSXLxZlxaTD65UaqB28PuOt7+LtKEPhm1jfH65cKu5vGqUp3145hSJuHB4FuA0ieplfxO78psVM=" # gb@gerhard
    ];
  };

  # Helper script to enable ww87 location (for moving to parents' home)
  environment.systemPackages = [
    (pkgs.writeScriptBin "enable-ww87" ''
      #!/usr/bin/env bash
      set -euo pipefail

      # ============================================================================
      # enable-ww87 - Switch hsb8 to Parents' Home Configuration
      # ============================================================================
      # This script switches the server to "ww87" location configuration:
      # - Changes gateway from 192.168.1.5 → 192.168.1.1
      # - Enables AdGuard Home (DNS + DHCP server)
      # - Changes search domain from "lan" → "local"
      # - Switches DNS from miniserver99 → local AdGuard
      #
      # DHCP is DISABLED by default for safety. To enable DHCP:
      # 1. Edit ~/nixcfg/hosts/hsb8/configuration.nix
      # 2. Find: dhcp.enabled = false
      # 3. Change to: dhcp.enabled = true
      # 4. Run: nixos-rebuild switch --flake ~/nixcfg#hsb8
      # ============================================================================

      NIXCFG_DIR="$HOME/nixcfg"
      CONFIG_FILE="$NIXCFG_DIR/hosts/hsb8/configuration.nix"

      echo "🏠 Enabling ww87 (Parents' Home) Configuration..."
      echo

      # Check if we're already at ww87
      if grep -q 'location = "ww87"' "$CONFIG_FILE"; then
        echo "✅ Already configured for ww87 location!"
        echo
        echo "Current configuration:"
        echo "  - Location: ww87 (Parents' home)"
        echo "  - Gateway: 192.168.1.1"
        echo "  - DNS: 127.0.0.1 (local AdGuard Home)"
        echo "  - Search: local"
        echo
        systemctl is-active adguardhome >/dev/null 2>&1 && echo "  - AdGuard Home: ✅ Running" || echo "  - AdGuard Home: ⚠️  Not running"
        echo
        echo "To enable DHCP, edit:"
        echo "  $CONFIG_FILE"
        echo "  (Change 'dhcp.enabled = false' to 'true')"
        exit 0
      fi

      # Check current location
      if ! grep -q 'location = "jhw22"' "$CONFIG_FILE"; then
        echo "❌ Error: Unexpected location setting in configuration"
        echo "Expected: location = \"jhw22\""
        echo "Please check: $CONFIG_FILE"
        exit 1
      fi

      cd "$NIXCFG_DIR"

      # Show current git status
      echo "📊 Current git status:"
      git status --short
      echo

      # Change location setting
      echo "🔧 Changing location from jhw22 → ww87..."
      sed -i 's/location = "jhw22"/location = "ww87"/' "$CONFIG_FILE"

      # Verify the change
      if ! grep -q 'location = "ww87"' "$CONFIG_FILE"; then
        echo "❌ Error: Failed to update location setting"
        exit 1
      fi
      echo "✅ Location updated in configuration"
      echo

      # Show the change
      echo "📝 Configuration change:"
      git diff hosts/hsb8/configuration.nix | grep -A2 -B2 "location ="
      echo

      # Apply the configuration FIRST (before committing/pushing)
      echo "🚀 Applying new configuration..."
      echo "This will:"
      echo "  - Enable AdGuard Home (DNS on port 53, Web UI on port 3000)"
      echo "  - Switch gateway to 192.168.1.1"
      echo "  - Use local DNS (127.0.0.1)"
      echo "  - Change search domain to 'local'"
      echo
      echo "⚠️  Network will be reconfigured. You may lose SSH connection briefly."
      echo
      read -p "Press Enter to continue or Ctrl+C to cancel..."
      echo

      nixos-rebuild switch --flake .#hsb8

      echo
      echo "✅ Configuration applied successfully!"
      echo

      # Commit and push AFTER network is reconfigured
      echo "💾 Committing change..."
      git add hosts/hsb8/configuration.nix
      git commit -m "feat(hsb8): enable ww87 location (parents' home)"
      echo

      echo "📤 Pushing to remote..."
      git push
      echo

      echo
      echo "✅ Successfully enabled ww87 configuration!"
      echo
      echo "📡 AdGuard Home Status:"
      systemctl status adguardhome --no-pager | head -5
      echo
      echo "🌐 Network Configuration:"
      ip addr show enp2s0f0 | grep "inet "
      ip route show default
      echo
      echo "🔗 AdGuard Home Web Interface:"
      echo "   http://192.168.1.100:3000"
      echo "   User: admin / Pass: admin"
      echo
      echo "⚠️  DHCP is DISABLED by default for safety!"
      echo "To enable DHCP server:"
      echo "  1. Edit: $CONFIG_FILE"
      echo "  2. Change: dhcp.enabled = false → true"
      echo "  3. Run: nixos-rebuild switch --flake ~/nixcfg#hsb8"
      echo
      echo "✨ Done! The server is now configured for parents' home."
    '')
  ]
  ++ lib.optionals enableAdGuard (
    with pkgs;
    [
      # Network diagnostic tools
      dig
      tcpdump
      nmap
      # Secret management tools
      rage # Modern age encryption tool (for agenix)
      inputs.agenix.packages.${pkgs.system}.default # agenix CLI
    ]
  );

  # Enable Fwupd for firmware updates
  # https://nixos.wiki/wiki/Fwupd
  services.fwupd.enable = true;

  # Passwordless sudo for wheel group (required for remote deployment)
  security.sudo-rs.wheelNeedsPassword = false;

  # ============================================================================
  # DOCKER CONFIGURATION
  # ============================================================================
  # Docker for running Home Assistant and related services (gb user)
  # Based on miniserver24 setup: ~/docker/docker-compose.yml
  # ============================================================================

  virtualisation.docker = {
    enable = true;
    enableOnBoot = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };

  # Add gb user to docker group for container management
  users.users.gb.extraGroups = [ "docker" ];

  # Docker containers will run under gb user account
  # Configuration expected at: /home/gb/docker/docker-compose.yml
  # Key services planned:
  # - Home Assistant (ghcr.io/home-assistant/home-assistant:stable)
  # - Zigbee2MQTT (koenkk/zigbee2mqtt:latest)
  # - Mosquitto MQTT broker (eclipse-mosquitto:latest)
  # - Matter Server (ghcr.io/home-assistant-libs/python-matter-server:stable)
  # - Watchtower for automatic updates
  #
  # Note: Docker Compose setup must be configured manually by gb user
  # Reference: miniserver24:/home/mba/docker/

  # ============================================================================
  # HOKAGE MODULE CONFIGURATION
  # ============================================================================
  # Using external hokage consumer pattern from github:pbek/nixcfg
  # This provides server-home role with explicit configuration
  # ============================================================================

  hokage = {
    hostName = "hsb8";
    userLogin = "mba"; # Primary user for hokage
    userNameLong = "Markus Barta"; # Full name (prevents "Patrizio Bekerle" default)
    userNameShort = "Markus"; # Short name
    userEmail = "markus@barta.com"; # Email (used by git config)
    role = "server-home"; # Explicit role (replaces serverMba mixin)
    useInternalInfrastructure = false; # Not using pbek's infrastructure
    useSecrets = false; # Not using agenix secrets yet (DHCP disabled)
    useSharedKey = false; # Not using shared SSH keys
    zfs.enable = true; # Enable ZFS support
    zfs.hostId = "cdbc4e20"; # ZFS host ID (required)
    audio.enable = false; # No audio on server
    programs.git.enableUrlRewriting = false; # No internal git rewrites

    # Multi-user configuration (both mba and gb)
    users = [
      "mba"
      "gb"
    ];
  };

  # ============================================================================
  # Fish Shell Configuration - Utility functions lost when migrating from serverMba mixin
  # ============================================================================
  programs.fish.interactiveShellInit = ''
    function sourcefish --description 'Load env vars from a .env file into current Fish session'
      set file "$argv[1]"
      if test -z "$file"
        echo "Usage: sourcefish PATH_TO_ENV_FILE"
        return 1
      end
      if test -f "$file"
        for line in (cat "$file" | grep -v '^[[:space:]]*#' | grep .)
          set key (echo $line | cut -d= -f1)
          set val (echo $line | cut -d= -f2-)
          set -gx $key "$val"
        end
      else
        echo "File not found: $file"
        return 1
      end
    end
    set -gx EDITOR nano
  '';

  # ============================================================================
  # Local /etc/hosts - Privacy-focused hostnames for critical infrastructure
  # ============================================================================
  # Provides fallback DNS resolution when AdGuard Home is unavailable
  # Uses encoded/cryptic hostnames to avoid revealing device details in git
  # ============================================================================
  networking.hosts = {
    # Self-reference - hsb8 itself
    "192.168.1.100" = [
      "hsb8"
      "hsb8.lan"
    ];
    # Critical infrastructure - add more as needed
    # Example format (uncomment and adapt):
    # "192.168.1.99" = [ "hsb0" "hsb0.lan" ];  # DNS/DHCP server
  };
}
