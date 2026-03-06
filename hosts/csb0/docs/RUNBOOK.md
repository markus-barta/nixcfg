# Runbook: csb0 (Smart Home Hub)

**Host**: csb0 (cs0.barta.cm / 89.58.63.96)  
**Role**: Smart Home Hub & IoT Automation Platform  
**Criticality**: HIGH - Smart home + backup manager for BOTH csb0 and csb1  
**Provider**: Netcup VPS (New Server 2026-01-10)

---

## Quick Connect

```bash
# Via alias
qc0

# Direct SSH
ssh mba@cs0.barta.cm -p 2222

# With IP
ssh mba@89.58.63.96 -p 2222
```

---

## Quick Reference Card

```
╔════════════════════════════════════════════════════════════╗
║ 🌀 csb0 - Smart Home Hub Emergency Reference               ║
╠════════════════════════════════════════════════════════════╣
║ SSH:       ssh mba@cs0.barta.cm -p 2222                    ║
║ IP:        89.58.63.96                                     ║
║ Netcup:    Customer # 227044 (2FA required)                ║
║ VNC:       servercontrolpanel.de/SCP                       ║
╠════════════════════════════════════════════════════════════╣
║ 🌐 SERVICES                                                ║
║ • Node-RED:    https://home.barta.cm                       ║
║ • Bitwarden:   https://bitwarden.barta.cm (TEST ONLY)      ║
║ • Headscale:   https://hs.barta.cm (VPN control)           ║
║ • MQTT:        mosquitto.barta.cm:8883 (TLS)               ║
║ • Telegram:    t.me/csb0bot                                ║
╠════════════════════════════════════════════════════════════╣
║ ⚠️ CRITICAL SERVICES                                       ║
║ • MQTT (mosquitto) → Feeds csb1 InfluxDB!                  ║
║ • Node-RED → Garage door control for family/neighbors!     ║
║ • Telegram bot → Smart home notifications & control        ║
║ • Backup cleanup → Manages BOTH csb0 and csb1!             ║
╠════════════════════════════════════════════════════════════╣
║ 🚨 IF DOWN                                                 ║
║ 1. SSH check: ssh mba@cs0.barta.cm -p 2222                 ║
║ 2. VNC console via Netcup SCP (if SSH fails)               ║
║ 3. Restore from backup (< 2h)                              ║
╚════════════════════════════════════════════════════════════╝
```

---

## Health Checks

### Quick Status

```bash
# One-liner: container count, disk usage, load
ssh mba@cs0.barta.cm -p 2222 "docker ps | wc -l && df -h / | tail -1 && uptime"
# Expected: 10 containers, <20% disk, load <1.0

# Check container health
ssh mba@cs0.barta.cm -p 2222 "docker ps --filter 'status=exited'"
# Should be empty (all running)

# Check services responding
curl -I https://home.barta.cm  # Node-RED (expect 200)
curl -I https://bitwarden.barta.cm  # Bitwarden (expect 200)
```

---

## Common Tasks

### Update & Switch Configuration

```bash
# Local
just build-host csb0
git push

# Remote
ssh mba@cs0.barta.cm -p 2222
cd ~/Code/nixcfg
git pull
just switch
```

### Docker Management

```bash
cd ~/Code/nixcfg/hosts/csb0/docker
docker-upf  # Custom fish abbreviation for force-recreate
```

---

## 🏗️ Uzumaki & Hokage Pattern

`csb0` is an **External Hokage Consumer**. It consumes the base server configuration from the global `hokage` module but applies local customizations via the `uzumaki` namespace.

- **Status**: Enabled (`uzumaki.enable = true`)
- **Role**: `server`
- **Indicator**: The `nixbit` command should be available and working.

---

## Docker Services

### Configuration & Data Paths

| Component        | Path                                                 |
| :--------------- | :--------------------------------------------------- |
| **Compose File** | `~/Code/nixcfg/hosts/csb0/docker/docker-compose.yml` |
| **Config (Git)** | `~/Code/nixcfg/hosts/csb0/docker/`                   |
| **Data (ZFS)**   | `/var/lib/csb0-docker/`                              |
| **Secrets**      | `/run/agenix/`                                       |

### All Containers

| Container                  | Purpose                          | Data Path (ZFS)                    |
| -------------------------- | -------------------------------- | ---------------------------------- |
| csb0-mosquitto-1           | MQTT broker (CRITICAL)           | `/var/lib/csb0-docker/mosquitto`   |
| csb0-nodered-1             | Smart home automation (CRITICAL) | `/var/lib/csb0-docker/nodered`     |
| csb0-traefik-1             | Reverse proxy                    | `/var/lib/csb0-docker/traefik`     |
| csb0-uptime-kuma-1         | Monitoring                       | `/var/lib/csb0-docker/uptime-kuma` |
| headscale                  | VPN control server (Tailscale)   | Docker volume `headscale-data`     |
| csb0-restic-cron-hetzner-1 | Backup manager                   | -                                  |

### Backup & Restore Logic

1. **Cold Backups**: Stop containers before backup to ensure DB consistency.
2. **Path Mapping**: Restic `/backup/home/mba/docker/` maps to `/var/lib/csb0-docker/`.
3. **Secrets**: Managed via `agenix` Tier 1. Decrypted to `/run/agenix/`.

### Quick Commands

```bash
# View all containers
docker ps -a

# Restart a container
docker-upf  # (Force all) OR
docker restart <container-name>

# View logs
docker logs csb0-nodered-1 --tail 50
docker logs csb0-mosquitto-1 --tail 50
```

---

## Troubleshooting

### Decision Tree

```
Service Not Responding?
├─ Can SSH?
│  ├─ YES: Docker/service issue
│  │  ├─ docker ps → container running?
│  │  │  ├─ YES: Check logs: docker logs <container>
│  │  │  └─ NO: Start it: cd ~/Code/nixcfg/hosts/csb0/docker && docker compose up -d
│  │  └─ Docker down? systemctl status docker
│  └─ NO: Server/network issue
│     ├─ Can ping 89.58.63.96?
│     │  ├─ YES: SSH service down → Use VNC console
│     │  └─ NO: Server down → Check Netcup panel
│     └─ Last resort: VNC console (Netcup SCP)
```

### Common Issues & Quick Fixes

```
Node-RED down → docker restart csb0-nodered-1
MQTT down → docker restart csb0-mosquitto-1 (⚠️ affects csb1!)
Headscale down → docker restart headscale (VPN clients reconnect automatically)
Backup failed → docker logs csb0-restic-cron-hetzner-1
Telegram bot → Re-register webhook (see SECRETS.md for token)
High load → Check docker stats (find heavy container)
SSL Error 526 (Cloudflare) → CF API token expired; rotate via csb1 RUNBOOK procedure
```

---

## 🚨 Disaster Recovery: ZFS Boot Loop (hostid mismatch)

If the server fails to boot with `cannot import 'zroot': pool was previously in use from another system`, follow these steps exactly:

### 1. Preparation

1. Download the ISO from this URL: https://nixos.org/download/ (eg. https://channels.nixos.org/nixos-25.11/latest-nixos-minimal-x86_64-linux.iso)
1. **Netcup SCP** -> **Media** -> **DVD Drive**.
1. **Upload custom ISO** (downloaded in step 1)
1. **Attach** the ISO and **Boot from DVD**.
1. **Start** the server.

### 2. The Fix (NixOS Shell)

Once the NixOS live environment boots to a prompt:

```bash
sudo -i
partprobe             # Ensure disks are scanned
zpool import -f zroot # Force import to reset the hostid lock
zpool export zroot    # Cleanly export to stamp it as safe
poweroff              # Shut down to safely detach DVD
```

### 3. Cleanup

1.  Wait for the server to reach "Offline" status in Netcup SCP.
2.  **Detach the DVD** or set **Boot Mode** back to **Hard Disk**.
3.  **Start** the server.

---

## Emergency Recovery

### Access Priority

1. **Primary**: SSH with key (`~/.ssh/id_rsa`)
2. **Backup**: SSH with mba password (see 1Password: "csb0 csb1 recovery")
3. **Emergency**: Netcup VNC console + mba password
4. **Recovery**: Netcup control panel access (with 2FA)

### Recovery Password

The `mba` user has a `hashedPassword` set in `configuration.nix` for emergency
VNC console access. Password stored in 1Password under "csb0 csb1 recovery".

### Network Configuration

| Setting   | Value                                  |
| --------- | -------------------------------------- |
| Static IP | `89.58.63.96/22`                       |
| Gateway   | `89.58.60.1`                           |
| DNS       | `46.38.225.230`, `46.38.252.230`       |
| MAC       | `2A:E3:9B:5B:92:23`                    |
| Interface | `ens3` (NixOS) / `eth0` (Ubuntu/Kexec) |

⚠️ **CRITICAL**: The interface is named `eth0` during the initial Ubuntu install and `nixos-anywhere` kexec phase, but renames to `ens3` once NixOS is fully booted. Both are listed in `networking.networkmanager.unmanaged` to prevent lockout.

### 🚨 Historical Incident: 2026-01-16 Old Server Decommissioned

**Event:** The old `csb0` server (`85.235.65.226`) was successfully decommissioned on Friday, 2026-01-16, following the migration to the new hardware (`89.58.63.96`).
**Action:** All DNS records and services have been transitioned. Documentation has been updated to reflect the new IP.

### 🚨 Historical Incident: 2026-01-10 Migration Lockout Prevention

**Symptom:** Potential lockout due to interface name mismatch (`eth0` vs `ens3`).
**Root Cause:** Ubuntu Minimal uses legacy naming; NixOS uses predictable naming.
**Fix:** Explicitly configure `ens3` but unmanage both names in NetworkManager. Verify `hostId` from `/etc/machine-id`.

### 🚨 Historical Incident: 2025-12-06 Network Lockout

**Symptom:** Server became unreachable immediately after `nixos-rebuild switch`.
**Root Cause:** The configuration assumed a `/24` subnet and a gateway at `.65.1` (based on `csb1` patterns). However, `csb0` is on a `/22` network where the gateway is at the start of the range: `85.235.64.1`.
**VNC Recovery Note:** The Netcup VNC console has severe keyboard mapping issues. Colons `:`, hyphens `-`, and pipes `|` often cannot be typed.
**Fix:** Always verify gateway via DHCP (`journalctl` or `ip route`) before applying static IP config.

### If SSH Fails

1. Login to Netcup SCP (<https://www.servercontrolpanel.de/SCP>)
2. Navigate to server, open VNC console
3. Login as `mba` with recovery password (see 1Password)

### VNC Console Recovery (Netcup)

⚠️ **Netcup VNC has German keyboard layout issues!**

**Keys that WORK:**

- Letters (a-z, A-Z), Numbers (0-9)
- Forward slash `/`, Period `.`, Spaces
- Dollar `$`, Parentheses `()`, Equals `=`, Underscore `_`
- Arrow keys, Tab completion (in bash, NOT busybox)

**Keys that DO NOT WORK:**

- Hyphen `-` (critical for commands!)
- Backslash `\`, Colon `:`, Pipe `|`

**If login prompt works** → Use mba password from 1Password

**If login broken** → Use `init=/bin/sh` recovery:

1. Reboot via Netcup panel
2. At GRUB, press `e` to edit boot entry
3. Add `init=/bin/sh` to end of linux line
4. Press Ctrl+X to boot
5. In minimal shell (`sh-5.3#`), find tools with glob:

```bash
# Find password tool
echo /nix/store/*shadow*/bin/passwd
# Example: /nix/store/117zjnjzaw0n22z0xinp17qpbdv3wsra-shadow-4.18.0/bin/passwd

# Set password (use Tab completion after partial path)
/nix/store/117z[Tab]/bin/passwd mba

# Find network tools
echo /nix/store/*iproute*/bin/ip

# Configure network (adjust path with Tab)
/nix/store/m1b[Tab]/bin/ip addr add 89.58.63.96/22 dev ens3
/nix/store/m1b[Tab]/bin/ip link set ens3 up
/nix/store/m1b[Tab]/bin/ip route add default via 89.58.60.1

# Continue normal boot
exec /nix/var/nix/profiles/system/init
```

**Note:** Busybox ash shell is worse than bash (no arrow-up, no Tab). If you accidentally enter it, type `exit` to return to bash.

### Netcup API Emergency Restart

```bash
# Get token and restart (see SECRETS.md for refresh token location)
TOKEN=$(curl -s 'https://servercontrolpanel.de/realms/scp/protocol/openid-connect/token' \
  -d 'client_id=scp' -d "refresh_token=$(cat ~/Code/nixcfg/hosts/csb0/secrets/netcup-api-refresh-token.txt)" \
  -d 'grant_type=refresh_token' | jq -r '.access_token') && \
  curl -X POST "https://servercontrolpanel.de/scp-core/api/v1/servers/607878/reset" \
  -H "Authorization: Bearer $TOKEN"
```

---

## Backup System

### 🚨 CRITICAL: csb0 is the Cleanup Manager

**⚠️ csb0 manages cleanup for BOTH csb0 and csb1 backups!**

- Both servers backup to the same Hetzner repository
- csb0 runs cleanup at 03:15 AM daily
- csb1's cleanup script exits early and defers to csb0

### Schedule

| Task    | Time                   | Container                  |
| ------- | ---------------------- | -------------------------- |
| Backup  | 01:30 AM daily         | csb0-restic-cron-hetzner-1 |
| Cleanup | 03:15 AM daily         | csb0-restic-cron-hetzner-1 |
| Check   | 05:30 AM monthly (1st) | csb0-restic-cron-hetzner-1 |

### What Gets Backed Up

```
✅ /var/lib/csb0-docker - ALL Docker volumes & data
✅ /home/mba/Code/nixcfg - System configuration (via git)
✅ /root - Root user data
✅ /etc - System configuration
❌ Exclusions: */cache/*, *.log*
```

### Check Backup Status

```bash
# View logs
docker logs csb0-restic-cron-hetzner-1 | tail -50

# List snapshots (see SECRETS.md for repository details)
docker exec csb0-restic-cron-hetzner-1 restic snapshots
```

---

## Service Dependencies

```
IoT Devices → MQTT (csb0) → InfluxDB (csb1) → Grafana (csb1)
            ↓
     Node-RED (csb0) → Telegram Bot → Users
            ↓
    Smart Home Controls
```

**⚠️ If csb0 MQTT is down, csb1's InfluxDB stops receiving IoT data!**

---

## Telegram Bot Architecture

### Bots Overview

| Bot              | Username              | Purpose                                     | Token Location                      |
| ---------------- | --------------------- | ------------------------------------------- | ----------------------------------- |
| **Building Bot** | `@janischhofweg22bot` | Smart home control (garage, doors, cameras) | `JHW22_BOT_TOKEN` in `telegram.env` |
| **CSB0 Bot**     | `@csb0bot`            | Legacy/test bot (NOT actively used)         | `CSB0_BOT_TOKEN` in `telegram.env`  |

### Active Bot: @janischhofweg22bot

This is the **production bot** used by building residents for:

- `/zufahrt` - Open driveway gate
- `/smartlock` - Control door lock
- `/keller` - Access cellar
- `/kamera` - View camera feeds
- `/pp20ein`, `/pp20aus` - Parking space controls

**User permissions** are defined in Node-RED flows (`flows.json` → `userConfig` object) by Telegram user ID.

### Cross-Server Communication

Both `csb0` and `hsb1` use the SAME `@janischhofweg22bot` token:

- **CSB0**: Handles interactive commands (via Node-RED Telegram nodes).
- **HSB1**: Sends notifications via Apprise (one-way).

---

## Headscale (VPN Control Server)

Self-hosted Tailscale control server. Manages mesh VPN for all infrastructure hosts.

- **URL**: <https://hs.barta.cm>
- **Container**: `headscale`
- **Config**: `~/Code/nixcfg/hosts/csb0/docker/headscale/config/config.yaml`
- **Data**: Docker volume `headscale-data` (SQLite DB + private keys)
- **DNS**: `hs.barta.cm` must be **DNS-only** in Cloudflare (NOT proxied - breaks WebSocket POSTs)

### Common Commands

```bash
# List users
docker exec headscale headscale users list

# List connected nodes
docker exec headscale headscale nodes list

# Create new user
docker exec headscale headscale users create <username>

# Generate pre-auth key (reusable, 24h expiry)
docker exec headscale headscale preauthkeys create --user <username> --reusable --expiration 24h

# Generate long-lived pre-auth key (store in 1Password!)
docker exec headscale headscale preauthkeys create --user <username> --reusable --expiration 87600h

# List existing pre-auth keys
docker exec headscale headscale preauthkeys list --user <username>

# Check config validity
docker exec headscale headscale configtest

# View logs
docker logs headscale --tail 50
```

### Connect a New Device

> **Note:** The `--authkey` does NOT need a `--user` flag on the client side.
> The user is baked into the pre-auth key at creation time (`--user <username>`).
> Any device registering with that key automatically belongs to that user.

```bash
# macOS (use the .app CLI, NOT brew's tailscale)
/Applications/Tailscale.app/Contents/MacOS/Tailscale up --login-server https://hs.barta.cm --authkey <KEY>

# NixOS (requires services.tailscale.enable = true in configuration.nix)
sudo tailscale up --login-server https://hs.barta.cm --authkey <KEY>

# Linux (generic)
tailscale up --login-server https://hs.barta.cm --authkey <KEY>
```

**Prerequisites per platform:**

- **macOS**: Tailscale.app installed and running
- **NixOS**: Add `services.tailscale.enable = true;` to host config, deploy first

### Troubleshooting

```
Headscale unhealthy → docker logs headscale (check for DB or config errors)
TLS cert missing → Check Cloudflare DNS is DNS-only (gray cloud); restart Traefik
Nodes can't connect → Verify hs.barta.cm resolves to 89.58.63.96 (not Cloudflare IP)
After restart → Nodes reconnect automatically (no action needed)
```

---

## Maintenance

### Clean Up Disk Space

```bash
ssh mba@cs0.barta.cm -p 2222 "docker system prune -f"
```

### View Logs

```bash
# Current boot
ssh mba@cs0.barta.cm -p 2222 "journalctl -b -e"

# Follow logs
ssh mba@cs0.barta.cm -p 2222 "journalctl -f"
```

---

## Web Interfaces

| Service   | URL                                      |
| --------- | ---------------------------------------- |
| Node-RED  | <https://home.barta.cm>                  |
| Bitwarden | <https://bitwarden.barta.cm> (TEST ONLY) |
| Headscale | <https://hs.barta.cm>                    |
| MQTT      | mosquitto.barta.cm:8883 (TLS)            |

---

## Related Documentation

- [csb0 README](../README.md) - Full server documentation
- [SECRETS.md](../../docs/SECRETS.md) - All credentials (gitignored)
- [csb1 Runbook](../../csb1/docs/RUNBOOK.md) - Monitoring server
