# hsb2 - Raspberry Pi Zero W
# Primary Purpose: Lightweight home server for future automation tasks
{
  pkgs,
  lib,
  inputs,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.nix
    ../../modules/uzumaki
    inputs.disko.nixosModules.disko
  ];

  # Resolve conflict between disko and native sdImage builder
  # sdImage expects / to be labeled NIXOS_SD
  fileSystems."/".device = lib.mkForce "/dev/disk/by-label/NIXOS_SD";

  # ============================================================================
  # UZUMAKI MODULE - Fish functions, zellij, stasysmo (minimal for Pi)
  # ============================================================================
  uzumaki = {
    enable = true;
    role = "server";
    fish.editor = "nano";
    stasysmo.enable = true;
  };

  # ============================================================================
  # Networking Configuration
  # ============================================================================
  networking = {
    hostName = "hsb2";
    nameservers = [ "192.168.1.99" ]; # hsb0 DNS
    search = [ "lan" ];
    defaultGateway = "192.168.1.5";

    # WiFi configuration (Pi Zero W has no ethernet)
    wireless = {
      enable = true;
      interfaces = [ "wlan0" ];
      # Network will be configured via wpa_supplicant or NetworkManager
    };

    interfaces.wlan0 = {
      ipv4.addresses = [
        {
          address = "192.168.1.95";
          prefixLength = 24;
        }
      ];
    };

    # Firewall - minimal for low-resource Pi
    firewall = {
      enable = true;
      allowedTCPPorts = [
        22 # SSH
      ];
    };
  };

  # Enable SSH
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # ============================================================================
  # System Packages (minimal for 512MB RAM)
  # ============================================================================
  environment.systemPackages = with pkgs; [
    # Essential tools only
    htop
    iotop
    # Secret management
    rage
    inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];

  # ============================================================================
  # ZFS - DISABLED (requires 2GB+ RAM)
  # ============================================================================
  # Pi Zero W only has 512MB RAM, insufficient for ZFS
  services.zfs.autoScrub.enable = lib.mkForce false;

  # ============================================================================
  # Hokage Configuration
  # ============================================================================
  hokage = {
    catppuccin.enable = false;
    hostName = "hsb2";
    userLogin = "mba";
    userNameLong = "Markus Barta";
    userNameShort = "Markus";
    userEmail = "markus@barta.com";
    role = "server-home";
    useInternalInfrastructure = false;
    useSecrets = true;
    useSharedKey = false;
    zfs.enable = false; # Disabled for Pi
    audio.enable = false;
    programs.git.enableUrlRewriting = false;
    programs.nixbit.repository = "https://github.com/markus-barta/nixcfg.git";
  };

  # ============================================================================
  # SSH Key Security (Markus-only)
  # ============================================================================
  users.users.mba = {
    openssh.authorizedKeys.keys = lib.mkForce [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H1iVXWYKnHkxQsS7tGsZq3SoHxlVccd+kroMC/DhC4MWwVnJInWwDpo/bz7LiLuh+1Bmq04PswD78EiHVVQ+O7Ckk32heWrywD2vufihukhKRTy5zl6uodb5+oa8PBholTnw09d3M0gbsVKfLEi4NDlgPJiiQsIU00ct/y42nI0s1wXhYn/Oudfqh0yRfGvv2DZowN+XGkxQQ5LSCBYYabBK/W9imvqrxizttw02h2/u3knXcsUpOEhcWJYHHn/0mw33tl6a093bT2IfFPFb3LE2KxUjVqwIYz8jou8cb0F/1+QJVKtqOVLMvDBMqyXAhCkvwtEz13KEyt"
    ];
  };

  # Passwordless sudo
  security.sudo-rs.wheelNeedsPassword = false;

  # ============================================================================
  # NixFleet Agent (optional - disabled by default for low-resource Pi)
  # ============================================================================
  # Uncomment after initial setup if resources allow
  # services.nixfleet-agent = {
  #   enable = true;
  #   url = "wss://fleet.barta.cm/ws";
  #   interval = 60; # Longer interval for low-resource system
  #   tokenFile = "/run/agenix/nixfleet-token";
  #   repoUrl = "https://github.com/markus-barta/nixcfg.git";
  #   user = "mba";
  #   logLevel = "warn";
  #   location = "home";
  #   deviceType = "server";
  # };
}
