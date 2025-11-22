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

A ready-to-use Docker Compose configuration is available at:

**[`../examples/docker-compose.yml`](../examples/docker-compose.yml)**

This configuration includes:

- Home Assistant (stable)
- Mosquitto MQTT broker
- Zigbee2MQTT
- Matter Server
- Watchtower (automatic weekly updates)

Based on the proven miniserver24 setup.

### Installation Steps

```bash
# 1. Create directory structure
mkdir -p ~/docker/mounts/{homeassistant,mosquitto/config,mosquitto/data,mosquitto/log,zigbee2mqtt,matter-server}

# 2. Copy the example configuration
cp /path/to/nixcfg/hosts/hsb8/examples/docker-compose.yml ~/docker/

# 3. Create Mosquitto configuration
cat > ~/docker/mounts/mosquitto/config/mosquitto.conf << 'EOF'
listener 1883
allow_anonymous true
persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log
EOF

# 4. Start services
cd ~/docker
docker compose up -d

# 5. Check status
docker compose ps
docker compose logs -f homeassistant
```

### Accessing Services

Once deployed at ww87:

- **Home Assistant**: <http://192.168.1.100:8123>
- **Zigbee2MQTT UI**: <http://192.168.1.100:8888>
- **MQTT Broker**: `192.168.1.100:1883`

### USB Device Pass-through (For Zigbee/Z-Wave)

If you have a Zigbee or Z-Wave USB adapter:

```bash
# Find your device
lsusb

# Edit docker-compose.yml and uncomment the devices section:
# devices:
#   - /dev/ttyUSB0:/dev/ttyUSB0
```

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

At ww87, USB devices for Zigbee and Matter may need to be passed through.

See the commented `devices:` section in [`../examples/docker-compose.yml`](../examples/docker-compose.yml) for configuration details.

```bash
# List USB devices to find your adapter
lsusb

# Typically appears as /dev/ttyUSB0 or /dev/ttyACM0
```

## Notes

- **Example Configuration**: [`../examples/docker-compose.yml`](../examples/docker-compose.yml)
- **Manual Setup Required**: Docker Compose configuration must be copied and configured by gb user
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
