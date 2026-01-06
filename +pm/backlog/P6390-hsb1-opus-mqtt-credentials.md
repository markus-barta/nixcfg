# hsb1 Opus-to-MQTT Credential Migration

**Created**: 2025-12-05  
**Updated**: 2026-01-06  
**Priority**: P6390 (Low)  
**Status**: Backlog  
**Host**: hsb1

---

## Problem

The `opus-stream-to-mqtt` Docker container uses a plain-text `.env` file embedded in the application directory instead of agenix-managed secrets.

**Current state** (verified 2026-01-06):

- Container is running (Up 4 days)
- Credentials stored in plain text at `/home/mba/docker/mounts/opus-stream-to-mqtt/app/.env`
- Contains both Opus gateway and MQTT credentials

---

## Current Credentials

| Variable      | Purpose                  |
| ------------- | ------------------------ |
| `STREAM_USER` | Opus gateway username    |
| `STREAM_PASS` | Opus gateway password    |
| `STREAM_IP`   | Opus gateway IP address  |
| `STREAM_PORT` | Opus gateway port        |
| `MQTT_BROKER` | MQTT broker URL          |
| `MQTT_TOPIC`  | MQTT topic for telegrams |
| `MQTT_USER`   | MQTT username            |
| `MQTT_PASS`   | MQTT password            |

**Location**: `/home/mba/docker/mounts/opus-stream-to-mqtt/app/.env`

---

## Solution

Migrate to agenix using Docker's `--env-file` option.

### 1. Create Agenix Secret

```bash
cd ~/Code/nixcfg

agenix -e secrets/opus-stream-hsb1.age
# Contents (copy from existing .env):
# STREAM_USER=admin
# STREAM_PASS=<password>
# STREAM_IP=192.168.1.102
# STREAM_PORT=8080
# MQTT_BROKER=<broker>
# MQTT_TOPIC=<topic>
# MQTT_USER=<user>
# MQTT_PASS=<password>
```

### 2. Update secrets/secrets.nix

```nix
"opus-stream-hsb1.age".publicKeys = [ mba hsb1 ];
```

### 3. Add to hosts/hsb1/configuration.nix

```nix
age.secrets.opus-stream-env = {
  file = ../../secrets/opus-stream-hsb1.age;
  owner = "mba";
  mode = "0400";
};
```

### 4. Update Docker Run Command

Change the container startup to use `--env-file /run/agenix/opus-stream-env` instead of the local `.env` file.

---

## Acceptance Criteria

- [ ] Create `secrets/opus-stream-hsb1.age` with all credentials
- [ ] Update `secrets/secrets.nix` with new secret
- [ ] Add `age.secrets` block to `hosts/hsb1/configuration.nix`
- [ ] Update container to use `--env-file` from agenix path
- [ ] Deploy and verify stream functionality
- [ ] Remove `.env` file from docker mounts directory

---

## Test Plan

### Manual Test

1. Deploy: `ssh mba@hsb1.lan 'cd ~/Code/nixcfg && git pull && just switch'`
2. Restart container with new env-file path
3. Verify container runs: `docker logs opus-stream-to-mqtt`
4. Verify MQTT messages are being published

### Automated Test

```bash
# Verify secret exists
ssh mba@hsb1.lan 'test -f /run/agenix/opus-stream-env && echo "✅ Secret deployed"'

# Verify container is running
ssh mba@hsb1.lan 'docker ps --filter "name=opus" --format "{{.Status}}"'
```

---

## Notes

- The MQTT credentials here are separate from the `mqtt.env` in `/etc/secrets/` (different service)
- Container is currently managed manually via Docker CLI, not declaratively
- Consider combining with P5500 (Docker restructure) or P5700 (VLC kiosk declarative)

---

## Related

- `P6380-hsb1-agenix-secrets.md` - System-level secrets migration (different secrets)
- `P5500-hsb1-docker-restructure.md` - Docker management improvements
