# Runbook: gpc0 (Gaming PC)

**Host**: gpc0 (192.168.1.154)  
**Role**: Gaming desktop with AMD GPU, Steam, NixOS build host  
**Criticality**: LOW - Personal gaming PC, not critical infrastructure

---

## Quick Connect

```bash
ssh mba@192.168.1.154
ssh mba@gpc0.lan
```

---

## Quick Reference

| Item           | Value                        |
| -------------- | ---------------------------- |
| **Hostname**   | `gpc0`                       |
| **IP Address** | `192.168.1.154`              |
| **CPU**        | Intel i7-7700K (8 threads)   |
| **GPU**        | AMD Radeon RX 9070 XT (16GB) |
| **Storage**    | 5TB SSD (ZFS)                |
| **Users**      | `mba`, `omega`               |

---

## Common Tasks

### Update & Switch Configuration

```bash
ssh mba@192.168.1.154
cd ~/Code/nixcfg
git pull
just switch
```

### Rollback to Previous Generation

```bash
sudo nixos-rebuild switch --rollback
```

## 🏗️ Fleet Build Host

`gpc0` is the most powerful machine in the infrastructure (8 threads, 4.2GHz, native x86_64). It should be used to build configurations for slower Mac minis to save time.

### Local Fleet Rebuilds

```bash
# Build configuration for another host (without deploying)
nixos-rebuild build --flake .#hsb0

# Deploy to remote host from gpc0
nixos-rebuild switch --flake .#hsb0 --target-host mba@192.168.1.99
```

### ⚡ Build Optimization

For heavy rebuilds, use `systemd-inhibit` to prevent the machine from sleeping:

```bash
systemd-inhibit --what=sleep:idle sudo nixos-rebuild switch --flake .#gpc0
```

---

## 📺 Display & Autologin (TV Workaround)

`gpc0` is configured with **autologin for the `mba` user** to prevent SDDM/Wayland from timing out if the TV is off during boot.

- **Switching Users**: Lock the screen or log out to switch to `omega`.

---

## 🔴 Critical Known Issues (Gotchas)

### Zellij Theming Override

**Symptom**: Zellij ignores Tokyo Night theming.
**Fix**: Use `lib.mkForce` on the `source` attribute in `theme-hm.nix`.
**Manual Step**: Run `rm -rf ~/.config/zellij` before the first rebuild after a theme change.

---

## Health Checks

### Quick Status

```bash
ssh mba@192.168.1.154 "zpool status && nvidia-smi 2>/dev/null || amdgpu_top --version"
```

### GPU Status

```bash
# AMD GPU monitoring
amdgpu_top

# GPU control GUI
lact
```

### ZFS Pool Status

```bash
zpool status mbazroot
zfs list
```

---

## Gaming

### Steam

```bash
steam
```

### Gamescope (Gaming Compositor)

```bash
# Example: 1440p fullscreen
gamescope -W 2560 -H 1440 -f steam
```

### Emulation

```bash
# Nintendo Switch emulation
ryubing
```

---

## Troubleshooting

### Steam Not Launching

```bash
# Check Steam logs
journalctl --user -u steam -n 50

# Restart Steam
killall steam
steam
```

### GPU Issues

```bash
# Check AMD driver is loaded
lsmod | grep amdgpu

# Check GPU info
cat /sys/class/drm/card1/device/power_dpm_force_performance_level

# Check for errors
dmesg | grep -i amdgpu | tail -20
```

### ZFS Issues

```bash
# Check pool health
zpool status mbazroot

# Start scrub
sudo zpool scrub mbazroot
```

---

## Emergency Recovery

### If SSH Fails

1. Connect keyboard and monitor directly
2. Login as `mba` or `omega`

### Restore from Generation

```bash
# At boot menu (GRUB), select previous generation
# Or after boot:
sudo nixos-rebuild switch --rollback
```

---

## Maintenance

### Clean Up Disk Space

```bash
cd ~/Code/nixcfg && just cleanup
```

### Docker Cleanup (if used)

```bash
docker system prune -a
```

### ZFS Scrub

```bash
sudo zpool scrub mbazroot
```

---

## Useful Commands

```bash
# GPU monitoring
amdgpu_top                    # Real-time GPU stats
lact                          # GUI for fan curves, power limits

# Gaming
steam                         # Launch Steam
gamescope --help              # Gamescope options

# ZFS
zpool status mbazroot         # Pool health
zfs list                      # Dataset sizes

# System
sensors                       # Temperature sensors
```

---

## Related Documentation

- [gpc0 README](../README.md) - Full system documentation
- [SECRETS.md](../secrets/SECRETS.md) - Credentials (gitignored)
