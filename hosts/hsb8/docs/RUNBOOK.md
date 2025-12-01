# Runbook: hsb8 (Parents' Home Server)

**Host**: hsb8 (192.168.1.100)  
**Role**: DNS/DHCP (AdGuard Home) + Home Automation at parents' home  
**Location**: ww87 (parents' home) - currently configured for this location  
**Criticality**: MEDIUM - Parents' network infrastructure

---

## Quick Connect

```bash
ssh mba@192.168.1.100
ssh mba@hsb8.lan

# As Gerhard (father)
ssh gb@192.168.1.100
```

---

## Quick Reference Card

```
╔════════════════════════════════════════════════════════════╗
║ 🌀 hsb8 - Parents' Home Emergency Reference                ║
╠════════════════════════════════════════════════════════════╣
║ SSH:       ssh mba@192.168.1.100                           ║
║ Users:     mba (admin), gb (Gerhard)                       ║
║ Location:  ww87 (parents' home)                            ║
╠════════════════════════════════════════════════════════════╣
║ 🌐 SERVICES (when at ww87)                                 ║
║ • AdGuard Home:  http://192.168.1.100:3000                 ║
║ • DNS Server:    192.168.1.100:53                          ║
║ • DHCP:          192.168.1.200-254 (if enabled)            ║
╠════════════════════════════════════════════════════════════╣
║ 🚨 IF DOWN                                                 ║
║ 1. SSH check: ssh mba@192.168.1.100                        ║
║ 2. Physical access to Mac mini (if SSH fails)              ║
║ 3. Rollback: sudo nixos-rebuild switch --rollback          ║
╚════════════════════════════════════════════════════════════╝
```

---

## Common Tasks

### Update & Switch Configuration

```bash
ssh mba@192.168.1.100
cd ~/nixcfg
git pull
just switch
```

### Rollback to Previous Generation

```bash
ssh mba@192.168.1.100
sudo nixos-rebuild switch --rollback
```

### Switch Location (jhw22 ↔ ww87)

⚠️ **Requires physical access** - Network gateway changes during switch!

```bash
# At physical console (SSH won't work during switch)
enable-ww87    # Switch to parents' home config
# OR manually edit configuration.nix and change location
```

---

## Health Checks

### Quick Status

```bash
ssh mba@192.168.1.100 "systemctl status adguardhome && zpool status | head -10"
```

### AdGuard Home Status (when at ww87)

```bash
ssh mba@192.168.1.100 "systemctl status adguardhome"
curl -I http://192.168.1.100:3000
```

### Docker Status

```bash
ssh mba@192.168.1.100 "docker ps"
```

### ZFS Pool Status

```bash
ssh mba@192.168.1.100 "zpool status"
```

---

## Troubleshooting

### AdGuard Home Not Responding

```bash
ssh mba@192.168.1.100
systemctl status adguardhome
journalctl -u adguardhome -n 50 --no-pager
sudo systemctl restart adguardhome
```

### DNS Not Resolving

1. Check if AdGuard Home is running
2. Check upstream DNS: `dig @1.1.1.1 google.com`
3. Verify location is set to ww87: `grep "location =" ~/nixcfg/hosts/hsb8/configuration.nix`

### Static DHCP Leases Not Loading

```bash
# Check agenix secret
ls -la /run/agenix/static-leases-hsb8

# Validate JSON format
cat /run/agenix/static-leases-hsb8 | jq empty

# Check preStart logs
journalctl -u adguardhome | grep -i "static"
```

### Network Issues After Rebuild

⚠️ If network fails after rebuild, you likely have wrong location setting:

```bash
# Check current location in config
grep "location =" ~/nixcfg/hosts/hsb8/configuration.nix

# ww87 = parents' home (gateway 192.168.1.1)
# jhw22 = Markus' home (gateway 192.168.1.5)
```

---

## Emergency Recovery

### If SSH Fails

1. Physical access to Mac mini required
2. Connect keyboard and monitor
3. Login as `mba` or `gb`

### Restore from Generation

```bash
# List available generations
sudo nix-env --list-generations -p /nix/var/nix/profiles/system

# Switch to specific generation
sudo nix-env --switch-generation N -p /nix/var/nix/profiles/system
sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
```

---

## Services

### AdGuard Home (when at ww87)

| Item             | Value                         |
| ---------------- | ----------------------------- |
| **Web UI**       | http://192.168.1.100:3000     |
| **DNS Port**     | 53                            |
| **DHCP Range**   | 192.168.1.200-254             |
| **DHCP Gateway** | 192.168.1.1                   |
| **Upstream DNS** | 1.1.1.1, 1.0.0.1 (Cloudflare) |

### Docker

- Ready for Home Assistant and related services
- Gerhard (`gb`) user has Docker access
- Configuration expected at: `/home/gb/docker/docker-compose.yml`

---

## Maintenance

### Clean Up Disk Space

```bash
ssh mba@192.168.1.100 "cd ~/nixcfg && just cleanup"
```

### ZFS Scrub

```bash
ssh mba@192.168.1.100 "sudo zpool scrub zroot"
```

### View Logs

```bash
# Current boot
ssh mba@192.168.1.100 "journalctl -b -e"

# Follow logs
ssh mba@192.168.1.100 "journalctl -f"
```

---

## User Access

| User  | Role                | SSH Key          |
| ----- | ------------------- | ---------------- |
| `mba` | Admin (Markus)      | Personal RSA key |
| `gb`  | Secondary (Gerhard) | Personal RSA key |

Both users have passwordless sudo.

---

## Related Documentation

- [hsb8 README](../README.md) - Full server documentation
- [SECRETS.md](../secrets/SECRETS.md) - All credentials (gitignored)
- [enable-ww87.md](./enable-ww87.md) - Location switching guide
- [hsb0 Runbook](../../hsb0/docs/RUNBOOK.md) - DNS server at Markus' home
