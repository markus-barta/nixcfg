# hsb1 - Expose Zigbee Light "z2m/te/licht" to HomeKit as "Terrasse D28"

**Created**: 2025-01-27  
**Priority**: P8200 (Backlog)  
**Status**: Backlog  
**Host**: hsb1

---

## Problem

The zigbee light device `te/licht` (Terrasse light, IEEE: `0x385b44fffe6d1ba4`) is currently available in Home Assistant as `light.0x385b44fffe6d1ba4` but not exposed to HomeKit. It needs to be added to the HomeKit bridge configuration and exposed as "Terrasse D28" (per naming best practices).

---

## Solution

Add the light entity to Home Assistant's HomeKit bridge configuration in `~/docker/mounts/homeassistant/configuration.yaml`:

1. Verified entity ID is `light.0x385b44fffe6d1ba4`
2. Add it to the `include_entities` list in the HomeKit bridge configuration
3. Configure it in `entity_config` with the name "Terrasse D28"
4. Restart Home Assistant to apply changes

---

## Acceptance Criteria

- [x] Entity ID identified: `light.0x385b44fffe6d1ba4`
- [ ] Light entity added to HomeKit bridge `include_entities` list
- [ ] Entity configured in `entity_config` with name "Terrasse D28"
- [ ] Home Assistant restarted successfully
- [ ] Light appears in HomeKit as "Terrasse D28" (displays as "D28" when in room "Terrasse")
- [ ] Light can be controlled via HomeKit (on/off, brightness)

---

## Implementation Steps

### 1. Identify Entity ID (Completed)

Confirmed via discovery:

- **Friendly Name**: `te/licht`
- **IEEE Address**: `0x385b44fffe6d1ba4`
- **HA Entity ID**: `light.0x385b44fffe6d1ba4`

### 2. Backup Configuration

```bash
ssh mba@hsb1.lan
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
        - light.0x385b44fffe6d1ba4 # Terrasse Light

    entity_config:
      # ... existing entries ...
      light.0x385b44fffe6d1ba4:
        name: "Terrasse D28"
```

### 4. Validate YAML

```bash
# Check syntax
docker exec homeassistant python3 -c "import yaml; yaml.safe_load(open('/config/configuration.yaml'))" && echo "✅ YAML valid"
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
2. Verify configuration: Check `configuration.yaml` contains `light.0x385b44fffe6d1ba4`
3. Restart Home Assistant: `docker restart homeassistant`
4. Check logs: `docker logs homeassistant --tail 50 | grep -i homekit`
5. Verify in HomeKit: Check Home app for "D28" accessory
6. Test control: Toggle light via HomeKit

### Automated Test

```bash
# Verify entity is in HomeKit config
ssh mba@hsb1.lan 'grep -q "0x385b44fffe6d1ba4" ~/docker/mounts/homeassistant/configuration.yaml && echo "✅ Config updated" || echo "❌ Config missing"'

# Verify Home Assistant is running
ssh mba@hsb1.lan 'docker ps | grep -q homeassistant && echo "✅ HA running" || echo "❌ HA not running"'
```

---

## Notes

- **Device Path**: `z2m/te/licht` follows the naming convention `room/type/device` (Terrasse/light)
- **HomeKit Name**: "Terrasse D28" (room name prefix per [SMARTHOME.md](../../hosts/hsb1/docs/SMARTHOME.md#🏆-naming--ux-best-practices))
- **Configuration Location**: `~/docker/mounts/homeassistant/configuration.yaml`
- **Port**: HomeKit bridge uses port 51828 (custom, default is 51827)
- **Reference**: See `hosts/hsb1/docs/SMARTHOME.md` for HomeKit bridge configuration details

---

## Related

- `hosts/hsb1/docs/SMARTHOME.md` - Smart home architecture and HomeKit configuration guide
- `hosts/hsb1/README.md` - hsb1 host overview
