# hsb1 - Home Server Barta 1 (formerly miniserver24)
{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:

let
  hostdashHsb1 = inputs.hostdash.packages.${pkgs.system}.hsb1;
in
{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.zfs.nix
    ./media-pool.nix # external 4TB USB — Plex media ZFS pool
    ./media-samba.nix # SMB share for /srv/media (Finder access) — independent of tm-*.nix
    ./tm-pool.nix # external 6TB USB — Time Machine ZFS pool (markus/mailina quotas + sanoid)
    ./tm-samba.nix # Samba + vfs_fruit + Avahi for the tm pool's two shares
    ./babycam-watchdog.nix # NIX-151 — probe + self-heal + MQTT telemetry for the kiosk babycam
    ./ir-bridge.nix # FLIRC IR receiver -> Sony Bravia IRCC (returned from hsb2)
    ../../modules/uzumaki # Consolidated module: fish, zellij, stasysmo
    ../../modules/funkeykid.nix
    # nixfleet-agent is now loaded via flake input (inputs.nixfleet.nixosModules.nixfleet-agent)

    # INSPR-73 (2026-05-04): system-side ssh-authorized — see the
    # inspr.ssh.authorized.users.mba block further down. force=true
    # because hsb1 hokage-injects external operator keys we do not
    # want admitted on this private/family host.
    inputs.inspr-modules.nixosModules.ssh-authorized
    ../../modules/shared/ssh-authorized-nixos.nix
  ];

  # ============================================================================
  # UZUMAKI MODULE - Fish functions, zellij, stasysmo (all-in-one)
  # ============================================================================
  uzumaki = {
    enable = true;
    role = "server";
    fish.editor = "nano";
    stasysmo.enable = true; # System metrics in Starship prompt
  };

  # Allow unfree package for "FLIRC" IR-USB-Module
  # NOTE: keep disabled unless FLIRC receiver returns to hsb1.
  nixpkgs.config.allowUnfreePredicate =
    pkg:
    builtins.elem (lib.getName pkg) [
      "flirc"
    ];

  # Remap ACME BK03 Power key to F13 to prevent accidental shutdowns
  # and allow using it for custom actions (like babycam toggle)
  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="input", ATTRS{name}=="ACME BK03", RUN+="${pkgs.kbd}/bin/setkeycodes 70 191"
  '';

  # Enable local APC UPS monitoring
  # Notes
  #     - The header '## apcupsd.conf v1.1 ##' with a comment is added by NixOS at the beginning
  #     - We do not need the SCRIPTDIR but it is aded by NixOS too with something like
  #       'SCRIPTDIR /nix/store/randomcharacters-apcupsd-scriptdir'
  services.apcupsd = {
    enable = true;
    configText = ''
      UPSCABLE usb
      UPSTYPE usb
      DEVICE
    '';
  };

  # Enable bluetooth
  hardware.bluetooth.enable = true;

  # ── funkeykid (educational keyboard toy) ─────────────────────────────
  # Architecture:
  #   - Docker container (ghcr.io/markus-barta/funkeykid) handles:
  #     → evdev keyboard listener (ACME BK03 via /dev/input, privileged)
  #     → sound playback (paplay via PipeWire)
  #     → MQTT publish to pixdcon for Pixoo display
  #     → web UI at http://hsb1.lan:8081 (config, test mode, file mgmt)
  #   - NixOS provides hardware-level isolation (always active):
  #     → udev rules: strip ACME BK03 from logind/X11 (no host keypresses)
  #     → logind: ignore power/suspend keys (child safety)
  #     → BT reconnect: auto-connect keyboard on boot
  #   - Docker compose: ~/docker/docker-compose.yml (funkeykid service)
  #   - Data: ~/docker/mounts/funkeykid/{settings.json,sounds/,images/}
  services.funkeykid = {
    enable = false; # systemd service off — Docker container runs instead
    hardwareIsolation = true; # udev + logind isolation (MUST stay on)
    bluetoothReconnect = true; # auto-connect ACME BK03 on boot
  };

  # ZFS configuration
  services.zfs.autoScrub.enable = true;

  # ============================================================================
  # FRITZ!BOX SMB MOUNT - Plex Media Storage
  # ============================================================================
  # RESILIENCE: Multiple layers prevent boot failure if mount unavailable:
  # 1. nofail: Boot continues if mount fails
  # 2. x-systemd.automount: Mount on-demand, not at boot
  # 3. x-systemd.idle-timeout: Unmount when idle (reduces lock issues)
  # 4. x-systemd.device-timeout: Give up quickly if device unavailable
  # 5. _netdev: Wait for network before attempting mount
  # ============================================================================
  fileSystems."/mnt/fritzbox-media" = {
    device = "//192.168.1.5/vr-fritz-box-smb";
    fsType = "cifs";
    options = [
      "credentials=/run/agenix/fritzbox-smb-credentials"
      "uid=1000" # mba user
      "gid=100" # users group
      "iocharset=utf8"
      "file_mode=0644"
      "dir_mode=0755"
      # RESILIENCE OPTIONS (prevent boot failure):
      "nofail" # Don't fail boot if mount unavailable
      "x-systemd.automount" # Mount on first access, not at boot
      "x-systemd.idle-timeout=0" # Never auto-unmount (prevent stale handles)
      "x-systemd.device-timeout=10" # Give up after 10s if device unavailable
      "x-systemd.mount-timeout=10" # Give up after 10s if mount fails
      "_netdev" # Wait for network before attempting
      # CIFS STABILITY OPTIONS (prevent stale file handles):
      "vers=3.0" # Use SMB3 protocol
      "cache=loose" # Better performance, cache aggressively
      "actimeo=30" # Attribute cache timeout
      "noserverino" # Don't use server-provided inode numbers
      "noperm" # Don't check permissions on client side
    ];
  };

  # Networking configuration
  networking = {
    nameservers = [
      "192.168.1.99" # miniserver99 / AdGuard Home
      "1.1.1.1" # Cloudflare fallback
    ];
    search = [ "lan" ];
    defaultGateway = "192.168.1.1";
    resolvconf.useLocalResolver = false;
    hosts = {
      # This DNS/DHCP server itself - local resolution for core services
      "192.168.1.99" = [
        "hsb0"
        "hsb0.lan"
      ];
      # This server itself
      "192.168.1.101" = [
        "hsb1"
        "hsb1.lan"
      ];
      # Gaming PC
      "192.168.1.154" = [
        "gpc0"
        "gpc0.lan"
      ];
      "192.168.1.32" = [
        "kr-sonnen-batteriespeicher"
        "kr-sonnen-batteriespeicher.lan"
      ];
      "192.168.1.102" = [
        "vr-opus-gateway"
        "vr-opus-gateway.lan"
      ];
      "192.168.1.159" = [
        "wz-pixoo-64-00"
        "wz-pixoo-64-00.lan"
      ];
      "192.168.1.189" = [
        "wz-pixoo-64-01"
        "wz-pixoo-64-01.lan"
      ];
    };
    interfaces.enp3s0f0 = {
      ipv4.addresses = [
        {
          address = "192.168.1.101";
          prefixLength = 24;
        }
      ];
    };
    # Firewall configuration
    firewall = {
      enable = false; # Firewall is disabled due to homekit issues (may be revisited later, so we keep settings)
      allowedTCPPorts = [
        80 # HTTP
        443 # HTTPS
        1880 # Node-RED Web UI
        1883 # MQTT
        9000 # Portainer web
        32400 # Plex Media Server
        445 # Samba (Time Machine shares)
        51827 # HomeKit accessory communication
        554 # HomeKit Secure Video RTSP
        5223 # HomeKit notifications (APNS, Apple Push Notification Service)
      ];
      allowedUDPPorts = [
        443 # HTTPS
        5353 # mDNS for HomeKit: Bonjour discovery and CIAO
        41641 # Tailscale WireGuard
      ];
    };
  };

  # Disable fail2ban since firewall is turned off
  services.fail2ban.enable = false;

  # Increase ulimit for influxdb
  security.pam.loginLimits = [
    {
      domain = "*";
      type = "soft";
      item = "nofile";
      value = "8192";
    }
  ];

  # Enable Fwupd
  # https://nixos.wiki/wiki/Fwupd
  services.fwupd.enable = true;

  # Tailscale VPN client (connects to headscale on csb0)
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client"; # Client mode only
  };

  # Enable FLIRC IR-USB-Module
  # NOTE: receiver RETURNED to hsb1 (2026-06-05) — IR bridge in ./ir-bridge.nix.
  hardware.flirc.enable = true;

  # Additional system packages
  environment.systemPackages = with pkgs; [
    # Python environment for debugging and Microsoft Graph integration
    (python3.withPackages (
      ps: with ps; [
        evdev
        paho-mqtt
        msal
        requests
      ]
    ))

    # agenix CLI — makes `agenix -e` / `just edit-secret` work natively on this
    # NixOS host (was Mac-only via home-manager before). NIX-158 phase 3.
    inputs.agenix.packages.x86_64-linux.default

    # Network-related packages
    samba # Enables remote shutdown of Windows PC via Node-RED and HomeKit voice command
    wol # Facilitates wake-on-LAN for Windows 10 PC in Node-RED, triggered by HomeKit voice command
    mosquitto # Only for mosquitto_sub on system level
    usbutils # Provides lsusb and other USB utilities
    #flirc-bin # Command line tool for programming FLIRC
    evtest # For testing input device events
    ## --------------------------------------
    # Packages for kiosk-mode-vlc-cam viewer
    # Note: Packages vlc, openbox, xorg.xset
    #   work together to create a kiosk-mode
    #   camera viewer
    ## --------------------------------------
    vlc # Video playback software
    openbox # Lightweight window manager
    xorg.xset # X11 user preference utility tool
    pulseaudio # To enable audio forwarding to a homepod
  ];

  # +X11 and VLC kiosk mode configuration
  # Note: kiosk launcher is HM-managed — hosts/hsb1/files/kiosk-autostart.sh (NIX-158).
  services.xserver = {
    enable = true;
    displayManager.lightdm.enable = true;
    windowManager.openbox.enable = true;
  };
  services.displayManager = {
    autoLogin = {
      enable = true;
      user = "kiosk";
    };
    defaultSession = "none+openbox";
  };

  # Configuration for user "kiosk"
  users.users.kiosk = {
    isNormalUser = true;
    description = "Kiosk User";
    extraGroups = [
      "video"
      "audio"
    ];
    hashedPassword = "!";
    home = "/home/kiosk";
    createHome = true;
  };

  # Home Manager configuration for the kiosk user
  home-manager.users.kiosk = {
    home.stateVersion = "23.11";
    # Ensure necessary packages are available to the kiosk user
    home.packages = with pkgs; [
      vlc
      xorg.xset
    ];
    # NIX-158: babycam kiosk launcher, now declarative (was the host-only,
    # hand-maintained /home/kiosk/.config/openbox/autostart). Sources camera
    # creds from agenix (/run/agenix/hsb1-tapo-c210-env), not shredded plaintext.
    home.file.".config/openbox/autostart" = {
      source = ./files/kiosk-autostart.sh;
      executable = true;
    };
  };

  # APC UPS MQTT periodic publishing (NIX-158: inlined declaratively, was the
  # unmanaged /home/mba/scripts/apc-to-mqtt.sh; creds now from agenix, not the
  # retired /home/mba/secrets/smarthome.env plaintext). Modeled on hsb0.
  systemd.services.apc-to-mqtt = {
    description = "Publish APC UPS status to MQTT";
    path = [
      pkgs.gawk
      pkgs.gnused
      pkgs.coreutils
      pkgs.util-linux # logger
    ];
    script = ''
      set -euo pipefail

      # Called by systemd timer (polling) or apcupsd NOTIFYCMD (event-driven)
      EVENT="''${1:-timer}"
      logger -t apc-to-mqtt "Triggered by: $EVENT"

      # Source MQTT credentials from agenix (was /home/mba/secrets/smarthome.env)
      source ${config.age.secrets.hsb1-smarthome-env.path}

      # Query UPS status
      apc_status=$(${pkgs.apcupsd}/bin/apcaccess status)

      # Current timestamp in milliseconds
      current_timestamp=$(date +%s%3N)

      # Convert APC status to JSON
      json_status=$(echo "$apc_status" | awk -v timestamp="$current_timestamp" -v event="$EVENT" '
      BEGIN { print "{" }
      NF > 1 {
          gsub(/^[ \t]+|[ \t]+$/, "", $0)
          key = tolower($1)
          $1 = ""
          gsub(/^[ \t]*: /, "", $0)
          gsub(/^[ \t]+|[ \t]+$/, "", $0)
          value = $0
          gsub(/"/, "\\\"", value)
          printf "  \"%s\": \"%s\",\n", key, value
      }
      END {
          printf "  \"__published\": %s,\n", timestamp
          printf "  \"__event\": \"%s\"\n", event
      }
      ' | sed '$ s/,$//')

      # Add closing brace
      json_status="$json_status
      }"

      logger -t apc-to-mqtt "Publishing to MQTT: $json_status"

      # Publish to MQTT for Back-UPS ES 550
      ${pkgs.mosquitto}/bin/mosquitto_pub \
        --topic home/wz/battery/ups550 \
        -u "$MOSQITTO_USER_MS24" \
        -P "$MOSQITTO_PASS_MS24" \
        -h "$MOSQITTO_HOST_MS24" \
        -m "$json_status"
    '';
    serviceConfig = {
      Type = "oneshot";
      User = "mba";
    };
  };

  systemd.timers.apc-to-mqtt = {
    description = "Timer for APC UPS MQTT publishing";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "1min"; # every 1 minutes
      Unit = "apc-to-mqtt.service";
    };
  };

  # MQTT-based VLC Volume Control Service for NixOS
  #
  # This service listens for MQTT messages on the topic 'home/hsb1/kiosk-vlc-volume'
  # and uses the received value to control VLC's volume via telnet.
  #
  # Features:
  # - Securely reads MQTT credentials from an environment file
  # - Validates incoming volume values (range: 0-512)
  # - Controls VLC volume using a Tapo camera password for authentication
  # - Comprehensive logging for easy troubleshooting
  #
  # Dependencies:
  # - Requires mosquitto_sub, sed, and netcat packages
  # - Expects MQTT credentials in /etc/secrets/mqtt.env
  # - Expects Tapo camera password in /etc/secrets/tapoC210-00.env
  # - Assumes VLC is running and listening on localhost:4212 for telnet connections
  #
  # Usage:
  # 1. Ensure VLC is running with telnet interface enabled
  # 2. Publish a message to 'home/hsb1/kiosk-vlc-volume' with a value between 0 and 512
  # 3. The service will set VLC's volume accordingly and log the action
  #
  # Logging:
  # - All actions are logged to systemd journal with identifier 'mqtt-volume-control'
  # - View logs with: journalctl -t mqtt-volume-control -f

  systemd.services.mqtt-volume-control = {
    description = "MQTT-based VLC Volume Control Service";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      MQTT_ENV_FILE = "/run/agenix/hsb1-mqtt-client-env";
      TAPO_ENV_FILE = "/run/agenix/hsb1-tapo-c210-env";
    };

    serviceConfig = {
      ExecStart = pkgs.writeShellScript "mqtt-volume-control" ''
        # Enhanced logging function with timestamps
        log() {
          echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | ${pkgs.systemd}/bin/systemd-cat -t mqtt-volume-control -p info
        }

        # Log script start
        log "Script starting. Attempting to source MQTT environment variables."

        # Source MQTT environment variables
        if [ -f "$MQTT_ENV_FILE" ]; then
          if [ -r "$MQTT_ENV_FILE" ]; then
            set -a
            source "$MQTT_ENV_FILE"
            set +a
            log "MQTT environment variables sourced successfully."
            log "DEBUG: MQTT_HOST=$MQTT_HOST, MQTT_USER=$MQTT_USER"

            # Validate that required variables are set
            if [ -z "$MQTT_HOST" ] || [ -z "$MQTT_USER" ] || [ -z "$MQTT_PASS" ]; then
              log "ERROR: One or more required MQTT variables are not set. Please check $MQTT_ENV_FILE"
              exit 1
            fi
          else
            log "ERROR: MQTT environment file is not readable: $MQTT_ENV_FILE"
            exit 1
          fi
        else
          log "ERROR: MQTT environment file not found: $MQTT_ENV_FILE"
          exit 1
        fi

        # Log MQTT connection attempt
        log "Attempting to connect to MQTT broker at $MQTT_HOST"

        # Main loop: Subscribe to MQTT topic and process incoming messages
        ${pkgs.mosquitto}/bin/mosquitto_sub -v -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASS" -t 'home/hsb1/kiosk-vlc-volume' 2>&1 | while read -r topic volume; do
          if [[ $topic == "home/hsb1/kiosk-vlc-volume" ]]; then
            log "Received message with topic: $topic"
            log "Received message with volume $volume"

            # Validate volume range (0-512)
            if [[ "$volume" =~ ^[0-9]+$ ]] && (( volume >= 0 && volume <= 512 )); then
              log "Valid volume received: $volume"

              # NIX-151: record the user's INTENT the moment it is expressed.
              #
              # This file is the reference the babycam watchdog reconciles
              # against, and it is why the watchdog can tell a DELIBERATE mute
              # (volume 0 at bedtime, with the bedroom door open — a nightly
              # habit) apart from an ACCIDENTAL one (a restarted VLC coming up
              # at 0 and silently staying there, which is the NIX-151 bug).
              # Without it, any watchdog would have to guess, and guessing wrong
              # in either direction is unacceptable: un-muting the house at 3am,
              # or leaving a baby monitor mute.
              #
              # Written BEFORE the telnet push, on purpose: this records what
              # was ASKED FOR, not what succeeded. If the push below fails, the
              # watchdog sees the mismatch and re-applies it within a minute.
              echo "$volume" > /var/lib/babycam-watchdog/desired-volume

              # Get Tapo camera password (used for VLC authentication)
              if [ -f "$TAPO_ENV_FILE" ]; then
                tapo_password=$(${pkgs.gnused}/bin/sed -n "s/TAPO_C210_PASSWORD=//p" "$TAPO_ENV_FILE")
                log "Tapo password retrieved successfully."
              else
                log "ERROR: Tapo environment file not found: $TAPO_ENV_FILE"
                continue
              fi

              # Send volume command to VLC via telnet
              log "Attempting to set VLC volume to $volume"
              if echo -e "$tapo_password\nvolume $volume\nquit\n" | ${pkgs.netcat}/bin/nc -w 5 localhost 4212; then
                log "Successfully set VLC volume to $volume"
              else
                log "ERROR: Failed to set VLC volume. Is VLC running and listening on port 4212?"
              fi
            else
              log "ERROR: Invalid volume received: $volume. Must be between 0 and 512."
            fi
          else
            log "DEBUG: Unexpected topic: $topic"
          fi
        done

        # Log unexpected exit
        log "ERROR: mosquitto_sub loop exited unexpectedly. Service will restart."
      '';
      Restart = "always";
      RestartSec = "5s";
      User = "kiosk";
      # NIX-151: shared with babycam-watchdog.service (also User=kiosk), which
      # reads desired-volume from here. systemd creates it as kiosk:kiosk.
      StateDirectory = "babycam-watchdog";
      StateDirectoryMode = "0750";
    };
  };

  hokage = {
    hostName = "hsb1";
    userLogin = "mba";
    userNameLong = "Markus Barta";
    userNameShort = "Markus";
    userEmail = "markus@barta.com";
    role = "server-home";
    useInternalInfrastructure = false;
    useSecrets = true;
    useSharedKey = false;
    zfs.enable = true;
    zfs.hostId = "dabfdb01";
    audio.enable = true; # Required for VLC kiosk
    programs.git.enableUrlRewriting = false;
    # Point nixbit to Markus' repository (not pbek's default)
    programs.nixbit.repository = "https://github.com/markus-barta/nixcfg.git";
    # NOTE: starship & atuin are configured via common.nix (DRY pattern)
    # Disable catppuccin theming - we use Tokyo Night (see theme-hm.nix)
    catppuccin.enable = false;
  };

  # ============================================================================
  # 🚨 SSH KEY SECURITY - CRITICAL FIX FROM hsb8 INCIDENT (2025-11-22)
  # ============================================================================
  # The external hokage server-home module auto-injects external SSH keys
  # (omega@yubikey, omega@rsa, etc). We use lib.mkForce to REPLACE these
  # with ONLY authorized keys.
  #
  # Security Policy: hsb1 allows mba (Markus) SSH keys.
  # ============================================================================
  users.users.mba = {
    # Prevent PAM lockout: Use actual password hash instead of empty initialHashedPassword
    # This overrides common.nix's initialHashedPassword = "" which causes PAM auth failures
    # Password can be changed with `passwd mba` - then update this hash
    # Fix: P6400 / P5012 - Force null on initialHashedPassword to avoid ambiguity
    initialHashedPassword = lib.mkForce null;
    # Plaintext recovery password lives in 1Password — entry "hsb1" (renamed
    # from "miniserver24"); verified against this hash 2026-06-28 (NIX-198).
    hashedPassword = "$y$j9T$bi9LmgTpnV.EleK4RduzQ/$eLkQ9o8n/Ix7YneRJBUNSdK6tCxAwwSYR.wL08wu1H/";
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
  # force = true here because hsb1 (server-home / hokage profile) injects
  # external operator keys we do NOT want admitted on this private/family
  # host. mkForce-wrap drops them. (Defence-in-depth: matches the
  # `lib.mkForce` posture the previous manual declaration used.)
  inspr.ssh.authorized = {
    enable = true;
    users.mba = {
      trust = config._inspr.trustPresets.personalHosts;
      force = true;
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
  # MERLIN AI AGENT USER
  # Dedicated user for Merlin (OpenClaw on hsb0) SSH access.
  # wheel + docker = full host control; intentional (hsb1 is home automation only).
  # Revoke: remove this block + nixos-rebuild switch.
  # ============================================================================
  users.users.merlin = {
    isNormalUser = true;
    description = "Merlin AI Agent (OpenClaw on hsb0)";
    extraGroups = [
      "wheel"
      "docker"
    ];
    shell = pkgs.bash;
    hashedPassword = "!"; # Locked — SSH key auth only
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDJCgudf3tbOJrT+HioSyT/DoHYf1rHVoLKc+hjGspsQ merlin@openclaw-gateway-hsb0"
    ];
  };

  # ============================================================================
  # 🚨 PASSWORDLESS SUDO - Lost when removing serverMba mixin
  # ============================================================================
  security.sudo-rs.wheelNeedsPassword = false;

  # ============================================================================
  # AGENIX SECRETS
  # ============================================================================

  # Fritz!Box SMB credentials for Plex media mount
  age.secrets.fritzbox-smb-credentials = {
    file = ../../secrets/fritzbox-smb-credentials.age;
    mode = "400";
    owner = "root";
  };

  # Samba credentials — used by media-samba.nix now (markus's line), and by
  # tm-samba.nix (markus + mailina) once that's enabled in NIX-295 step 6/7.
  age.secrets.hsb1-tm-smb-env = {
    file = ../../secrets/hsb1-tm-smb-env.age;
    mode = "400";
    owner = "root";
  };

  # Restic Hetzner secrets (isolated sub2)
  age.secrets.hsb1-restic-env = {
    file = ../../secrets/hsb1-restic-env.age;
    mode = "400";
    owner = "root";
  };

  age.secrets.hsb1-restic-ssh-key = {
    file = ../../secrets/hsb1-restic-ssh-key.age;
    mode = "400";
    owner = "root";
  };

  # ============================================================================
  # NIX-158 — Declarative docker-compose stack launcher
  # ============================================================================
  # NixOS owns the docker DAEMON (hokage server-home); this oneshot makes the
  # container SET declarative too: `docker compose up -d` on boot and whenever the
  # canonical compose file changes (restartTriggers) via `nixos-rebuild switch`.
  # Idempotent reconcile against hosts/hsb1/docker/docker-compose.yml (single
  # source of truth since NIX-158 phase 1). Purely additive — no destructive
  # teardown; containers keep their own restart:unless-stopped as a second layer.
  systemd.services.hsb1-stack = {
    description = "hsb1 docker-compose stack (declarative reconcile)";
    after = [
      "docker.service"
      "network-online.target"
    ];
    requires = [ "docker.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    restartTriggers = [
      (builtins.readFile ./docker/docker-compose.yml)
      hostdashHsb1
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.docker-compose}/bin/docker-compose -p docker -f /home/mba/Code/nixcfg/hosts/hsb1/docker/docker-compose.yml up -d";
      ExecStartPost = "${pkgs.docker-compose}/bin/docker-compose -p docker -f /home/mba/Code/nixcfg/hosts/hsb1/docker/docker-compose.yml up -d --force-recreate --no-deps hsb1-home";
      TimeoutStartSec = "600";
    };
  };

  environment.etc."hostdash/hsb1".source = hostdashHsb1;

  # ============================================================================
  # OPUS SmartHome Stream to MQTT Bridge
  # ============================================================================
  # Install source code directly from GitHub input
  environment.etc."opus-stream-to-mqtt".source = inputs.opus-stream;

  # Secrets for docker-compose (loaded via agenix)
  age.secrets.opus-stream-hsb1 = {
    file = ../../secrets/opus-stream-hsb1.age;
    mode = "400";
    owner = "mba"; # Needs to be readable by docker compose
  };

  # PIXDCON MQTT credentials
  age.secrets.hsb1-pixdcon-env = {
    file = ../../secrets/hsb1-pixdcon-env.age;
    mode = "0400";
    owner = "mba";
  };

  # hsb1 Mosquitto broker config + passwd (server-side), delivered encrypted via
  # agenix. conf carries the inline OPUS greennet bridge credential (vendor-locked,
  # LAN-only). mode 644 + owner/group 1883 = mosquitto's in-container uid (csb0 pattern).
  age.secrets.hsb1-mosquitto-conf = {
    file = ../../secrets/hsb1-mosquitto-conf.age;
    mode = "644";
    owner = "1883";
    group = "1883";
  };
  age.secrets.hsb1-mosquitto-passwd = {
    file = ../../secrets/hsb1-mosquitto-passwd.age;
    mode = "644";
    owner = "1883";
    group = "1883";
  };

  # hsb1 SMTP relay (namshi/smtp) env_file — hover.com SMARTHOST_PASSWORD.
  # owner mba so docker compose can read it (mirrors opus-stream / pixdcon env files);
  # root (the stack launcher) can read it too. Consumed via compose env_file
  # /run/agenix/hsb1-smtp-env. Live until the nixcfg compose launches it (Phase 2/3).
  age.secrets.hsb1-smtp-env = {
    file = ../../secrets/hsb1-smtp-env.age;
    mode = "400";
    owner = "mba";
  };

  # Pharos beacon per-host token. Docker Compose reads it as an env_file.
  age.secrets.pharos-beacon-hsb1-env = {
    file = ../../secrets/pharos-beacon-hsb1-env.age;
    path = "/run/agenix/pharos-beacon-hsb1-env";
    owner = "mba";
    group = "users";
    mode = "0400";
  };

  # NIX-158 phase 3 P2 — single-consumer service secrets migrated from
  # /home/mba/secrets/*.env. env_file consumers, except fritz (file-mount).
  age.secrets.hsb1-zigbee2mqtt-env = {
    file = ../../secrets/hsb1-zigbee2mqtt-env.age;
    path = "/run/agenix/hsb1-zigbee2mqtt-env";
    mode = "0400";
    owner = "mba";
  };
  age.secrets.hsb1-funkeykid-api-env = {
    file = ../../secrets/hsb1-funkeykid-api-env.age;
    path = "/run/agenix/hsb1-funkeykid-api-env";
    mode = "0400";
    owner = "mba";
  };
  age.secrets.hsb1-watchtower-env = {
    file = ../../secrets/hsb1-watchtower-env.age;
    path = "/run/agenix/hsb1-watchtower-env";
    mode = "0400";
    owner = "mba";
  };
  age.secrets.hsb1-opusweb-env = {
    file = ../../secrets/hsb1-opusweb-env.age;
    path = "/run/agenix/hsb1-opusweb-env";
    mode = "0400";
    owner = "mba";
  };
  age.secrets.hsb1-fritz-tripwire-env = {
    file = ../../secrets/hsb1-fritz-tripwire-env.age;
    path = "/run/agenix/hsb1-fritz-tripwire-env";
    mode = "0400";
    owner = "mba";
  };

  # NIX-158 phase 3 P3 — shared smarthome env (HA + funkeykid + nodered).
  age.secrets.hsb1-smarthome-env = {
    file = ../../secrets/hsb1-smarthome-env.age;
    path = "/run/agenix/hsb1-smarthome-env";
    mode = "0400";
    owner = "mba";
  };

  # NIX-158 phase 3 P3b — /etc/secrets pair. owner=root mode=0644 so BOTH the
  # kiosk mqtt-volume-control systemd unit AND the scrypted container can read.
  age.secrets.hsb1-mqtt-client-env = {
    file = ../../secrets/hsb1-mqtt-client-env.age;
    path = "/run/agenix/hsb1-mqtt-client-env";
    mode = "0644";
    owner = "root";
  };
  age.secrets.hsb1-tapo-c210-env = {
    file = ../../secrets/hsb1-tapo-c210-env.age;
    path = "/run/agenix/hsb1-tapo-c210-env";
    mode = "0644";
    owner = "root";
  };
}
