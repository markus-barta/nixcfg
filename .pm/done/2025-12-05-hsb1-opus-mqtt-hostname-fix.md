# 2025-12-05 - hsb1 Opus-to-MQTT Hostname Quick Fix

## Description

Quick fix to update the MQTT broker hostname in the Opus-to-MQTT container to point to the correct hsb1 address.

## Status

🔴 **URGENT** - Container currently using wrong MQTT broker address

## Scope

Applies to: hsb1

## Fix Required

Update `/home/mba/docker/mounts/opus-stream-to-mqtt/app/.env`:

```bash
MQTT_BROKER=mqtt://192.168.1.101:1883  # hsb1 local MQTT
```

## Verification

After fix, monitor MQTT topic for Opus gateway telegrams:

```bash
mosquitto_sub -h localhost -t "opus2mqtt/#" -v
```

Should see frequent updates from the Opus gateway (heating system activity).

## Notes

- This is a quick fix - proper agenix migration tracked in: `2025-12-05-hsb1-opus-mqtt-credentials.md`
- Container restart required after .env change
