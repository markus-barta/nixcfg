# P5600: Enable Home Assistant on hsb8

**Priority**: P5 (Medium)  
**Status**: Ready to implement  
**Access**: `ssh mba@192.168.1.100` (via WireGuard VPN to ww87)

## Description

Enable a bare-bones Home Assistant installation on hsb8 at parents' home (ww87). This provides a clean, minimal smart home platform with only HACS pre-configured for future extensibility.

## Source

- Reference: hsb1 Home Assistant architecture (Docker-based)
- Related: hsb8 ww87 deployment task (completed)

## Scope

Applies to: hsb8 (192.168.1.100 at ww87)

---

## Architecture Overview

```text
┌─────────────────────────────────────────────────────────────────────┐
│                    hsb8 SMART HOME STACK (Minimal)                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌──────────────┐    ┌──────────────┐                               │
│  │   Mosquitto  │◀──▶│    Home      │                               │
│  │    (MQTT)    │    │  Assistant   │                               │
│  │    :1883     │    │    :8123     │                               │
│  └──────────────┘    └──────┬───────┘                               │
│                             │                                       │
│                       ┌─────▼─────┐                                 │
│                       │   HACS    │                                 │
│                       │ (Add-ons) │                                 │
│                       └───────────┘                                 │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  Future: Zigbee2MQTT, Matter, Node-RED (not in this scope)   │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Pre-Requisites (Already Complete)

- [x] hsb8 deployed at ww87 with NixOS
- [x] Docker enabled in configuration.nix (`virtualisation.docker.enable = true`)
- [x] User `gb` added to docker group (`users.users.gb.extraGroups = [ "docker" ]`)
- [x] AdGuard Home running on hsb8 (DNS on port 53)
- [x] Static IP: 192.168.1.100
- [x] Firewall has ports 80, 443, 8883 open

---

## Implementation Tasks

### Phase 1: NixOS Configuration Updates

#### 1.1 Open Required Firewall Ports

Update `hosts/hsb8/configuration.nix` to add Home Assistant and MQTT ports:

```nix
networking.firewall = {
  allowedTCPPorts = [
    # ... existing ports ...
    1883  # MQTT (Mosquitto)
    8123  # Home Assistant Web UI
  ];
};
```

#### 1.2 Apply Configuration

```bash
# Via WireGuard VPN:
ssh mba@192.168.1.100 "cd ~/nixcfg && git pull && sudo nixos-rebuild switch --flake .#hsb8"
```

---

### Phase 2: Directory Structure Setup

Create the Docker directory structure on hsb8 (as user `gb`):

```bash
# SSH as gb user (or mba, then create for gb)
ssh gb@192.168.1.100

# Create base directories
mkdir -p ~/docker/mounts/{homeassistant,mosquitto/{config,data,log}}
mkdir -p ~/secrets

# Set permissions
chmod 750 ~/docker ~/secrets
```

#### 2.1 ⚠️ CRITICAL: Mosquitto Directory Permissions

The Eclipse Mosquitto Docker container runs as user `mosquitto` (UID 1883, GID 1883).
The `data` and `log` directories **must** be owned by this UID, otherwise Mosquitto will fail to start with permission errors.

```bash
# Set correct ownership for Mosquitto writable directories
sudo chown -R 1883:1883 ~/docker/mounts/mosquitto/data
sudo chown -R 1883:1883 ~/docker/mounts/mosquitto/log

# Config directory can remain owned by gb (read-only mount)
# Verify ownership
ls -la ~/docker/mounts/mosquitto/
```

**Expected output:**

```text
drwxr-xr-x 2 gb   gb   4096 ... config
drwxr-xr-x 2 1883 1883 4096 ... data
drwxr-xr-x 2 1883 1883 4096 ... log
```

**Why this is needed:**

- Mosquitto writes persistence data to `/mosquitto/data/`
- Mosquitto writes logs to `/mosquitto/log/`
- Without correct ownership, container exits with "Permission denied" errors
- The `config` directory only needs read access (config file is read-only)

**Target directory structure:**

```text
/home/gb/
├── docker/
│   ├── docker-compose.yml       # Main compose file
│   └── mounts/
│       ├── homeassistant/       # HA config directory
│       │   └── configuration.yaml
│       └── mosquitto/
│           ├── config/
│           │   └── mosquitto.conf
│           ├── data/
│           └── log/
└── secrets/
    └── mqtt.env                 # MQTT credentials
```

---

### Phase 3: Mosquitto MQTT Broker Setup

#### 3.1 Create Mosquitto Configuration

Create `/home/gb/docker/mounts/mosquitto/config/mosquitto.conf`:

```ini
# Mosquitto MQTT Broker Configuration for hsb8
# =============================================

# Listener for MQTT connections
listener 1883
protocol mqtt

# Allow anonymous connections (simple setup for internal network)
# For production, enable authentication below
allow_anonymous true

# Persistence
persistence true
persistence_location /mosquitto/data/

# Logging
log_dest file /mosquitto/log/mosquitto.log
log_dest stdout
log_type error
log_type warning
log_type notice
log_type information
```

#### 3.2 Create MQTT Secrets (Optional for Future)

Create `/home/gb/secrets/mqtt.env`:

```bash
# MQTT credentials for future use
MQTT_HOST=192.168.1.100
MQTT_PORT=1883
MQTT_USER=smarthome
MQTT_PASS=<generate-secure-password>
```

#### 3.3 Create Watchtower Notification Config

Create `/home/gb/secrets/watchtower.env`:

```bash
# Telegram notification for Watchtower on hsb8
# Uses the @janischhofweg22bot for home server notifications
WATCHTOWER_NOTIFICATION_URL=telegram://<BOT_TOKEN>@telegram?channels=<CHAT_ID>
```

Get the bot token and chat ID from hsb1's watchtower.env or ask mba for the values.

---

### Phase 4: Docker Compose Configuration

#### 4.1 Create docker-compose.yml

Create `/home/gb/docker/docker-compose.yml`:

```yaml
# hsb8 Home Assistant Stack (Minimal)
# ====================================
# Services:
#   - Home Assistant (stable)
#   - Mosquitto MQTT broker
#   - Watchtower (auto-updates)
#
# Usage:
#   cd ~/docker && docker compose up -d
#   docker compose logs -f homeassistant
#
# Web UI: http://192.168.1.100:8123

services:
  # ============================================================
  # HOME ASSISTANT - Smart Home Platform
  # ============================================================
  homeassistant:
    container_name: homeassistant
    image: ghcr.io/home-assistant/home-assistant:stable
    restart: unless-stopped
    network_mode: host
    privileged: true
    environment:
      - TZ=Europe/Vienna
    volumes:
      - ./mounts/homeassistant:/config
      - /run/dbus:/run/dbus:ro
    depends_on:
      - mosquitto
    labels:
      - "com.centurylinklabs.watchtower.scope=weekly"

  # ============================================================
  # MOSQUITTO - MQTT Message Broker
  # ============================================================
  mosquitto:
    container_name: mosquitto
    image: eclipse-mosquitto:latest
    restart: unless-stopped
    ports:
      - "1883:1883"
    volumes:
      - ./mounts/mosquitto/config:/mosquitto/config
      - ./mounts/mosquitto/data:/mosquitto/data
      - ./mounts/mosquitto/log:/mosquitto/log
    labels:
      - "com.centurylinklabs.watchtower.scope=weekly"

  # ============================================================
  # WATCHTOWER - Automatic Container Updates (Weekly)
  # ============================================================
  watchtower:
    container_name: watchtower
    image: containrrr/watchtower:latest
    restart: unless-stopped
    command: --schedule "0 0 8 * * SAT" --cleanup --scope weekly
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - TZ=Europe/Vienna
      - WATCHTOWER_CLEANUP=true
      - DOCKER_API_VERSION=1.44
      - WATCHTOWER_NOTIFICATIONS=shoutrrr
      - WATCHTOWER_NOTIFICATIONS_HOSTNAME=hsb8
      - WATCHTOWER_NOTIFICATION_TITLE_TAG=🏠
      - WATCHTOWER_SCOPE=weekly
    env_file:
      - ~/secrets/watchtower.env
```

---

### Phase 5: Initial Startup & Home Assistant Setup

#### 5.1 Start the Stack

```bash
cd ~/docker
docker compose up -d

# Verify containers are running
docker ps

# Watch Home Assistant logs for first-time initialization
docker logs -f homeassistant
```

#### 5.2 Initial Home Assistant Onboarding

1. Open browser: `http://192.168.1.100:8123`
2. Wait for "Preparing Home Assistant" (first boot takes 1-2 minutes)
3. Complete onboarding wizard:
   - Create admin account (for gb user)
   - Set home location (ww87 coordinates)
   - Set timezone: Europe/Vienna
   - Set unit system: Metric
   - Skip analytics (optional)

#### 5.3 Configure MQTT Integration

1. Go to: Settings → Devices & Services → Add Integration
2. Search for "MQTT"
3. Configure:
   - Broker: `localhost` (IMPORTANT: always use localhost, not hostname!)
   - Port: `1883`
   - Leave username/password empty (anonymous mode)
4. Submit

---

### Phase 6: HACS Installation

HACS (Home Assistant Community Store) provides access to custom integrations and frontend themes.

#### 6.1 Install HACS

```bash
# SSH to hsb8 as gb
ssh gb@192.168.1.100

# Download and run HACS installer
docker exec -it homeassistant bash -c "wget -O - https://get.hacs.xyz | bash -"

# Restart Home Assistant
docker restart homeassistant
```

#### 6.2 Configure HACS in Home Assistant

1. Wait for Home Assistant to restart (check `docker logs homeassistant`)
2. Go to: Settings → Devices & Services → Add Integration
3. Search for "HACS"
4. Follow the GitHub authentication flow:
   - Requires a GitHub account
   - Authorizes HACS to access public repos (read-only)
5. Complete setup

#### 6.3 Verify HACS Installation

After setup, HACS appears in the sidebar. Verify:

- Click HACS in sidebar
- Browse "Integrations" and "Frontend" tabs
- No errors in Home Assistant logs

---

### Phase 7: Basic Home Assistant Configuration

#### 7.1 Create Minimal configuration.yaml

The initial configuration.yaml is auto-generated. Add minimal customizations:

```bash
# Edit HA config
docker exec -it homeassistant nano /config/configuration.yaml
```

Add after the auto-generated content:

```yaml
# hsb8 Home Assistant Configuration
# =================================
# Location: ww87 (Parents' home)
# Minimal setup with HACS

# Enable default integrations
default_config:

# Logging (reduce noise)
logger:
  default: warning
  logs:
    homeassistant.components.mqtt: info

# MQTT configuration (auto-configured via UI)
# mqtt: configured via integrations

# Text-to-speech (optional)
tts:
  - platform: google_translate
```

#### 7.2 Restart to Apply Configuration

```bash
docker restart homeassistant
docker logs -f homeassistant --tail 100
```

---

### Phase 8: DNS Entry (Optional)

Add AdGuard Home rewrite for friendly hostname:

1. Open AdGuard Home: `http://192.168.1.100:3000`
2. Go to: Filters → DNS rewrites → Add DNS rewrite
3. Add:
   - Domain: `homeassistant.local`
   - Answer: `192.168.1.100`

This allows accessing HA via: `http://homeassistant.local:8123`

---

### Phase 9: Backup Configuration

#### 9.1 Create Backup Script

Create `/home/gb/scripts/backup-homeassistant.sh`:

```bash
#!/bin/bash
# Backup Home Assistant configuration
# Run manually or via cron

BACKUP_DIR="/home/gb/backups/homeassistant"
DATE=$(date +%Y%m%d-%H%M%S)
SOURCE="/home/gb/docker/mounts/homeassistant"

mkdir -p "$BACKUP_DIR"

# Stop HA for consistent backup (optional)
# docker stop homeassistant

# Create tarball
tar -czf "$BACKUP_DIR/ha-config-$DATE.tar.gz" -C "$SOURCE" .

# Restart HA (if stopped)
# docker start homeassistant

# Keep only last 7 backups
ls -t "$BACKUP_DIR"/ha-config-*.tar.gz | tail -n +8 | xargs -r rm

echo "Backup complete: $BACKUP_DIR/ha-config-$DATE.tar.gz"
```

```bash
chmod +x /home/gb/scripts/backup-homeassistant.sh
```

---

## Verification Checklist

After completing all phases, verify:

- [ ] **Docker containers running**: `docker ps` shows homeassistant, mosquitto, watchtower
- [ ] **Mosquitto permissions**: `ls -la ~/docker/mounts/mosquitto/` shows data/log owned by 1883:1883
- [ ] **Mosquitto logs clean**: `docker logs mosquitto --tail 20` shows no permission errors
- [ ] **Home Assistant accessible**: `http://192.168.1.100:8123` loads web UI
- [ ] **Admin account created**: Can login with gb's credentials
- [ ] **MQTT connected**: Settings → Devices & Services → MQTT shows "Connected"
- [ ] **HACS installed**: HACS appears in sidebar menu
- [ ] **HACS functional**: Can browse integrations in HACS store
- [ ] **Logs clean**: `docker logs homeassistant --tail 50` shows no errors
- [ ] **Watchtower running**: `docker logs watchtower` shows scheduled updates
- [ ] **Watchtower notifications**: Test with `docker exec watchtower /watchtower --run-once` and verify Telegram message shows "🏠 hsb8:"

---

## Common Operations

### View Logs

```bash
# Home Assistant logs
docker logs -f homeassistant --tail 100

# MQTT broker logs
docker logs -f mosquitto --tail 50

# All container status
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

### Restart Services

```bash
# Single service
docker restart homeassistant

# Entire stack
cd ~/docker && docker compose down && docker compose up -d
```

### Update Containers Manually

```bash
cd ~/docker
docker compose pull
docker compose up -d
```

### Access HA Shell

```bash
# For debugging
docker exec -it homeassistant bash
```

---

## Troubleshooting

### Mosquitto Fails to Start (Permission Denied)

**Symptom**: `docker logs mosquitto` shows errors like:

```text
Error: Unable to open log file /mosquitto/log/mosquitto.log for writing.
Error: Unable to open persistent database /mosquitto/data/mosquitto.db
```

**Cause**: Mosquitto container runs as UID 1883, but directories are owned by a different user.

**Fix**:

```bash
sudo chown -R 1883:1883 ~/docker/mounts/mosquitto/data
sudo chown -R 1883:1883 ~/docker/mounts/mosquitto/log
docker restart mosquitto
```

### Home Assistant Can't Connect to MQTT

**Symptom**: MQTT integration shows "Unable to connect" or "Connection failed"

**Diagnosis**:

```bash
# Check if Mosquitto is running
docker ps | grep mosquitto

# Check Mosquitto logs
docker logs mosquitto --tail 20

# Test MQTT port locally
nc -zv localhost 1883
```

**Fix**: Always use `localhost` as broker address (not hostname or IP).

### Container Won't Start After Reboot

**Check**: Verify Docker service and container restart policies:

```bash
sudo systemctl status docker
docker ps -a  # Check for containers in 'Exited' state
docker compose up -d  # Restart all services
```

---

## Security Notes

- **Network**: hsb8 is on internal network (192.168.1.0/24) only
- **Firewall**: Only required ports are open (8123, 1883)
- **MQTT**: Anonymous mode for simplicity; add auth if exposing externally
- **Updates**: Watchtower handles weekly container updates automatically
- **Backups**: Manual script provided; consider ZFS snapshots as additional layer

---

## Future Expansion (Out of Scope)

When needed, these can be added later:

| Service       | Purpose               | Notes                           |
| ------------- | --------------------- | ------------------------------- |
| Zigbee2MQTT   | Zigbee device support | Requires Zigbee coordinator USB |
| Matter Server | Matter protocol       | For Thread/Matter devices       |
| Node-RED      | Advanced automations  | Visual flow-based automation    |
| ESPHome       | ESP32/ESP8266 devices | For DIY sensors                 |
| Frigate       | Camera NVR            | If cameras are added            |

---

## Reference

- hsb1 architecture: `hosts/hsb1/docs/SMARTHOME.md`
- hsb1 runbook: `hosts/hsb1/docs/RUNBOOK.md`
- Docker config reference: `hosts/hsb1/README.md`

---

## Notes

- **Priority**: Medium (for future when time permits)
- **User**: Primary operator will be `gb` (Gerhard/father)
- **Support**: Remote support via SSH from Markus (mba)
- **Complexity**: Low - bare-bones setup intentionally simple
