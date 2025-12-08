# Runbook: hsb1 (Home Automation Server)

**Host**: hsb1 (192.168.1.101)  
**Role**: Home automation hub running Node-RED, Zigbee2MQTT, MQTT broker  
**Criticality**: MEDIUM - Home automation services

---

## Quick Connect

```bash
ssh mba@192.168.1.101
# or
ssh mba@hsb1.lan
```

---

## Common Tasks

### Update & Switch Configuration

```bash
ssh mba@192.168.1.101
cd ~/Code/nixcfg
git pull
just switch
```

### Fix Git Issues & Update

If git has merge conflicts or local changes blocking pull:

```bash
ssh mba@192.168.1.101
cd ~/Code/nixcfg
git status                           # Check what's wrong
git checkout -- .                    # Discard all local changes
# OR for specific file:
git checkout -- path/to/file
git pull
just switch
```

### Rollback to Previous Generation

```bash
ssh mba@192.168.1.101
sudo nixos-rebuild switch --rollback
```

---

## Health Checks

### Quick Status

```bash
ssh mba@192.168.1.101 "docker ps && zpool status | head -10"
```

### Container Status

```bash
ssh mba@192.168.1.101 "docker ps --format 'table {{.Names}}\t{{.Status}}'"
```

### ZFS Pool Status

```bash
ssh mba@192.168.1.101 "zpool status"
```

---

## Docker Services

### View All Containers

```bash
ssh mba@192.168.1.101 "docker ps -a"
```

### Restart a Container

```bash
ssh mba@192.168.1.101 "docker restart nodered"
ssh mba@192.168.1.101 "docker restart mosquitto"
ssh mba@192.168.1.101 "docker restart zigbee2mqtt"
```

### View Container Logs

```bash
ssh mba@192.168.1.101 "docker logs -f nodered --tail 100"
ssh mba@192.168.1.101 "docker logs -f mosquitto --tail 100"
```

### Restart All Docker Services

```bash
ssh mba@192.168.1.101 "cd ~/docker && docker-compose down && docker-compose up -d"
```

---

## Troubleshooting

### Node-RED Not Accessible

```bash
ssh mba@192.168.1.101
docker ps | grep nodered
docker logs nodered --tail 50
docker restart nodered
```

### Zigbee Devices Not Responding

1. Check Zigbee2MQTT: `docker logs zigbee2mqtt --tail 50`
2. Check USB device: `lsusb`
3. Restart container: `docker restart zigbee2mqtt`

### MQTT Connection Issues

```bash
ssh mba@192.168.1.101
docker logs mosquitto --tail 50
# Test MQTT locally (requires auth - see SECRETS.md for password)
docker exec mosquitto mosquitto_sub -h localhost -u smarthome -P '<password>' -t '#' -v -C 5
```

### Zigbee Devices Unresponsive in HA (but work in Z2M)

**Symptom:** Devices show "unresponsive" in Apple Home / HA, but work fine in Zigbee2MQTT UI. HA entities show "This entity is no longer being provided by the mqtt integration."

**Root Cause:** Home Assistant lost connection to MQTT broker.

**Diagnosis:**

```bash
# Check if HA can reach MQTT broker
docker exec homeassistant sh -c 'nc -zv localhost 1883'

# Check HA logs for MQTT errors
docker logs homeassistant 2>&1 | grep -iE 'mqtt.*not.*connected|broker'

# Verify Z2M is publishing discovery (should show config messages)
docker exec mosquitto mosquitto_sub -h localhost -u smarthome -P '<password>' \
  -t 'homeassistant/+/+/+/config' -v -C 3
```

**Common Causes:**

1. **Hostname change** — HA MQTT broker configured with old hostname (e.g., `miniserver24` → `hsb1`)
2. **Container restart** — MQTT client failed to reconnect

**Fix:**

1. Go to HA: Settings → Devices & Services → MQTT → Configure
2. Change broker to `localhost` (preferred) or `192.168.1.101`
3. Save — entities should recover automatically

**Prevention:** Always use `localhost` for MQTT broker in HA (not hostnames). Z2M already uses IP (`192.168.1.101`) which is correct.

### UPS Monitoring

```bash
ssh mba@192.168.1.101 "apcaccess status"
```

---

## Emergency Recovery

### If SSH Fails

1. Physical access to Mac mini required
2. Connect keyboard and monitor
3. Login as `mba` or `root`

### Docker Compose Location

```bash
~/docker/docker-compose.yml
```

### Restore from Generation

```bash
# List available generations
sudo nix-env --list-generations -p /nix/var/nix/profiles/system

# Switch to specific generation
sudo nix-env --switch-generation N -p /nix/var/nix/profiles/system
sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
```

### Restore from Backup (Restic/Hetzner)

Docker volumes are backed up daily to Hetzner StorageBox via `restic-cron-hetzner` container.

**1. List available snapshots:**

```bash
# On hsb1, enter the restic container
docker exec -it restic-cron-hetzner sh

# List snapshots (inside container)
restic snapshots
```

**2. Restore specific files/directories:**

```bash
# Restore to a temp directory first
restic restore SNAPSHOT_ID --target /tmp/restore --include /data/nodered

# Or restore latest
restic restore latest --target /tmp/restore --include /data/homeassistant
```

**3. Copy restored data to Docker mounts:**

```bash
# Stop the container first
docker stop nodered

# Copy restored data
cp -r /tmp/restore/data/nodered/* ~/docker/mounts/nodered/data/

# Restart container
docker start nodered
```

**Backup repository location:**

- Hetzner StorageBox (credentials in `~/secrets/` and 1Password)
- Repository password: See `runbook-secrets.md` or 1Password

---

## Maintenance

### Clean Up Disk Space

```bash
ssh mba@192.168.1.101 "cd ~/Code/nixcfg && just cleanup"
```

### Docker Cleanup

```bash
ssh mba@192.168.1.101 "docker system prune -f"
```

### ZFS Scrub (Manual)

```bash
ssh mba@192.168.1.101 "sudo zpool scrub zroot"
```

### View Logs

```bash
# Current boot
ssh mba@192.168.1.101 "journalctl -b -e"

# Follow logs
ssh mba@192.168.1.101 "journalctl -f"
```

---

## Web Interfaces

| Service        | URL                          |
| -------------- | ---------------------------- |
| Home Assistant | <http://192.168.1.101:8123>  |
| Node-RED       | <http://192.168.1.101:1880>  |
| Zigbee2MQTT    | <http://192.168.1.101:8888>  |
| Scrypted       | <http://192.168.1.101:10443> |
| Apprise        | <http://192.168.1.101:8001>  |

---

## Smarthome Stack

### Container Overview

| Container           | Image                                                     | Purpose                      | Port         |
| ------------------- | --------------------------------------------------------- | ---------------------------- | ------------ |
| homeassistant       | `ghcr.io/home-assistant/home-assistant:stable`            | Main automation hub          | 8123 (host)  |
| nodered             | `ghcr.io/markus-barta/node-red-miniserver24:main` ¹       | Automation flows + FLIRC IR  | 1880 (host)  |
| zigbee2mqtt         | `koenkk/zigbee2mqtt:latest`                               | Zigbee device bridge         | 8888         |
| mosquitto           | `eclipse-mosquitto:latest`                                | MQTT broker                  | 1883, 9001   |
| scrypted            | `ghcr.io/koush/scrypted`                                  | Camera/NVR/HomeKit bridge    | 10443 (host) |
| matter-server       | `ghcr.io/home-assistant-libs/python-matter-server:stable` | Matter protocol              | 5580 (host)  |
| pidicon             | `ghcr.io/markus-barta/pidicon:latest`                     | Pixoo display control        | 10829 (host) |
| apprise             | `caronc/apprise:latest`                                   | Multi-platform notifications | 8001         |
| opus-stream-to-mqtt | `node:alpine`                                             | OPUS gateway → MQTT bridge   | host         |
| smtp                | `namshi/smtp`                                             | Mail relay (via Hover)       | bridge       |
| restic-cron-hetzner | custom build                                              | Daily backups to Hetzner     | -            |
| watchtower-weekly   | `containrrr/watchtower:latest`                            | Weekly updates (Sat 5am)     | -            |
| watchtower-pidicon  | `containrrr/watchtower:latest`                            | Fast pidicon updates (10s)   | -            |

### Key Paths

```bash
# Docker compose
~/docker/docker-compose.yml

# Container data mounts
~/docker/mounts/homeassistant/     # HA config
~/docker/mounts/nodered/data/      # Node-RED flows
~/docker/mounts/zigbee2mqtt/       # Z2M config + database
~/docker/mounts/mosquitto/         # MQTT config + data
~/docker/mounts/scrypted/volume/   # Camera configs
~/docker/mounts/pidicon/data/      # Pixoo scenes/media
~/docker/mounts/matter-server/     # Matter credentials

# Secrets (env files) - passwords in secrets/SECRETS.md
~/secrets/smarthome.env            # Shared HA/NR secrets
~/secrets/zigbee2mqtt.env          # Z2M network key
~/secrets/watchtower.env           # Notification URLs
~/secrets/pidicon.env              # Pixoo API keys
~/secrets/github.env               # GHCR token
~/secrets/influxdb3-csb1.env       # InfluxDB connection
/etc/secrets/tapoC210-00.env       # Camera credentials
```

### Quick Debug Commands

```bash
# All container status
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# Follow specific container logs
docker logs -f homeassistant --tail 100
docker logs -f nodered --tail 100
docker logs -f zigbee2mqtt --tail 100

# Check Zigbee coordinator
docker exec zigbee2mqtt cat /app/data/configuration.yaml | grep -A5 serial

# MQTT test (subscribe to all topics)
docker exec mosquitto mosquitto_sub -h localhost -t '#' -v

# Restart entire stack
cd ~/docker && docker compose down && docker compose up -d

# Restart single container
docker restart homeassistant
docker restart nodered
docker restart zigbee2mqtt

# Check watchtower logs (update history)
docker logs watchtower-weekly --tail 50
```

### Update Schedule

- **watchtower-weekly**: Saturdays 5:00am — updates all containers with `scope=weekly`
- **watchtower-pidicon**: Every 10 seconds — fast updates for pidicon only
- **restic-cron-hetzner**: Daily 1:30am — backup to Hetzner StorageBox

### Network Modes

| Mode        | Containers                                                                    |
| ----------- | ----------------------------------------------------------------------------- |
| **host**    | homeassistant, nodered, scrypted, matter-server, pidicon, opus-stream-to-mqtt |
| **bridge**  | zigbee2mqtt, mosquitto, apprise, smtp, restic-cron, watchtowers               |
| **macvlan** | (available for static IP assignment on 192.168.1.0/24)                        |

### MQTT Broker Configuration

| Service            | Broker Setting  | Notes                                         |
| ------------------ | --------------- | --------------------------------------------- |
| **Home Assistant** | `localhost`     | ⚠️ Never use hostname — use `localhost` or IP |
| **Zigbee2MQTT**    | `192.168.1.101` | Uses IP (correct)                             |
| **Node-RED**       | `localhost`     | Via MQTT nodes                                |

If hostname changes, HA MQTT will break. Always use `localhost`.

> ¹ **Note**: The Node-RED Docker image is still named `node-red-miniserver24` (legacy name). This is the actual image name on GHCR and works correctly.

---

## Related Documentation

- [hsb1 README](../README.md) - Full server documentation
- [hsb0 Runbook](../../hsb0/docs/RUNBOOK.md) - DNS/DHCP server (dependency)
- [SECRETS.md](../secrets/SECRETS.md) - All service credentials (gitignored)
