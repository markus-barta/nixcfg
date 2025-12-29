# Backlog Item: Child's Bluetooth Keyboard Fun System

## Epic: Home Automation & Family UX

## Story

As a parent, I want my child's dedicated Bluetooth keyboard to trigger fun sounds and optional smart home actions, so that they can have an engaging, interactive experience without interfering with the main system input.

## Target Host

- **hsb1** (NixOS host)

## Requirements

### Functional Requirements

1. **Exclusive Keyboard Handling**
   - Detect and grab a dedicated child's Bluetooth keyboard device
   - Use stable device path (`/dev/input/by-id/...-event-kbd`)
   - Prevent key presses from affecting normal system input (console/X/Wayland)
   - Use `evdev` library with `dev.grab()` for exclusive access

2. **Per-Key Sound Configuration**
   - Each key can have specific sound(s) mapped via `.env` configuration
   - Default: play random sound from generic sound directory
   - Special handling for SPACE key: always play random sound from full collection
   - Sound directory: `/home/<user>/child-keyboard-sounds/` with `.wav` files
   - Use `aplay` (alsa-utils) for non-blocking background playback

3. **Home Assistant Integration**
   - Allow specific keys to trigger Home Assistant functions via MQTT
   - Configurable via `.env` file (e.g., `KEY_F1=mqtt:homeassistant/switch/lights/toggle`)
   - Support both sound + MQTT action on same key
   - MQTT connection details from environment variables

4. **Configuration File Format** (`.env` style)

   ```env
   # Device path
   KEYBOARD_DEVICE=/dev/input/by-id/usb-Bluetooth_Keyboard-event-kbd

   # Sound directory
   SOUND_DIR=/home/childuser/child-keyboard-sounds

   # MQTT settings (optional)
   MQTT_HOST=homeassistant.local
   MQTT_PORT=1883
   MQTT_USER=keyboard
   MQTT_PASS=secret

   # Key mappings (format: KEY_NAME=action)
   # Actions: sound:filename.wav, random, mqtt:topic:payload
   KEY_SPACE=random
   KEY_A=sound:letter_a.wav
   KEY_B=sound:letter_b.wav
   KEY_F1=mqtt:homeassistant/light/bedroom/set:{"state":"toggle"}
   KEY_F2=mqtt:homeassistant/scene/fun:ON
   ```

### Non-Functional Requirements

1. **Security & Permissions**
   - Service runs as dedicated user (not root)
   - User must be in `input` group for device access
   - User must have audio access for `aplay`

2. **Reliability**
   - Automatic service start on boot (after `multi-user.target`)
   - Auto-restart on failure
   - Graceful handling of missing device (retry/wait)
   - Graceful handling of missing sound files (log warning, continue)

3. **Declarative Configuration**
   - Full NixOS configuration in `configuration.nix`
   - Use `pkgs.writers.writePython3` for script generation
   - Include all dependencies: `python3Packages.evdev`, `python3Packages.paho-mqtt`, `alsa-utils`
   - systemd service definition with proper dependencies

## Technical Design

### Components

1. **Python Script** (`child-keyboard-fun.py`)
   - Load configuration from `.env` file
   - Connect to keyboard device via evdev
   - Grab device exclusively
   - Event loop handling key presses
   - Sound playback via subprocess (aplay)
   - MQTT client for Home Assistant integration

2. **NixOS Module**
   - User configuration (add to input group)
   - Script derivation with dependencies
   - systemd service definition
   - Environment file management

3. **Sound Collection**
   - Directory structure: `/home/childuser/child-keyboard-sounds/`
   - Mix of generic fun sounds (boops, clicks, animal sounds)
   - User-provided or downloaded separately

### Dependencies

- Python 3 with packages:
  - `evdev` - keyboard event handling
  - `paho-mqtt` - MQTT client for Home Assistant
  - `python-dotenv` - .env file parsing
- `alsa-utils` (aplay) - audio playback
- User in `input` and `audio` groups

## Acceptance Criteria

- [ ] Service starts automatically on hsb1 boot
- [ ] Child's keyboard is exclusively grabbed (no system input interference)
- [ ] Every key press triggers configured or random sound
- [ ] SPACE key always plays random sound
- [ ] Specific keys can trigger MQTT/Home Assistant actions
- [ ] Configuration changes via .env file work after service restart
- [ ] Service auto-restarts on failure
- [ ] No root privileges required
- [ ] Complete documentation provided

## Implementation Notes

- User will need to identify correct device path via `evtest` or `/proc/bus/input/devices`
- Sound files must be provided separately (not included in Nix config)
- MQTT is optional - service should work without it
- Consider future extensions: visual feedback, keyboard backlighting, more integrations

## Estimated Effort

- Implementation: 4-6 hours
- Testing: 2 hours
- Documentation: 1 hour

## Priority

Medium - fun family project with learning value

## Related Items

- Home Assistant MQTT integration setup
- Sound library curation for kids
- Future: Support for multiple child keyboards
