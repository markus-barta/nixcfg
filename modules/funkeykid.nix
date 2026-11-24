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

    keyboardName = mkOption {
      type = types.str;
      default = "ACME BK03";
      description = "evdev name of the kids' keyboard. Every input node named exactly this or '<name> <suffix>' (Consumer Control, System Control) is hidden from the host; hsb1 also passes it to the container as FUNKEYKID_KEYBOARD (OPS-667).";
    };

    hardwareIsolation = mkOption {
      type = types.bool;
      default = true;
      description = "udev rules + logind to isolate the funkeykid keyboard from the host. Keep enabled even with Docker.";
    };

    bluetoothReconnect = mkOption {
      type = types.bool;
      default = true;
      description = "Auto-reconnect the funkeykid keyboard on boot (looked up by name, no MAC in the config).";
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
      # OPS-667 gate r1 LOW: a packaged 72-funkeykid.rules runs after 70-power-switch/71-seat (which add the tags) and
      # before 73-seat-late's uaccess ACL helper, so the tag removal also stops the ACL; extraRules (99-local) is too late.
      services.udev.packages = [
        (pkgs.writeTextFile {
          name = "funkeykid-udev-rules";
          destination = "/etc/udev/rules.d/72-funkeykid.rules";
          text = ''
            # OPS-667: every node of the funkeykid keyboard is hidden from the host. A Bluetooth HID keyboard
            # registers extra nodes ("<name> Consumer Control", "<name> System Control" with sleep/power keys);
            # the old exact-name match missed them. Two rules: the exact name, and "<name> <suffix>" (a bare
            # "<name>*" glob would also catch unrelated names like "ACME BK030"). The former
            # ENV{KEYBOARD_KEY_*}="reserved" was a no-op (udev does not expand globs in assignment keys).
            SUBSYSTEM=="input", ATTRS{name}=="${cfg.keyboardName}", ENV{ID_INPUT}="0", ENV{ID_INPUT_KEY}="0", ENV{ID_INPUT_KEYBOARD}="0", ENV{LIBINPUT_IGNORE_DEVICE}="1", TAG-="seat", TAG-="uaccess", TAG-="power-switch"
            SUBSYSTEM=="input", ATTRS{name}=="${cfg.keyboardName} *", ENV{ID_INPUT}="0", ENV{ID_INPUT_KEY}="0", ENV{ID_INPUT_KEYBOARD}="0", ENV{LIBINPUT_IGNORE_DEVICE}="1", TAG-="seat", TAG-="uaccess", TAG-="power-switch"
          '';
        })
      ];

      # Defense-in-depth: udev TAG- can lose the race on BT reconnect (2026-04-11
      # incident: logind re-watched event9 and accidental power key press triggered
      # shutdown). Ignore power/suspend/hibernate keys at the logind level too.
      # Long-press still allows intentional poweroff.
      services.logind.settings.Login = {
        HandlePowerKey = "ignore";
        HandlePowerKeyLongPress = "poweroff";
        HandleSuspendKey = "ignore";
        HandleHibernateKey = "ignore";
        HandleRebootKey = "ignore"; # OPS-667: default would reboot on a keyboard reboot key
      };
    })

    # ── Bluetooth auto-reconnect (always on by default) ───────────────────
    (mkIf cfg.bluetoothReconnect {
      systemd.services.acme-bk03-reconnect = {
        description = "Auto-reconnect the funkeykid Bluetooth keyboard";
        wantedBy = [ "multi-user.target" ];
        after = [ "bluetooth.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = false;
        };
        script = ''
          sleep 3
          # OPS-667: look the address up by name among known devices instead of hardcoding the MAC.
          name=${lib.escapeShellArg cfg.keyboardName}
          addr=$(${pkgs.bluez}/bin/bluetoothctl devices | ${pkgs.gawk}/bin/awk -v n="$name" '$1=="Device" && substr($0, index($0, $3)) == n { print $2; exit }')
          if [ -z "$addr" ]; then
            echo "Warning: no known Bluetooth device named $name"
            exit 0
          fi
          for i in {1..5}; do
            echo "Attempt $i: connecting to $name..."
            if ${pkgs.bluez}/bin/bluetoothctl connect "$addr"; then
              echo "$name connected"
              exit 0
            fi
            sleep 2
          done
          echo "Warning: could not connect to $name (keyboard may be off or out of range)"
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
          # NIX-158: agenix-materialized smarthome env (was plaintext /home/mba/secrets/smarthome.env, now shredded).
          EnvironmentFile = [ "/run/agenix/hsb1-smarthome-env" ];
          ProtectHome = "read-only";
        };
      };
    })
  ];
}
