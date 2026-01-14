{ pkgs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.zfs.nix
    ../../modules/uzumaki # Consolidated module: fish, zellij, stasysmo
  ];

  # ==========================================================================
  # UZUMAKI MODULE - Fish functions, zellij, stasysmo (all-in-one)
  # ==========================================================================

  uzumaki = {
    enable = true;
    role = "server";
    fish.editor = "vim";
    stasysmo.enable = true; # System metrics in Starship prompt
  };

  # ==========================================================================
  # HOKAGE MODULE CONFIGURATION
  # ==========================================================================
  hokage = {
    catppuccin.enable = false; # Use Tokyo Night theme instead
    hostName = "miniserver-bp";
    userLogin = "mba";
    userNameLong = "Markus Barta";
    userNameShort = "Markus";
    userEmail = "markus@barta.com";
    role = "server-remote";
    useInternalInfrastructure = false;
    useSecrets = false; # No agenix secrets for this host yet
    useSharedKey = false;
    zfs.enable = true;
    zfs.hostId = "f687c770"; # Must match networking.hostId
    programs.git.enableUrlRewriting = false;
    # Point nixbit to Markus' repository (not pbek's default)
    programs.nixbit.repository = "https://github.com/markus-barta/nixcfg.git";
    # NOTE: starship & atuin are configured via common.nix (DRY pattern)
  };

  # ==========================================================================
  # SYSTEM IDENTITY
  # ==========================================================================

  networking.hostName = "miniserver-bp";
  networking.hostId = "f687c770"; # Required for ZFS - never change!

  # ==========================================================================
  # NETWORK CONFIGURATION
  # ==========================================================================

  # Static IP configuration (safer than DHCP for migration)
  # Office network: 10.17.0.0/16
  # MAC: 00:25:00:D7:6F:F6 (has DHCP reservation)
  networking.interfaces.enp0s10 = {
    ipv4.addresses = [
      {
        address = "10.17.1.40";
        prefixLength = 16;
      }
    ];
  };
  networking.defaultGateway = "10.17.1.1";
  networking.nameservers = [
    "1.1.1.1"
    "10.17.1.1"
  ];

  # ==========================================================================
  # WIREGUARD VPN
  # ==========================================================================

  # VPN for remote access from home
  # Allows SSH jump to mba-imac-work (10.17.1.7)
  # TODO: Enable after copying wireguard-private.key to /etc/nixos/secrets/
  # networking.wireguard.interfaces.wg0 = {
  #   ips = [ "10.100.0.51/32" ];
  #
  #   # Private key copied by nixos-anywhere --extra-files
  #   privateKeyFile = "/etc/nixos/secrets/wireguard-private.key";
  #
  #   peers = [
  #     {
  #       # BYTEPOETS VPN server
  #       publicKey = "TZHbPPkIaxlpLKP2frzJl8PmOjYaRnfz/MqwCS7JDUQ=";
  #       endpoint = "vpn.bytepoets.net:51820";
  #       allowedIPs = [ "10.100.0.0/24" ];
  #       persistentKeepalive = 25;
  #     }
  #   ];
  # };

  # ==========================================================================
  # SSH SERVER
  # ==========================================================================

  services.openssh = {
    enable = true;

    # Use default SSH host keys (generated automatically by NixOS)
    # Note: Host key will change from Ubuntu - clients will see warning on first connect

    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = lib.mkForce true; # Allow password auth for initial setup (override hokage)
      X11Forwarding = true;
    };
  };

  # ==========================================================================
  # 🚨 SSH KEY SECURITY - CRITICAL FIX FROM hsb8/hsb1/csb1 INCIDENTS
  # ==========================================================================
  # The external hokage server-remote module auto-injects external SSH keys
  # (omega@yubikey, omega@rsa, etc). We use lib.mkForce to REPLACE these
  # with ONLY authorized keys.
  #
  # SECURITY RATIONALE:
  # - hokage module adds pbek's SSH keys by default
  # - We want ONLY Markus' keys for security
  # - lib.mkForce ensures our list completely replaces hokage's list
  #
  # LEARNED FROM INCIDENTS:
  # - hsb8: Discovered unauthorized omega@ keys (2025-11-28)
  # - hsb1: SSH lockout during migration (2025-11-29)
  # - csb1: Successful migration with this pattern (2025-12-06)
  #
  # MIGRATION SAFETY:
  # - Password auth enabled as fallback (PasswordAuthentication = true above)
  # - Can disable password auth after verifying SSH key access works
  # ==========================================================================
  users.users.mba.openssh.authorizedKeys.keys = pkgs.lib.mkForce [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H1iVXWYKnHkxQsS7tGsZq3SoHxlVccd+kroMC/DhC4MWwVnJInWwDpo/bz7LiLuh+1Bmq04PswD78EiHVVQ+O7Ckk32heWrywD2vufihukhKRTy5zl6uodb5+oa8PBholTnw09d3M0gbsVKfLEi4NDlgPJiiQsIU00ct/y42nI0s1wXhYn/Oudfqh0yRfGvv2DZowN+XGkxQQ5LSCBYYabBK/W9imvqrxizttw02h2/u3knXcsUpOEhcWJYHHn/0mw33tl6a093bT2IfFPFb3LE2KxUjVqwIYz8jou8cb0F/1+QJVKtqOVLMvDBMqyXAhCkvwtEz13KEyt" # markus@iMac-5k-MBA-home.local
  ];

  # ==========================================================================
  # USER ACCOUNT
  # ==========================================================================

  users.users.mba = {
    isNormalUser = true;
    uid = 1000;
    # shell = pkgs.fish; # Managed by uzumaki module
    extraGroups = [
      "wheel"
      "networkmanager"
    ];

    # 🚨 EMERGENCY RECOVERY PASSWORD - matches csb0/csb1 pattern
    # Password stored in 1Password: "csb0 csb1 recovery"
    # Can be changed after successful migration with `passwd mba`
    hashedPassword = "$6$ee9NiRR00Ev9wlEZ$kFD53waKDKf5YHC.Tzwm68Iwhjey7om9Yld4i9cUBLa40HdpL8.umjtIpWnjCmzKzgsGUgS3y.Tx2UQOUp5AN.";

    # SSH keys configured below with lib.mkForce (security override)
  };

  # Fish shell enabled by uzumaki module

  # ==========================================================================
  # LOCALE & TIMEZONE
  # ==========================================================================

  time.timeZone = "Europe/Vienna";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_NUMERIC = "de_AT.UTF-8";
    LC_TIME = "de_AT.UTF-8";
    LC_MONETARY = "de_AT.UTF-8";
    LC_PAPER = "de_AT.UTF-8";
    LC_NAME = "de_AT.UTF-8";
    LC_ADDRESS = "de_AT.UTF-8";
    LC_TELEPHONE = "de_AT.UTF-8";
    LC_MEASUREMENT = "de_AT.UTF-8";
    LC_IDENTIFICATION = "de_AT.UTF-8";
  };

  # ==========================================================================
  # PACKAGES
  # ==========================================================================

  # Most packages provided by uzumaki module (vim, git, htop, btop, etc.)
  environment.systemPackages = with pkgs; [
    # Additional packages not in uzumaki
    tmux
    tree
  ];

  # ==========================================================================
  # FIREWALL
  # ==========================================================================

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ]; # SSH
    # WireGuard uses UDP 51820 (outbound only, no incoming needed)
  };

  # ==========================================================================
  # BOOT
  # ==========================================================================

  boot.loader.grub = {
    enable = true;
    zfsSupport = true;
    efiSupport = true;
    efiInstallAsRemovable = true; # Mac Mini 2009 - safer for old hardware
    device = "nodev"; # EFI mode
  };

  # ==========================================================================
  # NIX SETTINGS
  # ==========================================================================

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    auto-optimise-store = true;
  };

  # ==========================================================================
  # SYSTEM
  # ==========================================================================

  # NixOS version - DO NOT CHANGE after installation
  system.stateVersion = "24.11";
}
