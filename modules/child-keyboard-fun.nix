{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.child-keyboard-fun;

  # Python script wrapper that sets up environment and runs the actual script
  keyboardFunWrapper = pkgs.writeShellScript "child-keyboard-fun-wrapper" ''
    export PATH=${
      lib.makeBinPath [
        pkgs.python3
        pkgs.sudo
        pkgs.pulseaudio
      ]
    }:$PATH
    export PYTHONPATH=${pkgs.python3.pkgs.evdev}/lib/python${pkgs.python3.pythonVersion}/site-packages:${pkgs.python3.pkgs.paho-mqtt}/lib/python${pkgs.python3.pythonVersion}/site-packages
    exec ${pkgs.python3}/bin/python3 ${cfg.scriptPath}
  '';

in
{
  options.services.child-keyboard-fun = {
    enable = mkEnableOption "Child's Bluetooth Keyboard Fun System";

    user = mkOption {
      type = types.str;
      default = "mba";
      description = "User to run the service as";
    };

    scriptPath = mkOption {
      type = types.path;
      default = ../hosts/hsb1/files/child-keyboard-fun.py;
      description = "Path to the Python script";
    };

    configFile = mkOption {
      type = types.path;
      default = ../hosts/hsb1/files/child-keyboard-fun.env;
      description = "Path to the .env configuration file";
    };
  };

  config = mkIf cfg.enable {
    # Copy config file to /etc
    environment.etc."child-keyboard-fun.env".source = cfg.configFile;

    # Ensure user is in input group
    users.users.${cfg.user}.extraGroups = [
      "input"
      "audio"
    ];

    # udev rule to prevent X/systemd-logind from grabbing ACME BK03
    # This allows our service to have exclusive access without bluetooth issues
    # CRITICAL: Prevents power/suspend keys from shutting down the system
    services.udev.extraRules = ''
      # ACME BK03 Bluetooth Keyboard - for child-keyboard-fun only
      # Remove all input/keyboard identification to prevent system from processing events
      SUBSYSTEM=="input", ATTRS{name}=="ACME BK03", ENV{ID_INPUT}="0", ENV{ID_INPUT_KEYBOARD}="0", ENV{KEYBOARD_KEY_*}="reserved", TAG-="seat", TAG-="uaccess", TAG-="power-switch"
    '';

    # Auto-reconnect ACME BK03 keyboard on boot
    systemd.services.acme-bk03-reconnect = {
      description = "Auto-reconnect ACME BK03 Bluetooth Keyboard";
      wantedBy = [ "multi-user.target" ];
      after = [ "bluetooth.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = false;
      };
      script = ''
        # Wait for Bluetooth to be ready
        sleep 3

        # Try to connect up to 5 times with 2s delay between attempts
        for i in {1..5}; do
          echo "Attempt $i: Connecting to ACME BK03..."
          if ${pkgs.bluez}/bin/bluetoothctl connect 20:73:00:04:21:4F; then
            echo "ACME BK03 connected successfully!"
            exit 0
          fi
          sleep 2
        done

        echo "Warning: Could not connect to ACME BK03 (keyboard may be off or out of range)"
        # Don't fail the service - keyboard might be turned on later
        exit 0
      '';
    };

    # systemd service
    systemd.services.child-keyboard-fun = {
      description = "Child's Bluetooth Keyboard Fun System";
      wantedBy = [ "multi-user.target" ];
      after = [
        "bluetooth.target"
        "sound.target"
        "network-online.target"
        "multi-user.target"
        "acme-bk03-reconnect.service"
      ];
      wants = [
        "bluetooth.target"
        "acme-bk03-reconnect.service"
      ];
      # Wait a bit for Bluetooth devices to settle after boot
      preStart = ''
        sleep 5
      '';

      serviceConfig = {
        Type = "simple";
        User = "kiosk"; # Run as kiosk to access PipeWire session
        SupplementaryGroups = [
          "input"
          "audio"
        ]; # Need input for keyboard, audio for sound
        ExecStart = "${keyboardFunWrapper}";

        # Auto-healing: restart on any failure
        Restart = "always";
        RestartSec = "3"; # Quick restart for reconnection
        StartLimitBurst = 0; # No limit on restart attempts

        # Environment
        Environment = [
          "KEYBOARD_FUN_CONFIG=/etc/child-keyboard-fun.env"
          "XDG_RUNTIME_DIR=/run/user/1001" # kiosk user's runtime dir
        ];
        EnvironmentFile = "/home/mba/secrets/smarthome.env";

        # Security - minimal restrictions for device access
        ProtectHome = "read-only"; # Need to read sound files
      };
    };
  };
}
