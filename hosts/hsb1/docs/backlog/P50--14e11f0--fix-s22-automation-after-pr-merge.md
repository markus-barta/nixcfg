# fix-s22-automation-after-pr-merge

**Host**: hsb1
**Priority**: P50
**Status**: Backlog
**Created**: 2026-02-20

---

## Problem

Automation `1771000000000` (Master-Schalter Badezimmer) uses a raw `mqtt.publish`
workaround to control S22 on channel 0, because the `opus_greennet` integration
incorrectly treats `D2-01-11` as a single-channel device and only creates
`switch.s22` (ch0). Commands need explicit `channel: 0` to control the shower light.

PR filed: `kegelmeier/opus_homeassistant#13`

## Solution

Once PR#13 is merged and the integration updated on hsb1, the integration will
create `switch.s22_ch0` as a proper entity. Replace the MQTT workaround in the
automation with a clean `homeassistant.turn_on/off` call targeting `switch.s22_ch0`.

## Implementation

- [ ] Confirm PR#13 merged upstream
- [ ] Update `opus_greennet` custom component on hsb1 (copy from repo or HACS)
- [ ] Restart HA — verify `switch.s22_ch0` appears
- [ ] Edit automation `1771000000000`: replace `mqtt.publish` blocks with `switch.s22_ch0` in both condition and actions
- [ ] Reload automations, test S34 master switch

## Acceptance Criteria

- [ ] `switch.s22_ch0` exists as a proper HA entity
- [ ] S34 press turns S22 (Duschlicht) on/off correctly
- [ ] No raw `mqtt.publish` in the automation
- [ ] Automation trace shows `switch.s22_ch0` in action targets

## Notes

- Workaround payload: `{"state": {"functions": [{"key": "channel", "value": "0"}, {"key": "switch", "value": "on/off"}]}}`
- NOTE: ch=0 is the shower light output. ch=1 does NOT control the light despite linkTable showing rocker→ch1. OPUS maps rocker input channel ≠ actuator output channel.
- S22 device ID: `050BF283`, EAG: `0584E931`
- PR branch: `markus-barta:fix/d2-01-11-d2-01-12-multichannel`
- https://github.com/kegelmeier/opus_homeassistant/pull/13
