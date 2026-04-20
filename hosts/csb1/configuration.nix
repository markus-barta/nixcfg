# csb1 - Cloud Server Barta 1 (Netcup VPS)
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

  # Keep scripted stage 1 initrd: `boot.initrd.network.postCommands` below is
  # not supported under systemd stage 1 (nixpkgs default flipped). Revisit
  # migration to `boot.initrd.systemd.services.*` when console-testable.
  boot.initrd.systemd.enable = lib.mkForce false;

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
  # 🚨 STATIC IP CONFIG - Prevents lockout during deploy (incident 2025-12-05)
  # Root cause: NetworkManager had no connection profile after generation switch
  # Fix: Declarative static IP that NixOS manages, NM ignores
  networking = {
    hostName = "csb1";
    hostId = "dabfdc02"; # Required for ZFS
    networkmanager.enable = true;

    # Static IP for Netcup VPS
    interfaces.ens3 = {
      useDHCP = false;
      ipv4.addresses = [
        {
          address = "152.53.64.166";
          prefixLength = 24;
        }
      ];
    };

    defaultGateway = "152.53.64.1";
    nameservers = [
      "8.8.8.8"
      "8.8.4.4"
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
      allowedUDPPorts = [
        41641 # Tailscale WireGuard
      ];
    };
  };

  # Tailscale VPN client (connects to headscale on csb0)
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client"; # Client mode only
  };

  # ============================================================================
  # DOCKER COMPOSE SETUP - Declarative directory structure
  # ============================================================================
  # Separation of concerns:
  # - /home/mba/docker/ = current location (real files, not in git yet)
  # - /var/lib/csb1-docker/ = future runtime directory (mutable state)
  # - /run/agenix/ = decrypted secrets (ephemeral)
  #
  # TODO: Move docker files to git repo like csb0 (separate task)

  systemd.tmpfiles.rules =
    let
      dockerRoot = "/var/lib/csb1-docker";
    in
    [
      # Create runtime directory structure
      "d ${dockerRoot} 0755 mba users -"
      "d ${dockerRoot}/traefik 0755 mba users -"

      # Create mutable files (Docker writes to these)
      "f ${dockerRoot}/traefik/acme.json 0600 root root -"

      # Legacy compatibility: keep /home/mba/docker as primary location for now
      # Will migrate to /var/lib/csb1-docker in future task
    ];

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
  # PPM CI DEPLOY — restricted script for test report uploads
  # ============================================================================
  # GitHub Actions sends: tar czf - reports/ | ssh -p 2222 mba@... ppm-deploy-reports
  # The command= restriction in authorized_keys ensures this key can ONLY run this script.
  environment.etc."ppm-deploy-reports.sh" = {
    mode = "0755";
    text = ''
      #!/bin/sh
      set -eu
      docker exec ppm mkdir -p /app/data/test-reports
      TMPDIR=$(mktemp -d)
      tar xzf - -C "$TMPDIR"
      docker cp "$TMPDIR/." ppm:/app/data/test-reports/
      rm -rf "$TMPDIR"
      echo "ok: reports deployed"
    '';
  };

  # ============================================================================
  # PAIMOS DEPLOY — pull latest GHCR image and restart ppm container
  # ============================================================================
  # Image: ghcr.io/markus-barta/paimos (tag pinned in ~/docker/docker-compose.yml,
  # typically `:latest`). Assumes that file already points at the GHCR image.
  environment.etc."paimos-deploy.sh" = {
    mode = "0755";
    text = ''
      #!/bin/sh
      set -eu
      cd /home/mba/docker
      docker compose pull ppm
      docker compose up -d ppm
      echo "ok: ppm updated"
    '';
  };

  # ============================================================================
  # FLEETCOM CI DEPLOY — pull latest image and restart container
  # ============================================================================
  # GitHub Actions: ssh -p 2222 mba@csb1 fleetcom-deploy
  # The command= restriction in authorized_keys ensures this key can ONLY run this script.
  environment.etc."fleetcom-deploy.sh" = {
    mode = "0755";
    text = ''
      #!/bin/sh
      set -eu
      cd /home/mba/docker/fleetcom
      docker compose pull
      docker compose up -d
      echo "ok: fleetcom deployed"
    '';
  };

  # ============================================================================
  # HOKAGE MODULE CONFIGURATION
  # ============================================================================
  hokage = {
    catppuccin.enable = false; # Use Tokyo Night theme instead
    hostName = "csb1";
    userLogin = "mba";
    userNameLong = "Markus Barta";
    userNameShort = "Markus";
    userEmail = "markus@barta.com";
    role = "server-remote";
    useInternalInfrastructure = false;
    useSecrets = true;
    useSharedKey = false;
    zfs.enable = true;
    zfs.hostId = "dabfdc02";
    programs.git.enableUrlRewriting = false;
    # Point nixbit to Markus' repository (not pbek's default)
    programs.nixbit.repository = "https://github.com/markus-barta/nixcfg.git";
    # NOTE: starship & atuin are configured via common.nix (DRY pattern)
  };

  # ============================================================================
  # 🚨 SSH KEY SECURITY - CRITICAL FIX FROM hsb8/hsb1 INCIDENTS
  # ============================================================================
  # The external hokage server-cloud module auto-injects external SSH keys
  # (omega@yubikey, omega@rsa, etc). We use lib.mkForce to REPLACE these
  # with ONLY authorized keys.
  #
  # Security Policy: csb1 allows mba (Markus) SSH keys only.
  #
  # See: docs/SSH-KEY-SECURITY.md
  # ============================================================================
  users.users.mba = {
    extraGroups = [ "mosquitto" ];

    # Fix: Remove evaluation warning by forcing null on initialHashedPassword
    initialHashedPassword = lib.mkForce null;

    # 🚨 EMERGENCY RECOVERY PASSWORD - for VNC console access if SSH fails
    # Enables login via Netcup VNC console during lockout scenarios
    # Password stored in 1Password, rotate after migration complete
    hashedPassword = "$6$ee9NiRR00Ev9wlEZ$kFD53waKDKf5YHC.Tzwm68Iwhjey7om9Yld4i9cUBLa40HdpL8.umjtIpWnjCmzKzgsGUgS3y.Tx2UQOUp5AN.";

    openssh.authorizedKeys.keys = lib.mkForce [
      # markus@iMac-5k-MBA-home.local (id_rsa)
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H1iVXWYKnHkxQsS7tGsZq3SoHxlVccd+kroMC/DhC4MWwVnJInWwDpo/bz7LiLuh+1Bmq04PswD78EiHVVQ+O7Ckk32heWrywD2vufihukhKRTy5zl6uodb5+oa8PBholTnw09d3M0gbsVKfLEi4NDlgPJiiQsIU00ct/y42nI0s1wXhYn/Oudfqh0yRfGvv2DZowN+XGkxQQ5LSCBYYabBK/W9imvqrxizttw02h2/u3knXcsUpOEhcWJYHHn/0mw33tl6a093bT2IfFPFb3LE2KxUjVqwIYz8jou8cb0F/1+QJVKtqOVLMvDBMqyXAhCkvwtEz13KEyt"
      # hsb1 (miniserver24): Node-RED container SSH automation
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAhUleyXsqtdA4LC17BshpLAw0X1vMLNKp+lOLpf2bw1 mba@miniserver24"
      # PPM CI deploy key — command-restricted to test report uploads only
      "command=\"/etc/ppm-deploy-reports.sh\",no-port-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN2B8Ya6hnF5nxhZ7uBtN/YfChRRHIjsv+GIa01XdiI1 ppm-ci-deploy"
      # FleetCom CI deploy key — command-restricted to docker pull + restart
      "command=\"/etc/fleetcom-deploy.sh\",no-port-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJbe5h6FEOzyrh4f7I9RS84KOD9hKiVaBgjizcX3ztxS fleetcom-ci-deploy"
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
  #   modules/uzumaki/common.nix → modules/shared/theme-hm.nix
  #
  # Theme: Blue (cloud server identity)
  # See: modules/shared/theme-palettes.nix for color definitions
  #
  # Note: Zellij, fish functions, and stasysmo come from modules/uzumaki

  # ============================================================================
  # NIXFLEET AGENT - Disabled (decommissioned, replaced by FleetCom DSC26-52)
  # ============================================================================
  # age.secrets.nixfleet-token.file = ../../secrets/nixfleet-token.age;

  # Traefik Cloudflare API token (for DNS-01 ACME challenge)
  # TODO: Move to /var/lib/csb1-docker when docker files are in repo
  age.secrets.traefik-variables = {
    file = ../../secrets/traefik-variables.age;
    path = "/home/mba/docker/traefik/variables.env";
    owner = "root";
    group = "root";
    mode = "0644";
  };

  # PPM (Personal Project Management) Docker env
  # Format: KEY=VALUE (ADMIN_PASSWORD for first-run seed)
  age.secrets.csb1-ppm-env = {
    file = ../../secrets/csb1-ppm-env.age;
    path = "/run/agenix/csb1-ppm-env";
    owner = "root";
    group = "root";
    mode = "0644";
  };

  # MinIO Docker env (PPM attachment storage)
  # Format: KEY=VALUE (MINIO_ROOT_USER, MINIO_ROOT_PASSWORD)
  age.secrets.csb1-minio-env = {
    file = ../../secrets/csb1-minio-env.age;
    path = "/run/agenix/csb1-minio-env";
    owner = "root";
    group = "root";
    mode = "0644";
  };

  # FleetCom Docker env (password hash + TOTP secret)
  # Format: KEY=VALUE (FLEETCOM_PASSWORD_HASH, FLEETCOM_TOTP_SECRET)
  age.secrets.csb1-fleetcom-env = {
    file = ../../secrets/csb1-fleetcom-env.age;
    path = "/run/agenix/csb1-fleetcom-env";
    owner = "root";
    group = "root";
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

  # FleetCom agent — now runs as Docker container (FLEET-12)
  # Token kept for Docker agent .env: cat /run/agenix/fleetcom-token-csb1
  age.secrets.fleetcom-token-csb1.file = ../../secrets/fleetcom-token-csb1.age;

  # FLEET-51/52: per-gateway operator identity FleetCom uses to connect
  # to each OpenClaw gateway via WS. Mounted into the fleetcom container
  # at /run/agenix/fleetcom-openclaw-<host>-{key,tok}; the manager picks
  # them up on reconcile and starts auto-approving bridge pairings.
  age.secrets.fleetcom-openclaw-hsb0-key = {
    file = ../../secrets/fleetcom-openclaw-hsb0-key.age;
    path = "/run/agenix/fleetcom-openclaw-hsb0-key";
    mode = "0400";
  };
  age.secrets.fleetcom-openclaw-hsb0-tok = {
    file = ../../secrets/fleetcom-openclaw-hsb0-tok.age;
    path = "/run/agenix/fleetcom-openclaw-hsb0-tok";
    mode = "0400";
  };
}
