# T16: APC UPS Monitoring + MQTT (hsb0)

Test APC UPS monitoring daemon and MQTT publishing service.

## Host Information

| Property        | Value                  |
| --------------- | ---------------------- |
| **Host**        | hsb0                   |
| **Role**        | DNS/DHCP               |
| **IP**          | 192.168.1.99           |
| **UPS Model**   | APC Back-UPS ES 350    |
| **MQTT Topic**  | home/vr/battery/ups350 |
| **MQTT Broker** | hsb1 (192.168.1.101)   |

## Prerequisites

- [ ] NixOS configuration applied: `sudo nixos-rebuild switch --flake .#hsb0`
- [ ] APC UPS connected via USB
- [ ] MQTT credentials in `/run/agenix/mqtt-hsb0`
- [ ] hsb1 MQTT broker accessible

## Automated Tests

Run: `./T16-ups-mqtt.sh`

## Manual Test Procedures

### Test 1: apcupsd Service Running

**Steps:**

1. Check service: `systemctl status apcupsd`

**Expected Results:**

- Service is active (running)
- No errors in recent logs

**Status:** ⏳ Pending

### Test 2: UPS Accessible via apcaccess

**Steps:**

1. Query UPS: `apcaccess status`

**Expected Results:**

- Returns UPS status data
- Shows STATUS: ONLINE (or ONBATT if on battery)
- Shows battery percentage, voltage, etc.

**Status:** ⏳ Pending

### Test 3: MQTT Credentials Available

**Steps:**

1. Check credentials file: `sudo ls -la /run/agenix/mqtt-hsb0`

**Expected Results:**

- File exists
- Permissions are 400 (owner read only)

**Status:** ⏳ Pending

### Test 4: ups-mqtt-publish Service

**Steps:**

1. Check service: `systemctl status ups-mqtt-publish`
2. Check timer: `systemctl status ups-mqtt-publish.timer`

**Expected Results:**

- Service runs without errors
- Timer is active and enabled
- Publishes every 1 minute

**Status:** ⏳ Pending

### Test 5: Manual MQTT Publish

**Steps:**

1. Trigger manual publish: `sudo systemctl start ups-mqtt-publish`
2. Check logs: `journalctl -u ups-mqtt-publish -n 10`

**Expected Results:**

- Service completes successfully
- No authentication errors
- JSON payload sent

**Status:** ⏳ Pending

## Test Results Summary

| Test | Description      | Status |
| ---- | ---------------- | ------ |
| T1   | apcupsd Running  | ⏳     |
| T2   | apcaccess Works  | ⏳     |
| T3   | MQTT Credentials | ⏳     |
| T4   | Publish Service  | ⏳     |
| T5   | Manual Publish   | ⏳     |

## Notes

- UPS configuration in `configuration.nix` under `services.apcupsd`
- MQTT credentials encrypted with agenix (`secrets/mqtt-hsb0.age`)
- Publish script converts apcaccess output to JSON
- Can verify MQTT on broker: `mosquitto_sub -h hsb1.lan -u smarthome -P '<pass>' -t 'home/vr/battery/ups350'`
