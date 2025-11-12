# miniserver99 server for Markus
# Primary Purpose: DNS and DHCP server running AdGuard Home
{
  pkgs,
  lib,
  inputs,
  ...
}:

let
  staticLeases =
    if inputs ? miniserver99-static-leases then
      import inputs.miniserver99-static-leases
    else
      { static_leases = [ ]; };
  staticLeasesTransformed =
    map (
      lease:
        {
          mac = lib.toUpper lease.mac;
          ip = lease.ip;
          hostname = lease.hostname;
          lease_time = 0;
          comment = if lease ? comment then lease.comment else "";
        }
        // (if lease ? client_id then { client_id = lease.client_id; } else { })
    ) staticLeases.static_leases;
  staticLeasesJson =
    builtins.toJSON (
      map (
        lease:
          {
            mac = lease.mac;
            ip = lease.ip;
            hostname = lease.hostname;
          }
          // (if lease ? client_id then { client_id = lease.client_id; } else { })
      ) staticLeasesTransformed
    );
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/hokage
    ./disk-config.zfs.nix
  ];

  # ZFS configuration
  services.zfs.autoScrub.enable = true;

  # AdGuard Home - DNS and DHCP server with ad-blocking
  # Web interface: http://192.168.1.99:3000
  services.adguardhome =
    {
      enable = true;
      host = "0.0.0.0";
      port = 3000;
      mutableSettings = false; # Use declarative configuration
      settings = {
        dns = {
          bind_hosts = [ "0.0.0.0" ];
          port = 53;
          # Use Cloudflare DNS as upstream
          bootstrap_dns = [ "1.1.1.1" "1.0.0.1" ];
          upstream_dns = [ "1.1.1.1" "1.0.0.1" ];
          # Enable DNS cache
          cache_size = 4194304; # 4MB
          cache_ttl_min = 0;
          cache_ttl_max = 0;
          cache_optimistic = true;
        };

        rewrites = [
          { domain = "csb0"; answer = "cs0.barta.cm"; type = 5; }
          { domain = "csb1"; answer = "cs1.barta.cm"; type = 5; }
        ];

        # Admin user with password 'admin' (bcrypt hash)
        users = [
          {
            name = "admin";
            password = "REMOVED";
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
            # Static DHCP leases declared in ./static-leases.nix (gitignored)
            static_leases = staticLeasesTransformed;
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

  systemd.services.adguardhome.preStart = lib.mkAfter ''
    leases_dir="/var/lib/private/AdGuardHome/data"
    leases_file="$leases_dir/leases.json"
    tmp="$(mktemp)"
    static_tmp="$(mktemp)"
    install -d "$leases_dir"
    cat <<'EOF' > "$static_tmp"
${staticLeasesJson}
EOF

    if [ -f "$leases_file" ]; then
      ${pkgs.jq}/bin/jq --argjson static "$(cat "$static_tmp")" '
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
      ${pkgs.jq}/bin/jq -n --argjson static "$(cat "$static_tmp")" '
        {version: 1, leases: ($static | map(. + {static: true, expires: ""}))}
      ' > "$tmp"
    fi

    mv "$tmp" "$leases_file"
    rm -f "$static_tmp"
  '';

  # Networking configuration
  networking = {
    # Use localhost for DNS since AdGuard Home runs locally
    nameservers = [ "127.0.0.1" ];
    search = [ "lan" ];
    defaultGateway = "192.168.1.5";
    hosts = {
      "192.168.1.3" = [ "vr-netgear-gs724" "vr-netgear-gs724.lan" ];
      "192.168.1.5" = [ "vr-fritz-box" "vr-fritz-box.lan" ];
      "192.168.1.32" = [ "kr-sonnen-batteriespeicher" "kr-sonnen-batteriespeicher.lan" ];
      "192.168.1.99" = [ "miniserver99" "miniserver99.lan" ];
      "192.168.1.100" = [ "mosquitto" "mosquitto.lan" ];
      "192.168.1.101" = [ "miniserver24" "miniserver24.lan" ];
      "192.168.1.102" = [ "vr-opus-gateway" "vr-opus-gateway.lan" ];
      "192.168.1.159" = [ "wz-pixoo-64-00" "wz-pixoo-64-00.lan" ];
      "192.168.1.189" = [ "wz-pixoo-64-01" "wz-pixoo-64-01.lan" ];
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
  ];

  hokage = {
    hostName = "miniserver99";
    zfs.hostId = "dabfdb02";
    audio.enable = false;
    serverMba.enable = true;
  };
}

