{
  config,
  pkgs,
  lib,
  ...
}:

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
    ncps.enable = false; # Office network: can't reach hsb0.lan
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
  # AGENIX SECRETS
  # ==========================================================================

  age.secrets.miniserver-bp-wireguard-key.file = ../../secrets/miniserver-bp-wireguard-key.age;

  # OpenClaw secrets (mode 444: readable by container's node user uid 1000)
  age.secrets.miniserver-bp-openclaw-telegram-token = {
    file = ../../secrets/miniserver-bp-openclaw-telegram-token.age;
    mode = "444";
  };
  age.secrets.miniserver-bp-openclaw-gateway-token = {
    file = ../../secrets/miniserver-bp-openclaw-gateway-token.age;
    mode = "444";
  };
  age.secrets.miniserver-bp-openclaw-openrouter-key = {
    file = ../../secrets/miniserver-bp-openclaw-openrouter-key.age;
    mode = "444";
  };
  age.secrets.miniserver-bp-openclaw-brave-key = {
    file = ../../secrets/miniserver-bp-openclaw-brave-key.age;
    mode = "444";
  };
  age.secrets.miniserver-bp-gogcli-keyring-password = {
    file = ../../secrets/miniserver-bp-gogcli-keyring-password.age;
    mode = "444";
  };

  # M365 CLI credentials (Azure AD app: Percy-AI-miniserver-bp)
  # mode 444: readable by container's node user (uid 1000) via ro mount
  age.secrets.miniserver-bp-m365-client-id = {
    file = ../../secrets/miniserver-bp-m365-client-id.age;
    mode = "444";
  };
  age.secrets.miniserver-bp-m365-tenant-id = {
    file = ../../secrets/miniserver-bp-m365-tenant-id.age;
    mode = "444";
  };
  age.secrets.miniserver-bp-m365-client-secret = {
    file = ../../secrets/miniserver-bp-m365-client-secret.age;
    mode = "444";
  };

  # GitHub PAT for Percy AI (@bytepoets-percyai)
  age.secrets.miniserver-bp-github-pat = {
    file = ../../secrets/miniserver-bp-github-pat.age;
    mode = "444";
  };

  # OpenClaw Percaival Mattermost channel
  age.secrets.miniserver-bp-mattermost-bot-token = {
    file = ../../secrets/miniserver-bp-mattermost-bot-token.age;
    mode = "444";
  };

  # PMO (online PM tool) API token for OpenClaw Percaival
  age.secrets.miniserver-bp-openclaw-pmo-token = {
    file = ../../secrets/miniserver-bp-openclaw-pmo-token.age;
    mode = "444";
  };

  # Nextcloud share credentials for Percy (NEXTCLOUD_SHARE_URL, NEXTCLOUD_SHARE_PASSWORD)
  age.secrets.miniserver-bp-percy-nextcloud-share = {
    file = ../../secrets/miniserver-bp-percy-nextcloud-share.age;
    mode = "444";
  };

  # GHCR read-only PAT for pulling ghcr.io/bytepoets/bp-pm (PMO staging container)
  # Raw token, read by docker daemon at container login — root-readable only.
  age.secrets.miniserver-bp-ghcr-pat = {
    file = ../../secrets/miniserver-bp-ghcr-pat.age;
    mode = "400";
    owner = "root";
  };

  # GitHub Actions self-hosted runner registration token (one-shot, ~1h TTL).
  # Consumed by services.github-runners.bp-pm-staging on first start; after
  # successful registration, the runner persists its own credentials under
  # /var/lib/github-runners/bp-pm-staging/.credentials and this token is burnt.
  #
  # mode 444, no owner: the github-runner module uses a systemd DynamicUser,
  # so there is no static `github-runner` account at activation time — agenix
  # can't chown to a user that does not yet exist. World-readable is fine
  # because the /run/agenix tmpfs is only traversable by root.
  age.secrets.miniserver-bp-github-runner-token = {
    file = ../../secrets/miniserver-bp-github-runner-token.age;
    mode = "444";
  };

  # ==========================================================================
  # WIREGUARD VPN
  # ==========================================================================

  # VPN for remote access from home
  # Allows SSH jump to mba-imac-work (10.17.1.7)
  networking.wireguard.interfaces.wg0 = {
    ips = [ "10.100.0.51/32" ];
    privateKeyFile = config.age.secrets.miniserver-bp-wireguard-key.path;
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

    # Port 2222 is set automatically by hokage module (server-remote role)
    # No need to explicitly set services.openssh.ports here

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
  # Security Policy: miniserver-bp allows mba (Markus) SSH keys only.
  #
  # See: docs/SSH-KEY-SECURITY.md
  # ==========================================================================
  users.users.mba = {
    # Fix: Remove evaluation warning by forcing null on initialHashedPassword
    initialHashedPassword = lib.mkForce null;

    # 🚨 EMERGENCY RECOVERY PASSWORD - matches csb0/csb1 pattern
    # Password stored in 1Password: "csb0 csb1 recovery"
    # Can be changed after successful migration with `passwd mba`
    hashedPassword = "$6$ee9NiRR00Ev9wlEZ$kFD53waKDKf5YHC.Tzwm68Iwhjey7om9Yld4i9cUBLa40HdpL8.umjtIpWnjCmzKzgsGUgS3y.Tx2UQOUp5AN.";

    openssh.authorizedKeys.keys = lib.mkForce [
      # markus@iMac-5k-MBA-home.local (id_rsa)
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H1iVXWYKnHkxQsS7tGsZq3SoHxlVccd+kroMC/DhC4MWwVnJInWwDpo/bz7LiLuh+1Bmq04PswD78EiHVVQ+O7Ckk32heWrywD2vufihukhKRTy5zl6uodb5+oa8PBholTnw09d3M0gbsVKfLEi4NDlgPJiiQsIU00ct/y42nI0s1wXhYn/Oudfqh0yRfGvv2DZowN+XGkxQQ5LSCBYYabBK/W9imvqrxizttw02h2/u3knXcsUpOEhcWJYHHn/0mw33tl6a093bT2IfFPFb3LE2KxUjVqwIYz8jou8cb0F/1+QJVKtqOVLMvDBMqyXAhCkvwtEz13KEyt"
    ];
  };

  # ==========================================================================
  # USER ACCOUNT
  # ==========================================================================

  # User account configured above in SSH KEY SECURITY section
  # This ensures proper structure matching csb0/csb1
  users.users.mba.isNormalUser = true;
  users.users.mba.uid = 1000;
  users.users.mba.extraGroups = [
    "wheel"
    "networkmanager"
  ];

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
  # SUDO CONFIGURATION
  # ==========================================================================

  # Passwordless sudo for wheel group (matches hsb0/hsb1/csb0/csb1/gpc0/hsb8)
  security.sudo-rs.wheelNeedsPassword = false;

  # ==========================================================================
  # DOCKER CONTAINERS (declarative via NixOS)
  # ==========================================================================

  virtualisation.oci-containers.backend = "docker";

  # ──────────────────────────────────────────────────────────────────────────
  # bp-pm — PMO (BYTEPOETS Project Management Online) — STAGING
  # ──────────────────────────────────────────────────────────────────────────
  # Pulled from GHCR. Image is re-pulled on every deploy via a GitHub Actions
  # workflow that runs on a self-hosted runner on this host (see services
  # .github-runners below) — the runner issues `docker compose … pull && up -d`
  # locally. NixOS only handles first-start, restart, and volume wiring.
  #
  # Source repo: https://github.com/bytepoets/bp-pm
  # Image:        ghcr.io/bytepoets/bp-pm:latest  (private, auth via GHCR PAT)
  virtualisation.oci-containers.containers.bp-pm = {
    image = "ghcr.io/bytepoets/bp-pm:latest";
    login = {
      registry = "ghcr.io";
      username = "bytepoets-mba";
      passwordFile = config.age.secrets.miniserver-bp-ghcr-pat.path;
    };
    ports = [ "8888:8888" ];
    volumes = [ "/var/lib/bp-pm/data:/app/data" ];
    environment = {
      PORT = "8888";
      INSTANCE_LABEL = "STAGING";
      # COOKIE_SECURE left unset — staging is HTTP-only on the office LAN.
    };
    autoStart = true;
  };

  # OpenClaw Percaival - AI assistant via Telegram
  # Managed via docker-compose (hosts/miniserver-bp/docker/docker-compose.yml)
  # No longer using oci-containers (systemd mask/unmask hassle avoided)

  # bp-pm SQLite volume. The data/ bind-mount must exist before the container
  # starts, otherwise Docker creates it root-owned and the bp-pm process (uid
  # root inside the alpine image) works fine, but a wrong-owned host dir from a
  # previous rsync-era deploy would shadow it.
  system.activationScripts.bp-pm-data-dir = ''
    mkdir -p /var/lib/bp-pm/data
  '';

  # ──────────────────────────────────────────────────────────────────────────
  # GitHub Actions self-hosted runner for bp-pm deploys
  # ──────────────────────────────────────────────────────────────────────────
  # Runs as its own `github-runner` user, registers with the bp-pm repo on
  # first boot using the one-shot token above, then self-manages its
  # credentials. Executes the `deploy-staging.yml` workflow: pull the new
  # image from GHCR and restart the `docker-bp-pm.service` unit.
  #
  # Scoped to a single workflow via the runner label "bp-pm-staging".
  services.github-runners.bp-pm-staging = {
    enable = true;
    # Canonical org casing is BYTEPOETS — GitHub registration API returns 404
    # for lowercase `bytepoets` even though org names are case-insensitive in
    # most other contexts. Must match the URL shown on the "new runner" page.
    url = "https://github.com/BYTEPOETS/bp-pm";
    tokenFile = config.age.secrets.miniserver-bp-github-runner-token.path;
    name = "msbp-bp-pm-staging";
    extraLabels = [
      "self-hosted"
      "bp-pm-staging"
      "msbp"
    ];
    replace = true; # Re-register cleanly if the name already exists upstream
    # The runner writes deploy trigger/status files under /var/spool/bp-pm-deploy.
    # That path lives outside the default ReadWritePaths of the runner sandbox,
    # so add it explicitly. No sudo, no NoNewPrivileges tweaking — the runner
    # itself stays fully sandboxed, and the actual deploy runs in a separate
    # root-owned bp-pm-deploy.service (see below) triggered by a path unit.
    serviceOverrides = {
      ReadWritePaths = [ "/var/spool/bp-pm-deploy" ];
    };
  };

  # ──────────────────────────────────────────────────────────────────────────
  # bp-pm deploy path-triggered service
  # ──────────────────────────────────────────────────────────────────────────
  # Architecture: the github-runner writes a timestamp to
  #   /var/spool/bp-pm-deploy/trigger
  # A systemd path unit watches that file and fires bp-pm-deploy.service
  # (oneshot, root), which pulls the new GHCR image and restarts
  # docker-bp-pm.service. The deploy service writes /var/spool/bp-pm-deploy/
  # status with `ok` or `failed`/`unhealthy`. The runner then polls that
  # status file to decide the workflow result.
  #
  # Why not sudo? services.github-runners uses a systemd sandbox that sets
  # ProtectKernelTunables / RestrictSUIDSGID / friends, each of which implies
  # NoNewPrivileges=yes — a setting that, once on, **cannot be disabled per
  # systemd.exec(5)**. That blocks setuid elevation (sudo) even when the
  # sudoers allowlist is valid. Path-triggered deploy sidesteps the whole
  # problem: the runner never needs any privilege.

  systemd.tmpfiles.rules = [
    # Spool dir: world-writable so the DynamicUser runner can drop a trigger
    # file, world-readable so it can read the status file written by the
    # root-owned deploy service. Contains no secrets.
    "d /var/spool/bp-pm-deploy 0777 root root -"
    # Pre-create an empty trigger file with 0666 so the runner can truncate-
    # rewrite it without needing dir write for unlink+create (simpler and
    # race-free: the path unit fires on modification, including O_TRUNC).
    "f /var/spool/bp-pm-deploy/trigger 0666 root root - "
    # Status file starts as "unknown" so a brand-new host doesn't leave a
    # stale value from a previous deploy.
    "f /var/spool/bp-pm-deploy/status 0644 root root - unknown"
  ];

  systemd.paths.bp-pm-deploy = {
    description = "Watch for bp-pm deploy triggers";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = "/var/spool/bp-pm-deploy/trigger";
      Unit = "bp-pm-deploy.service";
    };
  };

  systemd.services.bp-pm-deploy = {
    description = "Pull latest bp-pm image from GHCR and restart container";
    # NOT wantedBy anything — only started by the path unit above.
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "bp-pm-deploy" ''
        set -e
        echo "running" > /var/spool/bp-pm-deploy/status
        echo "[bp-pm-deploy] pulling ghcr.io/bytepoets/bp-pm:latest"
        ${pkgs.docker}/bin/docker pull ghcr.io/bytepoets/bp-pm:latest
        echo "[bp-pm-deploy] restarting docker-bp-pm.service"
        ${pkgs.systemd}/bin/systemctl restart docker-bp-pm.service
        echo "[bp-pm-deploy] waiting for health"
        for _ in $(seq 1 15); do
          if ${pkgs.curl}/bin/curl -sf http://localhost:8888/api/health > /dev/null 2>&1; then
            echo "[bp-pm-deploy] OK"
            echo "ok" > /var/spool/bp-pm-deploy/status
            exit 0
          fi
          sleep 2
        done
        echo "[bp-pm-deploy] health check FAILED after 30s"
        echo "unhealthy" > /var/spool/bp-pm-deploy/status
        exit 1
      '';
      # Catch-all: if ExecStart bailed before writing a terminal status
      # (set -e mid-script, OOM, etc.) record a failure.
      ExecStopPost = "-${pkgs.writeShellScript "bp-pm-deploy-post" ''
        s=$(cat /var/spool/bp-pm-deploy/status 2>/dev/null || echo running)
        if [ "$s" = "running" ]; then
          echo "failed" > /var/spool/bp-pm-deploy/status
        fi
      ''}";
    };
  };

  # Create OpenClaw data directories. Config is git-managed (docker/openclaw-percaival/openclaw.json).
  system.activationScripts.openclaw-percaival = ''
    mkdir -p /var/lib/openclaw-percaival/data/workspace /var/lib/openclaw-percaival/gogcli /var/lib/openclaw-percaival/m365
    chown -R 1000:1000 /var/lib/openclaw-percaival/data /var/lib/openclaw-percaival/gogcli
  '';

  # ==========================================================================
  # FIREWALL
  # ==========================================================================

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      2222 # SSH
      8888 # bp-pm (PMO staging)
      18789 # OpenClaw Percaival
    ];
    allowedUDPPorts = [
      41641 # Tailscale WireGuard
    ];
    # WireGuard uses UDP 51820 (outbound only, no incoming needed)
  };

  # Tailscale VPN client (connects to headscale on csb0)
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
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

  # Substituters managed by uzumaki.ncps.enable = false (see above)
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

  # FleetCom agent — now runs as Docker container (FLEET-12)
  # Token kept for Docker agent .env: cat /run/agenix/fleetcom-token-miniserver-bp
  # Agents: FLEETCOM_AGENTS='[{"name":"Percy","agent_type":"assistant","status":"online"}]'
  age.secrets.fleetcom-token-miniserver-bp.file = ../../secrets/fleetcom-token-miniserver-bp.age;

  # NixOS version - DO NOT CHANGE after installation
  system.stateVersion = "24.11";
}
