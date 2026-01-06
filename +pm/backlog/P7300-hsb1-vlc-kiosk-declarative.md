# hsb1 VLC Kiosk Declarative Configuration

**Created**: 2025-12-01  
**Updated**: 2026-01-06 (Verified Current State)  
**Priority**: P7300 (Low)  
**Status**: Backlog  
**Host**: hsb1

---

## Problem

The VLC kiosk setup on hsb1 uses a manually managed autostart script that is not version controlled in nixcfg. This makes the setup non-reproducible and requires manual intervention after reinstalls.

**Current State** (verified 2026-01-06):

- ✅ VLC kiosk is running (PID 3397, up since Jan 2)
- ✅ Openbox autostart file exists at `/home/kiosk/.config/openbox/autostart`
- ❌ Autostart file is manually managed (owned by root, last updated 30.08.2025)
- ❌ Not in nixcfg repository
- ✅ `mqtt-volume-control.service` is declarative and working

---

## Current Setup

### Autostart Script Location

`/home/kiosk/.config/openbox/autostart` (3.7 KB, executable, owned by root)

### What It Does

1. **Cleanup**: Kills old VLC processes
2. **Display**: Disables screen blanking (`xset s off`, `xset -dpms`)
3. **Secrets**: Sources `/etc/secrets/tapoC210-00.env` for camera credentials
4. **Audio**: Configures PipeWire sink and sets volume to 100%
5. **VLC**: Launches fullscreen RTSP stream with telnet interface (port 4212)

### VLC Command

```bash
vlc \
  --no-keyboard-events \
  --fullscreen \
  --no-osd \
  --no-video-title-show \
  --no-embedded-video \
  --video-on-top \
  --loop \
  --rtsp-tcp \
  --network-caching=500 \
  --extraintf=telnet \
  --telnet-password="${TAPO_C210_PASSWORD}" \
  "rtsp://${MINISERVER24_IP}:35067/9726ad778d503184" &
```

### Environment Variables Used

| Variable             | Source                         | Purpose                |
| -------------------- | ------------------------------ | ---------------------- |
| `MINISERVER24_IP`    | `/etc/secrets/tapoC210-00.env` | RTSP stream IP address |
| `TAPO_C210_PASSWORD` | `/etc/secrets/tapoC210-00.env` | VLC telnet password    |
| `XDG_RUNTIME_DIR`    | Set in script                  | PipeWire/PulseAudio    |

---

## Target State

### Option A: Home Manager (Recommended)

Manage the autostart file declaratively via Home Manager:

```nix
home-manager.users.kiosk = {
  xdg.configFile."openbox/autostart" = {
    executable = true;
    text = ''
      #!/bin/bash
      # Kill old VLC instances
      pgrep -x vlc >/dev/null && pkill -9 vlc && sleep 1

      # Disable screen blanking
      xset s off && xset -dpms && xset s noblank

      # Load secrets
      set -a && source /etc/secrets/tapoC210-00.env && set +a
      export XDG_RUNTIME_DIR=/run/user/1001

      # Configure audio
      sleep 2
      pactl set-default-sink "alsa_output.pci-0000_00_1b.0.analog-stereo"
      pactl set-sink-volume @DEFAULT_SINK@ 100%

      # Launch VLC kiosk
      vlc \
        --no-keyboard-events \
        --fullscreen \
        --no-osd \
        --no-video-title-show \
        --no-embedded-video \
        --video-on-top \
        --loop \
        --rtsp-tcp \
        --network-caching=500 \
        --extraintf=telnet \
        --telnet-password="''${TAPO_C210_PASSWORD}" \
        "rtsp://''${MINISERVER24_IP}:35067/9726ad778d503184" &
    '';
  };
};
```

### Option B: Systemd Service (Alternative)

Create a systemd user service for the kiosk user:

```nix
systemd.user.services.vlc-kiosk = {
  description = "VLC Kiosk Display";
  after = [ "graphical-session.target" ];
  wantedBy = [ "graphical-session.target" ];

  environment = {
    DISPLAY = ":0";
    XDG_RUNTIME_DIR = "/run/user/1001";
  };

  serviceConfig = {
    ExecStart = pkgs.writeShellScript "vlc-kiosk" ''
      # ... (same script content)
    '';
    Restart = "always";
    RestartSec = "5s";
  };
};
```

---

## Optional Enhancement: Stream Switching Service

Add MQTT-based stream switching (similar to existing `mqtt-volume-control`):

```nix
systemd.services.mqtt-stream-control = {
  description = "MQTT-based VLC Stream Switching Service";
  after = [ "network.target" ];
  wantedBy = [ "multi-user.target" ];

  serviceConfig = {
    ExecStart = pkgs.writeShellScript "mqtt-stream-control" ''
      # Listen on: home/hsb1/kiosk-vlc-stream
      # Messages: "babycam" | "youtube" | "<custom-url>"

      # Map presets
      case "$message" in
        babycam)
          url="rtsp://192.168.1.101:35067/9726ad778d503184"
          ;;
        youtube)
          url="https://www.youtube.com/watch?v=THnF0IQ8JJM"
          ;;
        *)
          url="$message"  # Custom URL
          ;;
      esac

      # Send to VLC via telnet
      echo -e "$password\nclear\nadd $url\nplay\nlogout" | nc localhost 4212
    '';
    Restart = "always";
    User = "kiosk";
  };
};
```

---

## Migration Plan

### Phase 1: Copy Current Script to Repo

1. **Extract current autostart**:

   ```bash
   ssh mba@hsb1.lan 'sudo cat /home/kiosk/.config/openbox/autostart' > /tmp/autostart
   ```

2. **Create directory in nixcfg**:

   ```bash
   mkdir -p hosts/hsb1/users/kiosk/openbox
   cp /tmp/autostart hosts/hsb1/users/kiosk/openbox/autostart
   ```

3. **Commit to repo**:
   ```bash
   git add hosts/hsb1/users/kiosk/
   git commit -m "feat(hsb1): add kiosk autostart script to repo"
   git push
   ```

### Phase 2: Make It Declarative

1. **Add Home Manager config** to `hosts/hsb1/configuration.nix`
2. **Deploy**: `nixos-rebuild switch --flake .#hsb1`
3. **Verify**: Check that `/home/kiosk/.config/openbox/autostart` is now a symlink to the Nix store
4. **Test**: Restart display manager and verify VLC starts

### Phase 3: Optional Stream Switching

1. Implement `mqtt-stream-control.service`
2. Test stream switching via MQTT
3. Update Node-RED flows to use new topic

---

## Acceptance Criteria

- [ ] Autostart script exists in `hosts/hsb1/users/kiosk/openbox/autostart` (in repo)
- [ ] Home Manager manages `/home/kiosk/.config/openbox/autostart`
- [ ] File is a symlink to Nix store (not manually managed)
- [ ] VLC starts automatically on kiosk login
- [ ] Screen blanking is disabled
- [ ] Audio is configured correctly
- [ ] RTSP stream displays on monitor
- [ ] Telnet interface works on port 4212
- [ ] `mqtt-volume-control` still works

---

## Test Plan

### Pre-Migration Verification

```bash
# Verify current VLC is running
ssh mba@hsb1.lan 'pgrep -a vlc'

# Check autostart file
ssh mba@hsb1.lan 'sudo cat /home/kiosk/.config/openbox/autostart | head -20'

# Verify it's manually managed (not a symlink)
ssh mba@hsb1.lan 'sudo ls -la /home/kiosk/.config/openbox/autostart'
# Should show: -rwxr-xr-x  1 root  root  3659 ...
```

### Post-Migration Verification

```bash
# Verify it's now a symlink
ssh mba@hsb1.lan 'ls -la /home/kiosk/.config/openbox/autostart'
# Should show: lrwxrwxrwx ... -> /nix/store/...

# Restart display manager
ssh mba@hsb1.lan 'sudo systemctl restart display-manager.service'

# Wait 10 seconds, then verify VLC is running
sleep 10
ssh mba@hsb1.lan 'pgrep -a vlc'

# Test telnet interface
ssh mba@hsb1.lan 'echo -e "PASSWORD\nvolume 256\nquit" | nc localhost 4212'

# Test MQTT volume control
ssh mba@hsb1.lan 'mosquitto_pub -h localhost -t "home/hsb1/kiosk-vlc-volume" -m "256"'
```

---

## Risk Assessment

| Risk                       | Probability | Impact | Mitigation                                |
| -------------------------- | ----------- | ------ | ----------------------------------------- |
| VLC fails to start         | Low         | Medium | Rollback via `nixos-rebuild --rollback`   |
| Screen blanking re-enabled | Low         | Low    | Verify xset commands in script            |
| Audio sink wrong           | Low         | Medium | Test audio before deploying               |
| Secrets not loaded         | Very Low    | Medium | Verify `/etc/secrets/` path in script     |
| Display manager issues     | Low         | Medium | Physical access available, easy to revert |

**Overall Risk**: 🟢 LOW (well-understood, easy rollback)

---

## Why Not Do It Now?

- ✅ Current setup works fine (VLC running for 4+ days)
- ✅ Manual script is well-documented and stable
- ⚠️ Requires display manager restart (brief kiosk downtime)
- ⚠️ Marginal benefit (reproducibility vs. current stability)

**Decision**: Prepare thoroughly, execute when:

1. You're doing other hsb1 maintenance
2. You can physically verify the display
3. You have time to troubleshoot if needed

---

## Related

- `P6380-hsb1-agenix-secrets.md` - Migrate `/etc/secrets/tapoC210-00.env` to agenix
- `P7200-hsb1-docker-restructure.md` - Related hsb1 declarative improvements
- `hosts/hsb1/docs/SMARTHOME.md` - VLC kiosk documentation
- `hosts/hsb1/docs/RUNBOOK.md` - Documents target state (not yet implemented)
