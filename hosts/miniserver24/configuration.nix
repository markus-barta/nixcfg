# Configuration for miniserver24 (mba)
{ modulesPath, config, pkgs, username, ... }:

{
  # Import necessary configuration modules
  imports = [
    ./hardware-configuration.nix
    ../../modules/mixins/server-local.nix
    ../../modules/mixins/server-mba.nix
    ../../modules/mixins/audio.nix
    ./disk-config.zfs.nix
  ];

  # Bootloader configuration
  boot = {
    supportedFilesystems = [ "zfs" ];
    kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;
    loader.grub = {
      enable = true;
      zfsSupport = true;
      efiSupport = true;
      efiInstallAsRemovable = true;
      mirroredBoots = [
        { devices = [ "nodev" ]; path = "/boot"; }
      ];
    };
    initrd.network = {
      enable = true;
      postCommands = ''
        sleep 2
        zpool import -a;
      '';
    };
  };

  # ZFS configuration
  services.zfs.autoScrub.enable = true;

  # Networking configuration
  networking = {
    hostId = "dabfdb01";  # Needed for ZFS
    hostName = "miniserver24";
    networkmanager.enable = true;
    nameservers = ["192.168.1.100"];
    defaultGateway = "192.168.1.5";
    interfaces.enp3s0f0 = {
      ipv4.addresses = [{ address = "192.168.1.101"; prefixLength = 24; }];
    };
    # Firewall configuration
    firewall = {
      enable = false;  # Firewall is disabled due to homekit issues (may be revisited later, so we keep settings)
      allowedTCPPorts = [
        80    # HTTP
        443   # HTTPS
        1880  # Node-RED Web UI
        1883  # MQTT
        9000  # Portainer web
        51827 # HomeKit accessory communication
        554   # HomeKit Secure Video RTSP
        5223  # HomeKit notifications (APNS, Apple Push Notification Service)
      ];
      allowedUDPPorts = [
        443  # HTTPS
        5353 # mDNS for HomeKit: Bonjour discovery and CIAO
      ];
    };
  };

  # Disable fail2ban since firewall is turned off
  services.fail2ban.enable = false;

  # Increase ulimit for influxdb
  security.pam.loginLimits = [{
    domain = "*";
    type = "soft";
    item = "nofile";
    value = "8192";
  }];

  # Enable Fwupd
  # https://nixos.wiki/wiki/Fwupd
  services.fwupd.enable = true;

  # Additional system packages
  environment.systemPackages = with pkgs; [
    # Network-related packages
    samba  # Enables remote shutdown of Windows PC via Node-RED and HomeKit voice command
    wol    # Facilitates wake-on-LAN for Windows 10 PC in Node-RED, triggered by HomeKit voice command
    mosquitto  # Only for mosquitto_sub on system level

    # Packages for kiosk-mode-vlc-cam viewer
    # Note: Packages vlc, openbox, xorg.xset work together to create a kiosk-mode camera viewer
    vlc     # Video playback software
    openbox # Lightweight window manager
    xorg.xset  # X11 user preference utility tool
    #pamixer    # Command-line audio mixer for PulseAudio
    #pulseaudio  # Provides 'pactl' for per-application volume control

  ];

  # +X11 and VLC kiosk mode configuration
  # Note: For start script go to: /home/kiosk/.config/openbox/autostart
  services.xserver = {
    enable = true;
    displayManager = {
      lightdm.enable = true;
      autoLogin = {
        enable = true;
        user = "kiosk";
      };
      defaultSession = "none+openbox";
    };
    windowManager.openbox.enable = true;
  };

  # Configuration for user "kiosk"
  users.users.kiosk = {
    isNormalUser = true;
    description = "Kiosk User";
    extraGroups = [ "video" "audio" ];
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

  # Home Manager configuration for custom Zellij keybindings and themes for the 'mba' user
  home-manager.users.${username} = {
    home.file.".config/zellij/config.kdl".text = ''
      // Zellij keybindings configuration
      keybinds {
          unbind "Ctrl o"
          normal {
              bind "Ctrl a" { MoveTab "Left"; }
              bind "Ctrl e" { SwitchToMode "Session"; }
          }
          session {
              bind "Ctrl e" { SwitchToMode "Normal"; }
          }
          tab {
              bind "c" {
                  NewTab {
                      cwd "~"
                  }
                  SwitchToMode "normal";
              }
          }
      }

      // Zellij themes configuration
      themes {
          catppuccin-latte {
              bg "#acb0be" // Surface2
              fg "#acb0be" // Surface2
              red "#d20f39"
              green "#40a02b"
              blue "#1e66f5"
              yellow "#df8e1d"
              magenta "#ea76cb" // Pink
              orange "#fe640b" // Peach
              cyan "#04a5e5" // Sky
              black "#dce0e8" // Crust
              white "#4c4f69" // Text
          }

          catppuccin-frappe {
              bg "#626880" // Surface2
              fg "#c6d0f5"
              red "#e78284"
              green "#a6d189"
              blue "#8caaee"
              yellow "#e5c890"
              magenta "#f4b8e4" // Pink
              orange "#ef9f76" // Peach
              cyan "#99d1db" // Sky
              black "#292c3c" // Mantle
              white "#c6d0f5"
          }

          catppuccin-macchiato {
              bg "#5b6078" // Surface2
              fg "#cad3f5"
              red "#ed8796"
              green "#a6da95"
              blue "#8aadf4"
              yellow "#eed49f"
              magenta "#f5bde6" // Pink
              orange "#f5a97f" // Peach
              cyan "#91d7e3" // Sky
              black "#1e2030" // Mantle
              white "#cad3f5"
          }

          catppuccin-mocha {
              bg "#585b70" // Surface2
              fg "#cdd6f4"
              red "#f38ba8"
              green "#a6e3a1"
              blue "#89b4fa"
              yellow "#f9e2af"
              magenta "#f5c2e7" // Pink
              orange "#fab387" // Peach
              cyan "#89dceb" // Sky
              black "#181825" // Mantle
              white "#cdd6f4"
          }

          // cloud server csb0 theme
          csb0 {
              bg "#9999ff"  // + Text Selection
              fg "#6666af"  // + Footer Buttons
              red "#f0f0f0" // + Shortcuts in Buttons (best: white)
              green "#9999ff" // + Frame
              blue "#00d9e3" // Electric Blue
              yellow "#aae600" // Neon Yellow
              magenta "#aa00ff" // Neon Purple
              orange "#006611" // Retro Red
              cyan "#00e5e5" // Cyan
              black "#00000f" // + Header and Footer bg (Black)
              white "#ffffff" // White
          }

          // miniserver24 theme
          ms24 {
              bg "#585b70" // Surface2
              fg "#d5f4cd" // pastell green
              red "#2a9e00" // dark green
              green "#a6e3a1"
              blue "#89b4fa"
              yellow "#f9e2af"
              magenta "#f5c2e7" // Pink
              orange "#fab387" // Peach
              cyan "#89dceb" // Sky
              black "#181825" // Mantle
              white "#cdd6f4"
          }

          // miniserver legacy theme
          ms {
              bg "#9f9f9f"  // + Text Selection
              fg "#6f6f6f"  // + Footer Buttons
              red "#f0f0f0" // + Shortcuts in Buttons (best: white)
              green "#9f9f9f" // + Frame
              blue "#00d9e3" // Electric Blue
              yellow "#aae600" // Neon Yellow
              magenta "#aa00ff" // Neon Purple
              orange "#006611" // Retro Red
              cyan "#00e5e5" // Cyan
              black "#00000f" // + Header and Footer bg (Black)
              white "#ffffff" // White
          }
      }

      // Session configuration (optionally restores terminated sessions on start)      session_serialization true

      // Theme to be used
      theme "ms24"
    '';
  };

  # MQTT-based VLC Volume Control Service for NixOS
  #
  # This service listens for MQTT messages on the topic 'home/miniserver24/kiosk-vlc-volume'
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
  # 2. Publish a message to 'home/miniserver24/kiosk-vlc-volume' with a value between 0 and 512
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
        ${pkgs.mosquitto}/bin/mosquitto_sub -v -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASS" -t 'home/miniserver24/kiosk-vlc-volume' 2>&1 | while read -r topic volume; do
          if [[ $topic == "home/miniserver24/kiosk-vlc-volume" ]]; then
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
}
