# gpc0 - Gaming PC 0 (formerly mba-gaming-pc)
#
# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running 'nixos-help').
#
# To test in a VM, run:
# nixos-rebuild --flake .#gpc0 build-vm
# just boot-vm-no-kvm
#

{
  pkgs,
  inputs,
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
  # UZUMAKI MODULE - Fish functions, zellij, stasysmo (all-in-one)
  # ============================================================================
  uzumaki = {
    enable = true;
    role = "desktop";
    fish.editor = "nano";
    stasysmo.enable = true; # System metrics in Starship prompt
  };

  environment.systemPackages = with pkgs; [
    amdgpu_top # AMD GPU monitoring
    lact # AMD GPU monitoring
    _1password-gui # 1Password GUI client
    mplayer
    vlc
    brave # Brave browser
    inputs.helium-nix.packages.${pkgs.stdenv.hostPlatform.system}.helium
    # Audio not working on e.g. X (Twitter) and Tiktok
    # (callPackage ../../pkgs/zen-browser/package.nix { })
  ];

  # Enable hardware accelerated graphics drivers
  hardware.graphics.enable = true;

  # https://wiki.nixos.org/wiki/AMD_GPU
  services.xserver.videoDrivers = [ "amdgpu" ];
  boot.initrd.kernelModules = [ "amdgpu" ];

  # Make the console font bigger
  console.font = "${pkgs.terminus_font}/share/consolefonts/ter-u20n.psf.gz";

  # Increase the console font size for kmscon
  services.kmscon.extraConfig = "font-size = 26";

  # Enable flatpak support
  services.flatpak.enable = true;

  # ============================================================================
  # AUTOLOGIN CONFIGURATION
  # ============================================================================
  # Why autologin? When booting with TV off, SDDM's Wayland greeter starts but
  # quits after ~1 minute when it can't find a display. By the time you turn on
  # the TV, there's no login screen - just boot text stuck on screen.
  #
  # With autologin, Plasma starts immediately after boot, so when you turn on
  # the TV, the desktop is already ready.
  #
  # Security consideration: This is a gaming PC on a trusted home network
  # connected to a TV. Physical access = desktop access is acceptable here.
  # ============================================================================
  services.displayManager.autoLogin = {
    enable = true;
    user = "mba";
  };

  # Auto-unlock KDE Wallet on autologin (no password prompt at login)
  security.pam.services.sddm.enableKwallet = true;

  programs.gamescope = {
    enable = true;
    capSysNice = true;
  };

  programs.steam.gamescopeSession.enable = true; # Integrates with programs.steam

  # Networking configuration
  networking = {
    nameservers = [
      "192.168.1.99" # hsb0 / AdGuard Home
      "1.1.1.1" # Cloudflare fallback
    ];
    search = [ "lan" ];
    hosts = {
      # This DNS/DHCP server itself - local resolution for core services
      "192.168.1.99" = [
        "hsb0"
        "hsb0.lan"
      ];
      # Home automation server
      "192.168.1.101" = [
        "hsb1"
        "hsb1.lan"
      ];
      # This server itself
      "192.168.1.154" = [
        "gpc0"
        "gpc0.lan"
      ];
    };
  };

  users.users.mba = {
    openssh.authorizedKeys.keys = [
      # Markus public key
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H1iVXWYKnHkxQsS7tGsZq3SoHxlVccd+kroMC/DhC4MWwVnJInWwDpo/bz7LiLuh+1Bmq04PswD78EiHVVQ+O7Ckk32heWrywD2vufihukhKRTy5zl6uodb5+oa8PBholTnw09d3M0gbsVKfLEi4NDlgPJiiQsIU00ct/y42nI0s1wXhYn/Oudfqh0yRfGvv2DZowN+XGkxQQ5LSCBYYabBK/W9imvqrxizttw02h2/u3knXcsUpOEhcWJYHHn/0mw33tl6a093bT2IfFPFb3LE2KxUjVqwIYz8jou8cb0F/1+QJVKtqOVLMvDBMqyXAhCkvwtEz13KEyt"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAhUleyXsqtdA4LC17BshpLAw0X1vMLNKp+lOLpf2bw1 mba@hsb1" # node-red container ssh calls (formerly miniserver24)
    ];
  };

  users.users.omega = {
    description = "Patrizio Bekerle";
  };

  # TODO: Enable home-manager for "omega" user
  # home-manager.users.omega = config.home-manager.users.mba;

  hokage = {
    catppuccin.enable = false; # Use Tokyo Night theme instead
    users = [
      "mba"
      "omega"
    ];
    hostName = "gpc0";
    userLogin = "mba";
    userNameLong = "Markus Barta";
    userNameShort = "Markus";
    userEmail = "markus@barta.com";
    useInternalInfrastructure = false;
    useSecrets = false;
    useSharedKey = false;

    # Disable features we don't need on gaming PC
    programs.espanso.enable = false;
    programs.git.enableUrlRewriting = false;

    # Exclude heavy packages that require building from source
    excludePackages = with pkgs; [
      onlyoffice-desktopeditors
      brave
    ];

    # Enable Nixbit
    programs.nixbit = {
      enable = true;
      repository = "https://github.com/markus-barta/nixcfg.git";
      forceAutostart = true;
    };

    gaming = {
      enable = true;
      ryubing.highDpi = true;
    };

    zfs = {
      enable = true;
      hostId = "96cb2b24";
      poolName = "mbazroot";
    };
  };

  # Passwordless sudo for wheel group (gaming PC - low risk, local access)
  security.sudo-rs.wheelNeedsPassword = false;

  # ============================================================================
  # NIXFLEET AGENT v2 - Fleet management dashboard agent
  # ============================================================================
  age.secrets.nixfleet-token.file = ../../secrets/nixfleet-token.age;

  services.nixfleet-agent = {
    enable = true;
    url = "wss://fleet.barta.cm/ws"; # v2 uses WebSocket
    interval = 5; # Heartbeat interval in seconds
    tokenFile = "/run/agenix/nixfleet-token";
    repoUrl = "https://github.com/markus-barta/nixcfg.git";
    user = "mba";
    logLevel = "info";
    location = "home";
    deviceType = "gaming";
  };
}
