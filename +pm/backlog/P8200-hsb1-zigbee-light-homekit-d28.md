# hsb1 - Expose Zigbee Light "z2m/te/licht" to HomeKit as D28

**Created**: 2025-01-27  
**Priority**: P8200 (Backlog)  
**Status**: Backlog  
**Host**: hsb1

---

## Problem

The zigbee light device `z2m/te/licht` (Terrasse light) is currently available in Home Assistant but not exposed to HomeKit. It needs to be added to the HomeKit bridge configuration and exposed as "D28".

---

## Solution

Add the light entity to Home Assistant's HomeKit bridge configuration in `~/docker/mounts/homeassistant/configuration.yaml`:

1. Find the entity ID for `z2m/te/licht` in Home Assistant
2. Add it to the `include_entities` list in the HomeKit bridge configuration
3. Configure it in `entity_config` with the name "D28"
4. Restart Home Assistant to apply changes

---

## Acceptance Criteria

- [ ] Entity ID for `z2m/te/licht` identified in Home Assistant
- [ ] Light entity added to HomeKit bridge `include_entities` list
- [ ] Entity configured in `entity_config` with name "D28"
- [ ] Home Assistant restarted successfully
- [ ] Light appears in HomeKit as "D28"
- [ ] Light can be controlled via HomeKit (on/off, brightness if supported)

---

## Implementation Steps

### 1. Identify Entity ID

```bash
ssh mba@hsb1.lan

# Check Home Assistant entity registry for the device
cat ~/docker/mounts/homeassistant/.storage/core.entity_registry | \
  jq '.data.entities[] | select(.unique_id | contains("te") or contains("licht")) | {entity_id, original_name, unique_id}'

# Or check via MQTT topic
docker exec mosquitto mosquitto_sub -t "zigbee2mqtt/te/licht" -C 1 -W 5
```

### 2. Backup Configuration

```bash
cp ~/docker/mounts/homeassistant/configuration.yaml \
   ~/docker/mounts/homeassistant/configuration.yaml.bak-$(date +%Y%m%d)
```

### 3. Edit HomeKit Configuration

Edit `~/docker/mounts/homeassistant/configuration.yaml`:

```yaml
homekit:
  - name: "HASS Bridge YAML"
    port: 51828
    filter:
      include_entities:
        # ... existing entries ...
        - light.z2m_te_licht # Add this line (entity_id may vary)

    entity_config:
      # ... existing entries ...
      light.z2m_te_licht: # Add this block (entity_id may vary)
        name: "D28"
```

**Note**: The actual entity_id format may differ. Common patterns:

- `light.z2m_te_licht`
- `light.zigbee2mqtt_te_licht`
- `light.0xXXXXXXXX_light` (IEEE address-based)

### 4. Validate YAML

```bash
python3 -c "import yaml; yaml.safe_load(open('~/docker/mounts/homeassistant/configuration.yaml'))" && echo "✅ YAML valid"
```

### 5. Restart Home Assistant

```bash
docker restart homeassistant

# Wait ~30s, then check logs
docker logs homeassistant --tail 50 2>&1 | grep -i "homekit\|error"
```

### 6. Verify in HomeKit

- Open Home app on iOS/macOS
- Check for new accessory "D28"
- Test on/off and brightness control

---

## Test Plan

### Manual Test

1. SSH to hsb1: `ssh mba@hsb1.lan`
2. Verify entity exists: Check Home Assistant entity registry
3. Verify configuration: Check `configuration.yaml` contains the entity
4. Restart Home Assistant: `docker restart homeassistant`
5. Check logs: `docker logs homeassistant --tail 50 | grep -i homekit`
6. Verify in HomeKit: Check Home app for "D28" accessory
7. Test control: Toggle light via HomeKit

### Automated Test

```bash
# Verify entity is in HomeKit config
ssh mba@hsb1.lan 'grep -q "z2m.*licht\|D28" ~/docker/mounts/homeassistant/configuration.yaml && echo "✅ Config updated" || echo "❌ Config missing"'

# Verify Home Assistant is running
ssh mba@hsb1.lan 'docker ps | grep -q homeassistant && echo "✅ HA running" || echo "❌ HA not running"'

# Check HomeKit bridge logs for errors
ssh mba@hsb1.lan 'docker logs homeassistant 2>&1 | grep -i "homekit.*error" | tail -5'
```

---

## Notes

- **Device Path**: `z2m/te/licht` follows the naming convention `room/type/device` (Terrasse/light)
- **HomeKit Name**: Must be "D28" as specified
- **Configuration Location**: `~/docker/mounts/homeassistant/configuration.yaml`
- **Port**: HomeKit bridge uses port 51828 (custom, default is 51827)
- **Reference**: See `hosts/hsb1/docs/SMARTHOME.md` for HomeKit bridge configuration details

---

## Related

- `hosts/hsb1/docs/SMARTHOME.md` - Smart home architecture and HomeKit configuration guide
- `hosts/hsb1/README.md` - hsb1 host overview
