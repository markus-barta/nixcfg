# P4 - HSB1: Nuki KE Charging Automation

## Context

Adding automated charging for the new Nuki KE lock in the basement (Keller). Pattern should follow the existing `nuki_vr` setup.

## Tasks

- [ ] Identify/Install Smart Plug for Keller Nuki charging.
- [ ] Map entity IDs for the new plug (switch and power sensor).
- [ ] Implement Home Assistant Automation:
  - **Trigger**: `sensor.nuki_ke_battery` < 20%
  - **Action**: Turn on smart plug.
- [ ] Implement Home Assistant Automation:
  - **Trigger**: `sensor.nuki_ke_battery` == 100% OR `power` drops significantly.
  - **Action**: Turn off smart plug.

## References

- Host: `hsb1`
- Existing pattern: `nuki_vr` charging in Node-RED/HA.
- Docs: `hosts/hsb1/docs/SMARTHOME.md`
