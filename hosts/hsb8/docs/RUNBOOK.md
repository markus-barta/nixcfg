# Runbook: hsb8 (Parents' Home Server)

**Host**: hsb8 (192.168.1.100)  
**Role**: DNS/DHCP (AdGuard Home) + Home Automation at parents' home  
**Location**: ww87 (parents' home) - currently configured for this location  
**Criticality**: MEDIUM - Parents' network infrastructure  
**Owner**: Gerhard (gb) - primary admin when Markus is unavailable

---

## Quick Connect

```bash
# At ww87 (parents' home), prefer gb user (primary operator for HA/Docker)
ssh gb@192.168.1.100
ssh gb@hsb8.lan

# Accessing Home Assistant Config (on hsb8)
# Path: /srv/hsb8/mounts/homeassistant/configuration.yaml
# Note: File is owned by root, use 'sudo' for edits.
# Backups: ./Archive/
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
║ • HostDash:       http://192.168.1.100                     ║
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
# jhw22 = Markus' home (gateway 192.168.1.1 since the Starlink/Omada migration)
```

---

## Emergency Recovery

### If SSH Fails

1. Physical access to Mac mini required
2. Connect keyboard and monitor
3. Login as `gb` (preferred primary user) or `mba` (if needed for admin tasks)

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
| **DHCP Range**   | 192.168.1.225-254             |
| **DHCP Gateway** | 192.168.1.1                   |
| **Upstream DNS** | 1.1.1.1, 1.0.0.1 (Cloudflare) |

### Docker

- Gerhard (`gb`) user has Docker access
- Configuration: **declarative** — `hosts/hsb8/docker/compose-spec.nix` in nixcfg,
  rendered into the system closure and reconciled by `compose-hsb8.service`.
  Never hand-edit compose on the host.
- Data lives under `/srv/hsb8/mounts/` (NIX-236 moved it off `/home/gb`).
  `/home/gb/docker/` is **retired and gone** — if a doc still points there, it is stale.

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
# - hsb8-home (HostDash nginx)
# - pharos-beacon (fleet reporting, outbound only)
# - restic-cron-hetzner (backups)
#
# NOT watchtower. It was retired and is actively reaped by
# composeStack removeOrphans = true. If it ever reappears, something
# is running an unmanaged compose file.
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

Installed custom integrations are in `/srv/hsb8/mounts/homeassistant/custom_components/`:

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

| User  | Role                             | SSH Key          | Telegram Chat ID |
| ----- | -------------------------------- | ---------------- | ---------------- | ------------------------------------- |
| `gb`  | Owner/Primary Operator (Gerhard) | Personal RSA key | 873192422        | # Preferred for ww87 ops (HA/Docker)  |
| `mba` | Secondary Admin (Markus)         | Personal RSA key | 855566964        | # Backup access; check keys if denied |

Both users have passwordless sudo.

---

## Container updates — and the notification gap

Watchtower is **retired**. It is gone from the host (no container, not even
stopped) and its env file `/home/gb/secrets/watchtower.env` no longer exists.
`composeStack.removeOrphans = true` actively reaps it, so it cannot drift back.

Updates now run declaratively:

|             |                                                                                   |
| ----------- | --------------------------------------------------------------------------------- |
| Unit        | `compose-hsb8-update.service` (OPS-125) — pulls newer images, converges the stack |
| Schedule    | `compose-hsb8-update.timer`, weekly (Sat ~05:05)                                  |
| Declared in | `hosts/hsb8/configuration.nix` → `composeStack.autoUpdate.enable = true`          |

```bash
systemctl list-timers compose-hsb8-update.timer --no-pager
systemctl status compose-hsb8-update.service --no-pager | tail -20
journalctl -u compose-hsb8-update.service --since '2 weeks ago' | tail -40
```

> 🟡 **Decision (NIX-385): keep this updater intentionally silent for now.**
> `autoUpdate` sends no Telegram, mail or ntfy notification. hsb8 has no
> host-scoped outbound notification transport: its backup reports through a
> Pharos status file, while the Telegram bot is owned remotely by csb0. Reusing
> either path here would widen secret access or couple this family server to a
> different host. A failed update remains durable and visible as a failed
> systemd unit; it is not converted into success. Check the unit journal after
> the Saturday run.

Revisit this decision when a reviewed fleet-wide host-alert transport exists,
or before increasing the update cadence. At that point, add failure-only
delivery without exposing container environment files to the host service.

The `@janischhofweg22bot` Telegram bot still exists and is managed from csb0
Node-RED, but it is no longer fed by container updates. Treat any doc claiming
"Watchtower sends update notifications" as stale.

If the token itself ever needs replacing, rotate it in BotFather and write the new
value straight into the file with `sudo -e` — never via a command line that would
land in history.

---

## Related Documentation

- [NETWORK.md](./NETWORK.md) - ww87 network topology, device inventory, Orbi mesh, diagnostic playbook
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
- **jhw22 (Markus)**: Gateway `192.168.1.1` (was `.5` pre-Starlink) — DNS/AdGuard
  still differ between locations, which is what makes the switch necessary
  **Fix:** Run `enable-ww87` at the physical console after transport to apply location-specific networking.

---

## 📋 Deployment & Initial Setup

### Phase 1: Configuration Switch

If moving the server between locations:

1. Log in at console as `mba`.
2. Run: `enable-ww87` (one-command deployment).
3. Wait for configuration to apply (~2-3 minutes).
4. Network will reconfigure (may lose console connection briefly).

### Phase 2: DHCP state

✅ **hsb8 IS the ww87 DHCP server** — takeover from the old router
completed months ago (declared `dhcp.enabled = true` in
`configuration.nix`; confirmed live 2026-07-04, NIX-215 fleet rebuild).

If relocating to a site with an existing DHCP server, disable FIRST:

1. Edit `hosts/hsb8/configuration.nix`.
2. Set `services.adguardhome.settings.dhcp.enabled = false;`.
3. `just switch`.
4. Verify DHCP is gone: `ss -ulnp | grep :67` (no listener).

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
