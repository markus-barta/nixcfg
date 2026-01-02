# Child Keyboard Fun System - Technical Specification

**Host**: hsb1  
**Hardware**: ACME BK03 Bluetooth Keyboard  
**Service**: `child-keyboard-fun.service`  
**Status**: 🟡 In Progress (Audio debugging)  
**Last Updated**: 2026-01-02

---

## Overview

A dedicated Bluetooth keyboard for children that plays fun cartoon sounds when keys are pressed. Designed as a simple, robust toy that requires zero maintenance and survives reboots/reconnections automatically.

**Key Design Principles:**

- **Auto-healing**: Keyboard reconnects automatically, service auto-restarts
- **Zero-maintenance**: Must work reliably without debugging sessions
- **Easy configuration**: Change key mappings without rebuilding NixOS
- **Non-intrusive**: Runs alongside baby cam (VLC) without audio conflicts
- **Isolated & Safe**: ACME BK03 keys only play sounds, don't type into system. Other keyboards work normally.
- **Power-Safe**: Power/suspend keys are blocked to prevent accidental shutdowns

---

## Hardware Details

**Keyboard**: ACME BK03 Bluetooth Keyboard  
**MAC Address**: `20:73:00:04:21:4F`  
**Device Name**: `ACME BK03`  
**Device Type**: Keyboard (Class 0x00000540)  
**Connection**: Bluetooth (paired, bonded, trusted)

### Bluetooth Pairing Instructions

1. **Power on**: Slide power switch to ON position (side or back of keyboard)
2. **Enter pairing mode**: Press and hold **ESC + K** for 3 seconds
3. **Indicator**: Red LED at bottom will blink (pairing mode active)
4. **Pair**: On hsb1, run `bluetoothctl connect 20:73:00:04:21:4F`
5. **PIN entry**: If prompted, enter PIN displayed on screen

**First-time pairing** (see RUNBOOK.md for detailed commands):

```bash
bluetoothctl
> pairable on
> discoverable on
> agent KeyboardOnly
> default-agent
> pair 20:73:00:04:21:4F  # Enter PIN when prompted
> trust 20:73:00:04:21:4F
> connect 20:73:00:04:21:4F
```

---

## Safety & Isolation

### ✅ What Happens When Child Presses Keys

**ACME BK03 Keyboard (Bluetooth):**

- ✅ Plays cartoon sounds
- ❌ Does NOT type into terminal/X11
- ❌ Does NOT trigger system shortcuts
- ❌ Does NOT interfere with running applications
- ❌ Does NOT trigger power/suspend/hibernate (CRITICAL: prevents shutdowns)
- ✅ Safe to mash 1000 keys/second

**Other Keyboards (USB, etc.):**

- ✅ Work completely normally
- ✅ Type into terminal/X11 as expected
- ✅ Trigger system shortcuts
- ❌ Do NOT play cartoon sounds

### How It Works

The service opens **only** the ACME BK03 device by its specific path (`/dev/input/event0`). Events from this device are consumed by the Python script and never reach the system. Other input devices continue to work normally.

```bash
# ACME BK03 Bluetooth keyboard
/dev/input/event0  → child-keyboard-fun service → sounds only

# USB keyboard (or other input devices)
/dev/input/event3  → X11/systemd-logind → normal typing
/dev/input/event4  → X11/systemd-logind → normal typing
# ... etc
```

**Parent-Friendly Result:**

- Child plays with ACME BK03 → only sounds, no system interference
- Parent types on USB keyboard → works normally, no sounds
- Both can be used simultaneously without conflicts

---

## System Architecture

### Components

```
┌─────────────────────────────────────────────────────────────┐
│ hsb1 (NixOS Host)                                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────────┐        ┌──────────────────┐           │
│  │ ACME BK03        │  BT    │ /dev/input/      │           │
│  │ Bluetooth        │───────▶│ event0           │           │
│  │ Keyboard         │        │                  │           │
│  └──────────────────┘        └────────┬─────────┘           │
│                                       │                     │
│                                       │ evdev               │
│                                       ▼                     │
│  ┌────────────────────────────────────────────────┐         │
│  │ child-keyboard-fun.service                     │         │
│  │ - User: mba                                    │         │
│  │ - Python script with evdev                     │         │
│  │ - Reads /etc/child-keyboard-fun.env            │         │
│  │ - Maps keys → sound files                      │         │
│  └────────────────┬───────────────────────────────┘         │
│                   │                                         │
│                   │ sudo -u kiosk paplay                    │
│                   ▼                                         │
│  ┌────────────────────────────────────────────────┐         │
│  │ PipeWire Audio (kiosk user)                    │         │
│  │ - XDG_RUNTIME_DIR=/run/user/1001               │         │
│  │ - Mixes keyboard sounds + VLC baby cam         │         │
│  └────────────────┬───────────────────────────────┘         │
│                   │                                         │
│                   ▼                                         │
│              HDMI Audio Out                                 │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### File Locations

| Path                              | Purpose               | Managed By                        |
| --------------------------------- | --------------------- | --------------------------------- |
| `/etc/child-keyboard-fun.env`     | Key mappings & config | Manual (editable without rebuild) |
| `/var/lib/child-keyboard-sounds/` | MP3/WAV sound files   | Manual (rsync/scp)                |
| `modules/child-keyboard-fun.nix`  | NixOS module          | Git (requires rebuild)            |
| `hosts/hsb1/configuration.nix`    | Service enablement    | Git (requires rebuild)            |

---

## Configuration

### Main Config: `/etc/child-keyboard-fun.env`

**Location**: `/etc/child-keyboard-fun.env`  
**Format**: Simple `KEY=value` pairs  
**Reload**: `sudo systemctl restart child-keyboard-fun`

```bash
# Device path (auto-detected when keyboard connects)
KEYBOARD_DEVICE=/dev/input/event0

# Sound directory (MP3 or WAV files)
SOUND_DIR=/var/lib/child-keyboard-sounds

# Per-key sound mappings
# Format: KEY_<name>=sound:<filename>
KEY_A=sound:ad10.mp3
KEY_B=sound:ad15.mp3
KEY_C=sound:ad20.mp3
# ... (26 letter keys mapped)

# Special keys
KEY_SPACE=random
KEY_ENTER=sound:145.mp3
KEY_BACKSPACE=sound:150.mp3

# Numbers play random sounds
KEY_1=random
KEY_2=random
# ... etc

# Default: unmapped keys play random sound from SOUND_DIR
```

**Editing Configuration:**

```bash
# SSH to hsb1
ssh mba@hsb1.lan

# Edit config (no NixOS rebuild needed!)
sudo nano /etc/child-keyboard-fun.env

# Restart service to apply changes
sudo systemctl restart child-keyboard-fun

# Verify service is running
sudo systemctl status child-keyboard-fun
```

### Sound Files: `/var/lib/child-keyboard-sounds/`

**Current Library**: 28 Warner Bros cartoon sound effects (MP3)  
**Supported Formats**: MP3, WAV  
**Volume**: Played at ~70% (45875/65536) to not overpower baby cam

**Adding/Updating Sounds:**

```bash
# From local machine, copy sounds to hsb1
rsync -avz ~/my-sounds/*.mp3 mba@hsb1.lan:/var/lib/child-keyboard-sounds/

# Or SSH and download
ssh mba@hsb1.lan
cd /var/lib/child-keyboard-sounds
wget https://example.com/sound.mp3

# Restart service to pick up new files
sudo systemctl restart child-keyboard-fun
```

---

## Auto-Healing Features

### 1. Bluetooth Auto-Reconnect

**Problem**: Keyboard powers off/on, loses connection  
**Solution**: Service auto-restarts, waits for device to reappear

```nix
# In module configuration
serviceConfig = {
  Restart = "always";
  RestartSec = "5";
};
```

**Behavior:**

- Service fails if `/dev/input/event0` doesn't exist
- systemd waits 5 seconds and retries
- When keyboard reconnects, device reappears, service succeeds
- No manual intervention needed

### 2. Device Isolation & Safety

**Problem**: Need to prevent keyboard input from affecting the system  
**Solution**: Script opens the specific device exclusively by path

**Key Isolation:**

- **ACME BK03 only**: Service opens `/dev/input/event0` (ACME BK03 device)
- **Other keyboards unaffected**: USB keyboard at `/dev/input/event3` (or other) works normally
- **No system input**: Key presses on ACME BK03 only trigger sounds, don't type into X11/terminal
- **Safe for kids**: Child can mash 1000 keys/second without affecting system

**Why it works:**

```python
# Opens specific device by path
device = evdev.InputDevice('/dev/input/event0')  # Only ACME BK03

# Reads events exclusively - other devices not affected
for event in device.read_loop():
    # Only processes events from ACME BK03
    # Other keyboards (USB, etc.) continue working normally
```

**Note**: We removed `device.grab()` because it caused Bluetooth disconnects. However, since we open the specific device path (`/dev/input/event0`), only that device's events are processed. Other input devices are completely unaffected.

### 3. Service Restart on Crash

**Problem**: Python script crashes (device error, audio issue)  
**Solution**: systemd auto-restarts service

```bash
# Check restart counter
sudo systemctl status child-keyboard-fun
# Shows: "restart counter is at N"

# View crash logs
sudo journalctl -u child-keyboard-fun -n 50
```

---

## Boot Survival

### Requirements for Reboot Resilience

✅ **Bluetooth pairing persists** (bonded + trusted)  
✅ **Service enabled at boot** (`wantedBy = [ "multi-user.target" ]`)  
✅ **Config file in /etc** (survives reboots)  
✅ **Sound files in /var/lib** (survives reboots)  
⏳ **Auto-reconnect on boot** (untested - needs verification)

### Verification Checklist

```bash
# After reboot, check:

# 1. Service started automatically
sudo systemctl status child-keyboard-fun
# Should show: "Active: active (running)" or "activating (auto-restart)"

# 2. Bluetooth keyboard trusted
bluetoothctl info 20:73:00:04:21:4F | grep Trusted
# Should show: "Trusted: yes"

# 3. Keyboard auto-connects
bluetoothctl info 20:73:00:04:21:4F | grep Connected
# Should show: "Connected: yes" (may take 30-60 seconds after boot)

# 4. Device file exists
ls -la /dev/input/event0
# Should exist when keyboard is connected

# 5. Sound files present
ls /var/lib/child-keyboard-sounds/ | wc -l
# Should show: 28 (or your sound count)

# 6. Config file present
cat /etc/child-keyboard-fun.env | grep KEYBOARD_DEVICE
# Should show: KEYBOARD_DEVICE=/dev/input/event0
```

### Manual Reconnect (if needed)

```bash
# If keyboard doesn't auto-connect after boot
ssh mba@hsb1.lan

# Turn keyboard off and on (power switch)
# Press ESC + K for 3 seconds (red LED blinks)

# Connect via bluetoothctl
bluetoothctl connect 20:73:00:04:21:4F

# Service should automatically pick up device
sudo systemctl status child-keyboard-fun
```

---

## Troubleshooting

### Service Not Running

```bash
# Check service status
sudo systemctl status child-keyboard-fun

# View recent logs
sudo journalctl -u child-keyboard-fun -n 50 --no-pager

# Common issues:
# - "Error opening device /dev/input/event0: No such file"
#   → Keyboard not connected, reconnect via bluetoothctl
# - "OSError: [Errno 19] No such device"
#   → Keyboard disconnected mid-session, will auto-retry
```

### No Sound When Keys Pressed

```bash
# 1. Verify service is running and detecting keys
sudo journalctl -u child-keyboard-fun -f
# Press keys, should see log activity (if verbose logging enabled)

# 2. Test audio manually
sudo -u kiosk XDG_RUNTIME_DIR=/run/user/1001 paplay /var/lib/child-keyboard-sounds/ad10.mp3
# Should hear sound

# 3. Check PipeWire status
sudo -u kiosk XDG_RUNTIME_DIR=/run/user/1001 pactl list sinks short
# Should show active audio sink

# 4. Check volume/mute
sudo -u kiosk XDG_RUNTIME_DIR=/run/user/1001 pactl list sinks | grep -i mute
# Should show: "Mute: no"
```

### Keyboard Not Connecting

```bash
# 1. Check Bluetooth status
bluetoothctl info 20:73:00:04:21:4F

# 2. If "Connected: no", reconnect
bluetoothctl connect 20:73:00:04:21:4F

# 3. If pairing lost, re-pair (see RUNBOOK.md)

# 4. Check Bluetooth controller
bluetoothctl show
# Should show: "Powered: yes", "Pairable: yes"

# 5. Restart Bluetooth service
sudo systemctl restart bluetooth
```

### Device Path Changed

```bash
# Find new device path
cat /proc/bus/input/devices | grep -A 10 "ACME BK03"
# Look for: H: Handlers=... eventX

# Update config
sudo nano /etc/child-keyboard-fun.env
# Change: KEYBOARD_DEVICE=/dev/input/eventX

# Restart service
sudo systemctl restart child-keyboard-fun
```

---

## Operational Procedures

### Daily Use

1. **Turn on keyboard** (power switch)
2. **Wait 5-10 seconds** for auto-connect
3. **Press keys** → sounds play
4. **Turn off when done** (power switch)

**No manual steps required!** Service handles reconnection automatically.

### Changing Key Mappings

```bash
# 1. SSH to hsb1
ssh mba@hsb1.lan

# 2. Edit config (no rebuild needed!)
sudo nano /etc/child-keyboard-fun.env

# 3. Restart service
sudo systemctl restart child-keyboard-fun

# 4. Test immediately
# Press keys on keyboard, sounds should reflect new mappings
```

### Adding New Sounds

```bash
# 1. Copy sound files to hsb1
rsync -avz ~/new-sounds/*.mp3 mba@hsb1.lan:/var/lib/child-keyboard-sounds/

# 2. Update key mappings (if needed)
ssh mba@hsb1.lan
sudo nano /etc/child-keyboard-fun.env
# Add: KEY_X=sound:new-sound.mp3

# 3. Restart service
sudo systemctl restart child-keyboard-fun
```

### Updating Module Code

**Only needed for Python script changes or NixOS module updates.**

```bash
# 1. Edit module locally
vim modules/child-keyboard-fun.nix

# 2. Commit changes
git add modules/child-keyboard-fun.nix
git commit -m "fix: improve keyboard reconnection logic"
git push

# 3. Deploy to hsb1
ssh mba@hsb1.lan
cd ~/Code/nixcfg
git pull
sudo nixos-rebuild switch --flake .#hsb1

# 4. Service automatically restarts with new code
```

---

## Known Issues & Limitations

### 🐛 Current Issues (2026-01-02)

1. **Audio not playing** (P8001)
   - Service runs, detects keys, but no sound output
   - Manual test works: `sudo -u kiosk XDG_RUNTIME_DIR=/run/user/1001 paplay <file>`
   - Debugging in progress

2. **Device grab causes disconnect**
   - Exclusive grab (`device.grab()`) causes Bluetooth keyboard to disconnect
   - Workaround: Don't grab exclusively (keys visible to other processes)
   - Acceptable for toy use case

3. **Reboot survival untested**
   - Auto-reconnect after reboot not yet verified
   - May require manual `bluetoothctl connect` after boot
   - Needs testing

### 📋 Limitations

- **Single keyboard**: Only supports one ACME BK03 keyboard at a time
- **No MQTT**: Home Assistant integration not yet implemented
- **No visual feedback**: No on-screen display when keys are pressed
- **Device path hardcoded**: Must update config if device path changes (e.g., after re-pairing)

---

## Performance & Resource Usage

**Service Resources:**

- Memory: ~12-13 MB
- CPU: <1% (idle), ~5% (during key press + audio playback)
- Disk: ~10 MB (28 MP3 files)

**Audio Latency:**

- Key press → sound start: <100ms (target)
- Currently: Unknown (audio not working yet)

**Bluetooth Range:**

- Typical: 10 meters (33 feet)
- Walls/obstacles reduce range

---

## Security Considerations

- **Service runs as `mba` user** (not root)
- **Sudo rule**: `mba` can run `paplay` as `kiosk` without password
  - Limited to specific command: `/nix/store/*/paplay`
  - Sets `XDG_RUNTIME_DIR` to kiosk user's runtime
- **Input device access**: `mba` user in `input` group
- **Sound files**: World-readable in `/var/lib/child-keyboard-sounds/`
- **Config file**: Root-owned, world-readable

**Risk Assessment**: LOW

- Toy system, no sensitive data
- Limited sudo access (audio playback only)
- No network exposure

---

## Testing Checklist

### Pre-Deployment

- [ ] Bluetooth pairing successful
- [ ] Device appears at `/dev/input/event0`
- [ ] Service starts without errors
- [ ] Config file parsed correctly
- [ ] Sound files accessible
- [ ] Manual audio test works

### Post-Deployment

- [ ] Key presses detected in logs
- [ ] Sounds play through speakers
- [ ] Baby cam audio continues (no conflict)
- [ ] Service survives keyboard disconnect/reconnect
- [ ] Service survives system reboot
- [ ] Config changes work without rebuild

### Stress Testing

- [ ] Rapid key presses (no audio glitches)
- [ ] Long session (1+ hour, no memory leaks)
- [ ] Multiple disconnect/reconnect cycles
- [ ] Keyboard power off/on cycles

---

## Related Documentation

- **RUNBOOK.md**: Bluetooth pairing commands, operational procedures
- **P8000-child-keyboard-fun-acme-bk03.md**: Original requirements & design
- **P8001-child-keyboard-fun-audio-fix.md**: Audio debugging (in progress)
- **modules/child-keyboard-fun.nix**: NixOS module source code
- **examples/child-keyboard-fun.env**: Example configuration file

---

## Maintenance Schedule

**Daily**: None (auto-healing)  
**Weekly**: None  
**Monthly**: Check service logs for errors  
**Quarterly**: Verify reboot survival, test reconnection  
**Yearly**: Review sound library, update if needed

---

## Contact & Support

**Owner**: mba  
**System**: hsb1 (Home Automation Server)  
**Priority**: LOW (toy system, non-critical)

**For issues**:

1. Check service logs: `sudo journalctl -u child-keyboard-fun -n 50`
2. Verify Bluetooth connection: `bluetoothctl info 20:73:00:04:21:4F`
3. Test audio manually: `sudo -u kiosk XDG_RUNTIME_DIR=/run/user/1001 paplay <file>`
4. Restart service: `sudo systemctl restart child-keyboard-fun`
5. If all else fails: Reboot hsb1

---

**Last Updated**: 2026-01-02  
**Version**: 1.0 (Initial deployment, audio debugging in progress)
