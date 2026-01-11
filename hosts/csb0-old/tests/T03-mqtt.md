# T03: MQTT/Mosquitto (csb0)

Test MQTT broker functionality.

> ⚠️ **CRITICAL**: csb1's InfluxDB depends on this broker!

## Host Information

| Property    | Value                       |
| ----------- | --------------------------- |
| **Host**    | csb0                        |
| **Service** | Mosquitto MQTT Broker       |
| **Port**    | 1883 (internal), 8883 (TLS) |
| **Impact**  | Feeds data to csb1 InfluxDB |

## Prerequisites

- [ ] SSH access to csb0
- [ ] MQTT clients can connect

## Automated Tests

Run: `./T03-mqtt.sh`

## Test Procedures

### Test 1: Container Running

**Command:** `docker ps --format "{{.Names}}" | grep mosquitto`

**Expected:** Container found

### Test 2: Container Stable

**Command:** `docker inspect --format "{{.RestartCount}}" <container>`

**Expected:** < 5 restarts

### Test 3: Config File Exists

**Command:** `docker exec <container> test -f /mosquitto/config/mosquitto.conf`

**Expected:** File exists

### Test 4: MQTT Port Listening

**Command:** Check port 1883 listening inside container

**Expected:** Port bound

### Test 5: Container Uptime

**Command:** `docker ps --format "{{.Status}}" --filter name=mosquitto`

**Expected:** Uptime displayed (e.g., "Up 5 days")

## Dependency Check

If MQTT is down:

1. csb1 InfluxDB stops receiving IoT data
2. Grafana dashboards show no new data
3. Check: `docker logs csb0-mosquitto-1`

## Test Results Summary

| Test | Description       | Status |
| ---- | ----------------- | ------ |
| T1   | Container Running | ⏳     |
| T2   | Container Stable  | ⏳     |
| T3   | Config File       | ⏳     |
| T4   | Port Listening    | ⏳     |
| T5   | Container Uptime  | ⏳     |

## Notes

- IoT devices → MQTT (csb0) → InfluxDB (csb1) → Grafana
- If MQTT down, restart: `docker restart csb0-mosquitto-1`
