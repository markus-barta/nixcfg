# P8600: hsb8 Home Assistant ESP32 MQTT Integration

**Created**: 2026-01-11
**Priority**: P8600 (Backlog - Medium Priority)
**Status**: Backlog
**Depends on**: P8500 (hsb8 Grafana + InfluxDB Migration)

---

## Problem

Temperature data from 3 ESP32 controllers (with DS18B20 sensors) is currently flowing through MQTT to Mosquitto, Node-RED, and InfluxDB/Grafana. This data needs to be integrated into Home Assistant (HA) running on `hsb8` for centralized dashboarding and automation.

The data structure from the ESP32s is nested JSON, which needs careful parsing in HA.

**Current Setup:**
- **ESP32-1**: 1 sensor (Dachboden) + RSSI
- **ESP32-2**: 1 sensor (Kellerraum) + RSSI
- **ESP32-3**: 8 sensors (Heizung/WW/Außen) + RSSI

**Example Data (parsed JSON):**
```json
// Topic: esp32-3/ds18b20/temperature/#
{
  "0": 39.3125, // Heizkörperkreis Rücklauftemperatur
  "1": -0.125,  // Heizraum Außentemperatur
  "2": 15.5,    // Warmwasserwärmepumpe Austrittstemperatur
  "3": 42.8125, // Heizkörperkreis-Vorlauftemperatur
  "4": 19.4375, // Heizraum Innentemperatur
  "5": 32.75,   // Fußbodenheizungskreis-Vorlauftemperatur
  "6": 45.0625, // Warmwasserwärmepumpe Wassertemperatur
  "7": 31.4375, // Fußbodenheizungskreis-Rücklauftemperatur
  "rssi": -79
}
```

---

## Solution

Configure `mqtt` sensors in Home Assistant using `value_template` to extract individual values from the JSON payload. To ensure entities are manageable via the UI and grouped as devices, we use `unique_id` and the `device` object.

### Recommended Configuration (Professional Approach)

Using `unique_id` enables UI management, and the `device` block groups sensors under a single hardware entry.

```yaml
mqtt:
  sensor:
    # Example for ESP32-3 (Heizung)
    - name: "HKK Rücklauftemperatur"
      state_topic: "esp32-3/ds18b20/temperature"
      unique_id: "hsb8_esp32_3_t0"
      value_template: "{{ value_json['0'] }}"
      unit_of_measurement: "°C"
      device_class: temperature
      device:
        identifiers: "esp32_3_heating_ctrl"
        name: "ESP32-3 Heizungssteuerung"
        model: "ESP32 DS18B20 Multi-Sensor"
        manufacturer: "Custom"

    - name: "Heizraum Außentemperatur"
      state_topic: "esp32-3/ds18b20/temperature"
      unique_id: "hsb8_esp32_3_t1"
      value_template: "{{ value_json['1'] }}"
      unit_of_measurement: "°C"
      device_class: temperature
      device:
        identifiers: "esp32_3_heating_ctrl" # Identical ID groups sensors together
```

---

## Implementation Steps

### 1. Backup
- Create a full backup in HA (Settings > System > Backups).
- Download the backup and save the encryption key.

### 2. Configuration
- Edit `configuration.yaml`.
- Define all sensors for ESP32-1, ESP32-2, and ESP32-3.
- **CRITICAL**: Assign a `unique_id` to every sensor (e.g., `hsb8_esp32_1_temp`).
- **CRITICAL**: Add the `device` block to group sensors by their ESP32 controller.
- Use the correct `state_topic` (without the `#` wildcard).

### 3. Dashboard
- Since sensors are now part of a device, you can use the "Add to Dashboard" button directly from the Device page in HA.

### 4. Verification
- Restart Home Assistant or reload MQTT entities.
- Check "Settings > Devices & Services > Devices" for the new ESP32 entries.
- Verify that icons/names can be changed via the UI.

---

## Acceptance Criteria

- [ ] **Full Backup**: Created and downloaded.
- [ ] **MQTT Sensors**: All 10 temperature sensors + 3 RSSI sensors defined in HA.
- [ ] **Parsing Check**: Data correctly extracted from JSON (no `Unknown` states).
- [ ] **Dashboard**: Vertical stack with gauges/sensors and history graphs.
- [ ] **Unit Consistency**: All temperatures in °C, RSSI in dBm.

---

## Notes
- **Variante B** from the chat is mostly correct, but needs bracket notation for numeric keys: `value_json['0']`.
- Topic should be specific (e.g., `esp32-3/ds18b20/temperature`) rather than using wildcards if possible.
- If the ESP32s send data to sub-topics (e.g., `.../temperature/0`), then **Variante A** would be the way, but the JSON example suggests a single object.

**Last Updated**: 2026-01-11
**Created By**: SYSOP
