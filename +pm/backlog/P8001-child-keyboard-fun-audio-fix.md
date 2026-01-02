# P8001: Child Keyboard Fun - Event Loop Issue

**Status:** 🔴 Blocked  
**Priority:** High  
**Effort:** ~2 hours  
**Created:** 2026-01-01  
**Updated:** 2026-01-02 07:06  
**Parent:** P8000-child-keyboard-fun-acme-bk03.md

## Problem Statement

The child-keyboard-fun system is successfully grabbing keyboard input from the ACME BK03 Bluetooth keyboard and triggering sound playback attempts, but no audio is actually playing. Only the baby cam (VLC) audio is audible.

## Current Status

### ✅ Working

- ACME BK03 keyboard paired, bonded, and trusted to hsb1
- Keyboard device detected at `/dev/input/event0`
- Python script successfully grabs device exclusively ("Grabbed device: ACME BK03")
- Key presses are detected and trigger play_sound() function
- 28 Warner Bros cartoon sound effects (MP3) uploaded to `~/child-keyboard-sounds/`
- Configuration file at `/etc/child-keyboard-fun.env` with 39 key mappings
- systemd service running as `mba` user
- sudo rule configured: mba can run paplay as kiosk without password

### ❌ Not Working

- Audio playback - no sound is heard when keys are pressed
- Only baby cam (VLC running as kiosk user) audio is audible

## Technical Details

### Audio Architecture on hsb1

- **Baby Cam (VLC):** Runs as `kiosk` user (uid 1001) with PipeWire/PipeWire-Pulse
- **Keyboard Service:** Runs as `mba` user (uid 1000)
- **Audio System:** PipeWire with pipewire-pulse
- **Current Approach:** Using `sudo -u kiosk paplay` to play sounds in kiosk's audio session

### Attempted Solutions

1. ❌ mpg123 - couldn't connect to PulseAudio/PipeWire
2. ❌ ffplay (ffmpeg-headless) - binary not included in headless package
3. ❌ sox/play - crashed (exit code 136, zombie processes)
4. ❌ paplay with XDG_RUNTIME_DIR=/run/user/1001 - permission denied
5. ⏳ paplay via sudo as kiosk user - no errors but no audio output

### Current Implementation

```python
def play_sound(sound_file):
    """Play sound via kiosk user's PipeWire (same as VLC)"""
    subprocess.Popen([
        '/nix/store/.../sudo',
        '-u', 'kiosk',
        '/nix/store/.../paplay',
        '--volume=45875',  # ~70% volume (65536 = 100%)
        str(sound_file)
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
```

### Observations

- No errors in journalctl logs when keys are pressed
- paplay processes are spawned but no audio output
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

## Proposed Solutions (Priority Order)

### Option 1: Fix paplay with Proper Environment

- Set full environment for kiosk user's PipeWire session
- Specify sink explicitly
- Add error logging to catch failures

### Option 2: Convert to WAV and Use aplay

- Convert all MP3 files to WAV
- Use aplay (ALSA) directly - simpler, no PulseAudio/PipeWire needed
- May work better for mixing with VLC

### Option 3: Use mpv with Proper Configuration

- mpv is more robust for audio playback
- Can handle MP3 natively
- Better error reporting

### Option 4: Run as kiosk User Entirely

- Change service to run as kiosk user
- Simpler audio access (same session as VLC)
- Need to ensure kiosk user can access input devices

## Acceptance Criteria

- [ ] Key presses on ACME BK03 keyboard produce audible cartoon sounds
- [ ] Sounds play at ~70% volume (don't overpower baby cam)
- [ ] Baby cam (VLC) audio continues to play simultaneously
- [ ] No audio glitches or dropouts
- [ ] Service starts automatically on boot
- [ ] Works reliably after system reboots

## Files Modified

- `modules/child-keyboard-fun.nix` - Main module with Python script
- `hosts/hsb1/configuration.nix` - Service configuration and sudo rules
- `/etc/child-keyboard-fun.env` - Key mappings configuration
- `~/child-keyboard-sounds/` - 28 MP3 sound files

## Related Issues

- Parent: P8000-child-keyboard-fun-acme-bk03.md
- Depends on: Bluetooth keyboard pairing (✅ Complete)
- Blocks: Full system testing and handoff to child

## Notes

- System is 95% complete - only audio output is broken
- All infrastructure is in place and working
- This is purely an audio playback/routing issue
- VLC baby cam must continue to work - this is critical
