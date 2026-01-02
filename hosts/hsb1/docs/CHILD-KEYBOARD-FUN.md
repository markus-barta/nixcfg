# Child Keyboard Fun System - Technical Specification

**Host**: hsb1  
**Hardware**: ACME BK03 Bluetooth Keyboard  
**Service**: `child-keyboard-fun.service`  
**Status**: 🟢 Ready (All features implemented, needs audio verification)  
**Last Updated**: 2026-01-02

---

## Overview

A dedicated Bluetooth keyboard for children that plays fun cartoon sounds when keys are pressed. Designed as a simple, robust toy that requires zero maintenance and survives reboots/reconnections automatically.

**Key Design Principles:**

- **Auto-healing**: Keyboard reconnects automatically via `acme-bk03-reconnect.service`, service auto-restarts
- **Zero-maintenance**: Works reliably without debugging, survives reboots automatically
- **Easy configuration**: Change key mappings in `/etc/child-keyboard-fun.env` without rebuilding
- **Non-intrusive**: Runs alongside baby cam (VLC) without audio conflicts
- **Isolated & Safe**: ACME BK03 keys only play sounds, don't type into system. Other keyboards work normally.
- **Power-Safe**: Power/suspend/hibernate keys blocked via `services.logind.settings.Login`
- **Reboot-Proof**: Device found by name (not hardcoded path), auto-reconnects on boot

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

The service finds the ACME BK03 by its device name and opens it exclusively. Events from this device are consumed by the Python script and never reach the system. Other input devices continue to work normally.

```bash
# ACME BK03 Bluetooth keyboard (found by name "ACME BK03")
/dev/input/event10 (or event17, etc.) → child-keyboard-fun service → sounds only
# Path is auto-detected - no hardcoded paths!

# USB keyboard (or other input devices)
/dev/input/event3  → X11/systemd-logind → normal typing
/dev/input/event4  → X11/systemd-logind → normal typing
# ... etc
```

**udev rules** prevent the system from processing ACME BK03 events:

- Removes `ID_INPUT` and `ID_INPUT_KEYBOARD` tags
- Removes `seat` and `uaccess` tags
- Blocks `power-switch` tag (prevents shutdowns)

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
│  │ - User: kiosk (direct PipeWire access)         │         │
│  │ - Python script with evdev                     │         │
│  │ - Reads /etc/child-keyboard-fun.env            │         │
│  │ - Maps keys → sound files                      │         │
│  │ - MQTT debug/status topics                     │         │
│  └────────────────┬───────────────────────────────┘         │
│                   │                                         │
│                   │ paplay (direct, no sudo needed)         │
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

| Path                                     | Purpose                    | Managed By                        |
| ---------------------------------------- | -------------------------- | --------------------------------- |
| `/etc/child-keyboard-fun.env`            | Key mappings & config      | Manual (editable without rebuild) |
| `/var/lib/child-keyboard-sounds/`        | MP3/WAV sound files        | Manual (rsync/scp)                |
| `modules/child-keyboard-fun.nix`         | NixOS module               | Git (requires rebuild)            |
| `hosts/hsb1/configuration.nix`           | Service enablement         | Git (requires rebuild)            |
| `hosts/hsb1/files/child-keyboard-fun.py` | Python script (standalone) | Git (requires rebuild)            |

---

## Configuration

### Main Config: `/etc/child-keyboard-fun.env`

**Location**: `/etc/child-keyboard-fun.env`  
**Format**: Simple `KEY=value` pairs  
**Reload**: `sudo systemctl restart child-keyboard-fun`

```bash
# Device name (found automatically by name)
KEYBOARD_DEVICE=ACME BK03

# Sound directory (MP3 or WAV files)
SOUND_DIR=/var/lib/child-keyboard-sounds

# Per-key sound mappings
# Format: KEY_<name>=sound:<filename>
KEY_A=sound:ad10.mp3
KEY_B=sound:ad15.mp3
KEY_C=sound:ad20.mp3
# ... (26 letter keys mapped)

# Special keys
# KEY_SPACE is reserved for "stop all sounds" function
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
**Solution**: Dedicated reconnect service + service restart

```nix
# acme-bk03-reconnect.service (runs before main service)
script = ''
  sleep 3
  for i in {1..5}; do
    bluetoothctl connect 20:73:00:04:21:4F && exit 0
    sleep 2
  done
'';
```

**Behavior:**

- On boot: `acme-bk03-reconnect.service` tries to connect 5 times
- If keyboard is off: Service exits gracefully (no failure)
- If keyboard comes on later: Main service auto-restarts
- Device path changes handled automatically by name search

### 2. Device Isolation & Safety

**Problem**: Need to prevent keyboard input from affecting the system  
**Solution**: udev rules + device name search (no device.grab() needed)

**Key Isolation:**

- **ACME BK03 only**: Service finds device by name "ACME BK03"
- **Other keyboards unaffected**: USB keyboard works normally
- **No system input**: Key presses on ACME BK03 only trigger sounds
- **Safe for kids**: Child can mash 1000 keys/second without affecting system
- **Power-safe**: Power/suspend keys blocked via logind settings

**Why it works:**

```python
# Find device by name (handles dynamic event numbers)
def find_device_by_name(device_name):
    devices = [evdev.InputDevice(path) for path in evdev.list_devices()]
    for device in devices:
        if device.name == device_name:
            return device.path
    return None

# Opens found device
device = evdev.InputDevice(found_path)
```

**udev rules** (no device.grab() needed):

```
SUBSYSTEM=="input", ATTRS{name}=="ACME BK03",
  ENV{ID_INPUT}="0", ENV{ID_INPUT_KEYBOARD}="0",
  TAG-="seat", TAG-="uaccess", TAG-="power-switch"
```

**logind settings** (blocks power keys):

```
services.logind.settings.Login = {
  HandlePowerKey = "ignore";
  HandleSuspendKey = "ignore";
  HandleHibernateKey = "ignore";
  HandleLidSwitch = "ignore";
};
```

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
✅ **Auto-reconnect service** (`acme-bk03-reconnect.service`)  
✅ **Dynamic device finding** (handles event number changes)

### Verification Checklist

```bash
# After reboot, check:

# 1. Service started automatically
sudo systemctl status child-keyboard-fun
# Should show: "Active: active (running)"

# 2. Reconnect service ran
sudo journalctl -u acme-bk03-reconnect.service -n 5
# Should show: "ACME BK03 connected successfully!" or "Warning: Could not connect"

# 3. Bluetooth keyboard trusted
bluetoothctl info 20:73:00:04:21:4F | grep Trusted
# Should show: "Trusted: yes"

# 4. Keyboard connected
bluetoothctl info 20:73:00:04:21:4F | grep Connected
# Should show: "Connected: yes" (may take 10-15 seconds after boot)

# 5. Device exists (check by name)
cat /proc/bus/input/devices | grep -A 5 "ACME BK03"
# Should show device with Handlers including eventX

# 6. Sound files present
ls /var/lib/child-keyboard-sounds/ | wc -l
# Should show: 28 (or your sound count)

# 7. Config uses device name
cat /etc/child-keyboard-fun.env | grep KEYBOARD_DEVICE
# Should show: KEYBOARD_DEVICE=ACME BK03
```

### Manual Reconnect (if needed)

```bash
# If keyboard doesn't auto-connect (keyboard was off during boot)
ssh mba@hsb1.lan

# Turn keyboard on (power switch)
# Wait 10-15 seconds for auto-reconnect

# Or manually trigger reconnect:
sudo systemctl start acme-bk03-reconnect

# Check connection
bluetoothctl info 20:73:00:04:21:4F | grep Connected
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
# - "Device 'ACME BK03' not found"
#   → Keyboard not connected, check bluetoothctl
# - "OSError: [Errno 19] No such device"
#   → Keyboard disconnected mid-session, will auto-retry
# - "MQTT connection failed"
#   → Credentials missing or mosquitto not running
```

### No Sound When Keys Pressed

```bash
# 1. Verify service is running and detecting keys
sudo journalctl -u child-keyboard-fun -f
# Press keys, should see: "DEBUG: Key name = X" and "DEBUG: Playing specific sound"

# 2. Check if paplay subprocess starts
sudo journalctl -u child-keyboard-fun -n 20 | grep paplay
# Should show: "DEBUG: Subprocess started, PID=..."

# 3. Test audio manually (as kiosk user)
sudo -u kiosk paplay /var/lib/child-keyboard-sounds/ad10.mp3
# Should hear sound

# 4. Check PipeWire status
sudo -u kiosk pactl list sinks short
# Should show active audio sink

# 5. Check volume/mute
sudo -u kiosk pactl list sinks | grep -i mute
# Should show: "Mute: no"

# 6. Check service user
sudo systemctl show child-keyboard-fun --property=User
# Should show: User=kiosk
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
# NO ACTION NEEDED - Device is found by name automatically!

# The config uses KEYBOARD_DEVICE=ACME BK03
# The script searches for the device by name
# Event numbers change after reboot - this is handled automatically

# If keyboard won't connect:
# 1. Check Bluetooth connection
bluetoothctl info 20:73:00:04:21:4F

# 2. If disconnected, reconnect
bluetoothctl connect 20:73:00:04:21:4F

# 3. If pairing lost, re-pair (see RUNBOOK.md)
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

### 🐛 Known Issues (2026-01-02)

1. **Audio playback untested**
   - All infrastructure is in place
   - Need user verification that sounds actually play
   - Service runs as kiosk, paplay should work directly

### ✅ Fixed/Implemented

1. **Device isolation** - udev rules prevent system access, no device.grab() needed
2. **Reboot survival** - acme-bk03-reconnect.service handles auto-reconnect
3. **Dynamic device paths** - Device found by name, handles event number changes
4. **Power key blocking** - logind.settings prevents accidental shutdowns
5. **MQTT integration** - 3 topics: debug, status, keyboard-info
6. **Battery tracking** - Reads from sysfs when available
7. **Last key tracking** - Published to status topic
8. **Auto-reconnect** - 5 retry attempts on boot with 2s delays

### 📋 Limitations

- **Single keyboard**: Only supports one ACME BK03 keyboard at a time
- **Audio verification needed**: System is ready but sounds need testing
- **No visual feedback**: No on-screen display when keys are pressed
- **Battery may not work**: Some Bluetooth keyboards don't expose battery in sysfs

---

## Performance & Resource Usage

**Service Resources:**

- Memory: ~23 MB (peak)
- CPU: <1% (idle), ~5% (during key press + audio playback)
- Disk: ~10 MB (28 MP3 files)

**Audio Latency:**

- Key press → sound start: <100ms (target)
- Currently: Unknown (needs verification)

**Bluetooth Range:**

- Typical: 10 meters (33 feet)
- Walls/obstacles reduce range

**MQTT Topics:**

- `home/hsb1/keyboard-fun/debug` - Debug logs (non-retained)
- `home/hsb1/keyboard-fun/status` - Last key, battery, sound (retained)
- `home/hsb1/keyboard-fun/keyboard-info` - Device info, battery (retained, 60s updates)

---

## Security Considerations

- **Service runs as `kiosk` user** (direct PipeWire access, no sudo needed)
- **Supplementary groups**: `input` (for keyboard), `audio` (for sound)
- **EnvironmentFile**: `/home/mba/secrets/smarthome.env` for MQTT credentials
- **Sound files**: World-readable in `/var/lib/child-keyboard-sounds/`
- **Config file**: Root-owned, world-readable
- **udev rules**: Block system access to ACME BK03
- **logind settings**: Block power/suspend/hibernate keys

**Risk Assessment**: LOW

- Toy system, no sensitive data
- No sudo escalation needed
- Device isolation prevents system interference
- Power keys blocked to prevent shutdowns

---

## Testing Checklist

### Pre-Deployment

- [x] Bluetooth pairing successful
- [x] Service starts without errors
- [x] Config file parsed correctly
- [x] Sound files accessible
- [x] Device name search working
- [x] MQTT connection established
- [x] Power key blocking active
- [x] Auto-reconnect service configured
- [ ] Manual audio test works (needs verification)

### Post-Deployment

- [x] Key presses detected in logs
- [ ] Sounds play through speakers (needs verification)
- [ ] Baby cam audio continues (needs verification)
- [x] Service survives keyboard disconnect/reconnect
- [x] Service survives system reboot
- [x] Config changes work without rebuild
- [x] MQTT topics publishing correctly
- [x] Battery level tracking implemented
- [x] Last key tracking implemented

### Stress Testing

- [ ] Rapid key presses (no audio glitches)
- [ ] Long session (1+ hour, no memory leaks)
- [ ] Multiple disconnect/reconnect cycles
- [ ] Keyboard power off/on cycles
- [ ] Full reboot cycle (power off/on hsb1)

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
3. Test audio manually: `sudo -u kiosk paplay /var/lib/child-keyboard-sounds/ad10.mp3`
4. Restart service: `sudo systemctl restart child-keyboard-fun`
5. Check MQTT: `docker exec mosquitto mosquitto_sub -v -t 'home/hsb1/keyboard-fun/#' -u smarthome -P <password>`
6. If all else fails: Reboot hsb1

---

**Last Updated**: 2026-01-02  
**Version**: 1.0 (Initial deployment, audio debugging in progress)
