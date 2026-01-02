# P8001: Child Keyboard Fun - Audio Verification

**Status:** 🟡 Ready for Testing  
**Priority:** Medium  
**Effort:** ~30 minutes  
**Created:** 2026-01-01  
**Updated:** 2026-01-02 07:45  
**Parent:** P8000-child-keyboard-fun-acme-bk03.md

## Problem Statement

The child-keyboard-fun system is fully implemented and ready. All infrastructure is in place - need user verification that audio playback actually works.

## Current Status

### ✅ Fully Implemented

- ACME BK03 keyboard paired, bonded, and trusted to hsb1
- **Auto-reconnect service** (`acme-bk03-reconnect.service`) - tries 5x on boot
- **Device name search** - finds keyboard by name, handles dynamic event paths
- **Python script** - detects keys, maps to sounds, plays via paplay
- **28 sound files** - Warner Bros effects in `/var/lib/child-keyboard-sounds/`
- **Configuration** - 39 key mappings in `/etc/child-keyboard-fun.env`
- **Service runs as kiosk** - direct PipeWire access, no sudo needed
- **Power key blocking** - `services.logind.settings.Login` prevents shutdowns
- **udev isolation** - prevents X/systemd from accessing keyboard
- **MQTT integration** - 3 topics: debug, status, keyboard-info
- **Battery tracking** - reads from sysfs when available
- **Last key tracking** - published to status topic

### ⚠️ Needs Verification

- **Audio playback** - need user to press keys and confirm sounds play
- **Baby cam coexistence** - verify VLC audio continues uninterrupted

## Technical Details

### Audio Architecture on hsb1

- **Baby Cam (VLC):** Runs as `kiosk` user with PipeWire
- **Keyboard Service:** Runs as `kiosk` user (same user!)
- **Audio System:** PipeWire with pipewire-pulse
- **Current Approach:** Direct `paplay` as kiosk user (no sudo needed)

### Implementation Summary

**Before (Broken):**

- Service: `mba` user → sudo → kiosk → paplay
- Issues: sudo restrictions, XDG_RUNTIME_DIR issues

**After (Fixed):**

- Service: `kiosk` user → paplay directly
- Benefits: No sudo, direct PipeWire access, simpler

### Key Changes Made

1. ✅ Changed service user from `mba` to `kiosk`
2. ✅ Removed sudo rules (no longer needed)
3. ✅ Added `EnvironmentFile` for MQTT credentials
4. ✅ Added `acme-bk03-reconnect.service` for auto-reconnect
5. ✅ Added device name search (no hardcoded paths)
6. ✅ Added power key blocking via logind
7. ✅ Added MQTT topics (debug, status, keyboard-info)
8. ✅ Added battery level tracking
9. ✅ Added last key tracking

### Current Implementation

```python
def play_sound(sound_file, device=None):
    """Play sound via kiosk user's PipeWire (same as VLC)"""
    # Stop all currently playing sounds first
    stop_all_sounds()

    # Run paplay directly (service runs as kiosk user)
    proc = subprocess.Popen([
        'paplay',
        '--volume=45875',  # ~70% volume
        str(sound_file)
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    active_processes.append(proc)

    # Check for errors after brief delay
    time.sleep(0.1)
    if proc.poll() is not None:
        stdout, stderr = proc.communicate()
        if stderr:
            mqtt_log(f"paplay error: {stderr.decode()}", "error")

    # Publish status to MQTT
    mqtt_log(f"Playing: {os.path.basename(sound_file)}")
    if device:
        mqtt_publish_status(device, sound_file=sound_file)
```

### Observations

- ✅ No errors in journalctl logs when keys are pressed
- ✅ paplay processes spawn correctly
- ✅ Service runs as kiosk user
- ⚠️ Audio output needs verification
- sudo rule is working (verified with `sudo -n -u kiosk paplay --version`)
- VLC continues to play baby cam audio without issues

## Possible Root Causes

1. **PipeWire Sink/Device Selection**
   - paplay might be outputting to wrong sink
   - Need to check available sinks: `pactl list sinks`
   - May need to specify sink explicitly

2. **Audio Mixing Issue**
   - PipeWire might not be configured for mixing
   - VLC might have exclusive access to audio device

3. **MP3 Codec Support**
   - paplay might not support MP3 files directly
   - May need to convert to WAV or use different player

4. **Volume/Mute State**
   - kiosk user's audio might be muted
   - Volume settings might be at 0

5. **Permissions/Groups**
   - Despite sudo, there might be additional permission issues
   - kiosk user might need specific group memberships

## Next Steps to Debug

### 1. Test Manual Playback (as kiosk user)

```bash
# SSH to hsb1
ssh mba@hsb1.lan

# Test as kiosk user
sudo -u kiosk paplay /home/mba/child-keyboard-sounds/ad10.mp3

# Check if sound plays
```

### 2. Check PipeWire Configuration

```bash
# As kiosk user, list sinks
sudo -u kiosk XDG_RUNTIME_DIR=/run/user/1001 pactl list sinks short

# Check if audio is muted
sudo -u kiosk XDG_RUNTIME_DIR=/run/user/1001 pactl list sinks | grep -i mute

# Check volume levels
sudo -u kiosk XDG_RUNTIME_DIR=/run/user/1001 pactl list sinks | grep -i volume
```

### 3. Try Alternative Players

```bash
# Test with ffmpeg (full version, not headless)
sudo -u kiosk ffmpeg -i /home/mba/child-keyboard-sounds/ad10.mp3 -f alsa default

# Test with mpv
sudo -u kiosk mpv --no-video /home/mba/child-keyboard-sounds/ad10.mp3
```

### 4. Convert MP3 to WAV

```bash
# Convert all MP3s to WAV for better compatibility
cd /home/mba/child-keyboard-sounds
for f in *.mp3; do ffmpeg -i "$f" "${f%.mp3}.wav"; done
```

### 5. Check systemd Service Environment

```bash
# Add debug logging to see what's happening
sudo journalctl -u child-keyboard-fun -f

# Check if paplay is actually running
ps aux | grep paplay
```

## ✅ All Solutions Implemented

### Solution 1: Run as kiosk User ✅

- Service now runs as `kiosk` user
- Direct PipeWire access, no sudo needed

### Solution 2: Remove device.grab() ✅

- Uses udev rules for isolation
- No Bluetooth disconnects

### Solution 3: Auto-Reconnect Service ✅

- `acme-bk03-reconnect.service` handles boot reconnection
- 5 retry attempts with 2s delays

### Solution 4: Dynamic Device Finding ✅

- Device found by name "ACME BK03"
- Handles event number changes automatically

### Solution 5: Power Key Blocking ✅

- `services.logind.settings.Login` prevents shutdowns
- Child-safe

### Solution 6: MQTT Integration ✅

- 3 topics: debug, status, keyboard-info
- Battery tracking, last key tracking

## Acceptance Criteria

- [x] Service starts automatically on boot
- [x] Works reliably after system reboots
- [x] Keyboard auto-reconnects
- [x] Power keys blocked (safe from shutdown)
- [x] Device path changes handled automatically
- [x] MQTT topics publishing correctly
- [x] Battery level tracking
- [x] Last key tracking
- [ ] Key presses produce audible sounds (needs verification)
- [ ] Baby cam audio continues simultaneously (needs verification)

## Files Modified

- `modules/child-keyboard-fun.nix` - Auto-reconnect, kiosk user, udev rules, logind
- `hosts/hsb1/configuration.nix` - Service enablement, logind settings
- `hosts/hsb1/files/child-keyboard-fun.py` - Device name search, MQTT topics, battery
- `hosts/hsb1/files/child-keyboard-fun.env` - Device name instead of path
- `hosts/hsb1/docs/CHILD-KEYBOARD-FUN.md` - Updated documentation

## Related Issues

- Parent: P8000-child-keyboard-fun-acme-bk03.md
- Status: Ready for audio verification

## Notes

- System is 100% implemented - all infrastructure complete
- Need user to press keys and confirm sounds play
- All auto-healing, safety, and monitoring features in place
