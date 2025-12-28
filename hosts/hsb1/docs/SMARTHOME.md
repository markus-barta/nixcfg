# Smart Home Architecture & Best Practices

**Server**: hsb1 (Home Server Barta 1)  
**Location**: jhw22 (Home)  
**Last Updated**: November 28, 2025  
**Migration**: Completed 2025-11-28 (was miniserver24)

---

## 📊 Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            SMART HOME STACK                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌───────────┐  │
│  │   Zigbee     │───▶│  Zigbee2MQTT │───▶│   Mosquitto  │───▶│   Home    │  │
│  │   Devices    │    │   (Z2M)      │    │    (MQTT)    │    │ Assistant │  │
│  │   (133+)     │    │   :8888      │    │    :1883     │    │   :8123   │  │
│  └──────────────┘    └──────────────┘    └──────────────┘    └─────┬─────┘  │
│                                                                    │        │
│  ┌──────────────┐    ┌──────────────┐                         ┌────▼────┐   │
│  │   Node-RED   │◀──▶│   Mosquitto  │                         │ HomeKit │   │
│  │   :1880      │    │              │                         │ Bridge  │   │
│  └──────────────┘    └──────────────┘                         │ :51828  │   │
│                                                               └────┬────┘   │
│  ┌──────────────┐    ┌──────────────┐                              │        │
│  │   Scrypted   │───▶│   HomeKit    │◀─────────────────────────────┘        │
│  │   (Cameras)  │    │   (Apple)    │                                       │
│  └──────────────┘    └──────────────┘                                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 🐳 Docker Services

| Container               | Port       | Purpose                  | Critical |
| ----------------------- | ---------- | ------------------------ | -------- |
| **zigbee2mqtt**         | 8888       | Zigbee device management | 🔴 Yes   |
| **homeassistant**       | 8123       | Smart home platform      | 🔴 Yes   |
| **mosquitto**           | 1883, 9001 | MQTT broker              | 🔴 Yes   |
| **scrypted**            | varies     | Camera/HomeKit bridge    | 🔴 Yes   |
| **nodered**             | 1880       | Automation flows         | 🟠 High  |
| **matter-server**       | varies     | Matter protocol          | 🟡 Med   |
| **apprise**             | 8001       | Notifications            | 🟡 Med   |
| **restic-cron-hetzner** | N/A        | Backups                  | 🟠 High  |
| **watchtower-weekly**   | N/A        | Auto-updates             | 🟢 Low   |
| **smtp**                | 25         | Mail relay               | 🟢 Low   |
| **opus-stream-to-mqtt** | N/A        | Audio streaming          | 🟢 Low   |

---

## 📁 File Locations

### Docker Configuration

```
~/docker/
├── docker-compose.yml          # Main compose file
├── Makefile                    # Common commands
├── mounts/                     # Runtime data
│   ├── homeassistant/
│   │   ├── configuration.yaml  # ← Main HA config
│   │   ├── automations.yaml
│   │   └── .storage/           # Entity registry, etc.
│   ├── zigbee2mqtt/
│   │   ├── configuration.yaml  # ← Device friendly names
│   │   ├── database.db         # Device database
│   │   └── state.json          # Current device states
│   ├── nodered/
│   │   └── data/flows.json     # Node-RED automations
│   └── mosquitto/
│       └── config/mosquitto.conf
├── restic-cron/
└── smtp/
```

### Secrets

```
~/secrets/
├── smarthome.env       # Main credentials (HASS_TOKEN, etc.)
├── zigbee2mqtt.env     # Z2M MQTT credentials
├── mqtt.env            # MQTT broker credentials
└── tapoC210-00.env     # Camera passwords
```

---

## 🔧 Adding a New Zigbee Device

### Step 1: Pair the Device

```bash
# Enable pairing mode (via Z2M web UI or MQTT)
docker exec mosquitto mosquitto_pub -t "zigbee2mqtt/bridge/request/permit_join" -m '{"value": true}'

# Watch for new devices
docker logs -f zigbee2mqtt | grep -i "interview"
```

### Step 2: Rename in Zigbee2MQTT

Edit `~/docker/mounts/zigbee2mqtt/configuration.yaml`:

```yaml
devices:
  "0x54ef4410014966cf": # IEEE address from logs
    friendly_name: gz/presence/fp300 # Use room/type/model format
    description: |
      🔷 Aqara FP300 Multi-Presence Sensor
      🏠 Gästezimmer • Anwesenheit
```

**Naming Convention**: See [Naming & UX Best Practices](#🏆-naming--ux-best-practices) for details.

### Step 3: Verify in Home Assistant

```bash
# Check entity registry
cat ~/docker/mounts/homeassistant/.storage/core.entity_registry | \
  jq '.data.entities[] | select(.unique_id | contains("ADDRESS"))'

# Or use the HA API
curl -s http://localhost:8123/api/states | jq '.[].entity_id' | grep -i "device"
```

### Step 4: Add to HomeKit (if needed)

Edit `~/docker/mounts/homeassistant/configuration.yaml`:

1. **Add to `include_entities`** (whitelist):

```yaml
homekit:
  - name: "HASS Bridge YAML"
    port: 51828
    filter:
      include_entities:
        # ... existing entries ...
        - binary_sensor.0x54ef4410014966cf_presence # gz/presence/fp300
        - sensor.0x54ef4410014966cf_temperature
        - sensor.0x54ef4410014966cf_humidity
```

2. **Add to `entity_config`** (friendly names):

```yaml
entity_config:
  # ... existing entries ...

  binary_sensor.0x54ef4410014966cf_presence:
    name: "Gästezimmer Anwesenheit"
    # gz/presence/fp300 - Aqara FP300 Multi-Presence

  sensor.0x54ef4410014966cf_temperature:
    name: "Gästezimmer Temperatur"
```

3. **Restart Home Assistant**:

```bash
docker restart homeassistant
# Wait ~30s, check logs for errors
docker logs homeassistant --tail 50 2>&1 | grep -i homekit
```

---

## 🏠 Room Abbreviations

| Code | German       | English            |
| ---- | ------------ | ------------------ |
| `bz` | Badezimmer   | Bathroom           |
| `ki` | Kinderzimmer | Children's room    |
| `vr` | Vorraum      | Hallway            |
| `sz` | Schlafzimmer | Bedroom            |
| `ez` | Esszimmer    | Dining room        |
| `ku` | Küche        | Kitchen            |
| `vk` | Vorküche     | Pre-kitchen        |
| `te` | Terrasse     | Terrace            |
| `dt` | Dachterrasse | Roof terrace       |
| `tg` | Tiefgarage   | Underground garage |
| `wc` | WC           | Toilet             |
| `gz` | Gästezimmer  | Guest room         |
| `gw` | Gäste WC     | Guest toilet       |

---

## 🔍 Debugging Commands

### Check Device State (MQTT)

```bash
# Get current state of a device
docker exec mosquitto mosquitto_sub -t "zigbee2mqtt/DEVICE_NAME" -C 1 -W 5

# Subscribe to all messages from a device
docker exec mosquitto mosquitto_sub -v -t "zigbee2mqtt/DEVICE_NAME/#"
```

### Check Device in Z2M Database

```bash
# Find device by address
cat ~/docker/mounts/zigbee2mqtt/database.db | tr "}" "\n" | grep "ADDRESS"

# Check state.json for current values
cat ~/docker/mounts/zigbee2mqtt/state.json | jq '."0xADDRESS"'
```

### Check Home Assistant Entities

```bash
# Find entities for a device
cat ~/docker/mounts/homeassistant/.storage/core.entity_registry | \
  jq '.data.entities[] | select(.unique_id | contains("ADDRESS")) | {entity_id, original_name}'
```

### View Logs

```bash
docker logs zigbee2mqtt --tail 50 | grep -i "ADDRESS"
docker logs homeassistant --tail 100 2>&1 | grep -i "homekit\|error"
docker logs nodered --tail 50
```

---

## 📋 HomeKit Bridge Configuration

**Location**: `~/docker/mounts/homeassistant/configuration.yaml`

### Structure

```yaml
homekit:
  - name: "HASS Bridge YAML"
    port: 51828 # Custom port (default is 51827)
    filter:
      include_entities:
        # Contact Sensors
        - binary_sensor.XXX_contact

        # Motion & Presence
        - binary_sensor.XXX_presence
        - binary_sensor.XXX_occupancy

        # Environmental
        - sensor.XXX_temperature
        - sensor.XXX_humidity

        # Climate
        - climate.XXX

        # Lights
        - light.XXX

        # Switches (can be configured as valves)
        - switch.XXX

        # Locks
        - lock.XXX

    entity_config:
      switch.XXX:
        name: "Friendly Name"
        type: valve # Configure switch as HomeKit valve
```

### Special Entity Types

- **Valves**: Use `type: valve` for irrigation switches
- **Locks**: Get a warning recommending accessory mode (can ignore)
- **Sensors**: Automatically detected based on device class

---

## 🏆 Naming & UX Best Practices

### HomeKit Naming

When exposing entities to HomeKit via Home Assistant, always **prefix the literal room name** to the entity name in `entity_config`.

- ✅ **DO**: `Terrasse D28`, `Esszimmer Ensis Oben`
- ❌ **DON'T**: `D28`, `Ensis Oben`

**Benefits:**

1. **Searchability**: Easier to identify devices in global search or lists.
2. **Error Detection**: If a device is moved to the wrong room in HomeKit, the prefix makes the mismatch immediately obvious.
3. **Smart Display**: HomeKit automatically trims the room name from the UI if it matches the room the device is assigned to (e.g., "Terrasse D28" in the "Terrasse" room displays simply as "D28").

### Zigbee2MQTT Naming

Use the convention: `room/type/device_name` (e.g., `bz/light/mirror`, `ku/plug/coffee`).
See [Room Abbreviations](#🏠-room-abbreviations) for codes.

---

## 🤖 AI Agent Best Practices

### Before Making Changes

1. **Always backup first**:

   ```bash
   cp ~/docker/mounts/homeassistant/configuration.yaml \
      ~/docker/mounts/homeassistant/configuration.yaml.bak
   ```

2. **Check current state**:

   ```bash
   grep -n "PATTERN" ~/docker/mounts/homeassistant/configuration.yaml
   ```

3. **Validate YAML after changes**:
   ```bash
   python3 -c "import yaml; yaml.safe_load(open('FILE'))"
   ```

### Making Edits

1. **Use Python for complex edits** (fish shell doesn't support heredocs):

   ```bash
   ssh server 'bash -c "python3 << EOF
   # Python script here
   EOF"'
   ```

2. **Use sed for simple line additions** (be careful with escaping):

   ```bash
   sed -i '/PATTERN/a NEW_LINE' file
   ```

3. **Always verify changes before restarting**:
   ```bash
   grep -A5 "PATTERN" configuration.yaml
   ```

### After Changes

1. **Restart the affected service**:

   ```bash
   docker restart homeassistant  # or zigbee2mqtt, nodered, etc.
   ```

2. **Check logs for errors**:

   ```bash
   docker logs SERVICE --tail 50 2>&1 | grep -i "error\|warning"
   ```

3. **Verify functionality**:
   ```bash
   # Check if HomeKit bridge loaded
   docker logs homeassistant 2>&1 | grep -i "homekit" | tail -5
   ```

---

## 🔐 Security Notes

- **MQTT credentials**: Stored in `~/secrets/mqtt.env`
- **HASS token**: Stored in `~/secrets/smarthome.env`
- **Camera passwords**: Stored in `/etc/secrets/` (agenix managed)
- **Never commit secrets to git**

---

## 📱 Device Types & Entities

### Presence/Motion Sensors (Aqara)

| Model     | Entities Created                                                                       |
| --------- | -------------------------------------------------------------------------------------- |
| **FP1**   | `_presence`, `_device_temperature`                                                     |
| **FP1E**  | `_presence`, `_motion`, `_device_temperature`                                          |
| **FP300** | `_presence`, `_pir_detection`, `_temperature`, `_humidity`, `_illuminance`, `_battery` |
| **P1**    | `_occupancy`, `_illuminance`, `_device_temperature`                                    |

### Contact Sensors

| Model                 | Entities               |
| --------------------- | ---------------------- |
| **Aqara Door/Window** | `_contact`, `_battery` |

### Climate

| Type                   | Entities                                   |
| ---------------------- | ------------------------------------------ |
| **Generic Thermostat** | `climate.NAME` (uses switch + temp sensor) |

### Irrigation

| Type                | Entities                                   |
| ------------------- | ------------------------------------------ |
| **Gardeneer Valve** | `switch.ADDRESS`, `sensor.ADDRESS_battery` |

---

## 🔊 VLC Kiosk Audio Control (Babycam)

### Architecture (slightly insane but works™)

```
┌─────────────────┐     ┌──────────────┐     ┌─────────────────────────┐
│  Aqara Button   │────▶│   Node-RED   │────▶│   MQTT Topic            │
│  (double-press) │     │   (flow)     │     │   home/hsb1/kiosk-vlc-  │
└─────────────────┘     └──────────────┘     │   volume                │
                                             └───────────┬─────────────┘
                                                         │
                        ┌────────────────────────────────▼─────────────────┐
                        │  mqtt-volume-control.service (systemd)           │
                        │  - Subscribes to MQTT topic                      │
                        │  - Validates volume (0-512)                      │
                        │  - Sends telnet command to VLC                   │
                        └────────────────────────────────┬─────────────────┘
                                                         │
                        ┌────────────────────────────────▼─────────────────┐
                        │  VLC (kiosk user, fullscreen)                    │
                        │  - Telnet interface on localhost:4212            │
                        │  - Password from /etc/secrets/tapoC210-00.env    │
                        │  - Shows RTSP camera stream                      │
                        └──────────────────────────────────────────────────┘
```

### Components

| Component           | Location                                  | Purpose                                |
| ------------------- | ----------------------------------------- | -------------------------------------- |
| **Aqara Button**    | Physical device                           | Triggers volume toggle on double-press |
| **Node-RED Flow**   | `~/docker/mounts/nodered/data/flows.json` | Listens for button, publishes MQTT     |
| **MQTT Topic**      | `home/hsb1/kiosk-vlc-volume`              | Message bus for volume commands        |
| **systemd service** | `mqtt-volume-control.service`             | Bridge between MQTT and VLC telnet     |
| **VLC Telnet**      | `localhost:4212`                          | Accepts `volume N` commands            |
| **VLC Display**     | X11 kiosk session                         | Shows camera on attached monitor       |

### MQTT Message Format

```bash
# Mute (volume 0)
mosquitto_pub -h hsb1 -u USER -P PASS -t "home/hsb1/kiosk-vlc-volume" -m "0"

# Full volume (512)
mosquitto_pub -h hsb1 -u USER -P PASS -t "home/hsb1/kiosk-vlc-volume" -m "512"

# 50% volume (256)
mosquitto_pub -h hsb1 -u USER -P PASS -t "home/hsb1/kiosk-vlc-volume" -m "256"
```

### Files Involved

| File                           | Purpose                                            |
| ------------------------------ | -------------------------------------------------- |
| `/etc/secrets/mqtt.env`        | MQTT credentials (MQTT_HOST, MQTT_USER, MQTT_PASS) |
| `/etc/secrets/tapoC210-00.env` | VLC telnet password                                |
| `configuration.nix`            | systemd service definition                         |
| `flows.json`                   | Node-RED automation                                |

### Troubleshooting

```bash
# Check service status
systemctl status mqtt-volume-control

# View service logs
journalctl -t mqtt-volume-control -f

# Test MQTT manually
mosquitto_pub -h hsb1 -t "home/hsb1/kiosk-vlc-volume" -m "256"

# Test VLC telnet directly
echo -e "PASSWORD\nvolume 256\nquit" | nc localhost 4212
```

### ✅ Migration Complete (2025-11-28)

Hostname changed `miniserver24` → `hsb1`:

- **systemd service**: Listens on `home/hsb1/kiosk-vlc-volume` ✅
- **Node-RED flows**: Updated to `home/hsb1/kiosk-vlc-volume` ✅
- **DNS alias**: `miniserver24` still resolves (legacy, remove after 2025-12-28)

---

## 🔄 System Updates & Restarts

### After NixOS Rebuild

The kiosk display (babycam) may go blank after `nixos-rebuild switch`:

```bash
# Restart display manager to restore kiosk
sudo systemctl restart display-manager.service

# Verify VLC is running
pgrep -a vlc
```

### Known Non-Critical Warnings

These warnings appear after rebuild but are harmless:

| Warning                            | Cause                     | Impact                    |
| ---------------------------------- | ------------------------- | ------------------------- |
| `suid-sgid-wrappers.service`       | Restic capability setting | None (restic still works) |
| `systemd-zram-setup@zram0.service` | ZRAM swap restart         | None (16GB RAM is plenty) |

### Shell Differences (fish vs bash)

The default shell is **fish**. When sourcing `.env` files:

```bash
# ❌ Won't work in fish
source /etc/secrets/mqtt.env

# ✅ Use bash instead
bash -c 'source /etc/secrets/mqtt.env && echo $MQTT_HOST'
```

---

## 🔄 Common Workflows

### Add Presence Sensor to HomeKit

1. Pair device → Z2M assigns address
2. Rename in Z2M config (room/presence/model)
3. Find HA entities: `binary_sensor.ADDRESS_presence`
4. Add to HomeKit `include_entities`
5. Add to HomeKit `entity_config` with German name
6. Restart HA, verify in logs

### Troubleshoot Missing Device

1. Check Z2M logs: `docker logs zigbee2mqtt | grep ADDRESS`
2. Check database: `grep ADDRESS ~/docker/mounts/zigbee2mqtt/database.db`
3. Check state: `cat state.json | jq '."0xADDRESS"'`
4. Check MQTT: `mosquitto_sub -t "zigbee2mqtt/DEVICE/#"`

### Update Device Configuration

1. Edit Z2M `configuration.yaml` for device settings
2. Edit HA `configuration.yaml` for HomeKit exposure
3. Restart appropriate container
4. Verify in logs

---

## 📚 Related Documentation

- [Zigbee2MQTT Docs](https://www.zigbee2mqtt.io/)
- [Home Assistant HomeKit](https://www.home-assistant.io/integrations/homekit/)
- [Node-RED Docs](https://nodered.org/docs/)

---

**Maintainer**: Markus Barta  
**Server**: hsb1 (192.168.1.101)  
**133+ Zigbee Devices** | **11 Docker Containers** | **HomeKit Bridge** | **Babycam Kiosk**
