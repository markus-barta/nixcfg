# grafana-influxdb-migration

**Host**: hsb8
**Priority**: P85
**Status**: Backlog
**Created**: 2026-01-11

---

## Problem

hsb8 (parents' network) needs Grafana + InfluxDB setup for monitoring ESP32 temperature sensors. Currently no centralized monitoring.

## Solution

Deploy Grafana and InfluxDB (likely via Docker) on hsb8 to collect and visualize data from 3 ESP32 controllers with DS18B20 sensors.

## Implementation

- [ ] Design deployment strategy (Docker vs NixOS services)
- [ ] Install InfluxDB (decide version: InfluxDB 2.x or 3.x)
- [ ] Install Grafana
- [ ] Configure InfluxDB bucket for temperature data
- [ ] Set up MQTT → InfluxDB data flow (Node-RED or Telegraf)
- [ ] Create Grafana dashboards for temperature sensors
- [ ] Configure authentication and access
- [ ] Set up backup strategy
- [ ] Document in RUNBOOK.md

## Acceptance Criteria

- [ ] InfluxDB running and accessible
- [ ] Grafana running and accessible
- [ ] Temperature data flowing from ESP32s to InfluxDB
- [ ] Dashboards showing all sensor data
- [ ] Backup strategy in place
- [ ] Documentation updated

## Notes

### ESP32 Controllers

- **ESP32-1**: 1 sensor (Dachboden) + RSSI
- **ESP32-2**: 1 sensor (Kellerraum) + RSSI
- **ESP32-3**: 8 sensors (Heizung/WW/Außen) + RSSI

### Data Flow

- ESP32 → MQTT → (Telegraf/Node-RED) → InfluxDB → Grafana

### Related

- Depends on: P8600 (hsb8 HA ESP32 MQTT integration)
- Priority: 🟡 Medium (parents' monitoring, useful but not critical)
