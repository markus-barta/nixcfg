# msww87 server - Parents' home automation server
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
    ../../modules/hokage
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

  users.users.gb = {
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDAwgtI71qYnLJnq0PPs/PWR0O+0zvEQfT7QYaHbrPUdILnK5jqZTj6o02kyfce6JLk+xyYhI596T6DD9But943cKFY/cYG037EjlECq+LXdS7bRsb8wYdc8vjcyF21Ol6gSJdT3noAzkZnqnucnvd7D1lae2ZVw7km6GQvz5XQGS/LQ38JpPZ2JYb0ufT3Z1vgigq9GqhCU6C7NdUslJJJ1Lj4JfPqQTbS1ihZqMe3SQ+ctfmHNYniUkd5Potu7wLMG1OJDL13BXu/M5IihgerZ3QuPb2VPQkb37oxKfquMKveYL9bt4fmK+7+CRHJnzFB45HfG5PiTKsyjuPR5A1N3U5Os+9Wrav9YrqDHWjCaFI1EIY4HRM/kRufD+0ncvvXpsp4foS9DAhK5g3OObRlKgPEc4hkD7hC2KBXUt7Kyg6SLL89gD42qSXLxZlxaTD65UaqB28PuOt7+LtKEPhm1jfH65cKu5vGqUp3145hSJuHB4FuA0ieplfxO78psVM= Gerhard@imac-gb.local"
    ];
  };

  # Additional system packages (when at parents' home with AdGuard)
  environment.systemPackages = lib.optionals enableAdGuard (
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

  hokage = {
    hostName = "msww87";
    users = [
      "mba"
      "gb"
    ];
    zfs.hostId = "cdbc4e20";
    serverMba.enable = true;
  };
}
