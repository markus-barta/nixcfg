# P5600: Enable Home Assistant on hsb8

**Priority**: P5 (Medium)  
**Status**: ✅ Completed (2025-12-21)  
**Access**: `ssh mba@192.168.1.100` (via WireGuard VPN to ww87)

## Summary

Deployed Home Assistant on hsb8 at parents' home (ww87) with full smart home integration.

## What Was Deployed

### Docker Stack

| Container     | Image                                        | Purpose                    |
| ------------- | -------------------------------------------- | -------------------------- |
| homeassistant | ghcr.io/home-assistant/home-assistant:stable | Smart home platform        |
| mosquitto     | eclipse-mosquitto:latest                     | Local MQTT broker (backup) |
| watchtower    | containrrr/watchtower:latest                 | Auto-updates (Sat 08:00)   |

### Integrations Configured

| Integration  | Source                  | Config          | Notes                                       |
| ------------ | ----------------------- | --------------- | ------------------------------------------- |
| MQTT         | Built-in                | UI              | Connects to z2m broker at 192.168.1.11:1883 |
| Zigbee2MQTT  | HACS                    | UI              | 13 Zigbee devices via external z2m          |
| Kostal Piko  | HACS                    | YAML            | Solar inverter at 192.168.1.20              |
| Tesla Custom | HACS (copied from hsb1) | UI              | Via public fleet proxy                      |
| Tasmota      | Built-in                | Auto-discovered | Smart plugs via MQTT                        |
| HACS         | Manual install          | UI              | Community integrations store                |

### NixOS Configuration Changes

- Added firewall ports: 1883 (MQTT), 8123 (HA Web UI)
- Enabled Bluetooth: `hardware.bluetooth.enable = true`
- Cleaned up copy/paste Roborock DNS allowlist (not needed at ww87)

### File Locations on hsb8

```text
/home/gb/
├── docker/
│   ├── docker-compose.yml
│   └── mounts/
│       ├── homeassistant/
│       │   ├── configuration.yaml
│       │   └── custom_components/
│       │       ├── hacs/
│       │       ├── kostal/
│       │       └── tesla_custom/
│       └── mosquitto/
│           ├── config/mosquitto.conf
│           ├── data/
│           └── log/
└── secrets/
    └── watchtower.env
```

### HA configuration.yaml

```yaml
default_config:

frontend:
  themes: !include_dir_merge_named themes

automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml

# Kostal Solar Inverter
sensor:
  - platform: kostal
    host: http://192.168.1.20
    username: pvserver
    password: pvwr
    monitored_conditions:
      - solar_generator_power
      - consumption_phase_1
      - consumption_phase_2
      - consumption_phase_3
      - current_power
      - total_energy
      - daily_energy
      - status

# ESP32-CAM MQTT Sensors (if unique topics configured)
mqtt:
  sensor:
    - name: "ESP32-CAM Temperatur"
      state_topic: "sensor/temperature"
      unit_of_measurement: "°C"
      device_class: temperature

    - name: "ESP32-CAM RSSI"
      state_topic: "sensor/rssi"
      unit_of_measurement: "dBm"
      device_class: signal_strength
```

---

## Access

| Service         | URL                                 |
| --------------- | ----------------------------------- |
| Home Assistant  | http://192.168.1.100:8123           |
| AdGuard Home    | http://192.168.1.100:3000           |
| Zigbee2MQTT     | http://192.168.1.11:8085 (external) |
| Kostal Inverter | http://192.168.1.20                 |

---

## Common Operations

### View Logs

```bash
# HA logs
ssh mba@192.168.1.100 "docker logs homeassistant --tail 50"

# All containers
ssh mba@192.168.1.100 "docker ps --format 'table {{.Names}}\t{{.Status}}'"
```

### Restart Services

```bash
ssh mba@192.168.1.100 "docker restart homeassistant"
```

### Edit HA Config

```bash
ssh mba@192.168.1.100 "docker exec homeassistant cat /config/configuration.yaml"
```

---

## Known Issues / Notes

1. **ESP32-CAM**: Cameras not yet added (need `/stream` endpoint, not `/capture`)
2. **MQTT Topics**: ESP32s publish to same topics - need unique topics per device
3. **Kostal**: Uses old YAML platform (no device entry, only entities)
4. **Bluetooth**: Required enabling BlueZ on NixOS host for HA Bluetooth support

---

## Reference

- Runbook: `hosts/hsb8/docs/RUNBOOK.md`
- NixOS config: `hosts/hsb8/configuration.nix`
- hsb1 reference: `hosts/hsb1/docs/RUNBOOK.md`
