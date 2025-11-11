# miniserver99 server for Markus
# Primary Purpose: DNS and DHCP server running AdGuard Home
{
  pkgs,
  lib,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/hokage
    ./disk-config.zfs.nix
  ];

  # ZFS configuration
  services.zfs.autoScrub.enable = true;

  # Static DHCP Leases Injection Service
  # This service injects static DHCP leases into AdGuard Home's configuration
  # before the service starts, maintaining a fully declarative setup.
  # 
  # Pattern follows mqtt-volume-control service on miniserver24
  systemd.services.adguardhome-inject-static-leases =
    let
      staticLeases = import ./static-leases.nix;
      leasesYaml = builtins.concatStringsSep "\n" (
        builtins.map (
          lease: "      - mac: \"${lease.mac}\"\n        ip: ${lease.ip}\n        hostname: ${lease.hostname}"
        ) staticLeases.static_leases
      );
    in
    {
      description = "Inject static DHCP leases into AdGuard Home configuration";
      before = [ "adguardhome.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "inject-static-leases" ''
          CONFIG_FILE="/var/lib/AdGuardHome/AdGuardHome.yaml"
          
          # Logging function
          log() {
            echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | ${pkgs.systemd}/bin/systemd-cat -t adguardhome-static-leases -p info
          }
          
          log "Starting static DHCP leases injection"
          
          # Wait for config file to exist (created by adguardhome preStart)
          if [ ! -f "$CONFIG_FILE" ]; then
            log "AdGuard Home config file not found at $CONFIG_FILE, skipping"
            exit 0
          fi
          
          # Remove any existing static_leases section to ensure idempotency
          if ${pkgs.gnugrep}/bin/grep -q "static_leases:" "$CONFIG_FILE"; then
            log "Removing existing static_leases section"
            ${pkgs.gnused}/bin/sed -i '/^    static_leases:/,/^    [a-z]/{ /^    static_leases:/d; /^      -/d; }' "$CONFIG_FILE"
          fi
          
          # Generate static leases YAML
          LEASES_YAML="    static_leases:
${leasesYaml}"
          
          # Inject static leases after dhcpv4 section
          log "Injecting ${builtins.toString (builtins.length staticLeases.static_leases)} static DHCP leases"
          echo "$LEASES_YAML" | ${pkgs.gnused}/bin/sed -i '/^  dhcpv4:/r /dev/stdin' "$CONFIG_FILE"
          
          log "Successfully injected static DHCP leases into AdGuard Home configuration"
        '';
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
          bootstrap_dns = [ "1.1.1.1" "1.0.0.1" ];
          upstream_dns = [ "1.1.1.1" "1.0.0.1" ];
          # Enable DNS cache
          cache_size = 4194304; # 4MB
          cache_ttl_min = 0;
          cache_ttl_max = 0;
          cache_optimistic = true;
        };

        # Admin user with password 'admin' (bcrypt hash)
        users = [
          {
            name = "admin";
            password = "REMOVED";
          }
        ];

        dhcp = {
          # IMPORTANT: Set to false initially to avoid conflicting with miniserver24 DHCP!
          # After miniserver24 DHCP is disabled, change to true and rebuild:
          #   sudo nixos-rebuild switch --flake .#miniserver99
          enabled = false; # Change to true after miniserver24 DHCP is disabled
          interface_name = "enp2s0f0";
          gateway_ip = "192.168.1.5";
          subnet_mask = "255.255.255.0";
          range_start = "192.168.1.201";
          range_end = "192.168.1.254";
          lease_duration = 86400; # 24 hours
          # Important: Set DNS server to this machine
          dhcpv4 = {
            gateway_ip = "192.168.1.5";
            subnet_mask = "255.255.255.0";
            range_start = "192.168.1.201";
            range_end = "192.168.1.254";
            # Note: Static DHCP leases are injected via systemd service
            # See: systemd.services.adguardhome-inject-static-leases
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

  # Networking configuration
  networking = {
    # Use localhost for DNS since AdGuard Home runs locally
    nameservers = [ "127.0.0.1" ];
    search = [ "lan" ];
    defaultGateway = "192.168.1.5";
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

