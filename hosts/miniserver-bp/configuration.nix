{ pkgs, ... }:

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
  networking.wireguard.interfaces.wg0 = {
    ips = [ "10.100.0.51/32" ];

    # Private key copied by nixos-anywhere --extra-files
    privateKeyFile = "/etc/nixos/secrets/wireguard-private.key";

    peers = [
      {
        # BYTEPOETS VPN server
        publicKey = "TZHbPPkIaxlpLKP2frzJl8PmOjYaRnfz/MqwCS7JDUQ=";
        endpoint = "vpn.bytepoets.net:51820";
        allowedIPs = [ "10.100.0.0/24" ];
        persistentKeepalive = 25;
      }
    ];
  };

  # ==========================================================================
  # SSH SERVER
  # ==========================================================================

  services.openssh = {
    enable = true;

    # Preserve host keys from Ubuntu installation
    # Prevents "host key changed" warnings for existing clients
    # Copied by nixos-anywhere --extra-files
    hostKeys = [
      {
        path = "/secrets/ssh_host_ed25519_key";
        type = "ed25519";
      }
      {
        path = "/secrets/ssh_host_rsa_key";
        type = "rsa";
        bits = 4096;
      }
    ];

    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = true; # Allow password auth for initial setup
      X11Forwarding = true;
    };
  };

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

    # Your SSH public key for passwordless access
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H1iVXWYKnHkxQsS7tGsZq3SoHxlVccd+kroMC/DhC4MWwVnJInWwDpo/bz7LiLuh+1Bmq04PswD78EiHVVQ+O7Ckk32heWrywD2vufihukhKRTy5zl6uodb5+oa8PBholTnw09d3M0gbsVKfLEi4NDlgPJiiQsIU00ct/y42nI0s1wXhYn/Oudfqh0yRfGvv2DZowN+XGkxQQ5LSCBYYabBK/W9imvqrxizttw02h2/u3knXcsUpOEhcWJYHHn/0mw33tl6a093bT2IfFPFb3LE2KxUjVqwIYz8jou8cb0F/1+QJVKtqOVLMvDBMqyXAhCkvwtEz13KEyt" # markus@iMac-5k-MBA-home.local
    ];
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

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

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
