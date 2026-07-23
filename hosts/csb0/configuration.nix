# csb0 - Cloud Server Barta 0 (Netcup VPS)
# Smart Home Hub: Node-RED, MQTT, Telegram Bot
# Hokage Migration: 2025-11-29
{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:

let
  hostdashCsb0 = inputs.hostdash.packages.${pkgs.stdenv.hostPlatform.system}.csb0;
  csb0ComposeFile = "/home/mba/Code/nixcfg/hosts/csb0/docker/docker-compose.yml";
  csb0Compose = "${pkgs.docker-compose}/bin/docker-compose -p csb0 -f ${csb0ComposeFile}";
  csb0HostdashReconcile = pkgs.writeShellScript "csb0-hostdash-reconcile" ''
    set -eu
    ${csb0Compose} up -d --force-recreate --no-deps hostdash-auth
    ${csb0Compose} up -d --force-recreate --no-deps hostdash
    ${csb0Compose} up -d --force-recreate --no-deps traefik
  '';
in
{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.zfs.nix
    ../../modules/uzumaki # Consolidated module: fish, zellij, stasysmo
    # nixfleet-agent is now loaded via flake input (inputs.nixfleet.nixosModules.nixfleet-agent)

    # INSPR-73 (2026-05-04): system-side ssh-authorized — see the
    # inspr.ssh.authorized.users.mba block further down. force=true
    # because csb0 hokage-injects external operator keys we do not
    # want admitted on this private server. extraKeys carries the
    # one-off mba@miniserver24 (= mba@hsb1) ed25519 used by node-red
    # container ssh automation.
    inputs.inspr-modules.nixosModules.ssh-authorized
    ../../modules/shared/ssh-authorized-nixos.nix
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

  # Keep the historical post-network ZFS import, now as a supported systemd
  # initrd unit rather than the deprecated scripted stage 1.
  boot.initrd.network.enable = true;
  boot.initrd.systemd.services.csb0-zpool-import-after-network = {
    description = "Import csb0 ZFS pools after initrd networking";
    wantedBy = [ "initrd.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    before = [ "sysroot.mount" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.zfs}/bin/zpool import -a";
    };
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
    hostId = "ad684098"; # Generated from machine-id 2026-01-10
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

    # Tell NetworkManager NOT to manage ens3 or eth0 (we configure statically)
    networkmanager.unmanaged = [
      "ens3"
      "eth0"
    ];

    # Disable DHCP globally (static IP server)
    useDHCP = false;

    # Firewall - allow web traffic and SSH
    firewall = {
      allowedTCPPorts = [
        80 # HTTP
        443 # HTTPS
        2222 # SSH (hardened port)
      ];
      allowedUDPPorts = [
        41641 # Tailscale WireGuard
      ];
    };
  };

  # Tailscale VPN client (connects to headscale on csb0)
  # Note: csb0 runs the headscale server AND is a client node on its own network
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client"; # Client mode only
  };

  # ============================================================================
  # MOSQUITTO MQTT BROKER PERMISSIONS
  # ============================================================================
  users.groups.mosquitto = {
    gid = 1883;
  };

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
    zfs.hostId = "ad684098";
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

    # Fix: P6400 - Remove evaluation warning by forcing null on initialHashedPassword
    initialHashedPassword = lib.mkForce null;

    # 🚨 EMERGENCY RECOVERY PASSWORD — Netcup VNC console login if SSH fails.
    # Per-host (NIX-198, verified 2026-06-28): committed hash == live /etc/shadow.
    # Plaintext in 1Password vault "Familie Barta", entry "csb0 - system login".
    # (This $6$ was the old csb-shared hash; csb0 is now its sole holder — the
    # other hosts moved to their own per-host hashes. Same plaintext as the
    # legacy "csb0 • cs0 • csb1 • cs1 • nix shell" entry.)
    hashedPassword = "$6$ee9NiRR00Ev9wlEZ$kFD53waKDKf5YHC.Tzwm68Iwhjey7om9Yld4i9cUBLa40HdpL8.umjtIpWnjCmzKzgsGUgS3y.Tx2UQOUp5AN.";

    # NOTE: openssh.authorizedKeys.keys removed in INSPR-73 — the system-side
    # render is now declarative via inspr.ssh.authorized.users.mba below.
  };

  # ============================================================================
  # INSPR-73 (2026-05-04) — Declarative SSH inbound trust (NixOS + HM)
  # ============================================================================
  # System-side: inspr-modules nixosModules.ssh-authorized renders into
  # users.users.mba.openssh.authorizedKeys.keys → /etc/ssh/authorized_keys.d/mba.
  # HM-side: inspr-modules homeManagerModules.ssh-authorized renders into
  # ~/.ssh/authorized_keys (marker block).
  # Both consume the same shared keyring at modules/shared/ssh-keyring.nix.
  #
  # force = true here because csb0 (server-home / hokage profile) injects
  # external operator keys we do NOT want admitted on this private server.
  # mkForce-wrap drops them. (Defence-in-depth: matches the lib.mkForce
  # posture the previous manual declaration used.)
  #
  # extraKeys carries the one-off mba@miniserver24 ed25519 — used by the
  # Node-RED container's SSH automation calls into csb0. Not in the shared
  # keyring because it is csb-context only (not fleet-shared).
  inspr.ssh.authorized = {
    enable = true;
    users.mba = {
      trust = config._inspr.trustPresets.personalHosts;
      force = true;
      extraKeys = [
        # hsb1 (miniserver24): Node-RED container SSH automation
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAhUleyXsqtdA4LC17BshpLAw0X1vMLNKp+lOLpf2bw1 mba@miniserver24"
      ];
    };
  };

  home-manager.users.mba =
    { config, ... }:
    {
      imports = [
        inputs.inspr-modules.homeManagerModules.ssh-authorized
        ../../modules/shared/ssh-authorized.nix
      ];
      inspr.ssh.authorized = {
        enable = true;
        trust = config._inspr.trustPresets.personalHosts;
      };
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
  # HostDash — static public service dashboard for csb0
  # ============================================================================
  # Traefik owns public 80/443 on the cloud hosts. Recreate HostDash first so
  # the Nix store mount is current, then recreate Traefik so its Docker provider
  # initial scan always includes the dashboard container.
  systemd.services.csb0-hostdash = {
    description = "csb0 HostDash nginx dashboard";
    after = [
      "docker.service"
      "network-online.target"
    ];
    requires = [ "docker.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    restartTriggers = [
      (builtins.readFile ./docker/docker-compose.yml)
      hostdashCsb0
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${csb0HostdashReconcile}";
      TimeoutStartSec = "240";
    };
  };

  environment.etc."hostdash/csb0".source = hostdashCsb0;

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
  # NIXFLEET AGENT - Disabled (decommissioned, replaced by FleetCom DSC26-52)
  # ============================================================================
  # age.secrets.nixfleet-token.file = ../../secrets/nixfleet-token.age;
  age.secrets.nodered-env = {
    file = ../../secrets/nodered-env.age;
    owner = "mba";
  };
  age.secrets.mosquitto-passwd = {
    file = ../../secrets/mosquitto-passwd.age;
    mode = "644";
    owner = "1883";
    group = "1883";
  };
  age.secrets.mosquitto-conf = {
    file = ../../secrets/mosquitto-conf.age;
    mode = "644";
    owner = "1883";
    group = "1883";
  };
  age.secrets.restic-hetzner-ssh-key = {
    file = ../../secrets/restic-hetzner-ssh-key.age;
    owner = "mba";
  };
  age.secrets.restic-hetzner-env = {
    file = ../../secrets/restic-hetzner-env.age;
    owner = "mba";
  };
  age.secrets.uptime-kuma-env = {
    file = ../../secrets/uptime-kuma-env.age;
    owner = "mba";
  };
  age.secrets.traefik-variables = {
    file = ../../secrets/traefik-variables.age;
    path = "/var/lib/csb0-docker/traefik/variables.env";
    owner = "root";
    group = "root";
    mode = "0644";
  };

  age.secrets.csb-hostdash-oauth2-proxy-env = {
    file = ../../secrets/csb-hostdash-oauth2-proxy-env.age;
    path = "/run/agenix/csb-hostdash-oauth2-proxy-env";
    owner = "root";
    group = "root";
    mode = "0644";
  };

  age.secrets.mqtt-csb0 = {
    file = ../../secrets/mqtt-csb0.age;
    owner = "mba";
    group = "users";
    mode = "0644";
  };

  # services.nixfleet-agent = {
  #   enable = true;
  #   url = "wss://fleet.barta.cm/ws";
  #   interval = 5;
  #   tokenFile = "/run/agenix/nixfleet-token";
  #   repoUrl = "https://github.com/markus-barta/nixcfg.git";
  #   user = "mba";
  #   logLevel = "info";
  #   location = "cloud";
  #   deviceType = "server";
  # };

  # Pharos beacon per-host token. Docker Compose reads it as an env_file.
  age.secrets.pharos-beacon-csb0-env = {
    file = ../../secrets/pharos-beacon-csb0-env.age;
    path = "/run/agenix/pharos-beacon-csb0-env";
    owner = "mba";
    group = "users";
    mode = "0400";
  };

  # ============================================================================
  # UPTIME KUMA - Cloud services monitoring
  # ============================================================================
  # Uptime Kuma now runs as Docker service (consistent with other services)
  # Configuration moved to hosts/csb0/scripts/docker-compose.yml
  # See P6000 task for details
}
