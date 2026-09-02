# T04: Docker Services (hsb1)

Test that all expected Docker services are running and responding.

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

### Test 2: All Services Running

**Steps:**

1. List containers: `docker ps`

**Expected Results:**

All 17 services currently declared by `compose-spec.nix` are running:

- apprise
- fritz-tripwire
- funkeykid
- homeassistant
- hsb1-home
- matter-server
- mosquitto
- nodered
- opus-stream-to-mqtt
- opusweb
- pharos-beacon
- pixdcon
- plex
- restic-cron-hetzner
- scrypted
- smtp
- turbogmailify
- zigbee2mqtt

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
| T2   | Services Up      | ⏳     |
| T3   | Services Respond | ⏳     |

## Notes

- The stack is declared in `hosts/hsb1/docker/compose-spec.nix`, rendered at
  `/etc/compose/hsb1/docker-compose.yml`, and reconciled by
  `compose-hsb1.service`; `~/docker` holds runtime data, not the compose source.
- `compose-hsb1-update.timer` owns weekly image updates.
- Backups via restic-cron-hetzner container
