{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.funkeykid;

  funkeykidWrapper = pkgs.writeShellScript "funkeykid-wrapper" ''
    export PATH=${
      lib.makeBinPath [
        pkgs.python3
        pkgs.pulseaudio
      ]
    }:$PATH
    export PYTHONPATH=${pkgs.python3.pkgs.evdev}/lib/python${pkgs.python3.pythonVersion}/site-packages:${pkgs.python3.pkgs.paho-mqtt}/lib/python${pkgs.python3.pythonVersion}/site-packages
    exec ${pkgs.python3}/bin/python3 ${cfg.scriptPath}
  '';
in
{
  options.services.funkeykid = {
    enable = mkEnableOption "funkeykid NixOS systemd service (disable if using Docker container)";

    hardwareIsolation = mkOption {
      type = types.bool;
      default = true;
      description = "udev rules + logind to isolate ACME BK03 from host. Keep enabled even with Docker.";
    };

    bluetoothReconnect = mkOption {
      type = types.bool;
      default = true;
      description = "Auto-reconnect ACME BK03 on boot.";
    };

    scriptPath = mkOption {
      type = types.path;
      default = ../hosts/hsb1/files/funkeykid.py;
      description = "Path to the Python script";
    };

    configFile = mkOption {
      type = types.path;
      default = ../hosts/hsb1/files/funkeykid.env;
      description = "Path to the .env configuration file";
    };

    user = mkOption {
      type = types.str;
      default = "mba";
      description = "User to run the service as";
    };
  };

  config = mkMerge [
    # ── Hardware isolation (always on by default) ──────────────────────────
    # Keeps ACME BK03 events out of X11/logind/host, prevents power key shutdowns.
    # Required whether running as NixOS service OR Docker container.
    (mkIf cfg.hardwareIsolation {
      services.udev.extraRules = ''
        # ACME BK03 Bluetooth Keyboard — isolated for funkeykid only
        SUBSYSTEM=="input", ATTRS{name}=="ACME BK03", ENV{ID_INPUT}="0", ENV{ID_INPUT_KEYBOARD}="0", ENV{KEYBOARD_KEY_*}="reserved", TAG-="seat", TAG-="uaccess", TAG-="power-switch"
      '';
    })

    # ── Bluetooth auto-reconnect (always on by default) ───────────────────
    (mkIf cfg.bluetoothReconnect {
      systemd.services.acme-bk03-reconnect = {
        description = "Auto-reconnect ACME BK03 Bluetooth Keyboard";
        wantedBy = [ "multi-user.target" ];
        after = [ "bluetooth.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = false;
        };
        script = ''
          sleep 3
          for i in {1..5}; do
            echo "Attempt $i: Connecting to ACME BK03..."
            if ${pkgs.bluez}/bin/bluetoothctl connect 20:73:00:04:21:4F; then
              echo "ACME BK03 connected successfully!"
              exit 0
            fi
            sleep 2
          done
          echo "Warning: Could not connect to ACME BK03 (keyboard may be off or out of range)"
          exit 0
        '';
      };
    })

    # ── NixOS systemd service (only when enable = true) ───────────────────
    # Disabled when using Docker container instead.
    (mkIf cfg.enable {
      environment.etc."funkeykid.env".source = cfg.configFile;

      users.users.${cfg.user}.extraGroups = [
        "input"
        "audio"
      ];

      systemd.services.funkeykid = {
        description = "funkeykid — Educational keyboard toy";
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
          "network-online.target"
          "acme-bk03-reconnect.service"
        ];
        preStart = "sleep 5";
        serviceConfig = {
          Type = "simple";
          User = "kiosk";
          SupplementaryGroups = [
            "input"
            "audio"
          ];
          ExecStart = "${funkeykidWrapper}";
          Restart = "always";
          RestartSec = "3";
          StartLimitBurst = 0;
          Environment = [
            "FUNKEYKID_CONFIG=/etc/funkeykid.env"
            "XDG_RUNTIME_DIR=/run/user/1001"
          ];
          EnvironmentFile = [ "/home/mba/secrets/smarthome.env" ];
          ProtectHome = "read-only";
        };
      };
    })
  ];
}
