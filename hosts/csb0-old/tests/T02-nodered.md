# T02: Node-RED (csb0)

Test Node-RED container and external accessibility.

## Host Information

| Property         | Value                       |
| ---------------- | --------------------------- |
| **Host**         | csb0                        |
| **Service**      | Node-RED                    |
| **External URL** | https://home.barta.cm       |
| **Role**         | Smart home automation flows |

## Prerequisites

- [ ] SSH access to csb0
- [ ] Traefik routing working

## Automated Tests

Run: `./T02-nodered.sh`

## Test Procedures

### Test 1: Container Running

**Command:** `docker ps --format "{{.Names}}" | grep nodered`

**Expected:** Container found

### Test 2: Container Stable

**Command:** `docker inspect --format "{{.RestartCount}}" <container>`

**Expected:** < 5 restarts

### Test 3: Flows Data Exists

**Command:** `docker exec <container> test -f /data/flows.json`

**Expected:** File exists

### Test 4: External URL Accessible

**Command:** `curl -I https://home.barta.cm`

**Expected:** HTTP 200, 401, or 302

### Test 5: SSL Certificate

**Command:** `curl -sI https://home.barta.cm`

**Expected:** Valid SSL response

## Test Results Summary

| Test | Description       | Status |
| ---- | ----------------- | ------ |
| T1   | Container Running | ⏳     |
| T2   | Container Stable  | ⏳     |
| T3   | Flows Data        | ⏳     |
| T4   | External URL      | ⏳     |
| T5   | SSL Certificate   | ⏳     |

## Notes

- Node-RED controls garage door for family/neighbors
- Telegram bot integration for notifications
- Flows backed up via restic to Hetzner
