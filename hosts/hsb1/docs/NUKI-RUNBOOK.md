# Nuki Smart Lock Integration

**Server**: hsb1  
**Last Updated**: 2026-02-14

---

## Overview

| Lock   | Location           | Entity         | Unique ID       | MQTT Topic (State)                 |
| ------ | ------------------ | -------------- | --------------- | ---------------------------------- |
| **VR** | Vorraum (Entrance) | `lock.nuki_vr` | `463F8F47_lock` | `homeassistant/lock/nuki_vr/state` |
| **KE** | Keller (Basement)  | `lock.nuki_ke` | `4A5D18FF_lock` | `homeassistant/lock/nuki_ke/state` |

---

## Architecture

**Model**: Nuki Ultra (built-in WiFi, no bridge required)

```
Nuki Ultra (VR)
       │
       │ (Direct WiFi → MQTT)
       ▼
  ┌────────────┐
  │   Mosquitto │
  │  (MQTT)    │  hsb1:1883
  └─────┬──────┘
        │
        ▼ (Subscribe + Auto-Discovery)
  ┌─────────────────┐
  │ Home Assistant  │  Docker: homeassistant
  │  (MQTT Lock)    │  Port: 8123
  └────────┬────────┘
           │
           ▼ (State Topic)
  ┌─────────────────────────────────────┐
  │         Node-RED Flows              │
  │  • lock.nuki_vr state → Hue Bulb   │
  │  • lock.nuki_vr state → LED/Shellie│
  └─────────────────────────────────────┘
```

**Connectivity**: Nuki Ultra connects directly to WiFi and publishes MQTT to the broker on hsb1.

---

## MQTT Topics

### State Topics (Read by Node-RED)

- **VR**: `homeassistant/lock/nuki_vr/state` ( LOCK / UNLOCK / undefined )
- **KE**: `homeassistant/lock/nuki_ke/state` ( LOCK / UNLOCK / undefined )

### Command Topics (Write)

- **VR**: `ha/automation/nuki/set` - Publish `{"state": "LOCK"}` or `{"state": "UNLOCK"}`
- **KE**: `ha/automation/nuki_ke/set`

### Battery Topics

- `homeassistant/lock/nuki_vr/state` (contains battery in JSON payload)
- Entity: `sensor.nuki_vr_battery` (0-100%)

---

## Node-RED Flows

### VR (Vorraum) Flow

**Flow ID**: `d1b80e2d5f08edaf`

```
Input:  homeassistant/lock/nuki_vr/state
        │
        ├─► Hue Bulb (ez/light/hue-bulb-smartlock)
        │   - LOCK   → Red (#FF0000)
        │   - UNLOCK → Green (#00FF00)
        │   - undefined → Yellow (#FFFF00)
        │
        └─► Shellie LEDs (sz/statusled-smartlock)
            - green led  → relay/0 (UNLOCK)
            - red led    → relay/1 (LOCK)
```

### Access Node-RED

```bash
# Web UI
http://hsb1.lan:1880

# Flow URL
http://192.168.1.101:1880/#flow/d1b80e2d5f08edaf
```

---

## Home Assistant Entities

### VR (Vorraum)

| Entity                                   | Type   | Platform | Notes            |
| ---------------------------------------- | ------ | -------- | ---------------- |
| `lock.nuki_vr`                           | lock   | mqtt     | Main lock entity |
| `sensor.nuki_vr_battery`                 | sensor | mqtt     | Battery %        |
| `binary_sensor.nuki_vr_battery_critical` | binary | mqtt     | < 20%            |
| `binary_sensor.nuki_vr_battery_charging` | binary | mqtt     | Charging state   |
| `button.nuki_vr_unlatch`                 | button | mqtt     | Unlatch action   |
| `button.nuki_vr_lock_n_go`               | button | mqtt     | Lock 'n Go       |
| `sensor.nuki_vr_firmware_version`        | sensor | mqtt     | FW version       |

### KE (Keller)

| Entity                                   | Type   | Platform | Notes          |
| ---------------------------------------- | ------ | -------- | -------------- |
| `lock.nuki_ke`                           | lock   | mqtt     | Basement lock  |
| `sensor.nuki_ke_battery`                 | sensor | mqtt     | Battery %      |
| `binary_sensor.nuki_ke_battery_critical` | binary | mqtt     | < 20%          |
| `binary_sensor.nuki_ke_battery_charging` | binary | mqtt     | Charging state |

---

## Automations

### VR (Vorraum)

| Automation          | Trigger                        | Action                     |
| ------------------- | ------------------------------ | -------------------------- |
| MQTT steuert Nuki   | MQTT: `ha/automation/nuki/set` | Lock/Unlock `lock.nuki_vr` |
| Nuki aufladen Start | Battery < 25%                  | Turn on charging plug      |

### Charging Logic

- **VR**: Smart plug automation (see backlog: `P40--01f1163--nuki-ke-charging-automation.md`)
- **KE**: Similar pattern - see backlog item

---

## Troubleshooting

### Common Issue: Nuki Shows "undefined" (Yellow Hue Bulb)

**Symptom**: Hue bulb in Esszimmer shows yellow = Nuki state is undefined

**Cause**: Usually WiFi connectivity issues, NOT MQTT or Nuki firmware.

**2026-02-14 Incident**: Nuki was connecting to wrong mesh repeater, causing high latency and disconnects. Fix: Ensure Nuki connects to correct FritzBox mesh node.

**Debug Steps**:

1. Check WiFi signal in Nuki App
2. Ensure Nuki connects to main FritzBox, NOT a distant mesh repeater
3. If using mesh: place Nuki closer to main FritzBox or a strong repeater
4. Test: `ping <NUKI_IP>` - should be <10ms

**If WiFi is good and still issues**:

```bash
# Subscribe to Nuki MQTT topics
ssh mba@hsb1.lan
docker exec mosquitto mosquitto_sub -t 'homeassistant/lock/nuki_vr/#' -v
```

### Test MQTT Publishing

```bash
# Manually publish test state
docker exec mosquitto mosquitto_pub \
  -t 'homeassistant/lock/nuki_vr/state' \
  -m 'LOCK' \
  -u smarthome -P $(grep MQTT_PASS ~/secrets/mqtt.env | cut -d= -f2)
```

### Check Nuki Ultra MQTT Config

The Nuki Ultra should be configured in the Nuki App to publish to:

- Broker: `192.168.1.101:1883` (hsb1)
- Username: `smarthome`
- Password: (see `~/secrets/mqtt.env`)
- Topic prefix: `homeassistant/lock/`

---

## Files Reference

| File           | Location                                                   |
| -------------- | ---------------------------------------------------------- |
| Node-RED Flows | `~/docker/mounts/nodered/data/flows.json`                  |
| HA Config      | `~/docker/mounts/homeassistant/configuration.yaml`         |
| HA Automations | `~/docker/mounts/homeassistant/automations.yaml`           |
| MQTT Config    | HA Integration (Settings → Devices → MQTT)                 |
| Secrets        | `~/secrets/smarthome.env` (HA_TOKEN), `~/secrets/mqtt.env` |

---

## Hue Bulb Status (Visual Indicator)

| Nuki State    | Hue Bulb Color       | Shellie Green LED | Shellie Red LED |
| ------------- | -------------------- | ----------------- | --------------- |
| LOCKED        | Red (#FF0000)        | OFF               | ON              |
| UNLOCKED      | Green (#00FF00)      | ON                | OFF             |
| **undefined** | **Yellow (#FFFF00)** | ?                 | ?               |

---

**See Also**:

- [SMARTHOME.md](./SMARTHOME.md) - Full smart home architecture
- [backlog/P40--01f1163--nuki-ke-charging-automation.md](./docs/backlog/P40--01f1163--nuki-ke-charging-automation.md)

---

## 🛠️ Debugging: Check State History

### Find Entity Metadata ID

```bash
ssh mba@hsb1.lan 'python3 -c "
import sqlite3
conn = sqlite3.connect(\"/home/mba/docker/mounts/homeassistant/home-assistant_v2.db\")
c = conn.cursor()
c.execute(\"SELECT * FROM states_meta WHERE entity_id LIKE ?;\", (\"%nuki_vr%\",))
print(c.fetchall())
conn.close()
"'
```

Output:

```
[(2131, 'lock.nuki_vr'), ...]
```

→ Metadata ID = `2131`

### Query State History

```bash
ssh mba@hsb1.lan 'python3 -c "
import sqlite3
from datetime import datetime
conn = sqlite3.connect(\"/home/mba/docker/mounts/homeassistant/home-assistant_v2.db\")
c = conn.cursor()
c.execute(\"SELECT state, last_updated_ts FROM states WHERE metadata_id = 2131 ORDER BY last_updated_ts DESC LIMIT 30;\")
for row in c.fetchall():
    ts = row[1]
    if ts:
        dt = datetime.fromtimestamp(ts)
        print(f\"{dt} - {row[0]}\")
conn.close()
"'
```

### Pattern to Look For

| Pattern                                         | Meaning                        |
| ----------------------------------------------- | ------------------------------ |
| `unavailable` followed by `locked`              | MQTT dropped, then reconnected |
| Long gaps between states                        | Possible connectivity issue    |
| `unlocking` → `unlocked` → `locking` → `locked` | Normal operation               |

**Common Issue**: Nuki Ultra MQTT disconnects randomly, takes 10-30 min to recover. This is usually caused by WiFi issues (see above).

---

## ✅ No Additional Monitoring Needed (2026-02-14)

**Root cause of previous issues**: Nuki was connecting to wrong FritzBox mesh repeater, causing high latency and disconnects.

**Fix**: Ensure Nuki connects to main FritzBox or a strong mesh node with low latency (<10ms).

**Result**: Works flawlessly. No ping/heartbeat/keepalive workarounds required.
