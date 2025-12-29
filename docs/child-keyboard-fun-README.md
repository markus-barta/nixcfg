# Child's Keyboard Fun 🎮🎵

A NixOS service that turns a dedicated child's keyboard into an interactive, fun learning tool with sounds and smart home integration.

## What It Does

- **Exclusive Keyboard Handling**: Grabs a dedicated keyboard so key presses don't affect the system
- **Fun Sounds**: Every key press triggers a sound effect (random or per-key configured)
- **Smart Home Integration**: Map keys to Home Assistant actions via MQTT (toggle lights, scenes, etc.)
- **Declarative Configuration**: Fully configured in NixOS with automatic dependencies
- **Safe & Isolated**: Runs as unprivileged user with minimal permissions

## Perfect For

- Young children learning to type
- Interactive play without affecting parent's work
- Teaching letter/number recognition with sounds
- Giving kids "control" of smart home devices safely
- Fun keyboard toy during screen-free time

## Quick Start

### 1. Files Overview

```
nixcfg/
├── modules/child-keyboard-fun.nix        # Main NixOS module
├── examples/child-keyboard-fun.env       # Example configuration
├── docs/
│   ├── child-keyboard-fun-setup.md       # Complete setup guide
│   └── child-keyboard-fun-hsb1-integration.md  # hsb1-specific guide
└── BACKLOG-child-keyboard-fun.md         # Detailed requirements
```

### 2. Basic Setup (3 Steps)

**Step 1: Add to configuration.nix**

```nix
{
  imports = [ ./modules/child-keyboard-fun.nix ];

  services.child-keyboard-fun = {
    enable = true;
    user = "childuser";
    configFile = "/etc/child-keyboard-fun.env";
  };
}
```

**Step 2: Find keyboard device**

```bash
sudo evtest  # Find your keyboard's /dev/input/by-id/ path
```

**Step 3: Configure**

```bash
# Create config
sudo tee /etc/child-keyboard-fun.env << 'EOF'
KEYBOARD_DEVICE=/dev/input/by-id/YOUR-KEYBOARD-event-kbd
SOUND_DIR=/home/childuser/child-keyboard-sounds
KEY_SPACE=random
EOF

# Add sound files
sudo mkdir -p /home/childuser/child-keyboard-sounds
# Copy .wav files here

# Apply
sudo nixos-rebuild switch
```

### 3. Verify

```bash
# Check service
sudo systemctl status child-keyboard-fun

# Test keyboard - press keys, hear sounds!
# Keys should NOT type into console
```

## Configuration Examples

### Simple - Just Sounds

```env
KEYBOARD_DEVICE=/dev/input/by-id/usb-Logitech-event-kbd
SOUND_DIR=/home/kid/sounds
KEY_SPACE=random
```

### Educational - Letter Sounds

```env
KEYBOARD_DEVICE=/dev/input/by-id/usb-Logitech-event-kbd
SOUND_DIR=/home/kid/sounds

# Map letters to learning sounds
KEY_A=sound:letter_a_apple.wav
KEY_B=sound:letter_b_bear.wav
KEY_C=sound:letter_c_cat.wav
# ... etc
```

### Smart Home - Light Control

```env
KEYBOARD_DEVICE=/dev/input/by-id/usb-Logitech-event-kbd
SOUND_DIR=/home/kid/sounds

MQTT_HOST=homeassistant.local
MQTT_PORT=1883
MQTT_USER=keyboard
MQTT_PASS=secret

# Function keys control lights
KEY_F1=random,mqtt:homeassistant/light/bedroom/set:{"state":"toggle"}
KEY_F2=random,mqtt:homeassistant/scene/playtime:ON
KEY_F3=random,mqtt:homeassistant/scene/bedtime:ON
```

## Features

### ✅ Implemented

- [x] Exclusive keyboard grabbing (no system interference)
- [x] Random sound playback per key
- [x] Per-key specific sound mapping
- [x] SPACE key special handling (random sound)
- [x] Home Assistant integration via MQTT
- [x] Declarative NixOS configuration
- [x] Auto-restart on failure
- [x] Unprivileged user execution
- [x] .env file configuration
- [x] Multiple action types per key (sound + MQTT)

### 🚀 Future Ideas

- [ ] LED/RGB keyboard backlight control
- [ ] Visual feedback (screen overlay)
- [ ] Statistics and achievements
- [ ] Time-based profiles (different sounds morning/evening)
- [ ] Multiple keyboard support
- [ ] Web-based configuration UI
- [ ] Text-to-speech fallback
- [ ] Educational games mode

## Architecture

```
┌─────────────────────────────────────────┐
│         Child's Keyboard (USB/BT)       │
└────────────────┬────────────────────────┘
                 │ Raw input events
                 ▼
┌─────────────────────────────────────────┐
│      evdev (Python) - Exclusive Grab    │
│  • Intercepts all key events            │
│  • Prevents system input                │
└────────────┬───────────────┬────────────┘
             │               │
             ▼               ▼
     ┌──────────────┐  ┌──────────────┐
     │ Sound System │  │     MQTT     │
     │   (aplay)    │  │(Home Assist) │
     └──────────────┘  └──────────────┘
             │               │
             ▼               ▼
     ┌──────────────┐  ┌──────────────┐
     │  WAV Files   │  │    Lights     │
     │   /home/...  │  │   Scenes      │
     └──────────────┘  │   Switches    │
                       └──────────────┘
```

## Documentation

- **[Setup Guide](./child-keyboard-fun-setup.md)**: Complete installation and configuration
- **[hsb1 Integration](./child-keyboard-fun-hsb1-integration.md)**: Host-specific deployment guide
- **[Backlog Item](../BACKLOG-child-keyboard-fun.md)**: Detailed requirements and user stories

## Troubleshooting

| Problem             | Solution                                           |
| ------------------- | -------------------------------------------------- |
| Device not found    | Check path with `sudo evtest`                      |
| Permission denied   | Ensure user in `input` group                       |
| No sound            | Test with `aplay`, check `audio` group             |
| MQTT not working    | Verify credentials, check Home Assistant logs      |
| Service won't start | Check logs: `journalctl -u child-keyboard-fun -xe` |

See [Setup Guide](./child-keyboard-fun-setup.md) for detailed troubleshooting.

## Dependencies

Automatically handled by NixOS module:

- Python 3 with evdev, paho-mqtt, python-dotenv
- alsa-utils (aplay)
- User added to input and audio groups

## Requirements

- NixOS system
- Dedicated USB or Bluetooth keyboard
- Collection of WAV sound files
- (Optional) Home Assistant with MQTT

## Target Host

This is designed for **hsb1** but can run on any NixOS system.

## Credits & License

Built with:

- [python-evdev](https://python-evdev.readthedocs.io/) - Input device handling
- [paho-mqtt](https://www.eclipse.org/paho/) - MQTT client
- [alsa-utils](https://alsa-project.org/) - Audio playback
- NixOS - Declarative system configuration

## Contributing

Ideas for enhancement:

1. Visual feedback system
2. Educational game modes
3. Multiple keyboard profiles
4. Web configuration interface
5. Statistics and achievements
6. Bluetooth LE support for wireless keyboards
7. Custom action plugins

## Support

For issues or questions:

1. Check the [Setup Guide](./child-keyboard-fun-setup.md)
2. Review logs: `sudo journalctl -u child-keyboard-fun -f`
3. Test manually: `sudo -u user /path/to/script /path/to/config`

## Quick Reference

```bash
# Service control
sudo systemctl start|stop|restart|status child-keyboard-fun

# View logs
sudo journalctl -u child-keyboard-fun -f

# Edit config
sudo nano /etc/child-keyboard-fun.env

# Find keyboard
sudo evtest
ls -la /dev/input/by-id/

# Test sound
aplay /path/to/sound.wav

# Apply changes
sudo nixos-rebuild switch
```

---

Have fun! 🎉
