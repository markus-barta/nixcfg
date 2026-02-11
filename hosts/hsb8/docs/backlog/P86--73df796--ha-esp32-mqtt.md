# ha-esp32-mqtt

**Host**: hsb8
**Priority**: P86
**Status**: Backlog
**Created**: 2026-01-11

---

## Problem

Temperature data from 3 ESP32 controllers flows through MQTT to InfluxDB/Grafana, but not integrated into Home Assistant for centralized dashboarding and automation.

## Solution

Configure Home Assistant MQTT sensors to parse ESP32 JSON data using `value_template`. Group sensors by device for UI management.

## Implementation

- [ ] Add `mqtt` sensor config to HA configuration.yaml
- [ ] Create sensors for all 10 temperature readings + 3 RSSI values
- [ ] Use `value_template` to extract from JSON: `{{ value_json['0'] }}`
- [ ] Set `unique_id` for each sensor (enables UI management)
- [ ] Add `device` block to group sensors by ESP32 controller
- [ ] Deploy HA configuration
- [ ] Verify sensors appear in HA
- [ ] Create dashboard with gauges/graphs
- [ ] Test data updates in real-time

## Acceptance Criteria

- [ ] All 10 temperature sensors defined
- [ ] All 3 RSSI sensors defined
- [ ] Data correctly parsed from JSON (no `Unknown` states)
- [ ] Dashboard created with vertical stack
- [ ] Unit consistency (°C for temp, dBm for RSSI)
- [ ] Sensors grouped by device in HA UI

## Notes

### ESP32 Controllers

- **ESP32-1**: 1 temp (Dachboden) + RSSI
- **ESP32-2**: 1 temp (Kellerraum) + RSSI
- **ESP32-3**: 8 temps (Heizung system) + RSSI

### Data Structure

```json
{
  "0": 39.3125,  // HKK Rücklauf
  "1": -0.125,   // Außen
  "2": 15.5,     // WW Austritt
  ...
  "rssi": -79
}
```

### Topic

- `esp32-3/ds18b20/temperature` (no wildcard)

### Configuration Pattern

Use bracket notation for numeric keys: `value_json['0']` not `value_json.0`

### Related

- Depends on: P8500 (Grafana + InfluxDB migration)
- Current: Data in InfluxDB, not in HA
- Priority: 🟡 Medium (useful for parents' automation)
