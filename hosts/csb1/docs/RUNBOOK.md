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
║ • Grafana:     https://grafana.barta.cm                    ║
║ • InfluxDB:    http://influxdb.barta.cm:8086               ║
║ • Paperless:   https://paperless.barta.cm                  ║
║ • Docmost:     https://docmost.barta.cm                    ║
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

## Docker Services

### All Containers (15 running)

| Container                   | Purpose                   |
| --------------------------- | ------------------------- |
| csb1-grafana-1              | Monitoring dashboards     |
| csb1-influxdb-1             | Time-series database      |
| csb1-docmost-1              | Documentation wiki        |
| csb1-docmost-db-1           | PostgreSQL for Docmost    |
| csb1-docmost-redis-1        | Redis cache               |
| csb1-paperless-1            | Document management       |
| csb1-paperless-db-1         | PostgreSQL for Paperless  |
| csb1-paperless-redis-1      | Redis                     |
| csb1-paperless-tika-1       | Document parsing          |
| csb1-paperless-gotenberg-1  | PDF conversion            |
| csb1-traefik-1              | Reverse proxy             |
| csb1-docker-proxy-traefik-1 | Traefik proxy             |
| csb1-restic-cron-hetzner-1  | Backup (cleanup on csb0!) |
| csb1-smtp-1                 | Mail relay                |
| csb1-whoami-1               | Test service              |

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
```

---

## Emergency Recovery

### Access Priority

1. **Primary**: SSH with key (`~/.ssh/id_rsa`)
2. **Backup**: SSH with mba password (see SECRETS.md)
3. **Emergency**: Netcup VNC console + root password (see SECRETS.md)
4. **Recovery**: Netcup control panel access (with 2FA)

### If SSH Fails

1. Login to Netcup SCP (https://www.servercontrolpanel.de/SCP)
2. Navigate to server, open VNC console
3. Login as `mba` with password (see SECRETS.md)

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

| Service   | URL                           |
| --------- | ----------------------------- |
| Grafana   | https://grafana.barta.cm      |
| InfluxDB  | http://influxdb.barta.cm:8086 |
| Paperless | https://paperless.barta.cm    |
| Docmost   | https://docmost.barta.cm      |

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
