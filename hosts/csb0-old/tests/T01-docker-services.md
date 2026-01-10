# T01: Docker Services (csb0)

Test Docker and container health on the cloud smart home hub.

## Host Information

| Property | Value                                |
| -------- | ------------------------------------ |
| **Host** | csb0                                 |
| **IP**   | 85.235.65.226                        |
| **SSH**  | `ssh mba@cs0.barta.cm -p 2222`       |
| **Role** | Smart Home Hub (🔴 HIGH criticality) |

## Prerequisites

- [ ] SSH access to csb0 via port 2222
- [ ] Docker service running

## Automated Tests

Run: `./T01-docker-services.sh`

## Test Procedures

### Test 1: Docker Service Status

**Command:** `systemctl is-active docker`

**Expected:** `active`

### Test 2: Docker Version

**Command:** `docker version --format "{{.Server.Version}}"`

**Expected:** Version number displayed

### Test 3: Running Containers

**Command:** `docker ps -q | wc -l`

**Expected:** Multiple containers running (9+)

### Test 4: No Unhealthy Containers

**Command:** `docker ps --filter "health=unhealthy" -q | wc -l`

**Expected:** 0

### Test 5: No Restarting Containers

**Command:** `docker ps --filter "status=restarting" -q | wc -l`

**Expected:** 0

### Test 6: Docker Networks

**Command:** `docker network ls -q | wc -l`

**Expected:** Multiple networks

### Test 7: Docker Volumes

**Command:** `docker volume ls -q | wc -l`

**Expected:** Multiple volumes

## Test Results Summary

| Test | Description           | Status |
| ---- | --------------------- | ------ |
| T1   | Docker Service Status | ⏳     |
| T2   | Docker Version        | ⏳     |
| T3   | Running Containers    | ⏳     |
| T4   | No Unhealthy          | ⏳     |
| T5   | No Restarting         | ⏳     |
| T6   | Docker Networks       | ⏳     |
| T7   | Docker Volumes        | ⏳     |

## Notes

- csb0 runs ~9 containers (Node-RED, MQTT, Traefik, etc.)
- Container issues affect smart home automation
