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
  config,
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

    # INSPR-73 (2026-05-04): system-side ssh-authorized — see the
    # `inspr.ssh.authorized.users.mba` block below + the per-host
    # extraKeys for the node-red container's mba@hsb1 ed25519.
    inputs.inspr-modules.nixosModules.ssh-authorized
    ../../modules/shared/ssh-authorized-nixos.nix
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
  # Commented out 2026-04-30 as a small boot-path cleanup while
  # investigating an SDDM autologin DRM race. kmscon was initially
  # suspected, but post-fix evidence ruled it out (kmsconvt@tty1 was
  # already inactive during the failure). Leaving it disabled because
  # the kernel `console.font` above already gives a readable big-font
  # tty1, so there is no day-to-day visual change. See
  # docs/AUTOLOGIN-RACE.md for the full analysis + rollback.
  # services.kmscon.extraConfig = "font-size = 26";

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

  users.users.omega = {
    description = "Patrizio Bekerle";
  };

  # TODO: Enable home-manager for "omega" user
  # home-manager.users.omega = config.home-manager.users.mba;

  # ============================================================================
  # INSPR-73 (2026-05-04) — Declarative SSH inbound trust (NixOS + HM)
  # ============================================================================
  # Two complementary modules; both consume the same shared keyring at
  # ../../modules/shared/ssh-keyring.nix (single source of truth).
  #
  # 1. NixOS-scope module — inspr-modules nixosModules.ssh-authorized
  #    Renders into users.users.mba.openssh.authorizedKeys.keys, which
  #    NixOS materializes as /etc/ssh/authorized_keys.d/mba. Imported
  #    in the top-level `imports` list above; configured in the
  #    `inspr.ssh.authorized = { ... };` block below.
  #
  # 2. HM-scope module — inspr-modules homeManagerModules.ssh-authorized
  #    Renders into ~/.ssh/authorized_keys (marker-block managed, since
  #    INSPR-43 Phase 3). Imported via `home-manager.users.mba.imports`
  #    below; configured via `inspr.ssh.authorized = { ... };` at HM
  #    scope (note: SAME option-path string, but different scope, so no
  #    conflict).
  #
  # sshd reads BOTH /etc/ssh/authorized_keys.d/mba AND ~/.ssh/authorized_keys
  # per `AuthorizedKeysFile %h/.ssh/authorized_keys /etc/ssh/authorized_keys.d/%u`,
  # so the two are complementary not competing. On gpc0 today they admit
  # an identical key set (legacy RSA + 2 ed25519s); the HM-side file is
  # also the safety net during this NixOS-side migration.
  #
  # `force = false` here — gpc0 has no upstream hokage server-home
  # injection to displace (cf. csb0/csb1/hsb0/hsb1 where the omega/Yubi
  # keys would otherwise leak in). List-merge semantics is the safer
  # default during rollout.
  #
  # `extraKeys` carries the one-off mba@hsb1 ed25519 used by the node-red
  # container ssh calls (formerly miniserver24) — kept as raw because
  # this key is gpc0-specific, not fleet-shared, so it doesn't belong
  # in the shared keyring.
  inspr.ssh.authorized = {
    enable = true;
    users.mba = {
      trust = config._inspr.trustPresets.personalHosts;
      force = false;
      extraKeys = [
        # node-red container ssh calls (formerly miniserver24)
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAhUleyXsqtdA4LC17BshpLAw0X1vMLNKp+lOLpf2bw1 mba@hsb1"
      ];
    };
  };

  home-manager.users.mba = { config, ... }: {
    imports = [
      inputs.inspr-modules.homeManagerModules.ssh-authorized
      ../../modules/shared/ssh-authorized.nix
    ];
    inspr.ssh.authorized = {
      enable = true;
      trust  = config._inspr.trustPresets.personalHosts;
    };
  };

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
  # NIXFLEET AGENT - Disabled (decommissioned, replaced by FleetCom DSC26-52)
  # ============================================================================
  # age.secrets.nixfleet-token.file = ../../secrets/nixfleet-token.age;

  # services.nixfleet-agent = {
  #   enable = true;
  #   url = "wss://fleet.barta.cm/ws";
  #   interval = 5;
  #   tokenFile = "/run/agenix/nixfleet-token";
  #   repoUrl = "https://github.com/markus-barta/nixcfg.git";
  #   user = "mba";
  #   logLevel = "info";
  #   location = "home";
  #   deviceType = "gaming";
  # };

  # FleetCom agent — now runs as Docker container (FLEET-12)
  # Token kept for Docker agent .env: cat /run/agenix/fleetcom-token-gpc0
  age.secrets.fleetcom-token-gpc0.file = ../../secrets/fleetcom-token-gpc0.age;
}
