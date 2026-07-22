# hsb9 server - Parents-in-law home automation server (Mac mini Late 2009)
{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:
let
  hostdashHsb9 = inputs.hostdash.packages.${pkgs.stdenv.hostPlatform.system}.hsb9;

  # ============================================================================
  # LOCATION CONFIGURATION
  # ============================================================================
  # Set location before deploying:
  # - "jhw22"          = Markus' home (192.168.1.5 gateway, miniserver99 DNS)
  # - "parents-in-law" = Live since 2026-05-31: 192.168.1.1 gateway, Cloudflare DNS (confirmed on-site)
  # ============================================================================
  location = "parents-in-law"; # was "jhw22" — physically moved 2026-05-31 (NIX-138)

  gatewayIP =
    if location == "jhw22" then
      "192.168.1.5" # Markus' home: Fritz!Box
    else
      "192.168.1.1"; # Parents-in-law: Fritz!Box (confirmed on-site 2026-05-31)

  dnsServers =
    if location == "jhw22" then
      [
        "192.168.1.99" # Markus' home: miniserver99 (AdGuard Home)
        "1.1.1.1" # Cloudflare fallback
      ]
    else
      [
        "1.1.1.1" # Parents-in-law: Cloudflare (no local AdGuard there)
        "1.0.0.1"
      ];

  staticIP =
    if location == "jhw22" then
      "192.168.1.203" # Current DHCP-reserved address at Markus' home
    else
      "192.168.1.200"; # Live static address at parents-in-law (since 2026-05-31)
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/uzumaki

    # INSPR-73: System-side ssh-authorized — mba-only with mkForce to
    # drop hokage's external operator-key injection (family-server rule).
    # Mirrors hsb8's pattern but single-user (no `gb`).
    inputs.inspr-modules.nixosModules.ssh-authorized
    ../../modules/shared/ssh-authorized-nixos.nix
  ];

  # ==========================================================================
  # UZUMAKI MODULE
  # ==========================================================================
  uzumaki = {
    enable = true;
    role = "server";
    ncps.enable = false; # Eventually offsite; no LAN binary-cache reachable
  };

  # ==========================================================================
  # HOKAGE MODULE
  # ==========================================================================
  hokage = {
    catppuccin.enable = false; # Use Tokyo Night
    hostName = "hsb9";
    userLogin = "mba";
    userNameLong = "Markus Barta";
    userNameShort = "Markus";
    userEmail = "markus@barta.com";
    role = "server-home";
    useInternalInfrastructure = false;
    useSecrets = false; # No agenix secrets yet (flip when MQTT/HA wired)
    useSharedKey = false;
    zfs.enable = false; # ext4 root (4 GB RAM is below ZFS comfort)
    audio.enable = false; # Headless
    programs.git.enableUrlRewriting = false;
    programs.nixbit.repository = "https://github.com/markus-barta/nixcfg.git";
  };

  # Validate location setting
  assertions = [
    {
      assertion = location == "jhw22" || location == "parents-in-law";
      message = "location must be 'jhw22' or 'parents-in-law'. Current: ${location}";
    }
  ];

  # ==========================================================================
  # BOOT — Macmini3,1: 32-bit EFI, install GRUB to MBR (BIOS/CSM path)
  # ==========================================================================
  boot.loader.grub = {
    enable = true;
    devices = [ "/dev/sda" ];
    useOSProber = false;
    efiSupport = false;
  };

  # Pin kernel 6.18 (matches msbp's stable Mac mini 2009 config). Kernel
  # 6.12.x had a forcedeth (NVIDIA MCP79 NIC) regression on this hardware
  # that was a contributing factor to the install-day boot hangs.
  boot.kernelPackages = pkgs.linuxPackages_6_18;

  # NIX-138 root cause workaround: `dhcpcd`'s broadcast-before-link-up
  # races forcedeth's TX-queue init on this NIC, wedging the queue and
  # cascading into a CPU#1 RCU stall. Static IP (below) avoids it.

  # NIX-138 diagnostic insurance: dump forcedeth TX ring on next watchdog.
  boot.extraModprobeConfig = ''
    options forcedeth debug_tx_timeout=1
  '';

  # BCM4321 WiFi (b43) — no firmware ships; we're wired-only. Blacklist
  # to silence the boot-time "Firmware file b43/ucode11.fw not found" errors.
  boot.blacklistedKernelModules = [
    "b43"
    "b43legacy"
  ];

  hardware.enableRedistributableFirmware = true;

  # ==========================================================================
  # NETWORK
  # ==========================================================================
  networking = {
    hostName = "hsb9";
    networkmanager.enable = false;
    useDHCP = false;
    defaultGateway = gatewayIP;
    nameservers = dnsServers;
    search = [ "lan" ]; # both sites: ".local" collides with mDNS (RFC 6762)

    interfaces.enp0s10 = {
      useDHCP = false;
      ipv4.addresses = [
        {
          address = staticIP;
          prefixLength = 24;
        }
      ];
    };

    firewall = {
      enable = true;
      allowedTCPPorts = [
        22 # SSH
        80 # HostDash
        1883 # MQTT (mosquitto)
        8123 # Home Assistant
        # 8080 # Zigbee2MQTT UI — open when the dongle lands (NIX-140)
      ];
      allowedUDPPorts = [
        41641 # Tailscale
      ];
    };
  };

  # Local fallback for site DNS: hsb9 runs with Cloudflare resolvers at the
  # parents-in-law site, so declare its own LAN names explicitly.
  networking.hosts = {
    "${staticIP}" = [
      "hsb9"
      "hsb9.lan"
    ];
  };

  # ==========================================================================
  # SSH — family-server lockdown (mba only)
  # ==========================================================================
  # ssh-authorized: drop hokage's external operator-key admissions. mba's
  # personal-host keys are the only inbound trust on hsb9.
  inspr.ssh.authorized = {
    enable = true;
    users.mba = {
      trust = config._inspr.trustPresets.personalHosts;
      force = true;
    };
  };

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # ==========================================================================
  # SYSTEM
  # ==========================================================================
  time.timeZone = "Europe/Vienna";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";

  security.sudo.wheelNeedsPassword = false;
  # NixOS unstable defaults to sudo-rs (Rust rewrite). The classic sudo
  # toggle above is a no-op when sudo-rs is the actual binary. Set both.
  security.sudo-rs.wheelNeedsPassword = false;

  # ==========================================================================
  # CONSOLE RECOVERY PASSWORD (NIX-198 per-host standardisation, 2026-06-28)
  # ==========================================================================
  # hsb9 lives offsite at the parents-in-law behind a Fritz!Box, reachable only
  # via Tailscale — without a console password a network/Tailscale outage left
  # NO way in. This hash mirrors the LIVE /etc/shadow value (set via `passwd`),
  # so config == reality and a reinstall reproduces it. Plaintext in 1Password
  # vault "Familie Barta", entry "hsb9 - system login". SSH key auth unaffected;
  # PasswordAuthentication stays off. (Already live — no switch required.)
  users.users.mba.initialHashedPassword = lib.mkForce null;
  users.users.mba.hashedPassword = "$y$j9T$Kd0VTmZ4AjlUNXFJhMU/N.$RHQ22ipCdJHqQt.qTQPkI0EHrDxZHB1ns2DRc5x5ikA";

  # ==========================================================================
  # TAILSCALE — joins the fleet's Headscale at hs.barta.cm
  # ==========================================================================
  # `tailscale up` after first rebuild:
  #   sudo tailscale up --login-server=https://hs.barta.cm --authkey=<preauth>
  # (preauth key generated on csb0 via headscale CLI)
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
    # hsb9 keeps its static resolver (.99 / 1.1.1.1) — do NOT let tailscaled
    # take over resolvconf. With accept-dns left at the default (true), a
    # logged-out tailscaled grabbed resolvconf and emptied /etc/resolv.conf,
    # which then blocked it from reaching hs.barta.cm to log in (NIX-138
    # chicken-and-egg). The live pref is already set via `tailscale up
    # --accept-dns=false` (persisted in tailscaled.state); this documents it
    # and covers any future authKeyFile-driven auto-up.
    extraUpFlags = [ "--accept-dns=false" ];
  };

  zramSwap = {
    enable = true;
    memoryPercent = 50;
    algorithm = "zstd";
  };

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    trusted-users = [
      "root"
      "@wheel"
    ];
  };

  environment.systemPackages = with pkgs; [
    git
    vim
    curl
    wget
    htop
    tmux
    file
    pciutils
    usbutils
    ethtool
  ];

  # ==========================================================================
  # HostDash — static LAN service dashboard for hsb9
  # ==========================================================================
  systemd.services.hsb9-home-dashboard = {
    description = "hsb9 HostDash nginx dashboard";
    after = [
      "docker.service"
      "network-online.target"
    ];
    requires = [ "docker.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    restartTriggers = [
      (builtins.readFile ./docker/docker-compose.yml)
      hostdashHsb9
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.docker-compose}/bin/docker-compose -p docker -f /home/mba/Code/nixcfg/hosts/hsb9/docker/docker-compose.yml up -d --force-recreate --no-deps hsb9-home";
      TimeoutStartSec = "180";
    };
  };

  environment.etc."hostdash/hsb9".source = hostdashHsb9;

  # Pharos beacon per-host token. Docker Compose reads it as an env_file.
  age.secrets.pharos-beacon-hsb9-env = {
    file = ../../secrets/pharos-beacon-hsb9-env.age;
    path = "/run/agenix/pharos-beacon-hsb9-env";
    owner = "mba";
    group = "users";
    mode = "0400";
  };

  # hsb9 was installed at NixOS 25.05; common.nix's "24.11" is the fleet
  # baseline. mkForce keeps per-host stateVersion semantics correct.
  system.stateVersion = lib.mkForce "25.05";
}
