# hsb1 VLC Kiosk Declarative Configuration

## Summary

Make the VLC kiosk setup on hsb1 fully declarative in NixOS, including the ability to switch streams (babycam ↔ YouTube video) via remote call.

## Current State (Manual Setup)

### Scripts on hsb1 (`/home/mba/scripts/`)

| Script                | Purpose                                     | Declarative? |
| --------------------- | ------------------------------------------- | ------------ |
| `vlc-kiosk-output.sh` | Switch VLC stream to any URL (RTSP/YouTube) | ❌ No        |
| `fullvolume.sh`       | Set PipeWire volume to 100%                 | ❌ No        |
| `set_vlc_volume.sh`   | Set VLC-specific volume via pactl           | ❌ No        |

### Kiosk Autostart (`/home/kiosk/.config/openbox/autostart`)

Currently a **manual file** with:

- Screen blanking disabled (`xset s off`, `xset -dpms`)
- Environment loading from `/etc/secrets/tapoC210-00.env`
- Audio sink configuration (PipeWire/PulseAudio)
- VLC launched with telnet interface on port 4212

### Key Script: `vlc-kiosk-output.sh`

```bash
#!/bin/bash
# Switches VLC to any URL via telnet (port 4212)
# Usage:
#   sudo -u kiosk /home/mba/scripts/vlc-kiosk-output.sh 'rtsp://192.168.1.101:35067/9726ad778d503184'
#   sudo -u kiosk /home/mba/scripts/vlc-kiosk-output.sh 'https://www.youtube.com/watch?v=THnF0IQ8JJM'

source /etc/secrets/tapoC210-00.env
PASSWORD=${TAPO_C210_PASSWORD}
NEW_URL="$1"

COMMANDS=$(cat <<EOF
$PASSWORD
clear
add $NEW_URL
play
logout
EOF
)

echo "$COMMANDS" | nc localhost 4212
```

### What's Already Declarative

- ✅ VLC kiosk packages in `configuration.nix`
- ✅ `kiosk` user creation
- ✅ X11 + Openbox + LightDM autologin
- ✅ `mqtt-volume-control.service` (volume via MQTT)

## Proposed Solution

### Phase 1: Move Autostart to NixOS

Use Home Manager to declaratively manage the kiosk autostart:

```nix
home-manager.users.kiosk = {
  xdg.configFile."openbox/autostart" = {
    executable = true;
    text = ''
      #!/bin/bash
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
      vlc --fullscreen --no-osd --loop --extraintf=telnet \
          --telnet-password="''${TAPO_C210_PASSWORD}" \
          "rtsp://''${MINISERVER24_IP}:35067/9726ad778d503184" &
    '';
  };
};
```

### Phase 2: MQTT Stream Switching Service

Create a new systemd service (similar to `mqtt-volume-control`) that listens for stream switch commands:

```nix
systemd.services.mqtt-stream-control = {
  description = "MQTT-based VLC Stream Switching Service";
  after = [ "network.target" ];
  wantedBy = [ "multi-user.target" ];

  # Listen on: home/hsb1/kiosk-vlc-stream
  # Messages: "babycam" | "youtube" | "<custom-url>"

  serviceConfig = {
    ExecStart = pkgs.writeShellScript "mqtt-stream-control" ''
      # Similar to mqtt-volume-control but switches streams
      # Maps "babycam" → RTSP URL
      # Maps "youtube" → predefined YouTube URL
      # Allows custom URLs
    '';
    Restart = "always";
    User = "kiosk";
  };
};
```

### Phase 3: Predefined Stream Presets

Add a configuration option for stream presets:

```nix
# In configuration.nix or module
vlcKiosk.streams = {
  babycam = "rtsp://192.168.1.101:35067/9726ad778d503184";
  underwater = "https://www.youtube.com/watch?v=THnF0IQ8JJM";
  fireplace = "https://www.youtube.com/watch?v=...";
};
```

## MQTT Topic Design

| Topic                        | Payload   | Action                   |
| ---------------------------- | --------- | ------------------------ |
| `home/hsb1/kiosk-vlc-volume` | `0-512`   | Set volume (existing)    |
| `home/hsb1/kiosk-vlc-stream` | `babycam` | Switch to camera         |
| `home/hsb1/kiosk-vlc-stream` | `youtube` | Switch to YouTube preset |
| `home/hsb1/kiosk-vlc-stream` | `<url>`   | Switch to custom URL     |

## Files to Create/Move

| Source (hsb1)                           | Destination (repo)                   |
| --------------------------------------- | ------------------------------------ |
| `/home/kiosk/.config/openbox/autostart` | Managed via Home Manager             |
| `/home/mba/scripts/vlc-kiosk-output.sh` | Embedded in systemd service          |
| `/home/mba/scripts/fullvolume.sh`       | Not needed (autostart handles it)    |
| `/home/mba/scripts/set_vlc_volume.sh`   | Not needed (MQTT service handles it) |

## Benefits

1. **Reproducible**: Rebuild NixOS → kiosk works identically
2. **Version controlled**: All configs in git
3. **Remote control**: Switch streams via MQTT (Node-RED, HomeKit, etc.)
4. **Presets**: Easy to add new video presets

## Dependencies

- Existing: `mqtt-volume-control.service` (working)
- Existing: VLC telnet interface on port 4212
- Existing: `/etc/secrets/tapoC210-00.env`

## Acceptance Criteria

- [ ] Kiosk autostart is declarative (Home Manager)
- [ ] `mqtt-stream-control.service` created
- [ ] Stream switching works via MQTT
- [ ] Node-RED flow updated to use new MQTT topic
- [ ] Manual scripts removed from hsb1
- [ ] Documentation updated in `docs/SMARTHOME.md`

## Priority

**Medium** - Current manual setup works, but not reproducible after reinstall.

## Estimated Effort

~2-3 hours

## Related

- `hosts/hsb1/configuration.nix` - Existing VLC kiosk config
- `hosts/hsb1/docs/SMARTHOME.md` - VLC kiosk documentation
- Existing: `mqtt-volume-control.service`
