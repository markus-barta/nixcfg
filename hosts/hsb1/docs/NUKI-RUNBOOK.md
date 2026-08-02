# Nuki Smart Lock Integration

**Server**: hsb1  
**Last Updated**: 2026-08-02

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

- **VR**: `homeassistant/lock/nuki_vr/state` ( `locked` / `unlocked` / `locking` / `unlocking` / `unavailable` )
- **KE**: `homeassistant/lock/nuki_ke/state` ( same payloads )

These are published by HA statestream (retained, lowercase HA states). The Nuki Ultra's own raw topics live under `nuki/<ID>/…` (e.g. `nuki/463F8F47/state`, numeric).

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
Input:  homeassistant/lock/nuki_vr/state (statestream, retained)
        │  VR tab: mqtt in → global.set "home/vr/smartlock/state"
        │
        ├─► Hue Bulb (💡 Lights tab → z2m/ez/light/hue-bulb-smartlock/set)
        │   - locked   → Red (#FF0000)
        │   - unlocked → Green (#00FF00)
        │   - else     → Yellow (#FFFF00)
        │
        └─► Shellie LEDs (💡 Lights tab, group "Statusled sz":
            3s inject polls the global var → switch → rbe →
            shellies/home/sz/statusled-smartlock/relay/N/command)
            - locked   → red on  (relay/1), green off (relay/0)
            - unlocked → green on (relay/0), red off  (relay/1)
            - else (unavailable/unknown) → BOTH OFF   (since 2026-08-02)
```

**Note**: the `rbe` (report-by-exception) nodes only publish on _change_. After a
Shelly reboot or MQTT outage the LEDs stay stale until the next lock state change —
force a resync by publishing the relay commands manually (see below) or via the
inject buttons in group "VR-Lock-Status-LEDs /sz".

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

- **VR**: Smart plug automation follow-up is tracked in PPM (`pm.barta.cm`)
- **KE**: Similar pattern; track follow-up in PPM

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
# Subscribe to Nuki MQTT topics (broker requires auth — creds via agenix)
ssh mba@hsb1.lan
sudo bash -c 'set -a; source /run/agenix/hsb1-mqtt-client-env; set +a
  docker exec mosquitto mosquitto_sub -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t "homeassistant/lock/nuki_vr/#" -v'
```

### Test MQTT Publishing

```bash
# Manually publish test state (payloads are lowercase HA states)
sudo bash -c 'set -a; source /run/agenix/hsb1-mqtt-client-env; set +a
  docker exec mosquitto mosquitto_pub -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t "homeassistant/lock/nuki_vr/state" -m locked'
```

### Check Nuki Ultra MQTT Config

The Nuki Ultra should be configured in the Nuki App to publish to:

- Broker: `192.168.1.101:1883` (hsb1)
- Username: `smarthome`
- Password: (agenix `/run/agenix/hsb1-mqtt-client-env`, `$MQTT_PASS` — never cat)
- Topic prefix: `homeassistant/lock/`

---

## Files Reference

| File           | Location                                                                                                                    |
| -------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Node-RED Flows | `~/docker/mounts/nodered/data/flows.json`                                                                                   |
| HA Config      | `~/docker/mounts/homeassistant/configuration.yaml`                                                                          |
| HA Automations | `~/docker/mounts/homeassistant/automations.yaml`                                                                            |
| MQTT Config    | HA Integration (Settings → Devices → MQTT)                                                                                  |
| Secrets        | agenix: `/run/agenix/hsb1-smarthome-env` (HA_TOKEN), `/run/agenix/hsb1-mqtt-client-env` (MQTT_USER / MQTT_PASS / MQTT_HOST) |

---

## Hue Bulb Status (Visual Indicator)

| Nuki State      | Hue Bulb Color       | Shellie Green LED | Shellie Red LED |
| --------------- | -------------------- | ----------------- | --------------- |
| locked          | Red (#FF0000)        | OFF               | ON              |
| unlocked        | Green (#00FF00)      | ON                | OFF             |
| **unavailable** | **Yellow (#FFFF00)** | **OFF**           | **OFF**         |

_Unavailable → both LEDs off since 2026-08-02 (previously the else-branch lit green)._

---

## Shelly Uni Status LEDs (SZ)

Custom-built indicator in the bedroom: Shelly Uni (Gen1, `SHUNI-1`) in an encasing
with a green and a red LED on the relay outputs.

| Item     | Value                                                                    |
| -------- | ------------------------------------------------------------------------ |
| IP       | `192.168.1.181` (WiFi)                                                   |
| MQTT id  | `home/sz/statusled-smartlock`                                            |
| relay/0  | green LED — "Unlocked"                                                   |
| relay/1  | red LED — "Locked"                                                       |
| Commands | `shellies/home/sz/statusled-smartlock/relay/{0,1}/command` (`on`/`off`)  |
| Power-on | both relays default **off** (LEDs dark until next state change / resync) |

### 🔴 Gotcha: Shelly Cloud kills MQTT (2026-08-02 incident)

Gen1 firmware runs **either** Shelly Cloud **or** MQTT — never both. Enabling
cloud (e.g. via the Shelly app) silently disables MQTT; the LEDs then freeze at
their last state while Node-RED publishes into the void. Check with:

```bash
curl -s http://192.168.1.181/status | jq '.mqtt, .cloud'
```

Fix: disable cloud / re-enable MQTT, then force a resync (rbe won't resend an
unchanged state):

```bash
sudo bash -c 'set -a; source /run/agenix/hsb1-mqtt-client-env; set +a
  docker exec mosquitto mosquitto_pub -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t "shellies/home/sz/statusled-smartlock/relay/1/command" -m on   # red (locked)
  docker exec mosquitto mosquitto_pub -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t "shellies/home/sz/statusled-smartlock/relay/0/command" -m off  # green
'
```

---

**See Also**:

- [SMARTHOME.md](./SMARTHOME.md) - Full smart home architecture
- NUKI charging automation follow-up: tracked in PPM (`pm.barta.cm`)

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
