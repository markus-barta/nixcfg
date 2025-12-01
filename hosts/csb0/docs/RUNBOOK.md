# Runbook: csb0 (Smart Home Hub)

**Host**: csb0 (cs0.barta.cm / 85.235.65.226)  
**Role**: Smart Home Hub & IoT Automation Platform  
**Criticality**: HIGH - Smart home + backup manager for BOTH csb0 and csb1  
**Provider**: Netcup VPS

---

## Quick Connect

```bash
# Via alias
qc0

# Direct SSH
ssh mba@cs0.barta.cm -p 2222

# With IP
ssh mba@85.235.65.226 -p 2222
```

---

## Quick Reference Card

```
╔════════════════════════════════════════════════════════════╗
║ 🌀 csb0 - Smart Home Hub Emergency Reference               ║
╠════════════════════════════════════════════════════════════╣
║ SSH:       ssh mba@cs0.barta.cm -p 2222                    ║
║ IP:        85.235.65.226                                   ║
║ Netcup:    Customer # 227044 (2FA required)                ║
║ VNC:       servercontrolpanel.de/SCP                       ║
╠════════════════════════════════════════════════════════════╣
║ 🌐 SERVICES                                                ║
║ • Node-RED:    https://home.barta.cm                       ║
║ • Bitwarden:   https://bitwarden.barta.cm (TEST ONLY)      ║
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
ssh mba@cs0.barta.cm -p 2222
cd ~/nixcfg  # or ~/Code/nixcfg
git pull
just switch
```

### Rollback to Previous Generation

```bash
ssh mba@cs0.barta.cm -p 2222
sudo nixos-rebuild switch --rollback
```

---

## Docker Services

### All Containers (9 running)

| Container                   | Purpose                          |
| --------------------------- | -------------------------------- |
| csb0-traefik-1              | Reverse proxy                    |
| csb0-bitwarden-1            | Password manager (TEST ONLY)     |
| csb0-bitwarden-db-1         | MariaDB for Bitwarden            |
| csb0-mosquitto-1            | MQTT broker (CRITICAL)           |
| csb0-nodered-1              | Smart home automation (CRITICAL) |
| csb0-cypress-1              | Sonnen website scraper           |
| csb0-smtp-1                 | Mail relay                       |
| csb0-restic-cron-hetzner-1  | Backup + cleanup manager         |
| csb0-docker-proxy-traefik-1 | Traefik proxy                    |

### Quick Commands

```bash
# View all containers
docker ps -a

# Restart a container
docker restart csb0-nodered-1
docker restart csb0-mosquitto-1

# View logs
docker logs csb0-nodered-1 --tail 50
docker logs csb0-mosquitto-1 --tail 50

# Restart all services
cd ~/docker && docker-compose down && docker-compose up -d
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
│  │  │  └─ NO: Start it: cd ~/docker && docker-compose up -d
│  │  └─ Docker down? systemctl status docker
│  └─ NO: Server/network issue
│     ├─ Can ping 85.235.65.226?
│     │  ├─ YES: SSH service down → Use VNC console
│     │  └─ NO: Server down → Check Netcup panel
│     └─ Last resort: VNC console (Netcup SCP)
```

### Common Issues & Quick Fixes

```
Node-RED down → docker restart csb0-nodered-1
MQTT down → docker restart csb0-mosquitto-1 (⚠️ affects csb1!)
Backup failed → docker logs csb0-restic-cron-hetzner-1
Telegram bot → Re-register webhook (see SECRETS.md for token)
High load → Check docker stats (find heavy container)
```

---

## Emergency Recovery

### Access Priority

1. **Primary**: SSH with key (`~/.ssh/id_rsa`)
2. **Emergency**: Netcup VNC console + root password (see SECRETS.md)
3. **Recovery**: Netcup control panel access (with 2FA)

### If SSH Fails

1. Login to Netcup SCP (https://www.servercontrolpanel.de/SCP)
2. Navigate to server, open VNC console
3. Login as `mba` or `root` (see SECRETS.md for password)

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

### 🚨 CRITICAL: csb0 is the Cleanup Manager!

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
✅ /var/lib/docker/volumes - Docker volumes
✅ /home - All Docker bind mounts (Node-RED, Mosquitto, everything!)
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

| Service   | URL                                    |
| --------- | -------------------------------------- |
| Node-RED  | https://home.barta.cm                  |
| Bitwarden | https://bitwarden.barta.cm (TEST ONLY) |
| MQTT      | mosquitto.barta.cm:8883 (TLS)          |

---

## Related Documentation

- [csb0 README](../README.md) - Full server documentation
- [SECRETS.md](../secrets/SECRETS.md) - All credentials (gitignored)
- [DEPRECATED-RUNBOOK.md](../secrets/DEPRECATED-RUNBOOK.md) - Old runbook with inline secrets
- [csb1 Runbook](../../csb1/docs/RUNBOOK.md) - Monitoring server
