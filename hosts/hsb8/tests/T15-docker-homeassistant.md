# T15: Docker & Home Assistant

**Feature ID**: F15  
**Status**: ⏳ Planned  
**Location**: both (Docker infrastructure, Home Assistant at ww87)

## Overview

Tests that Docker is properly configured and Home Assistant can be deployed for the gb user. This feature provides the infrastructure for home automation at parents' home.

## Prerequisites

- Docker service enabled
- gb user in docker group
- Network connectivity
- (Optional) USB devices for Zigbee/Matter (at ww87)

## Manual Test Procedure

### Step 1: Verify Docker Service

```bash
ssh mba@192.168.1.100 'sudo systemctl status docker'
```

**Expected**: Service is `active (running)`

### Step 2: Check Docker Group Membership

```bash
ssh mba@192.168.1.100 'groups gb'
```

**Expected**: Output includes `docker` group

### Step 3: Test Docker Access (gb user)

```bash
ssh mba@192.168.1.100 'sudo -u gb docker ps'
```

**Expected**: Command runs without permission errors (may show empty container list)

### Step 4: Verify Docker Version

```bash
ssh mba@192.168.1.100 'docker --version'
```

**Expected**: Shows Docker version

### Step 5: Check Docker Auto-Prune Configuration

```bash
ssh mba@192.168.1.100 'sudo systemctl list-timers | grep docker'
```

**Expected**: Shows docker-prune timer scheduled weekly

### Step 6: Create Docker Directory Structure (gb user)

```bash
# This step must be performed by gb user or mba with sudo
ssh mba@192.168.1.100 'sudo -u gb mkdir -p /home/gb/docker/mounts'
ssh mba@192.168.1.100 'ls -la /home/gb/docker/'
```

**Expected**: Directory exists and is owned by gb

### Step 7: Verify Home Assistant Can Pull Image

```bash
ssh mba@192.168.1.100 'sudo -u gb docker pull ghcr.io/home-assistant/home-assistant:stable'
```

**Expected**: Image downloads successfully

**Note**: This test can take several minutes depending on network speed.

### Step 8: Check Docker Compose Availability

```bash
ssh mba@192.168.1.100 'docker compose version'
```

**Expected**: Shows Docker Compose version (V2 integrated with Docker)

## Deployment Guide (For gb User)

### Home Assistant Docker Compose Setup

Based on miniserver24 configuration, create `/home/gb/docker/docker-compose.yml`:

```yaml
# name: hsb8-homeassistant
services:
  homeassistant:
    container_name: homeassistant
    image: "ghcr.io/home-assistant/home-assistant:stable"
    volumes:
      - ./mounts/homeassistant:/config
      - /etc/localtime:/etc/localtime:ro
      - /run/dbus:/run/dbus:ro
    restart: unless-stopped
    privileged: true
    network_mode: host
    environment:
      - TZ=Europe/Vienna
    labels:
      - "com.centurylinklabs.watchtower.enable=true"
      - "com.centurylinklabs.watchtower.scope=weekly"

  mosquitto:
    image: eclipse-mosquitto:latest
    container_name: mosquitto
    restart: unless-stopped
    ports:
      - "1883:1883"
      - "9001:9001"
    volumes:
      - ./mounts/mosquitto/config/mosquitto.conf:/mosquitto/config/mosquitto.conf
      - ./mounts/mosquitto/data:/mosquitto/data
      - ./mounts/mosquitto/log:/mosquitto/log
    labels:
      - "com.centurylinklabs.watchtower.enable=true"
      - "com.centurylinklabs.watchtower.scope=weekly"

  zigbee2mqtt:
    container_name: zigbee2mqtt
    depends_on:
      - mosquitto
    image: koenkk/zigbee2mqtt:latest
    volumes:
      - ./mounts/zigbee2mqtt:/app/data
    restart: unless-stopped
    ports:
      - "8888:8888"
    environment:
      - TZ=Europe/Vienna
    labels:
      - "com.centurylinklabs.watchtower.enable=true"
      - "com.centurylinklabs.watchtower.scope=weekly"

  matter-server:
    image: ghcr.io/home-assistant-libs/python-matter-server:stable
    container_name: matter-server
    restart: unless-stopped
    network_mode: host
    security_opt:
      - apparmor:unconfined
    volumes:
      - ./mounts/matter-server:/data
      - /run/dbus:/run/dbus:ro
    environment:
      - TZ=Europe/Vienna
    labels:
      - "com.centurylinklabs.watchtower.enable=true"
      - "com.centurylinklabs.watchtower.scope=weekly"

  watchtower-weekly:
    image: containrrr/watchtower:latest
    container_name: watchtower-weekly
    restart: unless-stopped
    command: --schedule "0 0 5 * * 6" --label-enable --scope weekly
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:rw
    environment:
      - "WATCHTOWER_CLEANUP=true"
      - "WATCHTOWER_DEBUG=true"
```

### Starting Services

```bash
# As gb user
cd ~/docker
docker compose up -d
```

### Accessing Home Assistant

Once deployed at ww87:

- **URL**: `http://192.168.1.100:8123`
- **Initial Setup**: Follow Home Assistant onboarding wizard
- **MQTT Broker**: `192.168.1.100:1883` (mosquitto)
- **Zigbee2MQTT UI**: `http://192.168.1.100:8888`

## Success Criteria

- ✅ Docker service is running
- ✅ Docker auto-prune configured (weekly)
- ✅ gb user has docker group membership
- ✅ gb user can run docker commands without sudo
- ✅ Home Assistant image can be pulled
- ✅ Docker Compose V2 is available

## Troubleshooting

### Permission Denied (Docker Socket)

```bash
# Verify gb is in docker group
ssh mba@192.168.1.100 'groups gb'

# If not, add to group (requires logout/login)
ssh mba@192.168.1.100 'sudo usermod -aG docker gb'

# Restart docker service
ssh mba@192.168.1.100 'sudo systemctl restart docker'
```

### Container Won't Start

```bash
# Check logs
docker compose logs homeassistant

# Check docker daemon logs
sudo journalctl -u docker -n 50
```

### USB Device Access (Zigbee/Matter)

At ww87, USB devices for Zigbee and Matter may need to be passed through:

```bash
# List USB devices
lsusb

# Add device to docker-compose.yml
devices:
  - /dev/ttyUSB0:/dev/ttyUSB0  # Zigbee adapter
```

## Notes

- **Manual Setup Required**: Docker Compose configuration must be created by gb user
- **Reference Implementation**: miniserver24:/home/mba/docker/ (similar setup)
- **Network Mode**: Home Assistant uses `host` mode for mDNS discovery
- **Automatic Updates**: Watchtower updates containers weekly on Saturdays at 05:00
- **Storage**: All persistent data in `/home/gb/docker/mounts/`
- **Secrets**: Not yet integrated with agenix (future enhancement)

## Test Log

| Date | Tester | Location | Result | Notes         |
| ---- | ------ | -------- | ------ | ------------- |
| -    | -      | -        | ⏳     | Awaiting test |

## Related

- **F10**: Multi-User Access (gb user account)
- **F11**: ZFS Storage (Docker volumes on ZFS)
- **miniserver24**: Reference Docker Compose setup at `/home/mba/docker/`
