# csb0 - Cloud Server Barta 0 (Netcup VPS)
# Smart Home Hub: Node-RED, MQTT, Telegram Bot
# Hokage Migration: 2025-11-29
{
  lib,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.zfs.nix
    ../../modules/uzumaki # Consolidated module: fish, zellij, stasysmo
    # nixfleet-agent is now loaded via flake input (inputs.nixfleet.nixosModules.nixfleet-agent)
  ];

  # ============================================================================
  # UZUMAKI MODULE CONFIGURATION
  # ============================================================================
  uzumaki = {
    enable = true;
    role = "server";
    ncps.enable = false; # Cloud server: Never sees hsb0
  };

  # ============================================================================
  # BOOTLOADER CONFIGURATION
  # ============================================================================
  boot.supportedFilesystems = [ "zfs" ];

  boot.loader.grub = {
    enable = true;
    zfsSupport = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    mirroredBoots = [
      {
        devices = [ "nodev" ];
        path = "/boot";
      }
    ];
  };

  # Network settings for the initial RAM disk (initrd)
  boot.initrd.network = {
    enable = true;
    postCommands = ''
      sleep 2
      zpool import -a;
    '';
  };

  # ============================================================================
  # ZFS CONFIGURATION
  # ============================================================================
  services.zfs.autoScrub.enable = true;

  # ============================================================================
  # NETWORKING
  # ============================================================================
  # 🚨 STATIC IP CONFIG - Prevents lockout during deploy (learned from csb1 incident 2025-12-05)
  # Root cause: NetworkManager had no connection profile after generation switch
  # Fix: Declarative static IP that NixOS manages, NM ignores
  networking = {
    hostName = "csb0";
    hostId = "dabfdc01"; # Required for ZFS
    networkmanager.enable = true;

    # Static IP: Netcup VPS - NEW SERVER (2026-01-10)
    interfaces.ens3 = {
      useDHCP = false;
      ipv4.addresses = [
        {
          address = "89.58.63.96";
          prefixLength = 22; # /22 = 89.58.60.0 - 89.58.63.255
        }
      ];
    };

    defaultGateway = "89.58.60.1"; # Gateway from Netcup SCP
    nameservers = [
      "46.38.225.230" # Netcup primary DNS
      "46.38.252.230" # Netcup secondary DNS
    ];

    # Tell NetworkManager NOT to manage ens3 (we configure it statically)
    networkmanager.unmanaged = [ "ens3" ];

    # Disable DHCP globally (static IP server)
    useDHCP = false;

    # Firewall - allow web traffic and SSH
    firewall = {
      allowedTCPPorts = [
        80 # HTTP
        443 # HTTPS
        2222 # SSH (hardened port)
      ];
    };
  };

  # ============================================================================
  # MOSQUITTO MQTT BROKER PERMISSIONS
  # ============================================================================
  users.groups.mosquitto = {
    gid = 1883;
  };

  system.activationScripts.mosquittoPermissions = ''
    if [ -d /home/mba/docker/mosquitto ]; then
      chown -R mba:mosquitto /home/mba/docker/mosquitto
      chmod -R 775 /home/mba/docker/mosquitto
    fi
  '';

  # ============================================================================
  # HOKAGE MODULE CONFIGURATION
  # ============================================================================
  hokage = {
    catppuccin.enable = false; # Use Tokyo Night theme instead
    hostName = "csb0";
    userLogin = "mba";
    userNameLong = "Markus Barta";
    userNameShort = "Markus";
    userEmail = "markus@barta.com";
    role = "server-remote";
    useInternalInfrastructure = false;
    useSecrets = true;
    useSharedKey = false;
    zfs.enable = true;
    zfs.hostId = "dabfdc01";
    programs.git.enableUrlRewriting = false;
    # Point nixbit to Markus' repository (not pbek's default)
    programs.nixbit.repository = "https://github.com/markus-barta/nixcfg.git";
    # NOTE: starship & atuin are configured via common.nix (DRY pattern)
  };

  # ============================================================================
  # 🚨 SSH KEY SECURITY - CRITICAL FIX FROM hsb8/hsb1/csb1 INCIDENTS
  # ============================================================================
  # The external hokage server-remote module auto-injects external SSH keys
  # (omega@yubikey, omega@rsa, etc). We use lib.mkForce to REPLACE these
  # with ONLY authorized keys.
  #
  # Security Policy: csb0 allows mba (Markus) SSH keys only.
  #
  # See: docs/SSH-KEY-SECURITY.md
  # ============================================================================
  users.users.mba = {
    extraGroups = [ "mosquitto" ];

    # 🚨 EMERGENCY RECOVERY PASSWORD - for VNC console access if SSH fails
    # Enables login via Netcup VNC console during lockout scenarios
    # Password stored in 1Password, rotate after migration complete
    hashedPassword = "$6$ee9NiRR00Ev9wlEZ$kFD53waKDKf5YHC.Tzwm68Iwhjey7om9Yld4i9cUBLa40HdpL8.umjtIpWnjCmzKzgsGUgS3y.Tx2UQOUp5AN.";

    openssh.authorizedKeys.keys = lib.mkForce [
      # markus@iMac-5k-MBA-home.local (id_rsa)
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H1iVXWYKnHkxQsS7tGsZq3SoHxlVccd+kroMC/DhC4MWwVnJInWwDpo/bz7LiLuh+1Bmq04PswD78EiHVVQ+O7Ckk32heWrywD2vufihukhKRTy5zl6uodb5+oa8PBholTnw09d3M0gbsVKfLEi4NDlgPJiiQsIU00ct/y42nI0s1wXhYn/Oudfqh0yRfGvv2DZowN+XGkxQQ5LSCBYYabBK/W9imvqrxizttw02h2/u3knXcsUpOEhcWJYHHn/0mw33tl6a093bT2IfFPFb3LE2KxUjVqwIYz8jou8cb0F/1+QJVKtqOVLMvDBMqyXAhCkvwtEz13KEyt"
      # hsb1 (miniserver24): Node-RED container SSH automation
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAhUleyXsqtdA4LC17BshpLAw0X1vMLNKp+lOLpf2bw1 mba@miniserver24"
    ];
  };

  # ============================================================================
  # SSH CONFIGURATION
  # ============================================================================
  services.openssh.ports = [ 2222 ];

  # 🚨 TEMPORARY: Enable password auth during external hokage migration
  # This provides a fallback if SSH keys fail (learned from hsb1 lockout)
  # TODO: Remove after successful migration verification!
  services.openssh.settings.PasswordAuthentication = lib.mkForce true;

  # ============================================================================
  # PASSWORDLESS SUDO
  # ============================================================================
  security.sudo-rs.wheelNeedsPassword = false;

  # ============================================================================
  # THEMING - Managed via theme-hm.nix
  # ============================================================================
  # Starship, Zellij, and Eza colors are auto-applied by:
  #   modules/common.nix → modules/shared/theme-hm.nix
  #
  # Theme: Ice Blue (soft sky blue for cloud server identity)
  # See: modules/shared/theme-palettes.nix for color definitions
  #
  # Note: Zellij, fish functions, and stasysmo come from modules/uzumaki

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
    location = "cloud";
    deviceType = "server";
  };

  # ============================================================================
  # UPTIME KUMA - Cloud services monitoring
  # ============================================================================
  # Uptime Kuma now runs as Docker service (consistent with other services)
  # Configuration moved to hosts/csb0/scripts/docker-compose.yml
  # See P6000 task for details
}
