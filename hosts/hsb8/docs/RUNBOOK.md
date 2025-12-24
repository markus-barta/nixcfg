# Runbook: hsb8 (Parents' Home Server)

**Host**: hsb8 (192.168.1.100)  
**Role**: DNS/DHCP (AdGuard Home) + Home Automation at parents' home  
**Location**: ww87 (parents' home) - currently configured for this location  
**Criticality**: MEDIUM - Parents' network infrastructure  
**Owner**: Gerhard (gb) - primary admin when Markus is unavailable

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
║ • Home Assistant: http://192.168.1.100:8123                ║
║ • AdGuard Home:   http://192.168.1.100:3000                ║
║ • DNS Server:     192.168.1.100:53                         ║
║ • Zigbee2MQTT:    http://192.168.1.11:8085 (external)      ║
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

- Gerhard (`gb`) user has Docker access
- Configuration: `/home/gb/docker/docker-compose.yml`

### Home Assistant (Deployed 2025-12-21)

| Item                    | Value                                  |
| ----------------------- | -------------------------------------- |
| **Web UI**              | http://192.168.1.100:8123              |
| **User**                | gb (primary operator)                  |
| **MQTT Broker**         | External: 192.168.1.11:1883 (z2m host) |
| **Zigbee2MQTT**         | External: http://192.168.1.11:8085     |
| **Custom Integrations** | HACS, Kostal Piko, Tesla Custom        |

#### Docker Containers

```bash
# Check status
ssh mba@192.168.1.100 "docker ps --format 'table {{.Names}}\t{{.Status}}'"

# Expected containers:
# - homeassistant (HA core)
# - mosquitto (local MQTT, may be unused)
# - watchtower (auto-updates, Saturdays 08:00)
```

#### Integrations Configured

| Integration  | Purpose                       | Config Method             |
| ------------ | ----------------------------- | ------------------------- |
| MQTT         | Zigbee devices via z2m        | UI (broker: 192.168.1.11) |
| Zigbee2MQTT  | z2m UI integration            | HACS + UI                 |
| Kostal Piko  | Solar inverter (192.168.1.20) | YAML                      |
| Tesla Custom | Tesla vehicle                 | HACS + UI                 |
| Tasmota      | Smart plugs/switches          | Auto-discovered via MQTT  |

#### HA Logs

```bash
# View logs
ssh mba@192.168.1.100 "docker logs homeassistant --tail 50"

# Follow logs
ssh mba@192.168.1.100 "docker logs -f homeassistant"

# Restart HA
ssh mba@192.168.1.100 "docker restart homeassistant"
```

#### HACS

Installed custom integrations are in `/home/gb/docker/mounts/homeassistant/custom_components/`:

- `hacs` - Home Assistant Community Store
- `kostal` - Kostal Piko solar inverter
- `tesla_custom` - Tesla vehicle integration

To install new integrations: HACS → Integrations → Explore & Download

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

| User  | Role                     | SSH Key          | Telegram Chat ID |
| ----- | ------------------------ | ---------------- | ---------------- |
| `mba` | Secondary Admin (Markus) | Personal RSA key | 855566964        |
| `gb`  | Owner/Primary (Gerhard)  | Personal RSA key | 873192422        |

Both users have passwordless sudo.

---

## Telegram Notifications

Watchtower sends container update notifications to both users via the `janischhofweg22bot`.

**Bot**: @janischhofweg22bot (managed from csb0 Node-RED)

| Recipient | Chat ID   | Receives                    |
| --------- | --------- | --------------------------- |
| Gerhard   | 873192422 | Watchtower updates (owner)  |
| Markus    | 855566964 | Watchtower updates (backup) |

### Manual Test Notification

To verify notifications work:

```bash
# From csb0 (where the bot runs)
curl -s "https://api.telegram.org/bot<TOKEN>/sendMessage?chat_id=873192422&text=Test%20from%20hsb8"
```

### Configuration

Watchtower env file: `/home/gb/secrets/watchtower.env`

```bash
# View current config
ssh mba@hsb8.lan "sudo cat /home/gb/secrets/watchtower.env"

# Add/remove recipients: edit the channels= parameter (comma-separated chat IDs)
```

---

## Related Documentation

- [hsb8 README](../README.md) - Full server documentation
- [ip-100.md](../ip-100.md) - Identity Card (Static IP, MAC, Gateway)
- [SECRETS.md](../secrets/SECRETS.md) - All credentials (gitignored)
- [enable-ww87.md](./enable-ww87.md) - Location switching guide
- [hsb0 Runbook](../../hsb0/docs/RUNBOOK.md) - DNS server at Markus' home

---

## 🔴 Critical Known Issues (Gotchas)

### 🚨 Historical Incident: 2025-11-22 SSH Lockout

**Symptom:** Complete loss of SSH access after reboot.
**Root Cause:** When migrating to the "External Hokage Consumer" pattern, the default hokage configuration injected external developer keys (omega@\*) and removed local authorized keys.
**Impact:** Required physical console access to recover.
**Fix:** Always use `lib.mkForce` for `users.users.<name>.openssh.authorizedKeys.keys` to block external key injection.
**Security Policy:** Familly servers (`hsb0`, `hsb8`) MUST NOT allow external developer keys.

### 📍 Location Switching (ww87 ↔ jhw22)

**Symptom:** Server reachable via IP but no internet/DNS after transport.
**Cause:** Gateway and DNS settings differ between locations.

- **ww87 (Parents)**: Gateway `192.168.1.1`
- **jhw22 (Markus)**: Gateway `192.168.1.5`
  **Fix:** Run `enable-ww87` at the physical console after transport to apply location-specific networking.

---

## 📋 Deployment & Initial Setup

### Phase 1: Configuration Switch

If moving the server between locations:

1. Log in at console as `mba`.
2. Run: `enable-ww87` (one-command deployment).
3. Wait for configuration to apply (~2-3 minutes).
4. Network will reconfigure (may lose console connection briefly).

### Phase 2: DHCP Activation

⚠️ **DHCP is disabled by default for safety.**
When ready to take over DHCP from an old router/Pi-hole:

1. Edit `hosts/hsb8/configuration.nix`.
2. Set `services.adguardhome.settings.dhcp.enabled = true;`.
3. `just switch`.
4. Verify with `ss -ulnp | grep :67`.

---

## 🔐 Handover Inventory (2025-11-23)

| Service        | Port | URL / Access                        |
| -------------- | ---- | ----------------------------------- |
| AdGuard Home   | 3000 | http://192.168.1.100:3000           |
| Home Assistant | 8123 | http://192.168.1.100:8123           |
| Zigbee2MQTT    | 8085 | http://192.168.1.11:8085 (external) |
| SSH (mba/gb)   | 22   | ssh 192.168.1.100                   |

### System Stats

- **Storage**: ZFS (zroot) on 120GB SSD (~7% used).
- **Users**: `mba` (admin), `gb` (Gerhard/Owner).
- **Backup**: 15+ generations for rollback.
