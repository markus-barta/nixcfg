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
in
{
  imports = [
    ../../modules/shared/compose-stack # OPS-116 — containers reconciled at switch
    ./hardware-configuration.nix
    ./disk-config.zfs.nix
    ./ops-alerts.nix # OPS-104: watch all three HA instances, report to Telegram
    ../../modules/shared/fleet-alerts/heartbeat.nix # OPS-107: let csb1 see this poller is alive
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

  # OPS-116 — the container stack, rendered from Nix into the closure.
  #
  # 🟡 reconcile = false while this host is prepared: the spec lands in /etc and
  # can be diffed against the running stack, but switch does NOT run
  # `compose up -d`. Flip to true only when the cutover is intended.
  #
  # 🔴 project must stay "csb0" — named volumes are prefixed with it.
  nixcfg.composeStack = {
    enable = true;
    project = "csb0";
    stackName = "csb0";
    # 🟢 CUT OVER 2026-08-01 (OPS-121).
    reconcile = true;
    projectDirectory = "/home/mba/Code/nixcfg/hosts/csb0/docker";
    # Order matters: auth before dashboard before the edge (was the
    # csb0-hostdash unit's documented sequence).
    postRecreate = [
      "hostdash-auth"
      "hostdash"
      "traefik"
    ];
    extraRestartTriggers = [ hostdashCsb0 ];
    # Safe HERE: all project-csb0 containers are declared in the spec
    # (verified live) — reaps the retired watchtower container.
    removeOrphans = true;
    autoUpdate.enable = true;
    spec = import ./docker/compose-spec.nix;
  };

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
      # OPS-184: drop an orphaned ex-employer Tailscale client (85.125.96.34, UPC-business
      # static, RIPE MarineXChange Software GmbH, Graz). Its headscale node record was deleted
      # at the June 2026 exit, but the device still long-polls hs.barta.cm every ~15 s and
      # fills the headscale log with 'node not found' 404s (~5760/day since 2026-06-15,
      # attribution confirmed 2026-08-21 via socket byte counters). There is nothing left
      # to revoke server-side, so the block lives here. Docker-published ports (443 → traefik
      # → headscale) traverse DOCKER-USER, host ports traverse nixos-fw; both get the rule.
      # Docker creates DOCKER-USER itself; creating it first keeps this order-independent.
      # Trade-off accepted by the operator: a shared business NAT could catch a bystander.
      extraCommands = ''
        iptables -w -N DOCKER-USER 2>/dev/null || true
        iptables -w -D DOCKER-USER -s 85.125.96.34 -j DROP 2>/dev/null || true
        iptables -w -I DOCKER-USER 1 -s 85.125.96.34 -j DROP
        iptables -w -I nixos-fw 1 -s 85.125.96.34 -j DROP
      '';
      extraStopCommands = ''
        iptables -w -D DOCKER-USER -s 85.125.96.34 -j DROP 2>/dev/null || true
      '';
    };
  };

  # Tailscale VPN client (connects to headscale on csb0)
  # Note: csb0 runs the headscale server AND is a client node on its own network
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client"; # Client mode only
    # Keep the static Netcup resolvers. With accept-dns at its default (true),
    # tailscaled REPLACES the whole nameserver list with 100.100.100.100, so both
    # configured resolvers disappear and every lookup depends on tailscaled
    # answering. On this host that is acute: csb0 runs the OPS-104 fleet alert
    # poller, which must resolve api.telegram.org to report anything at all, and
    # it runs headscale itself -- so the resolver would depend on tailscaled,
    # which depends on the control plane running in a container here. hsb8 lost
    # its Tesla integration for four days to exactly this at boot (OPS-109,
    # nixcfg #153). NOTE: extraUpFlags only applies at `tailscale up`; on an
    # already-authenticated host run `sudo tailscale set --accept-dns=false`.
    extraUpFlags = [ "--accept-dns=false" ];
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
    hashedPasswordFile = config.age.secrets.csb0-recovery-password.path;

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

  # SSH password auth: DELIBERATE, not temporary (INSPR-80, decided 2026-08-18).
  #
  # This was once a migration fallback with a TODO to remove it. That TODO is
  # resolved: it stays, as the recovery path if key auth fails. The hsb1 lockout
  # is why it exists — a host with only key auth and a broken key is a host you
  # visit in person, and these two are in a datacentre.
  #
  # The risk was reassessed when the /etc/shadow verifiers were moved out of this
  # PUBLIC repo. Offline attack on the verifier is not the concern: yescrypt
  # $y$j9T$ is N=4096, r=32, 16 MiB per guess, which against a strong random
  # password is astronomically infeasible. Online guessing is bounded by
  # fail2ban, PermitRootLogin no, and a nonstandard port; 0 failed attempts in
  # the 24h sampled.
  #
  # What makes this acceptable is the credential, not the setting: the password
  # is 1Password-generated and unique per host. If that ever stops being true,
  # this decision must be revisited.
  services.openssh.settings.PasswordAuthentication = lib.mkForce true;

  # ============================================================================
  # PASSWORDLESS SUDO
  # ============================================================================
  security.sudo-rs.wheelNeedsPassword = false;

  # csb0-hostdash lived here — SUPERSEDED by composeStack postRecreate
  # (OPS-116/121): hostdash-auth → hostdash → traefik, same order.

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

  # Emergency recovery password verifier for users.users.mba.hashedPasswordFile.
  # Root-owned by design: the consumer is the `users` activation script running
  # as root, not a user-level service, so mba has no reason to read its own
  # verifier. Ordering is safe — agenixInstall precedes users in the activation
  # script (verified per host: csb0 60/411, csb1 60/951).
  age.secrets.csb0-recovery-password = {
    file = ../../secrets/csb0-recovery-password.age;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  # OPS-104: HA tokens + Telegram credentials for the fleet alert poller
  # (units and targets live in ./ops-alerts.nix). Root-owned — the poller runs
  # as root and nothing else needs to read it.
  age.secrets.csb0-ops-alerts-env.file = ../../secrets/csb0-ops-alerts-env.age;
  # NIX-356: 0400 — the compose service pins `user: 1883:1883`, so mosquitto
  # reads both ro bind mounts as their owner; nothing on the host side needs
  # group or world bits.
  age.secrets.mosquitto-passwd = {
    file = ../../secrets/mosquitto-passwd.age;
    mode = "0400";
    owner = "1883";
    group = "1883";
  };
  age.secrets.mosquitto-conf = {
    file = ../../secrets/mosquitto-conf.age;
    mode = "0400";
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
  # NIX-356: 0400 — the spec's env_file reads /run/agenix/traefik-variables
  # client-side via the root-run composeStack units (OPS-121); the declared
  # path is only the compatibility symlink. Mirrors the csb1 flip (NIX-353).
  age.secrets.traefik-variables = {
    file = ../../secrets/traefik-variables.age;
    path = "/var/lib/csb0-docker/traefik/variables.env";
    owner = "root";
    group = "root";
    mode = "0400";
  };

  # NIX-356: 0400 — read client-side by the root-run compose units only.
  age.secrets.csb-hostdash-oauth2-proxy-env = {
    file = ../../secrets/csb-hostdash-oauth2-proxy-env.age;
    path = "/run/agenix/csb-hostdash-oauth2-proxy-env";
    owner = "root";
    group = "root";
    mode = "0400";
  };

  # NIX-356: 0400 root:root — the only reader is ops-alerts.service via
  # EnvironmentFile (read by the root manager). Matches the documented
  # mqtt-hsb0 pattern in docs/SECRETS.md; no interactive mba workflow exists
  # for this file (the former mba ownership was historical).
  age.secrets.mqtt-csb0 = {
    file = ../../secrets/mqtt-csb0.age;
    owner = "root";
    group = "root";
    mode = "0400";
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
