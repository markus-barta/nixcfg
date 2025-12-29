# Child's Keyboard Fun System
# A systemd service that handles a dedicated child's Bluetooth keyboard
# with sound effects and Home Assistant integration

{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.child-keyboard-fun;

  # Python script that handles the keyboard events
  childKeyboardScript =
    pkgs.writers.writePython3 "child-keyboard-fun"
      {
        libraries = with pkgs.python3Packages; [
          evdev
          paho-mqtt
          python-dotenv
        ];
      }
      ''
        #!/usr/bin/env python3
        """
        Child's Keyboard Fun - Make a dedicated keyboard trigger sounds and smart home actions
        """
        import os
        import sys
        import time
        import subprocess
        import random
        import logging
        from pathlib import Path
        from typing import Optional, Dict, List
        import signal
        import evdev
        from evdev import InputDevice, categorize, ecodes
        from dotenv import load_dotenv

        # Optional MQTT support
        try:
            import paho.mqtt.client as mqtt
            MQTT_AVAILABLE = True
        except ImportError:
            MQTT_AVAILABLE = False

        # Setup logging
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
        )
        logger = logging.getLogger('child-keyboard-fun')

        class ChildKeyboardFun:
            def __init__(self, config_file: str = "/etc/child-keyboard-fun.env"):
                self.config_file = config_file
                self.running = True
                self.device: Optional[InputDevice] = None
                self.mqtt_client: Optional[mqtt.Client] = None
                self.sound_dir: Optional[Path] = None
                self.sound_files: List[Path] = []
                self.key_mappings: Dict[str, List[str]] = {}
                
                # Load configuration
                self.load_config()
                
                # Setup signal handlers
                signal.signal(signal.SIGTERM, self.signal_handler)
                signal.signal(signal.SIGINT, self.signal_handler)
            
            def signal_handler(self, signum, frame):
                logger.info(f"Received signal {signum}, shutting down...")
                self.running = False
            
            def load_config(self):
                """Load configuration from .env file"""
                if not os.path.exists(self.config_file):
                    logger.error(f"Config file not found: {self.config_file}")
                    sys.exit(1)
                
                load_dotenv(self.config_file)
                
                # Get device path
                self.device_path = os.getenv('KEYBOARD_DEVICE')
                if not self.device_path:
                    logger.error("KEYBOARD_DEVICE not set in config file")
                    sys.exit(1)
                
                # Get sound directory
                sound_dir_str = os.getenv('SOUND_DIR', '/home/childuser/child-keyboard-sounds')
                self.sound_dir = Path(sound_dir_str)
                if not self.sound_dir.exists():
                    logger.warning(f"Sound directory not found: {self.sound_dir}")
                    self.sound_files = []
                else:
                    self.sound_files = list(self.sound_dir.glob('*.wav'))
                    logger.info(f"Found {len(self.sound_files)} sound files")
                
                # Parse key mappings
                for key, value in os.environ.items():
                    if key.startswith('KEY_'):
                        actions = value.split(',')
                        self.key_mappings[key] = [a.strip() for a in actions]
                
                logger.info(f"Loaded {len(self.key_mappings)} key mappings")
                
                # Setup MQTT if configured
                if MQTT_AVAILABLE:
                    mqtt_host = os.getenv('MQTT_HOST')
                    if mqtt_host:
                        self.setup_mqtt(
                            host=mqtt_host,
                            port=int(os.getenv('MQTT_PORT', '1883')),
                            user=os.getenv('MQTT_USER'),
                            password=os.getenv('MQTT_PASS')
                        )
            
            def setup_mqtt(self, host: str, port: int, user: Optional[str], password: Optional[str]):
                """Setup MQTT client for Home Assistant integration"""
                try:
                    self.mqtt_client = mqtt.Client()
                    if user and password:
                        self.mqtt_client.username_pw_set(user, password)
                    
                    def on_connect(client, userdata, flags, rc):
                        if rc == 0:
                            logger.info(f"Connected to MQTT broker at {host}:{port}")
                        else:
                            logger.error(f"Failed to connect to MQTT broker: {rc}")
                    
                    def on_disconnect(client, userdata, rc):
                        if rc != 0:
                            logger.warning(f"Unexpected MQTT disconnection: {rc}")
                    
                    self.mqtt_client.on_connect = on_connect
                    self.mqtt_client.on_disconnect = on_disconnect
                    
                    self.mqtt_client.connect_async(host, port, 60)
                    self.mqtt_client.loop_start()
                    
                except Exception as e:
                    logger.error(f"Failed to setup MQTT: {e}")
                    self.mqtt_client = None
            
            def open_device(self) -> bool:
                """Open and grab the keyboard device"""
                try:
                    if not os.path.exists(self.device_path):
                        logger.error(f"Device not found: {self.device_path}")
                        return False
                    
                    self.device = InputDevice(self.device_path)
                    logger.info(f"Opened device: {self.device.name} ({self.device_path})")
                    
                    # Grab the device exclusively
                    self.device.grab()
                    logger.info("Device grabbed exclusively - key presses will not affect system")
                    
                    return True
                    
                except PermissionError:
                    logger.error(f"Permission denied accessing {self.device_path}. Is user in 'input' group?")
                    return False
                except Exception as e:
                    logger.error(f"Failed to open device: {e}")
                    return False
            
            def play_sound(self, sound_file: Optional[Path] = None):
                """Play a sound file using aplay"""
                if not self.sound_files:
                    logger.debug("No sound files available")
                    return
                
                if sound_file is None:
                    sound_file = random.choice(self.sound_files)
                
                if not sound_file.exists():
                    logger.warning(f"Sound file not found: {sound_file}")
                    return
                
                try:
                    # Play in background, don't wait
                    subprocess.Popen(
                        ['${pkgs.alsa-utils}/bin/aplay', '-q', str(sound_file)],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL
                    )
                    logger.debug(f"Playing: {sound_file.name}")
                except Exception as e:
                    logger.error(f"Failed to play sound: {e}")
            
            def publish_mqtt(self, topic: str, payload: str):
                """Publish MQTT message"""
                if not self.mqtt_client:
                    logger.debug("MQTT not available")
                    return
                
                try:
                    result = self.mqtt_client.publish(topic, payload)
                    if result.rc == mqtt.MQTT_ERR_SUCCESS:
                        logger.debug(f"Published to {topic}: {payload}")
                    else:
                        logger.warning(f"Failed to publish to {topic}: {result.rc}")
                except Exception as e:
                    logger.error(f"MQTT publish error: {e}")
            
            def handle_key_event(self, event):
                """Handle a key press event"""
                # Only handle key down events (not repeats or releases)
                if event.value != 1:  # 1 = key down, 0 = key up, 2 = repeat
                    return
                
                # Get key name
                try:
                    key_name = f"KEY_{ecodes.KEY[event.code]}"
                except KeyError:
                    key_name = f"KEY_{event.code}"
                
                logger.info(f"Key pressed: {key_name}")
                
                # Check for specific mapping
                if key_name in self.key_mappings:
                    actions = self.key_mappings[key_name]
                    sound_played = False
                    
                    for action in actions:
                        if action == 'random':
                            # Play random sound
                            self.play_sound()
                            sound_played = True
                        elif action.startswith('sound:'):
                            # Play specific sound
                            sound_file = self.sound_dir / action[6:]
                            self.play_sound(sound_file)
                            sound_played = True
                        elif action.startswith('mqtt:'):
                            # Send MQTT message
                            parts = action[5:].split(':', 1)
                            if len(parts) == 2:
                                topic, payload = parts
                                self.publish_mqtt(topic, payload)
                    
                    # If no sound action was specified, play random sound
                    if not sound_played:
                        self.play_sound()
                else:
                    # No specific mapping - play random sound
                    self.play_sound()
            
            def run(self):
                """Main event loop"""
                logger.info("Child's Keyboard Fun starting...")
                
                # Wait for device to be available
                max_retries = 30
                retry_count = 0
                while retry_count < max_retries and self.running:
                    if self.open_device():
                        break
                    retry_count += 1
                    logger.info(f"Waiting for device... ({retry_count}/{max_retries})")
                    time.sleep(2)
                
                if not self.device:
                    logger.error("Failed to open device after retries")
                    return 1
                
                logger.info("Ready! Listening for key presses...")
                
                try:
                    # Main event loop
                    for event in self.device.read_loop():
                        if not self.running:
                            break
                        
                        # Only process key events
                        if event.type == ecodes.EV_KEY:
                            self.handle_key_event(event)
                            
                except OSError as e:
                    logger.error(f"Device error: {e}")
                    return 1
                except Exception as e:
                    logger.error(f"Unexpected error: {e}", exc_info=True)
                    return 1
                finally:
                    self.cleanup()
                
                logger.info("Shutting down")
                return 0
            
            def cleanup(self):
                """Cleanup resources"""
                if self.device:
                    try:
                        self.device.ungrab()
                        self.device.close()
                    except:
                        pass
                
                if self.mqtt_client:
                    try:
                        self.mqtt_client.loop_stop()
                        self.mqtt_client.disconnect()
                    except:
                        pass

        if __name__ == '__main__':
            config_file = sys.argv[1] if len(sys.argv) > 1 else '/etc/child-keyboard-fun.env'
            app = ChildKeyboardFun(config_file)
            sys.exit(app.run())
      '';

in
{
  options.services.child-keyboard-fun = {
    enable = mkEnableOption "Child's Keyboard Fun service";

    user = mkOption {
      type = types.str;
      default = "childuser";
      description = "User to run the service as";
    };

    configFile = mkOption {
      type = types.path;
      description = "Path to the .env configuration file";
      example = "/etc/child-keyboard-fun.env";
    };
  };

  config = mkIf cfg.enable {
    # Ensure the script is available in system packages
    environment.systemPackages = [
      childKeyboardScript
      pkgs.alsa-utils
      pkgs.evtest # Useful for finding device paths
    ];

    # Ensure user is in required groups
    users.users.${cfg.user} = {
      isNormalUser = mkDefault true;
      extraGroups = [
        "input"
        "audio"
      ];
    };

    # Create systemd service
    systemd.services.child-keyboard-fun = {
      description = "Child's Keyboard Fun - Interactive keyboard with sounds and smart home";
      documentation = [ "file:///Users/markus/Code/nixcfg/BACKLOG-child-keyboard-fun.md" ];
      wantedBy = [ "multi-user.target" ];
      after = [
        "multi-user.target"
        "sound.target"
      ];

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        ExecStart = "${childKeyboardScript} ${cfg.configFile}";
        Restart = "always";
        RestartSec = "10";

        # Security hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = false; # Need access to home directory for sounds
        ReadWritePaths = [ ];

        # Allow access to input devices and audio
        SupplementaryGroups = [
          "input"
          "audio"
        ];

        # Device access
        DeviceAllow = [
          "/dev/input"
          "/dev/snd"
        ];
      };
    };
  };
}
