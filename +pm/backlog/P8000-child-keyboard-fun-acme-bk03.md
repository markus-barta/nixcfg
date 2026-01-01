# Child's Bluetooth Keyboard Fun System (ACME BK03)

**Created**: 2026-01-01  
**Priority**: P8000 (⚪ Backlog)  
**Status**: Backlog  
**Target Host**: hsb1

---

## Epic: Home Automation & Family UX

## Story

As a parent, I want my child's dedicated Bluetooth keyboard (ACME BK03) to trigger fun sounds and optional smart home actions, so that they can have an engaging, interactive experience without interfering with the main system input.

---

## Hardware Details

**Keyboard**: ACME BK03 Bluetooth Keyboard

### Bluetooth Pairing Instructions

1. Turn on the keyboard (slide the power switch to the ON position — it's usually on the side or back)
2. Press and hold **ESC + K** for 3 seconds
3. The red indicator light (at the bottom or on the keyboard) will start blinking, indicating pairing mode
4. On your device, enable Bluetooth, scan for devices, and select "BK03" from the list

---

## Target Host

- **hsb1** (NixOS host)

---

## Requirements

### Core Functionality

1. **Grab the keyboard exclusively** - BK03 key presses don't affect system
2. **Per-key sound mapping** - specific keys play specific sounds
3. **Random fallback** - unmapped keys play random sound from directory
4. **Optional: MQTT actions** - for Home Assistant integration

### Simple Configuration

Single `.env` file:

```env
# Device (find with: ls /dev/input/by-id/*BK03*)
KEYBOARD_DEVICE=/dev/input/by-id/usb-ACME_BK03-event-kbd

# Sounds directory (for random fallback)
SOUND_DIR=/home/mba/child-keyboard-sounds

# Per-key sound mappings
KEY_O=sound:oooooooo.wav
KEY_A=sound:letter_a.wav
KEY_B=sound:letter_b.wav
KEY_SPACE=random    # explicitly random
# ... any key not listed plays random sound

# Optional MQTT (leave empty to skip)
MQTT_HOST=hsb1.lan
MQTT_PORT=1883
MQTT_USER=keyboard
MQTT_PASS_FILE=/run/agenix/mqtt-keyboard

# Optional MQTT actions
KEY_F1=mqtt:homeassistant/light/bedroom/toggle
KEY_F2=mqtt:homeassistant/scene/fun/set:ON
```

### Implementation Approach

- **Simple Python script**: ~150 lines, just evdev + subprocess
- **NixOS module**: enable service, add user to `input` group
- **Dependencies**: `python3Packages.evdev`, `alsa-utils`, optionally `paho-mqtt`
- **No .env parsing library needed**: just read file manually
- **Service runs as normal user** (mba), auto-restart on failure

---

## Technical Design

**Keep it simple - it's a toy.**

### Single Python Script (~150 lines)

```python
# Pseudocode flow:
1. Read .env file (simple line parsing, no library)
   - Build dict: key_mappings = {'KEY_O': 'sound:oooooooo.wav', ...}
2. Open keyboard device with evdev
3. Grab it exclusively (dev.grab())
4. Loop: on any key press
   - Check if key in key_mappings
     - If "sound:filename.wav" → play that specific file
     - If "random" → pick random from SOUND_DIR
     - If "mqtt:..." → publish MQTT message
     - If not mapped → play random from SOUND_DIR (default)
   - subprocess.Popen(['aplay', sound_file])  # non-blocking
```

### NixOS Module

```nix
# In modules/child-keyboard-fun.nix or hosts/hsb1/configuration.nix:
- Create systemd service
- Add user to input group
- Include python3Packages.evdev, alsa-utils
- Point to .env file location
```

### Sound Files

Just a directory with `.wav` files. User downloads/creates them separately.

Example: `/home/mba/child-keyboard-sounds/{oooooooo.wav, letter_a.wav, boop.wav, ...}`

---

## Acceptance Criteria

- [ ] BK03 paired to hsb1 via Bluetooth
- [ ] Service starts on boot
- [ ] BK03 exclusively grabbed (no system input interference)
- [ ] Specific keys play specific sounds (e.g., O key → "oooooooo.wav")
- [ ] Unmapped keys play random sound from directory
- [ ] Optional: specific keys trigger MQTT actions (if configured)
- [ ] Service auto-restarts on failure
- [ ] Runs as normal user (not root)

---

## Implementation Notes

**Keep it simple:**

- Find device path: `ls /dev/input/by-id/*BK03*` after pairing
- Sound files: user provides, not in Nix config
- MQTT: completely optional, skip if not needed
- Config parsing: just split on `=`, no fancy library
- BK03 pairing: ESC + K for 3 seconds (red LED blinks)

**Key mapping logic:**

- `KEY_O=sound:oooooooo.wav` → plays that specific file
- `KEY_SPACE=random` → picks random from sound directory
- No mapping → plays random (default behavior)
- Simple dict lookup, nothing fancy

---

## Estimated Effort

- Bluetooth pairing & device identification: 30 min
- Python script: 2-3 hours (per-key mapping + random fallback)
- NixOS module: 1 hour
- Testing: 1 hour
- Documentation: 30 min

**Total**: ~5 hours

---

## Priority

⚪ P8000 (Backlog) - Fun family project with learning value

---

## Related Items

- Home Assistant MQTT integration setup on hsb1
- Sound library curation for kids
- Future: Support for multiple child keyboards
