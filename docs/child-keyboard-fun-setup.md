# Child's Keyboard Fun - Setup Guide

Complete setup guide for the child's keyboard fun system on NixOS.

## Overview

This service makes a dedicated child's Bluetooth keyboard trigger fun sounds and optionally control Home Assistant smart home devices. The keyboard is exclusively grabbed so key presses don't affect normal system input.

## Prerequisites

- NixOS system (tested on hsb1)
- Dedicated USB or Bluetooth keyboard for child
- Collection of WAV sound files
- (Optional) Home Assistant with MQTT enabled

## Installation Steps

### 1. Add Module to Configuration

Edit your `/etc/nixos/configuration.nix` or host-specific config:

```nix
{ config, pkgs, ... }:

{
  # Import the module
  imports = [
    ./modules/child-keyboard-fun.nix
  ];

  # Enable and configure the service
  services.child-keyboard-fun = {
    enable = true;
    user = "childuser";  # Change to your user
    configFile = "/etc/child-keyboard-fun.env";
  };

  # The module automatically adds the user to required groups (input, audio)
  # But you may want to ensure the user exists:
  users.users.childuser = {
    isNormalUser = true;
    description = "Child User";
    extraGroups = [ "input" "audio" ];  # Added automatically by module
  };
}
```

### 2. Find Your Keyboard Device Path

You need to identify the stable device path for the child's keyboard:

```bash
# List all input devices
sudo evtest

# Or check device info
cat /proc/bus/input/devices

# Or list stable paths
ls -la /dev/input/by-id/
```

Look for your keyboard and note its `/dev/input/by-id/...` path. For example:

- `usb-Logitech_USB_Receiver-event-kbd`
- `usb-Microsoft_Wireless_Keyboard_800-event-kbd`

### 3. Prepare Sound Files

Create a directory for sound files:

```bash
sudo mkdir -p /home/childuser/child-keyboard-sounds
sudo chown childuser:users /home/childuser/child-keyboard-sounds
```

Add WAV files to this directory. You can:

- Download free sound effects from freesound.org
- Record your own sounds
- Use system sounds from `/usr/share/sounds/`

Example sounds to look for:

- Click sounds (mechanical keyboard sounds)
- Boops and beeps
- Animal sounds (for letters: a=alligator, b=bear, etc.)
- Musical notes
- Voice recordings (letters, numbers)

```bash
# Example: Copy some system sounds
cp /run/current-system/sw/share/sounds/freedesktop/stereo/*.wav \
   /home/childuser/child-keyboard-sounds/
```

### 4. Configure the Service

Copy and edit the configuration file:

```bash
# Copy example config
sudo cp examples/child-keyboard-fun.env /etc/child-keyboard-fun.env

# Edit configuration
sudo nano /etc/child-keyboard-fun.env
```

**Minimal configuration:**

```env
KEYBOARD_DEVICE=/dev/input/by-id/usb-Your_Keyboard_Here-event-kbd
SOUND_DIR=/home/childuser/child-keyboard-sounds
```

**With Home Assistant MQTT:**

```env
KEYBOARD_DEVICE=/dev/input/by-id/usb-Your_Keyboard_Here-event-kbd
SOUND_DIR=/home/childuser/child-keyboard-sounds

# MQTT settings
MQTT_HOST=192.168.1.100
MQTT_PORT=1883
MQTT_USER=keyboard
MQTT_PASS=your_password

# Map keys to Home Assistant actions
KEY_F1=mqtt:homeassistant/light/bedroom/set:{"state":"toggle"}
KEY_F2=mqtt:homeassistant/scene/goodnight:ON
```

### 5. Apply Configuration

```bash
# Rebuild NixOS configuration
sudo nixos-rebuild switch

# Check service status
sudo systemctl status child-keyboard-fun

# View logs
sudo journalctl -u child-keyboard-fun -f
```

## Configuration Examples

### Per-Key Sounds

Map specific keys to specific sounds:

```env
# Letters make letter sounds
KEY_A=sound:letter_a.wav
KEY_B=sound:letter_b.wav
KEY_C=sound:letter_c.wav

# Numbers make number sounds
KEY_1=sound:number_1.wav
KEY_2=sound:number_2.wav

# Space always random (default behavior)
KEY_SPACE=random

# Enter has special sound
KEY_ENTER=sound:enter_sound.wav
```

### Smart Home Integration

Control lights, scenes, and switches:

```env
# Toggle bedroom light
KEY_F1=mqtt:homeassistant/light/bedroom/set:{"state":"toggle"}

# Turn on/off specific lights
KEY_F2=mqtt:homeassistant/light/desk/set:{"state":"ON"}
KEY_F3=mqtt:homeassistant/light/desk/set:{"state":"OFF"}

# Activate scenes
KEY_F4=mqtt:homeassistant/scene/playtime:ON
KEY_F5=mqtt:homeassistant/scene/bedtime:ON

# Control switches
KEY_F6=mqtt:homeassistant/switch/fan/set:ON
```

### Combined Actions

A key can trigger both sound and MQTT action:

```env
# Play sound AND toggle light
KEY_F1=random,mqtt:homeassistant/light/bedroom/set:{"state":"toggle"}

# Play specific sound AND trigger scene
KEY_F2=sound:magic.wav,mqtt:homeassistant/scene/fun:ON
```

## Troubleshooting

### Device Not Found

```bash
# Check if device exists
ls -la /dev/input/by-id/

# Test device with evtest
sudo evtest

# Check permissions
sudo ls -la /dev/input/by-id/your-device-here
```

### Permission Denied

Ensure user is in input group:

```bash
# Check groups
groups childuser

# Should include: input audio

# If not, add manually
sudo usermod -aG input,audio childuser

# Then rebuild
sudo nixos-rebuild switch
```

### No Sound Playing

```bash
# Test aplay directly
aplay /home/childuser/child-keyboard-sounds/some_sound.wav

# Check ALSA devices
aplay -L

# Check user's audio access
groups childuser | grep audio

# Test as the user
sudo -u childuser aplay /home/childuser/child-keyboard-sounds/test.wav
```

### MQTT Not Connecting

```bash
# Test MQTT connection
mosquitto_pub -h homeassistant.local -u keyboard -P password \
  -t test/topic -m "test"

# Check Home Assistant MQTT logs
# In Home Assistant: Settings > System > Logs

# View service logs
sudo journalctl -u child-keyboard-fun -n 100
```

### Service Keeps Restarting

```bash
# Check detailed logs
sudo journalctl -u child-keyboard-fun -xe

# Common issues:
# - Wrong device path in config
# - User not in input group
# - Sound directory doesn't exist
# - Config file syntax error
```

## Testing

### Test Device Grabbing

When the service is running, try typing on the child's keyboard:

- Keys should NOT appear in any terminal or application
- You should hear sounds for each keypress

### Test Without Service

Stop the service and test the script directly:

```bash
# Stop service
sudo systemctl stop child-keyboard-fun

# Run script manually (as user)
sudo -u childuser /run/current-system/sw/bin/child-keyboard-fun \
  /etc/child-keyboard-fun.env

# Press keys on the child's keyboard
# Ctrl+C to stop
```

### Test MQTT

With service running, press mapped keys and check Home Assistant:

```bash
# Monitor MQTT traffic
mosquitto_sub -h homeassistant.local -u keyboard -P password \
  -t 'homeassistant/#' -v
```

## Maintenance

### Update Sound Files

```bash
# Add new sounds
sudo cp new_sounds/*.wav /home/childuser/child-keyboard-sounds/
sudo chown childuser:users /home/childuser/child-keyboard-sounds/*.wav

# No service restart needed - sounds are loaded on each keypress
```

### Update Configuration

```bash
# Edit config
sudo nano /etc/child-keyboard-fun.env

# Restart service to apply changes
sudo systemctl restart child-keyboard-fun
```

### Disable Temporarily

```bash
# Stop service
sudo systemctl stop child-keyboard-fun

# Keyboard will work normally again

# Re-enable
sudo systemctl start child-keyboard-fun
```

## Advanced Usage

### Multiple Keyboards

To support multiple child keyboards, create separate service instances:

```nix
services.child-keyboard-fun-kid1 = {
  enable = true;
  user = "kid1";
  configFile = "/etc/child-keyboard-fun-kid1.env";
};

services.child-keyboard-fun-kid2 = {
  enable = true;
  user = "kid2";
  configFile = "/etc/child-keyboard-fun-kid2.env";
};
```

### Custom Sound Selection Logic

Edit the Python script in `modules/child-keyboard-fun.nix` to implement custom sound selection, like:

- Sequential playback instead of random
- Time-based sounds (different sounds morning vs evening)
- Achievement sounds (after N keypresses)
- Educational features (spell words, count numbers)

## Resources

- evdev documentation: https://python-evdev.readthedocs.io/
- Home Assistant MQTT: https://www.home-assistant.io/integrations/mqtt/
- Free sound effects: https://freesound.org/
- ALSA utilities: https://alsa-project.org/

## Credits

Built with:

- Python evdev library
- ALSA utilities (aplay)
- Paho MQTT client
- NixOS declarative configuration
