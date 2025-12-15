# hsb0 server for Markus
# Primary Purpose: DNS and DHCP server running AdGuard Home
{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:
let
  # ============================================================================
  # DNS ALLOWLIST - Domains that bypass ad-blocking
  # ============================================================================
  # Add domains here that need to be whitelisted for devices to function
  # Format: "@@||domain.example.com^" (AdGuard Home allowlist syntax)
  # Source: sudo grep 'DEVICE_IP' /var/lib/private/AdGuardHome/data/querylog.json | jq -r '.QH' | sort -u
  # ============================================================================
  dnsAllowlist = [
    # Roborock Vacuum (192.168.1.235 / roborock-vacuum-a226)
    "@@||mqtt-eu-3.roborock.com^" # MQTT broker
    "@@||api-eu.roborock.com^" # API endpoint
    "@@||eu-app.roborock.com^" # App backend
    "@@||euiot.roborock.com^" # IoT endpoint
    "@@||v-eu-2.roborock.com^" # Voice/firmware
    "@@||v-eu-3.roborock.com^" # Voice/firmware
    "@@||vivianspro-eu-1316693915.cos.eu-frankfurt.myqcloud.com^" # Tencent COS (maps)
    "@@||conf-eu-1316693915.cos.eu-frankfurt.myqcloud.com^" # Tencent COS (config)
    "@@||anonymousinfo-eu-1316693915.cos.eu-frankfurt.myqcloud.com^" # Tencent COS (telemetry)
    "@@||cdn.awsde0.fds.api.mi-img.com^" # Xiaomi CDN (firmware/images)
  ];

  # DNS rewrite rules (internal hostnames)
  dnsRewrites = [
    "||csb0^$dnsrewrite=NOERROR;CNAME;cs0.barta.cm"
    "||csb1^$dnsrewrite=NOERROR;CNAME;cs1.barta.cm"
  ];
in
{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.zfs.nix
    ../../modules/uzumaki # Consolidated module: fish, zellij, stasysmo
    # nixfleet-agent is now loaded via flake input (inputs.nixfleet.nixosModules.nixfleet-agent)
  ];

  # ============================================================================
  # UZUMAKI MODULE - Fish functions, zellij, stasysmo (all-in-one)
  # ============================================================================
  uzumaki = {
    enable = true;
    role = "server";
    fish.editor = "nano";
    stasysmo.enable = true; # System metrics in Starship prompt
  };

  # NOTE: starship and atuin are configured in common.nix (via commonServerModules)

  # ZFS configuration
  services.zfs.autoScrub.enable = true;

  # ============================================================================
  # APC UPS Monitoring (Back-UPS ES 350)
  # ============================================================================
  # USB-connected UPS provides power protection and status monitoring.
  # Status is published to MQTT every minute for home automation integration.
  # ============================================================================

  services.apcupsd = {
    enable = true;
    configText = ''
      UPSCABLE usb
      UPSTYPE usb
      DEVICE
      UPSNAME ups350vr
    '';
  };

  # MQTT credentials for UPS status publishing
  # Format: MQTT_HOST, MQTT_USER, MQTT_PASS (sourced by bash)
  # Edit: agenix -e secrets/mqtt-hsb0.age
  age.secrets.mqtt-hsb0 = {
    file = ../../secrets/mqtt-hsb0.age;
    mode = "400";
    owner = "root";
    group = "root";
  };

  # Systemd service: Publish UPS status to MQTT as JSON
  systemd.services.ups-mqtt-publish = {
    description = "Publish APC UPS status to MQTT";
    after = [
      "apcupsd.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    path = [
      pkgs.gawk
      pkgs.gnused
      pkgs.coreutils
    ];
    script = ''
      set -euo pipefail

      # Source MQTT credentials from agenix secret
      source ${config.age.secrets.mqtt-hsb0.path}

      # Query UPS status
      apc_status=$(${pkgs.apcupsd}/bin/apcaccess status)

      # Get current timestamp in milliseconds
      current_timestamp=$(date +%s%3N)

      # Convert APC status to JSON
      json_status=$(echo "$apc_status" | awk -v timestamp="$current_timestamp" '
      BEGIN { print "{" }
      NF > 1 {
          gsub(/^[ \t]+|[ \t]+$/, "", $0)
          key = tolower($1)
          $1 = ""
          gsub(/^[ \t]*: /, "", $0)
          gsub(/^[ \t]+|[ \t]+$/, "", $0)
          value = $0
          gsub(/"/, "\\\"", value)
          printf "  \"%s\": \"%s\",\n", key, value
      }
      END { printf "  \"__published\": %s\n", timestamp }
      ' | sed '$ s/,$//')

      json_status="$json_status
      }"

      # Publish to MQTT
      ${pkgs.mosquitto}/bin/mosquitto_pub \
        --topic home/vr/battery/ups350 \
        -u "$MQTT_USER" \
        -P "$MQTT_PASS" \
        -h "$MQTT_HOST" \
        -m "$json_status"
    '';
    serviceConfig = {
      Type = "oneshot";
      # Run as root to access agenix secrets
    };
  };

  # Timer: Run every minute
  systemd.timers.ups-mqtt-publish = {
    description = "Timer for APC UPS MQTT publishing";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "1min";
      Unit = "ups-mqtt-publish.service";
    };
  };

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

      # Custom filtering rules: allowlist + DNS rewrites
      user_rules = dnsAllowlist ++ dnsRewrites;

      users = [
        {
          name = "admin";
          # NOTE: Bcrypt hash intentionally inline - AdGuard Home requires password in config.
          # This is an accepted tradeoff since bcrypt is resistant to reversal and
          # the hash is already in git history. The actual password is in 1Password.
          password = "$2y$05$6tWeTokm6nLLq7nTIpeQn.J9ln.4CWK9HDyhJzY.w6qAk4CmEpUNy";
        }
      ];

      dhcp = {
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
        "hsb1"
        "hsb1.lan"
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
        3001 # Uptime Kuma web interface
        80 # HTTP (for future use)
        443 # HTTPS (for future use)
      ];
      allowedUDPPorts = [
        53 # DNS
        67 # DHCP
      ];
    };
  };

  # ============================================================================
  # Uptime Kuma - Service Monitoring
  # ============================================================================
  # Monitors service uptime and availability. Web interface: http://192.168.1.99:3001
  # Uses native NixOS service (no Docker required).
  # ============================================================================
  services.uptime-kuma = {
    enable = true;
    settings = {
      PORT = "3001";
      HOST = "0.0.0.0"; # Listen on all interfaces
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
    # UPS monitoring
    apcupsd # For apcaccess CLI
    mosquitto # For mosquitto_sub debugging
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
    catppuccin.enable = false; # Use Tokyo Night theme instead
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
    # Point nixbit to Markus' repository (not pbek's default)
    programs.nixbit.repository = "https://github.com/markus-barta/nixcfg.git";
    # NOTE: atuin disabled in common.nix (via commonServerModules)
  };

  # NOTE: Starship configured in common.nix (via commonServerModules)

  # ============================================================================
  # StaSysMo - Starship System Monitoring
  # ============================================================================
  # Displays CPU, RAM, Load, Swap in the prompt with threshold-based coloring.
  # Daemon writes to /dev/shm/stasysmo/ every 5 seconds.
  # ============================================================================
  services.stasysmo.enable = true;

  # ============================================================================
  # 🚨 SSH KEY SECURITY
  # ============================================================================
  # The hokage server-home module auto-injects external SSH keys (omega@*).
  # We use lib.mkForce to REPLACE (not append) with our own keys only.
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

  # ============================================================================
  # NIXFLEET AGENT - Fleet management dashboard agent
  # ============================================================================
  age.secrets.nixfleet-token.file = ../../secrets/nixfleet-token.age;

  services.nixfleet-agent = {
    enable = true;
    url = "wss://fleet.barta.cm/ws"; # v2 uses WebSocket
    interval = 5; # Heartbeat interval in seconds
    tokenFile = "/run/agenix/nixfleet-token";
    repoUrl = "https://github.com/markus-barta/nixcfg.git"; # Isolated repo mode
    user = "mba";
    logLevel = "info";
    location = "home";
    deviceType = "server";
  };
}
