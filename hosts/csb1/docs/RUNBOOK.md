# Runbook: csb1 (Monitoring & Documentation Server)

**Host**: csb1 (cs1.barta.cm / 152.53.64.166)  
**Role**: Monitoring, Metrics & Documentation Platform  
**Criticality**: MEDIUM - Monitoring dashboards, document management  
**Provider**: Netcup VPS 1000 G11 (Vienna)

---

## Quick Connect

```bash
# Via alias
qc1

# Direct SSH
ssh mba@cs1.barta.cm -p 2222

# With IP
ssh mba@152.53.64.166 -p 2222
```

---

## Quick Reference Card

```
╔════════════════════════════════════════════════════════════╗
║ 🌀 csb1 - Monitoring & Docs Emergency Reference            ║
╠════════════════════════════════════════════════════════════╣
║ SSH:       ssh mba@cs1.barta.cm -p 2222                    ║
║ IP:        152.53.64.166                                   ║
║ Netcup:    Customer # 227044 (2FA required)                ║
║ VNC:       servercontrolpanel.de/SCP                       ║
╠════════════════════════════════════════════════════════════╣
║ 🌐 SERVICES                                                ║
║ • PAIMOS (PM): https://pm.barta.cm                         ║
║ • Grafana:     https://grafana.barta.cm                    ║
║ • InfluxDB:    http://influxdb.barta.cm:8086               ║
║ • Paperless:   https://paperless.barta.cm                  ║
║ • Docmost:     https://docmost.barta.cm                    ║
║ • Excalidraw:  https://draw.barta.cm                       ║
╠════════════════════════════════════════════════════════════╣
║ ⚠️  CRITICAL DEPENDENCIES                                  ║
║ • InfluxDB → Depends on csb0's MQTT!                       ║
║ • Cleanup → Managed by csb0 (not here!)                    ║
╠════════════════════════════════════════════════════════════╣
║ 🚨 IF DOWN                                                 ║
║ 1. SSH check: ssh mba@cs1.barta.cm -p 2222                 ║
║ 2. VNC console via Netcup SCP (if SSH fails)               ║
║ 3. Restore from backup (< 2h)                              ║
╚════════════════════════════════════════════════════════════╝
```

---

## Health Checks

### Quick Status

```bash
# One-liner: container count, disk usage, load
ssh mba@cs1.barta.cm -p 2222 "docker ps | wc -l && df -h / | tail -1 && uptime"
# Expected: 16 containers, <50% disk, load <1.0

# Check container health
ssh mba@cs1.barta.cm -p 2222 "docker ps --filter 'status=exited'"
# Should be empty (all running)

# Check services responding
curl -I https://grafana.barta.cm  # Grafana (expect 302 redirect)
curl -I https://paperless.barta.cm  # Paperless (expect 200)
curl -I https://docmost.barta.cm  # Docmost (expect 200)
curl -I https://draw.barta.cm  # Excalidraw (expect 200)
```

---

## Common Tasks

### Update & Switch Configuration

```bash
ssh mba@cs1.barta.cm -p 2222
cd ~/nixcfg  # or ~/Code/nixcfg
git pull
just switch
```

### Rollback to Previous Generation

```bash
ssh mba@cs1.barta.cm -p 2222
sudo nixos-rebuild switch --rollback
```

---

## 🏗️ Uzumaki & Hokage Pattern

`csb1` is an **External Hokage Consumer**. It consumes the base server configuration from the global `hokage` module but applies local customizations via the `uzumaki` namespace.

- **Status**: Enabled (`uzumaki.enable = true`)
- **Role**: `server`
- **Indicator**: The `nixbit` command should be available and working.

---

## NixFleet Dashboard (DECOMMISSIONED)

NixFleet has been decommissioned (DSC26-53). Successor: **FleetCom** (DSC26-52).

**To fully remove**: stop the nixfleet container on csb1 and comment out in docker-compose.yml:

```bash
ssh mba@cs1.barta.cm -p 2222 "cd ~/docker && docker compose stop nixfleet"
# Then comment out nixfleet service in ~/docker/docker-compose.yml
```

---

## Docker Services

### All Containers (15 running)

| Container                   | Purpose                    |
| --------------------------- | -------------------------- |
| csb1-grafana-1              | Monitoring dashboards      |
| csb1-influxdb-1             | Time-series database       |
| csb1-docmost-1              | Documentation wiki         |
| csb1-docmost-db-1           | PostgreSQL for Docmost     |
| csb1-docmost-redis-1        | Redis cache                |
| csb1-paperless-1            | Document management        |
| csb1-paperless-db-1         | PostgreSQL for Paperless   |
| csb1-paperless-redis-1      | Redis                      |
| csb1-paperless-tika-1       | Document parsing           |
| csb1-paperless-gotenberg-1  | PDF conversion             |
| csb1-traefik-1              | Reverse proxy              |
| csb1-docker-proxy-traefik-1 | Traefik proxy              |
| csb1-restic-cron-hetzner-1  | Backup (cleanup on csb0!)  |
| csb1-smtp-1                 | Mail relay                 |
| csb1-whoami-1               | Test service               |
| csb1-excalidraw-1           | Whiteboard (draw.barta.cm) |
| ppm                         | PAIMOS PM (pm.barta.cm)    |
| minio                       | S3 for ppm attachments     |
| paimos-www                  | paimos.com static (caddy)  |

### Quick Commands

```bash
# View all containers
docker ps -a

# Restart a container
docker restart csb1-grafana-1
docker restart csb1-influxdb-1
docker restart csb1-paperless-1

# View logs
docker logs csb1-grafana-1 --tail 50
docker logs csb1-influxdb-1 --tail 50

# Restart all services
cd ~/docker && docker-compose down && docker-compose up -d
```

### Upgrade PAIMOS (pm.barta.cm)

Image source: `ghcr.io/markus-barta/paimos:latest` (published by the
`ci.yml` workflow on every push to main).

```bash
# On csb1 — safety backup first, then pull + swap:
ssh mba@cs1.barta.cm -p 2222
TS=$(date +%Y-%m-%d-%H%M)
mkdir -p ~/backups/paimos-$TS
docker save ghcr.io/markus-barta/paimos:latest | gzip > ~/backups/paimos-$TS/paimos-latest.tar.gz
docker run --rm -v ppm_data:/data -v ~/backups/paimos-$TS:/backup alpine \
  tar czf /backup/ppm_data.tar.gz -C /data .

# Pull + recreate:
/etc/paimos-deploy.sh
# Equivalent: (cd ~/docker && docker compose pull ppm && docker compose up -d ppm)

# Verify:
docker ps --filter name=ppm --format '{{.Image}} {{.Status}}'
curl -fsSI https://pm.barta.cm/ | head -1
docker logs ppm --tail 50
```

Rollback on failure: `docker load -i ~/backups/paimos-<TS>/paimos-latest.tar.gz`,
pin the compose `image:` line back to the saved tag, `docker compose up -d ppm`.

Data rollback (only on migration corruption — additive-only schema, very rare):
`docker compose stop ppm && docker run --rm -v ppm_data:/data -v ~/backups/paimos-<TS>:/backup alpine sh -c "rm -rf /data/* && tar xzf /backup/ppm_data.tar.gz -C /data" && docker compose up -d ppm`.

---

## Troubleshooting

### Decision Tree

```
Service Not Responding?
├─ Can SSH?
│  ├─ YES: Docker/service issue
│  │  ├─ docker ps → container running?
│  │  │  ├─ YES: Check logs: docker logs <container>
│  │  │  └─ NO: Start it: cd ~/docker && docker-compose up -d
│  │  └─ Docker down? systemctl status docker
│  └─ NO: Server/network issue
│     ├─ Try password SSH (see SECRETS.md)
│     ├─ Can ping 152.53.64.166?
│     │  ├─ YES: SSH service down → Use VNC console
│     │  └─ NO: Server down → Check Netcup panel
│     └─ Last resort: VNC console (Netcup SCP)

InfluxDB No Data?
└─ Check csb0's MQTT broker → It feeds InfluxDB!
```

### Common Issues & Quick Fixes

```
Grafana down → docker restart csb1-grafana-1
InfluxDB down → docker restart csb1-influxdb-1
InfluxDB no data → Check csb0's MQTT (dependency!)
Paperless down → docker restart csb1-paperless-1
Backup failed → docker logs csb1-restic-cron-hetzner-1
High load → Check docker stats (find heavy container)
SSL Error 526 (Cloudflare) → CF API token expired; see below
```

### SSL / TLS Certificate Renewal (Cloudflare DNS-01)

Traefik uses `secrets/traefik-variables.age` (shared with csb0) for ACME DNS-01 via Cloudflare API.

**Symptom:** Cloudflare Error 526 on all `*.barta.cm` services; Traefik logs show:
`status code 403 — 9109: Invalid access token`

**Token rotation (last done: 2026-03-06, stored in 1Password as "dns-token-2026-03-06"):**

1. Cloudflare Dashboard → Profile → API Tokens → Create Token
   - Permission: `Zone / DNS / Edit` scoped to `barta.cm` (no TTL, no IP filter)
2. Save new token to 1Password; name entry with date
3. Re-encrypt: `cd ~/Code/nixcfg && agenix -e secrets/traefik-variables.age`
4. Commit + push; deploy both csb0 and csb1
5. `docker restart csb1-traefik-1` to trigger immediate cert renewal
6. Verify: `docker logs csb1-traefik-1 --tail 50 2>&1 | grep -i acme`

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

Static IP `152.53.64.166/24` is configured declaratively in NixOS.
Gateway: `152.53.64.1` | DNS: `8.8.8.8`, `8.8.4.4`

### 🚨 Historical Incident: 2025-12-05 Network Loss

**Symptom:** Server became unreachable immediately after `nixos-rebuild switch`.
**Root Cause:** The configuration used NetworkManager (`networking.networkmanager.enable = true`) but did not define a static IP declaratively. On a fresh generation switch, the imperative connection profile was lost, and NetworkManager didn't know how to bring up the interface.
**Recovery:** Had to boot with `init=/bin/sh`, manually bring up `ens3` with `ip addr add` and `ip link set`, and then start `sshd -o UsePAM=no` to regain access and fix the configuration.
**Fix:** Always define static networking declaratively for servers (`networking.interfaces.ens3...`) and set a `hashedPassword` for the `mba` user for VNC console recovery.

### If SSH Fails

1. Login to Netcup SCP (https://www.servercontrolpanel.de/SCP)
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
/nix/store/m1b[Tab]/bin/ip addr add 152.53.64.166/24 dev ens3
/nix/store/m1b[Tab]/bin/ip link set ens3 up
/nix/store/m1b[Tab]/bin/ip route add default via 152.53.64.1

# Continue normal boot
exec /nix/var/nix/profiles/system/init
```

**Note:** Busybox ash shell is worse than bash (no arrow-up, no Tab). If you accidentally enter it, type `exit` to return to bash.

### Netcup API Emergency Restart

```bash
# Get token and restart (see SECRETS.md for refresh token location)
TOKEN=$(curl -s 'https://servercontrolpanel.de/realms/scp/protocol/openid-connect/token' \
  -d 'client_id=scp' -d "refresh_token=$(cat ~/Code/nixcfg/hosts/csb1/secrets/netcup-api-refresh-token.txt)" \
  -d 'grant_type=refresh_token' | jq -r '.access_token') && \
curl -X POST "https://servercontrolpanel.de/scp-core/api/v1/servers/646294/reset" \
  -H "Authorization: Bearer $TOKEN"
```

### Single Service Restore (Example: Grafana)

```bash
docker-compose down grafana
docker exec csb1-restic-cron-hetzner-1 restic restore latest \
  --target /tmp/restore --path /backup/var/lib/docker/volumes/csb1_grafana_data
sudo cp -a /tmp/restore/backup/var/lib/docker/volumes/csb1_grafana_data/* \
  /var/lib/docker/volumes/csb1_grafana_data/
docker-compose up -d grafana
```

---

## Backup System

### ⚠️ Shared Repository with csb0

- Both servers backup to the same Hetzner repository
- Snapshots identified by hostname (csb0 vs csb1)
- **Cleanup managed by csb0** (runs at 03:15 AM daily)

### Schedule

| Task    | Time                   | Container                  |
| ------- | ---------------------- | -------------------------- |
| Backup  | 01:30 AM daily         | csb1-restic-cron-hetzner-1 |
| Cleanup | N/A (done on csb0)     | -                          |
| Check   | 05:30 AM monthly (1st) | csb1-restic-cron-hetzner-1 |

### What Gets Backed Up

```
✅ /var/lib/docker/volumes - ALL Docker volumes
   └─ Grafana, InfluxDB, Docmost, Paperless data
✅ /home - All user home directories
✅ /root - Root user data
✅ /etc - System configuration
❌ Exclusions: */cache/*, *.log*
```

### Check Backup Status

```bash
# View logs
docker logs csb1-restic-cron-hetzner-1 | tail -50

# List snapshots
docker exec csb1-restic-cron-hetzner-1 restic snapshots
```

---

## Service Dependencies

```
csb0 (MQTT) → csb1 (InfluxDB) → csb1 (Grafana)
```

**⚠️ If csb0's MQTT is down, InfluxDB stops receiving IoT data!**

---

## Maintenance

### Clean Up Disk Space

```bash
ssh mba@cs1.barta.cm -p 2222 "docker system prune -f"
```

### View Logs

```bash
# Current boot
ssh mba@cs1.barta.cm -p 2222 "journalctl -b -e"

# Follow logs
ssh mba@cs1.barta.cm -p 2222 "journalctl -f"
```

---

## Web Interfaces

| Service    | URL                           | Auth                          |
| ---------- | ----------------------------- | ----------------------------- |
| Grafana    | https://grafana.barta.cm      | Grafana login                 |
| InfluxDB   | http://influxdb.barta.cm:8086 | InfluxDB login                |
| Paperless  | https://paperless.barta.cm    | Paperless login               |
| Docmost    | https://docmost.barta.cm      | Docmost login                 |
| Excalidraw | https://draw.barta.cm         | Cloudflare Access (email OTP) |

### Excalidraw Access Management

Protected via **Cloudflare Zero Trust** → Access → Applications → `Excalidraw`.

- Auth method: One-time PIN (email)
- Policy: email allowlist (family + friends)
- To add/remove users: Cloudflare Zero Trust dashboard → Access → Applications → Excalidraw → Edit policy

---

## Services to Archive Post-Migration

### Hedgedoc ❌ DECOMMISSIONED

- **Status**: Will not be migrated
- **Volumes to archive**: `csb1_hedgedoc-app-uploads`, `csb1_hedgedoc-db-data`

---

## Related Documentation

- [csb1 README](../README.md) - Full server documentation
- [SECRETS.md](../secrets/SECRETS.md) - All credentials (gitignored)
- [DEPRECATED-RUNBOOK.md](../secrets/DEPRECATED-RUNBOOK.md) - Old runbook with inline secrets
- [csb0 Runbook](../../csb0/docs/RUNBOOK.md) - Smart home hub (dependency)
