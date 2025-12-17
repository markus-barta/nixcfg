# 2025-12-05 - hsb1 Opus-to-MQTT Credential Fix

## Description

The Opus to MQTT stream container on hsb1 uses a local `.env` file embedded within the application directory instead of externalized secrets. This should be migrated to use proper agenix-managed secrets.

## Scope

Applies to: hsb1

## Current State (Problem)

**Container**: `opus-stream-to-mqtt` (node:alpine)

**Credential file location**:

```
/home/mba/docker/mounts/opus-stream-to-mqtt/app/.env
```

**Credentials stored** (plain text):

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

**Application**: `opus_stream_to_mqtt.js` loads via `require('dotenv').config()`

**Issues**:

- Credentials in plain text on filesystem
- Not managed via agenix
- Mixed with application code in bind mount
- No encryption at rest

## Acceptance Criteria

- [ ] Create agenix secret `secrets/opus-stream-hsb1.age` with all credentials
- [ ] Update `secrets/secrets.nix` to include the new secret
- [ ] Modify container to mount secret file from `/run/agenix/`
- [ ] Update `opus_stream_to_mqtt.js` to read from mounted secret (or use env-file)
- [ ] Remove `.env` file from `/home/mba/docker/mounts/opus-stream-to-mqtt/app/`
- [ ] Verify stream functionality after migration
- [ ] Document the secret in `docs/private/secrets-inventory.md`

## Implementation Options

### Option A: Docker `--env-file` with agenix

```nix
# In configuration.nix
age.secrets.opus-stream-env = {
  file = ../../secrets/opus-stream-hsb1.age;
  owner = "mba";
};

# Docker run with --env-file /run/agenix/opus-stream-env
```

### Option B: Mount secret and modify app

Mount the decrypted secret file and have the app read from the mounted path instead of local `.env`.

## Notes

- Related to: `2025-12-01-hsb1-agenix-secrets.md` (general secrets migration)
- Priority: Medium - security improvement, not blocking functionality
- The MQTT credentials may overlap with existing `mqtt.env` in `/etc/secrets/`

## References

- Container mount: `/home/mba/docker/mounts/opus-stream-to-mqtt/app`
- hsb1 configuration: `hosts/hsb1/configuration.nix`
- Secrets documentation: `docs/how-it-works.md`
