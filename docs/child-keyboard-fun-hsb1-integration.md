# Child's Keyboard Fun - hsb1 Integration Guide

Quick reference for integrating the child's keyboard fun service into the hsb1 host configuration.

## Integration Steps for hsb1

### 1. Add to Host Configuration

Edit `hosts/hsb1/configuration.nix` (or wherever hsb1 is configured):

```nix
{ config, pkgs, ... }:

{
  imports = [
    # ... existing imports ...
    ../../modules/child-keyboard-fun.nix
  ];

  # ... existing configuration ...

  # Enable child keyboard fun service
  services.child-keyboard-fun = {
    enable = true;
    user = "childuser";  # Change to actual user on hsb1
    configFile = "/etc/child-keyboard-fun.env";
  };

  # Ensure user exists (if not already configured)
  users.users.childuser = {
    isNormalUser = true;
    description = "Child User";
    # Groups are automatically added by the module
    # but you can add more if needed
    extraGroups = [ ];
  };
}
```

### 2. Deploy Configuration

```bash
# Option A: Deploy from local machine
nixos-rebuild switch --flake .#hsb1 --target-host hsb1

# Option B: Deploy on hsb1 directly
ssh hsb1
sudo nixos-rebuild switch
```

### 3. Setup on hsb1

SSH into hsb1 and complete the setup:

```bash
ssh hsb1

# 1. Find the keyboard device
sudo evtest
# Note the /dev/input/by-id/ path for the child's keyboard

# 2. Create sound directory
sudo mkdir -p /home/childuser/child-keyboard-sounds
sudo chown childuser:users /home/childuser/child-keyboard-sounds

# 3. Add sound files
# Either copy from another machine:
scp ~/sounds/*.wav hsb1:/home/childuser/child-keyboard-sounds/
# Or download directly on hsb1

# 4. Create configuration
sudo tee /etc/child-keyboard-fun.env << 'EOF'
KEYBOARD_DEVICE=/dev/input/by-id/YOUR-KEYBOARD-HERE-event-kbd
SOUND_DIR=/home/childuser/child-keyboard-sounds

# Optional: Add MQTT for Home Assistant
# MQTT_HOST=homeassistant.local
# MQTT_PORT=1883
# MQTT_USER=keyboard
# MQTT_PASS=your_password

# Key mappings
KEY_SPACE=random
# Add more as needed...
EOF

# 5. Set permissions
sudo chmod 600 /etc/child-keyboard-fun.env

# 6. Start service
sudo systemctl start child-keyboard-fun

# 7. Check status
sudo systemctl status child-keyboard-fun
sudo journalctl -u child-keyboard-fun -f
```

## Flake Integration (if using flakes)

If hsb1 is configured via flakes, you might structure it like:

```nix
# flake.nix
{
  outputs = { self, nixpkgs, ... }: {
    nixosConfigurations.hsb1 = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hosts/hsb1/configuration.nix
        ./modules/child-keyboard-fun.nix
        {
          services.child-keyboard-fun = {
            enable = true;
            user = "childuser";
            configFile = "/etc/child-keyboard-fun.env";
          };
        }
      ];
    };
  };
}
```

## Home Assistant Integration on hsb1

If you're running Home Assistant on hsb1 or the same network:

### 1. Setup MQTT User in Home Assistant

1. In Home Assistant, go to Settings > Devices & Services > MQTT
2. Add MQTT integration if not already configured
3. Create a user for the keyboard service

### 2. Configure in .env file

```env
MQTT_HOST=localhost  # or homeassistant.local
MQTT_PORT=1883
MQTT_USER=keyboard
MQTT_PASS=secure_password

# Example mappings for hsb1 smart home
KEY_F1=mqtt:homeassistant/light/office/set:{"state":"toggle"}
KEY_F2=mqtt:homeassistant/light/hallway/set:{"state":"toggle"}
KEY_F3=mqtt:homeassistant/scene/movie_mode:ON
KEY_F4=mqtt:homeassistant/scene/bright:ON
```

### 3. Test MQTT Connection

```bash
# On hsb1, test MQTT publish
mosquitto_pub -h localhost -u keyboard -P secure_password \
  -t homeassistant/light/office/set \
  -m '{"state":"toggle"}'

# Monitor MQTT traffic
mosquitto_sub -h localhost -u keyboard -P secure_password \
  -t 'homeassistant/#' -v
```

## Monitoring

### Check Service Status

```bash
# Service status
systemctl status child-keyboard-fun

# Recent logs
journalctl -u child-keyboard-fun -n 50

# Follow logs live
journalctl -u child-keyboard-fun -f

# Check if device is grabbed
lsof | grep /dev/input/by-id/
```

### Performance

The service should be very lightweight:

- Minimal CPU usage (event-driven)
- Low memory (~20-30 MB)
- No network overhead (unless MQTT is used)

## Troubleshooting on hsb1

### Device Permissions

```bash
# Check if user is in input group
id childuser

# Should show: groups=... input(XX) audio(YY) ...

# If not, the module should handle it, but you can verify:
sudo usermod -aG input,audio childuser
sudo nixos-rebuild switch
```

### Audio Issues

```bash
# Check audio devices
aplay -L

# Test audio as user
sudo -u childuser aplay /home/childuser/child-keyboard-sounds/test.wav

# Check PulseAudio/PipeWire
systemctl --user -M childuser@ status pipewire
systemctl --user -M childuser@ status pulseaudio
```

### Bluetooth Keyboard Connection

If using Bluetooth keyboard on hsb1:

```bash
# Check Bluetooth status
bluetoothctl

# Pair keyboard
bluetoothctl
> scan on
> pair XX:XX:XX:XX:XX:XX
> trust XX:XX:XX:XX:XX:XX
> connect XX:XX:XX:XX:XX:XX

# Check if device appears
ls -la /dev/input/by-id/*bluetooth*
```

## Security Considerations

1. **User Isolation**: Service runs as unprivileged user
2. **Device Access**: Only input group required (not root)
3. **Config File**: Stored in `/etc/` with restricted permissions (600)
4. **MQTT Credentials**: Keep secure, use strong passwords
5. **Network**: If using MQTT, consider firewall rules

```nix
# Optional: Restrict MQTT to local network
networking.firewall = {
  allowedTCPPorts = [ ];  # MQTT only accessible locally
};
```

## Future Enhancements

Ideas for extending the system on hsb1:

1. **Visual Feedback**: LED strips via Home Assistant
2. **Multiple Keyboards**: Support different kids' keyboards
3. **Educational Mode**: Letter/number learning sounds
4. **Time Limits**: Automatic disable during certain hours
5. **Statistics**: Track key presses, show fun stats
6. **Web UI**: Configuration interface via web browser
7. **Backup Sounds**: Fallback to TTS if sound file missing

## Quick Commands Reference

```bash
# Start/stop service
sudo systemctl start child-keyboard-fun
sudo systemctl stop child-keyboard-fun
sudo systemctl restart child-keyboard-fun

# View logs
sudo journalctl -u child-keyboard-fun -f

# Edit config
sudo nano /etc/child-keyboard-fun.env
sudo systemctl restart child-keyboard-fun

# Test manually
sudo systemctl stop child-keyboard-fun
sudo -u childuser /run/current-system/sw/bin/child-keyboard-fun \
  /etc/child-keyboard-fun.env

# Rebuild NixOS
sudo nixos-rebuild switch

# Check device path
ls -la /dev/input/by-id/
sudo evtest
```
