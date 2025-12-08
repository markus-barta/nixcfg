# T04: Docker Services (hsb1)

Test that all expected Docker containers are running and responding.

## Host Information

| Property | Value         |
| -------- | ------------- |
| **Host** | hsb1          |
| **Role** | Home Server   |
| **IP**   | 192.168.1.101 |

## Prerequisites

- [ ] SSH access to hsb1
- [ ] Docker daemon running

## Automated Tests

Run: `./T04-docker-services.sh`

## Manual Test Procedures

### Test 1: Docker Daemon Running

**Steps:**

1. Check Docker: `systemctl status docker`

**Expected Results:**

- Docker service active (running)

**Status:** ⏳ Pending

### Test 2: All Containers Running

**Steps:**

1. List containers: `docker ps`

**Expected Results:**

All 13 containers running:

- homeassistant
- nodered
- mosquitto
- zigbee2mqtt
- scrypted
- matter-server
- pidicon
- apprise
- opus-stream-to-mqtt
- smtp
- restic-cron-hetzner
- watchtower-weekly
- watchtower-pidicon

**Status:** ⏳ Pending

### Test 3: Key Services Responding

**Steps:**

1. Home Assistant: `curl -s http://localhost:8123`
2. Node-RED: `curl -s http://localhost:1880`
3. Zigbee2MQTT: `curl -s http://localhost:8888`
4. MQTT port: `ss -tlnp | grep 1883`

**Expected Results:**

- HTTP 200/302 responses from web UIs
- Port 1883 listening (MQTT)

**Status:** ⏳ Pending

## Test Results Summary

| Test | Description      | Status |
| ---- | ---------------- | ------ |
| T1   | Docker Daemon    | ⏳     |
| T2   | Containers Up    | ⏳     |
| T3   | Services Respond | ⏳     |

## Notes

- All containers managed via `~/docker/docker-compose.yml`
- Watchtower handles automatic updates
- Backups via restic-cron-hetzner container
