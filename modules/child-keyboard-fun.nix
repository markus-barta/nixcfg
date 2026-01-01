{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.child-keyboard-fun;

  # Python script for keyboard handling
  keyboardFunScript =
    pkgs.writers.writePython3 "child-keyboard-fun"
      {
        libraries = with pkgs.python3Packages; [ evdev ];
        flakeIgnore = [
          "E265"
          "E501"
        ]; # Ignore shebang format and line length (Nix paths)
      }
      ''
        #!/usr/bin/env python3
        import evdev
        import subprocess
        import os
        import random
        import sys
        from pathlib import Path


        def load_env(env_file):
            """Simple .env file parser"""
            config = {}
            if not os.path.exists(env_file):
                print(f"Error: Config file {env_file} not found")
                sys.exit(1)

            with open(env_file, 'r') as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith('#') and '=' in line:
                        key, value = line.split('=', 1)
                        config[key.strip()] = value.strip()
            return config


        def get_sound_files(sound_dir):
            """Get list of audio files in directory"""
            if not os.path.exists(sound_dir):
                print(f"Warning: Sound directory {sound_dir} not found")
                return []
            wav_files = list(Path(sound_dir).glob('*.wav'))
            mp3_files = list(Path(sound_dir).glob('*.mp3'))
            return wav_files + mp3_files


        def play_sound(sound_file):
            """Play sound using appropriate player (non-blocking)"""
            if not os.path.exists(sound_file):
                print(f"Warning: Sound file {sound_file} not found")
                return

            # Use mpg123 for MP3, aplay for WAV
            if str(sound_file).endswith('.mp3'):
                player = '${pkgs.mpg123}/bin/mpg123'
            else:
                player = '${pkgs.alsa-utils}/bin/aplay'
            subprocess.Popen([player, '-q', str(sound_file)])


        def main():
            # Load configuration
            env_file = os.getenv('KEYBOARD_FUN_CONFIG', '/etc/child-keyboard-fun.env')
            config = load_env(env_file)

            device_path = config.get('KEYBOARD_DEVICE')
            sound_dir = config.get('SOUND_DIR')

            if not device_path:
                print("Error: KEYBOARD_DEVICE not set in config")
                sys.exit(1)

            if not sound_dir:
                print("Error: SOUND_DIR not set in config")
                sys.exit(1)

            # Get available sound files
            sound_files = get_sound_files(sound_dir)
            if not sound_files:
                print(f"Warning: No audio files found in {sound_dir}")

            # Build key mapping from config
            key_mappings = {}
            for key, value in config.items():
                if key.startswith('KEY_'):
                    key_name = key[4:]  # Remove 'KEY_' prefix
                    key_mappings[key_name] = value

            print("Child Keyboard Fun starting...")
            print(f"Device: {device_path}")
            print(f"Sound directory: {sound_dir}")
            print(f"Available sounds: {len(sound_files)}")
            print(f"Key mappings: {len(key_mappings)}")

            # Open and grab the keyboard device
            try:
                device = evdev.InputDevice(device_path)
            except Exception as e:
                print(f"Error opening device {device_path}: {e}")
                sys.exit(1)

            print(f"Grabbed device: {device.name}")
            device.grab()

            # Event loop
            try:
                for event in device.read_loop():
                    if event.type == evdev.ecodes.EV_KEY:
                        key_event = evdev.categorize(event)
                        if key_event.keystate == evdev.KeyEvent.key_down:
                            key_name = key_event.keycode
                            if isinstance(key_name, list):
                                key_name = key_name[0]

                            # Remove KEY_ prefix if present
                            if key_name.startswith('KEY_'):
                                key_name = key_name[4:]

                            # Check if key has specific mapping
                            if key_name in key_mappings:
                                action = key_mappings[key_name]
                                if action.startswith('sound:'):
                                    # Play specific sound
                                    sound_file = os.path.join(sound_dir, action[6:])
                                    play_sound(sound_file)
                                elif action == 'random':
                                    # Play random sound
                                    if sound_files:
                                        sound_file = random.choice(sound_files)
                                        play_sound(sound_file)
                            else:
                                # Default: play random sound
                                if sound_files:
                                    sound_file = random.choice(sound_files)
                                    play_sound(sound_file)

            except KeyboardInterrupt:
                print("\nStopping...")
            finally:
                device.ungrab()


        if __name__ == '__main__':
            main()
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

    configFile = mkOption {
      type = types.path;
      description = "Path to the .env configuration file";
      example = "/etc/child-keyboard-fun.env";
    };
  };

  config = mkIf cfg.enable {
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
        ExecStart = "${keyboardFunScript}";
        Restart = "always";
        RestartSec = "5";

        # Environment
        Environment = "KEYBOARD_FUN_CONFIG=${cfg.configFile}";

        # Security - relaxed for input/audio device access
        NoNewPrivileges = true;
        ProtectHome = "read-only"; # Need to read sound files from home
        ReadOnlyPaths = [ cfg.configFile ];

        # Device access - allow all devices (needed for input and audio)
        DevicePolicy = "closed";
        DeviceAllow = [
          "char-input rw" # Input devices
          "char-sound rw" # Sound devices
        ];
      };
    };
  };
}
