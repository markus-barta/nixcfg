# Runbook: hsb2 (Raspberry Pi Zero W)

**Host**: hsb2 (192.168.1.95)  
**OS**: Raspbian 11 (bullseye)  
**Role**: Lightweight home server  
**Criticality**: LOW - Non-essential services  
**Management**: Manual (not NixOS)

---

## Quick Connect

```bash
ssh mba@192.168.1.95
```

---

## Security Policy (SSH Access)

### The Markus-Only Rule

As a personal infrastructure server, `hsb2` allows SSH access **ONLY** for the `mba` user using Markus' authorized keys.

**Current Setup:**

- User: `mba` (sudo access)
- Auth: SSH key only (password auth disabled)
- Keys managed manually in `~/.ssh/authorized_keys`

---

## Common Tasks

### Update System Packages

```bash
ssh mba@192.168.1.95
sudo apt update && sudo apt upgrade -y
```

### Install New Package

```bash
ssh mba@192.168.1.95
sudo apt install <package-name>
```

### Reboot System

```bash
ssh mba@192.168.1.95
sudo reboot
```

---

## Health Checks

### Quick Status

```bash
# System status
ssh mba@192.168.1.95 "uptime && free -h && df -h"

# Running services
ssh mba@192.168.1.95 "systemctl --state=running"
```

### WiFi Check

```bash
ssh mba@192.168.1.95 "iwconfig && ip addr show wlan0"
```

### Check for Updates

```bash
ssh mba@192.168.1.95 "sudo apt update && apt list --upgradable"
```

---

## Troubleshooting

### SSH Connection Issues

1. Verify Pi is powered on (check LED)
2. Check WiFi connectivity: `ping 192.168.1.95`
3. Try power cycling if unresponsive

### Out of Memory

The Pi Zero W has only 512MB RAM. If OOM occurs:

```bash
# Check memory usage
ssh mba@192.168.1.95 "free -h && ps aux --sort=-%mem | head -10"

# Find and kill heavy processes
sudo pkill <process-name>
```

### WiFi Not Connecting

```bash
# Check WiFi interface status
ssh mba@192.168.1.95 "ip link show wlan0 && dmesg | grep -i wlan"

# Restart WiFi
ssh mba@192.168.1.95 "sudo systemctl restart dhcpcd"

# Check wpa_supplicant
ssh mba@192.168.1.95 "sudo systemctl status wpa_supplicant"
```

### Disk Space Issues

```bash
# Check disk usage
ssh mba@192.168.1.95 "df -h"

# Clean apt cache
ssh mba@192.168.1.95 "sudo apt clean && sudo apt autoremove -y"

# Find large files
ssh mba@192.168.1.95 "sudo du -sh /var/log/* | sort -hr | head -10"
```

---

## Emergency Recovery

### If SSH Fails

1. Physical access to Pi Zero W required
2. Connect via USB serial (GPIO pins) - see below
3. Or re-flash SD card with fresh Raspbian image

### Recovery via Serial Console

Connect USB-to-TTL adapter to GPIO pins:

- Pin 6 (GND)
- Pin 8 (TX) -> RX on adapter
- Pin 10 (RX) -> TX on adapter

Use screen/minicom at 115200 baud:

```bash
screen /dev/tty.usbserial-* 115200
```

### Re-flash SD Card

1. Power off Pi, remove SD card
2. Use Raspberry Pi Imager to flash new Raspbian image
3. Reconfigure WiFi and SSH on boot partition:
   - Create `wpa_supplicant.conf` with WiFi credentials
   - Create empty `ssh` file to enable SSH
4. Insert SD card and boot

---

## Maintenance

### Monthly Tasks

```bash
# Update packages
ssh mba@192.168.1.95 "sudo apt update && sudo apt upgrade -y"

# Check disk space
ssh mba@192.168.1.95 "df -h"

# Check for failed services
ssh mba@192.168.1.95 "systemctl --failed"
```

### View Logs

```bash
# System logs
ssh mba@192.168.1.95 "sudo journalctl -b -e"

# Follow logs
ssh mba@192.168.1.95 "sudo journalctl -f"

# Kernel messages
ssh mba@192.168.1.95 "dmesg | tail -50"
```

---

## Services

### IR → Sony TV Bridge

**Status**: 🔵 PLANNED / IN DEVELOPMENT  
**Documentation**: [IR-BRIDGE.md](./IR-BRIDGE.md) - Complete technical specification  
**Purpose**: Convert IR remote signals to Sony Bravia TV commands over HTTP

#### Overview

This service bridges IR remote control signals (via FLIRC USB receiver) to a Sony Bravia TV using the IRCC (IR Control Client) protocol over HTTP.

**Why hsb2?**

- Replaces Node-RED implementation on hsb1 that had issues:
  - Unavailable during high load or reboots
  - Slowdowns affecting responsiveness
  - Double commands for single presses
- Dedicated service eliminates Docker/Node-RED overhead
- Independent from hsb1's automation stack

**Hardware:**

- FLIRC USB IR Receiver (moved from hsb1)
- Sony Bravia TV at `192.168.1.137`
- Raspberry Pi Zero W as bridge host

**Key Technical Details:**

- FLIRC appears as USB HID keyboard (`/dev/input/event0`)
- 39 different buttons mapped (numbers, navigation, media, apps)
- Sony IRCC protocol over HTTP with PSK authentication
- Python script using `evdev` library for input reading
- MQTT debug logging to `home/hsb2/ir-debug`

#### Quick Commands

```bash
# Check if ir-bridge service is running
ssh mba@192.168.1.95 "sudo systemctl status ir-bridge"

# View ir-bridge logs
ssh mba@192.168.1.95 "sudo journalctl -u ir-bridge -f"

# Test FLIRC input events
ssh mba@192.168.1.95 "sudo evtest /dev/input/event0"

# Check MQTT debug messages
ssh mba@hsb1.lan "mosquitto_sub -h localhost -t 'home/hsb2/ir-debug' -v"
```

#### Environment Configuration

Configuration stored in `/etc/ir-bridge.env`:

```bash
SONY_TV_IP=192.168.1.137
SONY_TV_PSK=<your_psk_here>
MQTT_BROKER=192.168.1.101
MQTT_TOPIC=home/hsb2/ir-debug
LOG_LEVEL=INFO
```

#### Service Management

```bash
# Start/stop/restart
sudo systemctl start ir-bridge
sudo systemctl stop ir-bridge
sudo systemctl restart ir-bridge

# Enable/disable auto-start
sudo systemctl enable ir-bridge
sudo systemctl disable ir-bridge
```

#### Troubleshooting

**FLIRC not detected:**

```bash
# Check USB device
lsusb | grep flirc

# Check input device
cat /proc/bus/input/devices | grep -A5 flirc

# List input events
ls -la /dev/input/event*
```

**TV not responding:**

```bash
# Test TV reachability
ping 192.168.1.137

# Check PSK is configured
cat /etc/ir-bridge.env | grep SONY_TV_PSK

# Test IRCC endpoint manually (from script directory)
cd ~/ir-bridge && python3 test_tv.py
```

**Double commands issue:**

- Documented in IR-BRIDGE.md under "Known Issues"
- Not yet implemented - monitor during testing
- May require debounce logic in Python script

#### Migration Status

- [ ] Move FLIRC hardware from hsb1 to hsb2
- [ ] Install Python dependencies (`evdev`, `requests`, `paho-mqtt`)
- [ ] Create `ir-bridge.py` script
- [ ] Create environment file with TV PSK
- [ ] Create systemd service
- [ ] Test all 39 buttons
- [ ] Verify MQTT debug logging
- [ ] Monitor for double commands
- [ ] Document fallback procedure
- [ ] Disable hsb1 Node-RED TV flows

**Fallback:** If hsb2 fails, FLIRC can be moved back to hsb1 and Node-RED TV flows re-enabled.

---

## Related Documentation

- [hsb2 README](../README.md) - Full server documentation
- [IR-BRIDGE.md](./IR-BRIDGE.md) - IR → Sony TV Bridge technical documentation
- [Raspberry Pi Documentation](https://www.raspberrypi.com/documentation/)
- [Raspbian/Debian Handbook](https://debian-handbook.info/)

---

## Historical: NixOS Migration

NixOS migration was planned but abandoned due to ARMv6l complexity.
See README.md "NixOS Migration Status" section for details.

Old NixOS configuration files remain in this directory for reference:

- `configuration.nix` (inactive)
- `hardware-configuration.nix` (inactive)
- `disk-config.nix` (inactive)
