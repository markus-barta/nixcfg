# nuki-ke-charging-automation

**Host**: hsb1
**Priority**: P40
**Status**: Backlog
**Created**: 2026-02-10

---

## Problem

New Nuki KE lock in basement (Keller) needs automated charging setup. Currently manual charging required.

## Solution

Follow existing `nuki_vr` charging pattern using smart plug automation in Home Assistant.

## Implementation

- [ ] Identify/install smart plug for Keller Nuki charging
- [ ] Map entity IDs for new plug (switch and power sensor)
- [ ] Create HA automation: Turn on plug when `sensor.nuki_ke_battery` < 20%
- [ ] Create HA automation: Turn off plug when `sensor.nuki_ke_battery` == 100% OR power drops
- [ ] Test charging cycle
- [ ] Update `hosts/hsb1/docs/SMARTHOME.md` with new automation

## Acceptance Criteria

- [ ] Smart plug installed and accessible in HA
- [ ] Low battery triggers charging automatically
- [ ] Full battery stops charging automatically
- [ ] Documentation updated

## Notes

- Existing pattern: `nuki_vr` charging in Node-RED/HA
- Reference: `hosts/hsb1/docs/SMARTHOME.md`
