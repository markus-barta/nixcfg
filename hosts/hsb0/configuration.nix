# hsb0 server for Markus
# Primary Purpose: DNS and DHCP server running AdGuard Home
{
  pkgs,
  lib,
  inputs,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.zfs.nix
  ];

  # ZFS configuration
  services.zfs.autoScrub.enable = true;

  # AdGuard Home - DNS and DHCP server with ad-blocking
  # Web interface: http://192.168.1.99:3000
  services.adguardhome = {
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
      user_rules = [
        "||csb0^$dnsrewrite=NOERROR;CNAME;cs0.barta.cm"
        "||csb1^$dnsrewrite=NOERROR;CNAME;cs1.barta.cm"
      ];

      users = [
        {
          name = "admin";
          password = "$2y$05$6tWeTokm6nLLq7nTIpeQn.J9ln.4CWK9HDyhJzY.w6qAk4CmEpUNy";
        }
      ];

      dhcp = {
        # IMPORTANT: Ensure miniserver24 DHCP is disabled before enabling this.
        enabled = true;
        interface_name = "enp2s0f0";
        dhcpv4 = {
          gateway_ip = "192.168.1.5";
          subnet_mask = "255.255.255.0";
          range_start = "192.168.1.201";
          range_end = "192.168.1.254";
          lease_duration = 86400; # 24 hours
          icmp_timeout_msec = 1000;

          # Add DHCP Option 15 (domain name)
          # Format: "option_code type value"
          # See: https://github.com/AdguardTeam/AdGuardHome/wiki/DHCP
          options = [
            "15 text lan"
          ];

          # Static DHCP leases are managed via agenix and loaded at runtime
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

  # Static DHCP Leases Management
  # Leases are stored encrypted in git and decrypted at system activation
  systemd.services.adguardhome.preStart = lib.mkAfter ''
    leases_dir="/var/lib/private/AdGuardHome/data"
    leases_file="$leases_dir/leases.json"
    install -d "$leases_dir"

    # Read static leases from agenix-decrypted JSON file
    # Agenix automatically decrypts to /run/agenix/<secret-name>
    static_leases_file="/run/agenix/static-leases-hsb0"

    # Validate that the agenix secret file exists
    if [ ! -f "$static_leases_file" ]; then
      echo "ERROR: Static leases file not found at $static_leases_file"
      echo "This should have been decrypted by agenix during activation."
      exit 1
    fi

    # Validate JSON format
    if ! ${pkgs.jq}/bin/jq empty "$static_leases_file" 2>/dev/null; then
      echo "ERROR: Invalid JSON in static leases file: $static_leases_file"
      echo "Use 'agenix -e secrets/static-leases-hsb0.age' to fix the format."
      exit 1
    fi

    # Merge static leases with existing dynamic leases
    tmp="$(mktemp)"

    if [ -f "$leases_file" ]; then
      # Merge: keep dynamic leases, replace/add static leases
      ${pkgs.jq}/bin/jq --argjson static "$(cat "$static_leases_file")" '
        def normalize_mac($mac): ($mac | ascii_downcase);
        def static_entries: $static | map(.mac |= normalize_mac(.));
        def without_static($list):
          ($list // [])
          | map(
              (.mac | ascii_downcase) as $m
              | (.static // false) as $is_static
              | (static_entries | map(.mac) | index($m)) as $idx
              | select($idx == null and ($is_static | not))
            );
        def build_static:
          static_entries | map(. + {static: true, expires: ""});
        {version: (.version // 1), leases: without_static(.leases) + build_static}
      ' "$leases_file" > "$tmp"
    else
      # First run: create leases file with static entries only
      ${pkgs.jq}/bin/jq --argjson static "$(cat "$static_leases_file")" '
        {version: 1, leases: ($static | map(. + {static: true, expires: ""}))}
      ' <<< '{}' > "$tmp"
    fi

    # Atomic update
    mv "$tmp" "$leases_file"
    echo "✓ Loaded $(${pkgs.jq}/bin/jq '[.leases[] | select(.static == true)] | length' "$leases_file") static DHCP leases"
  '';

  # Networking configuration - Triple redundancy for core infrastructure
  # 1. /etc/hosts: Immediate resolution without network/DNS dependency
  # 2. Search domain (.lan): Client-side domain appending
  # 3. DNS server (AdGuard Home): Full DNS resolution with blocking/filtering
  # Critical devices get guaranteed resolution even if DNS server fails
  networking = {
    # Use localhost for DNS since AdGuard Home runs locally
    nameservers = [ "127.0.0.1" ];
    search = [ "lan" ];
    defaultGateway = "192.168.1.5";

    # Critical infrastructure hosts - guaranteed resolution via /etc/hosts
    # Provides fallback when DNS server (AdGuard Home) is unavailable
    # Both short names and FQDNs for maximum compatibility
    hosts = {
      # Network switch - core infrastructure, must be reachable for network management
      "192.168.1.3" = [
        "vr-netgear-gs724"
        "vr-netgear-gs724.lan"
      ];
      # Router/gateway - internet access, must work even during DNS outages
      "192.168.1.5" = [
        "vr-fritz-box"
        "vr-fritz-box.lan"
      ];
      # Solar battery storage - power monitoring, critical for energy management
      "192.168.1.32" = [
        "kr-sonnen-batteriespeicher"
        "kr-sonnen-batteriespeicher.lan"
      ];
      # This DNS/DHCP server itself - self-resolution for services and management
      "192.168.1.99" = [
        "hsb0"
        "hsb0.lan"
      ];
      # Home automation server + MQTT broker - runs Node-RED, Home Assistant, cameras, notifications + MQTT for IoT devices
      "192.168.1.101" = [
        "miniserver24"
        "miniserver24.lan"
        "mosquitto"
        "mosquitto.lan"
      ];
      # Smart home controller - for controlling lights, roller-blinds, ... and expose them to HomeKit as bridge
      "192.168.1.102" = [
        "vr-opus-gateway"
        "vr-opus-gateway.lan"
      ];
      # Smart home status display 1 - shows system health and status information
      "192.168.1.159" = [
        "wz-pixoo-64-00"
        "wz-pixoo-64-00.lan"
      ];
      # Smart home status display 2 - shows system health and status information
      "192.168.1.189" = [
        "wz-pixoo-64-01"
        "wz-pixoo-64-01.lan"
      ];
    };
    interfaces.enp2s0f0 = {
      ipv4.addresses = [
        {
          address = "192.168.1.99";
          prefixLength = 24;
        }
      ];
    };
    # Firewall configuration for DNS/DHCP server
    firewall = {
      enable = true;
      allowedTCPPorts = [
        53 # DNS
        3000 # AdGuard Home web interface
        80 # HTTP (for future use)
        443 # HTTPS (for future use)
      ];
      allowedUDPPorts = [
        53 # DNS
        67 # DHCP
      ];
    };
  };

  # Enable Fwupd for firmware updates
  # https://nixos.wiki/wiki/Fwupd
  services.fwupd.enable = true;

  # Additional system packages for DNS/DHCP server
  environment.systemPackages = with pkgs; [
    # Network diagnostic tools
    dig
    tcpdump
    nmap
    # Secret management tools
    rage # Modern age encryption tool (for agenix)
    inputs.agenix.packages.${pkgs.system}.default # agenix CLI
  ];

  # Agenix secrets configuration
  # Static DHCP leases: encrypted JSON array in git, decrypted at activation
  # Format: [{"mac": "AA:BB:CC:DD:EE:FF", "ip": "192.168.1.100", "hostname": "device-name"}]
  # Edit with: agenix -e secrets/static-leases-hsb0.age
  age.secrets.static-leases-hsb0 = {
    file = ../../secrets/static-leases-hsb0.age;
    # Agenix creates /run/agenix/static-leases-hsb0 automatically
    # The 'path' attribute is optional and defaults to /run/agenix/<secret-name>
    mode = "444"; # World-readable (not sensitive data, just DHCP assignments)
    owner = "root";
    group = "root";
  };

  hokage = {
    hostName = "hsb0";
    userLogin = "mba";
    userNameLong = "Markus Barta";
    userNameShort = "Markus";
    userEmail = "markus@barta.com";
    role = "server-home";
    useInternalInfrastructure = false;
    useSecrets = true;
    useSharedKey = false;
    zfs.enable = true;
    zfs.hostId = "dabfdb02";
    audio.enable = false;
    programs.git.enableUrlRewriting = false;
  };

  # ============================================================================
  # 🚨 FISH SHELL CONFIGURATION - Lost when removing serverMba mixin
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
  # 🚨 SSH KEY SECURITY - CRITICAL FIX FROM hsb8 INCIDENT
  # ============================================================================
  # The hokage server-home module auto-injects external SSH keys (omega@*).
  # We use lib.mkForce to REPLACE (not append) with our own keys only.
  #
  # Security Policy:
  # - hsb0: Only mba (Markus) key
  # - NO external access (omega/Yubikey) on personal/family servers
  # ============================================================================

  users.users.mba = {
    openssh.authorizedKeys.keys = lib.mkForce [
      # Markus' SSH key ONLY
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H1iVXWYKnHkxQsS7tGsZq3SoHxlVccd+kroMC/DhC4MWwVnJInWwDpo/bz7LiLuh+1Bmq04PswD78EiHVVQ+O7Ckk32heWrywD2vufihukhKRTy5zl6uodb5+oa8PBholTnw09d3M0gbsVKfLEi4NDlgPJiiQsIU00ct/y42nI0s1wXhYn/Oudfqh0yRfGvv2DZowN+XGkxQQ5LSCBYYabBK/W9imvqrxizttw02h2/u3knXcsUpOEhcWJYHHn/0mw33tl6a093bT2IfFPFb3LE2KxUjVqwIYz8jou8cb0F/1+QJVKtqOVLMvDBMqyXAhCkvwtEz13KEyt" # mba@markus
    ];
  };

  # ============================================================================
  # 🚨 PASSWORDLESS SUDO - Also lost when removing serverMba mixin
  # ============================================================================
  # The serverMba mixin provided passwordless sudo, which is also lost.
  # Re-enable it explicitly to prevent sudo failures.
  # ============================================================================

  security.sudo-rs.wheelNeedsPassword = false;
}
