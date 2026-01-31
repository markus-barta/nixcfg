# Runbook: hsb2 (Raspberry Pi Zero W)

**Host**: hsb2 (192.168.1.95)  
**Role**: Lightweight home server  
**Criticality**: LOW - Non-essential services

---

## Quick Connect

```bash
ssh mba@192.168.1.95
```

---

## Security Policy (SSH Hardening)

### The Markus-Only Rule

As a personal infrastructure server, `hsb2` allows SSH access **ONLY** for the `mba` user using Markus' authorized keys.

**Hokage Override:**
The `hokage` module (role `server-home`) automatically injects external developer keys (omega@\*). To prevent this, we use `lib.mkForce` in the NixOS configuration:

```nix
users.users.mba.openssh.authorizedKeys.keys = lib.mkForce [
  "ssh-rsa AAAAB3..." # mba@markus
];
```

---

## Common Tasks

### Update & Switch Configuration

```bash
ssh mba@192.168.1.95
cd ~/Code/nixcfg
git pull
just switch
```

### Rollback to Previous Generation

```bash
ssh mba@192.168.1.95
sudo nixos-rebuild switch --rollback
```

---

## Health Checks

### Quick Status

```bash
ssh mba@192.168.1.95 "systemctl status && free -h"
```

### WiFi Check

```bash
ssh mba@192.168.1.95 "iwconfig && ip addr show"
```

---

## Troubleshooting

### SSH Connection Issues

1. Verify Pi is powered on
2. Check WiFi connectivity: ping from router
3. Try serial console if available

### Out of Memory

The Pi Zero W has only 512MB RAM. If OOM occurs:

```bash
# Check memory usage
ssh mba@192.168.1.95 "free -h && ps aux --sort=-%mem | head -10"

# Kill heavy processes
sudo pkill <process-name>
```

### WiFi Not Connecting

```bash
# Check WiFi status
ssh mba@192.168.1.95 "ip link show wlan0 && dmesg | grep -i wlan"

# Restart WiFi
sudo systemctl restart wpa_supplicant
```

---

## Emergency Recovery

### If SSH Fails

1. Physical access to Pi Zero W required
2. Connect via USB serial (GPIO pins)
3. Or re-flash SD card

### Recovery via Serial Console

Connect USB-to-TTL adapter to GPIO pins:

- Pin 6 (GND)
- Pin 8 (TX) -> RX on adapter
- Pin 10 (RX) -> TX on adapter

Use screen/minicom at 115200 baud.

### Restore from Backup

**Re-flash SD card:**

1. Remove SD card from Pi
2. Flash new NixOS image
3. Boot and re-deploy configuration

---

## Maintenance

### Clean Up Disk Space

```bash
ssh mba@192.168.1.95 "cd ~/Code/nixcfg && just cleanup"
```

### View Logs

```bash
# Current boot
ssh mba@192.168.1.95 "journalctl -b -e"

# Follow logs
ssh mba@192.168.1.95 "journalctl -f"
```

---

## Related Documentation

- [hsb2 README](../README.md) - Full server documentation
