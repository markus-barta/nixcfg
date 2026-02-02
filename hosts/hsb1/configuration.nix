# hsb1 - Home Server Barta 1 (formerly miniserver24)
{
  pkgs,
  lib,
  ...
}:

let
  # Custom OpenClaw package (templates included)
  openclaw = pkgs.callPackage ../../pkgs/openclaw/package.nix { };
in

{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.zfs.nix
    ../../modules/uzumaki # Consolidated module: fish, zellij, stasysmo
    ../../modules/child-keyboard-fun.nix
    # nixfleet-agent is now loaded via flake input (inputs.nixfleet.nixosModules.nixfleet-agent)
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

  # Enable cron daemon (needed for OpenClaw scheduler)
  services.cron.enable = true;

  # Prevent keyboard from triggering power events (power button, suspend, etc.)
  # This is critical for child-keyboard-fun to prevent accidental shutdowns
  services.logind.settings.Login = {
    HandlePowerKey = "ignore";
    HandleSuspendKey = "ignore";
    HandleHibernateKey = "ignore";
    HandleLidSwitch = "ignore";
  };

  # Child's Bluetooth Keyboard Fun System
  # Script: hosts/hsb1/files/child-keyboard-fun.py (edit directly, no rebuild needed)
  # Config: hosts/hsb1/files/child-keyboard-fun.env (edit directly, no rebuild needed)
  # Sounds: /var/lib/child-keyboard-sounds/
  services.child-keyboard-fun = {
    enable = true;
    user = "mba";
  };

  # No sudo rules needed - service runs as kiosk user directly

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
    defaultGateway = "192.168.1.5";
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
        51827 # HomeKit accessory communication
        554 # HomeKit Secure Video RTSP
        5223 # HomeKit notifications (APNS, Apple Push Notification Service)
      ];
      allowedUDPPorts = [
        443 # HTTPS
        5353 # mDNS for HomeKit: Bonjour discovery and CIAO
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

  # Enable FLIRC IR-USB-Module
  # NOTE: receiver moved off hsb1.
  hardware.flirc.enable = false;

  # OpenClaw template path (custom package includes templates)
  environment.variables.OPENCLAW_TEMPLATES_DIR = "${openclaw}/lib/openclaw/docs/reference/templates";

  # Additional system packages
  environment.systemPackages = with pkgs; [
    # Python environment for debugging
    (python3.withPackages (
      ps: with ps; [
        evdev
        paho-mqtt
      ]
    ))

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
    openclaw
  ];

  # +X11 and VLC kiosk mode configuration
  # Note: For start script go to: /home/kiosk/.config/openbox/autostart
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
  };

  # APC UPS MQTT periodic publishing
  systemd.services.apc-to-mqtt = {
    description = "Publish APC UPS status to MQTT";
    script = "/home/mba/scripts/apc-to-mqtt.sh";
    serviceConfig = {
      Type = "oneshot";
      User = "mba";
      Environment = "PATH=/run/current-system/sw/bin";
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
      MQTT_ENV_FILE = "/etc/secrets/mqtt.env";
      TAPO_ENV_FILE = "/etc/secrets/tapoC210-00.env";
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
    hashedPassword = "$y$j9T$bi9LmgTpnV.EleK4RduzQ/$eLkQ9o8n/Ix7YneRJBUNSdK6tCxAwwSYR.wL08wu1H/";
    openssh.authorizedKeys.keys = lib.mkForce [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H1iVXWYKnHkxQsS7tGsZq3SoHxlVccd+kroMC/DhC4MWwVnJInWwDpo/bz7LiLuh+1Bmq04PswD78EiHVVQ+O7Ckk32heWrywD2vufihukhKRTy5zl6uodb5+oa8PBholTnw09d3M0gbsVKfLEi4NDlgPJiiQsIU00ct/y42nI0s1wXhYn/Oudfqh0yRfGvv2DZowN+XGkxQQ5LSCBYYabBK/W9imvqrxizttw02h2/u3knXcsUpOEhcWJYHHn/0mw33tl6a093bT2IfFPFb3LE2KxUjVqwIYz8jou8cb0F/1+QJVKtqOVLMvDBMqyXAhCkvwtEz13KEyt" # markus@iMac-5k-MBA-home.local (id_rsa)
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

  # OpenClaw AI assistant secrets
  # Runtime paths: /run/agenix/hsb1-openclaw-*
  # Config references these in ~/.openclaw/openclaw.json
  age.secrets.hsb1-openclaw-gateway-token = {
    file = ../../secrets/hsb1-openclaw-gateway-token.age;
    mode = "400";
    owner = "mba";
  };

  age.secrets.hsb1-openclaw-telegram-token = {
    file = ../../secrets/hsb1-openclaw-telegram-token.age;
    mode = "400";
    owner = "mba";
  };

  age.secrets.hsb1-openclaw-openrouter-key = {
    file = ../../secrets/hsb1-openclaw-openrouter-key.age;
    mode = "400";
    owner = "mba";
  };

  age.secrets.hsb1-openclaw-hass-token = {
    file = ../../secrets/hsb1-openclaw-hass-token.age;
    mode = "400";
    owner = "mba";
  };

  age.secrets.hsb1-openclaw-brave-key = {
    file = ../../secrets/hsb1-openclaw-brave-key.age;
    mode = "400";
    owner = "mba";
  };

  # ============================================================================
  # NIXFLEET AGENT - Fleet management dashboard agent
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
    deviceType = "server";
  };

  /*
    # ============================================================================
    # OPENCLAW AI ASSISTANT - Gateway service
    # ============================================================================
    systemd.services.openclaw-gateway = {
      description = "OpenClaw AI Assistant Gateway";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        User = "mba";
        Group = "users";
        WorkingDirectory = "/home/mba/.openclaw";
        ExecStart = "${openclaw}/bin/openclaw gateway";
        Restart = "always";
        RestartSec = "10s";
        Environment = [
          "PATH=/run/current-system/sw/bin"
          # OpenClaw environment variables for secrets
          "OPENCLAW_GATEWAY_TOKEN_FILE=/run/agenix/hsb1-openclaw-gateway-token"
          "OPENCLAW_TELEGRAM_TOKEN_FILE=/run/agenix/hsb1-openclaw-telegram-token"
          "OPENCLAW_OPENROUTER_KEY_FILE=/run/agenix/hsb1-openclaw-openrouter-key"
          "OPENCLAW_TEMPLATES_DIR=${openclaw}/lib/openclaw/docs/reference/templates"
        ];
      };

        # Ensure workspace directory exists and generate valid config
        preStart = ''
          mkdir -p /home/mba/.openclaw/workspace
          mkdir -p /home/mba/.openclaw/logs

          # Create dummy template files (upstream packaging issue)
          mkdir -p /home/mba/.openclaw/workspace
          touch /home/mba/.openclaw/workspace/AGENTS.md
          touch /home/mba/.openclaw/workspace/SOUL.md
          touch /home/mba/.openclaw/workspace/TOOLS.md
          chown -R mba:users /home/mba/.openclaw/workspace

          # Always write valid openclaw.json with token from agenix (backup old if exists)
          if [ -f /home/mba/.openclaw/openclaw.json ]; then
            mv /home/mba/.openclaw/openclaw.json /home/mba/.openclaw/openclaw.json.bak.$(date +%s)
          fi

          # Read gateway token from agenix secret
          GATEWAY_TOKEN=$(cat /run/agenix/hsb1-openclaw-gateway-token 2>/dev/null || echo "")

          cat > /home/mba/.openclaw/openclaw.json << EOF
          {
            "gateway": {
              "mode": "local",
              "auth": {
                "token": "$GATEWAY_TOKEN"
              }
            },
            "agents": {
              "defaults": {
                "workspace": "/home/mba/.openclaw/workspace"
              }
            },
            "meta": {
              "lastTouchedVersion": "2026.1.30",
              "lastTouchedAt": "2026-01-31T00:00:00.000Z"
            }
          }
          EOF

          chown mba:users /home/mba/.openclaw/openclaw.json
          chmod 600 /home/mba/.openclaw/openclaw.json
        '';
    };
  */
}
