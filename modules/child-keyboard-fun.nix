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

    # systemd service
    systemd.services.child-keyboard-fun = {
      description = "Child's Bluetooth Keyboard Fun System";
      wantedBy = [ "multi-user.target" ];
      after = [
        "bluetooth.target"
        "sound.target"
      ];

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        ExecStart = "${keyboardFunWrapper}";
        Restart = "always";
        RestartSec = "5";

        # Environment
        Environment = "KEYBOARD_FUN_CONFIG=/etc/child-keyboard-fun.env";

        # Security - minimal restrictions for device access
        ProtectHome = "read-only"; # Need to read sound files
      };
    };
  };
}
