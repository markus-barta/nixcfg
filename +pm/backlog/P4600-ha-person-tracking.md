# Unified Person Identification and Tracking in HA

**Created**: 2026-02-03  
**Priority**: P4600 (Medium)  
**Status**: Backlog  
**Depends on**: P4500-generic-home-assistant-skill.md

---

## Problem

Home Assistant currently shows inconsistent presence data for Markus and Mailina. GPS-based app trackers often show "home" (stale data) while Fritz!Box router trackers correctly identify them as away. There is no unified "Person" entity that combines these data sources for reliable status.

---

## Solution

Create and configure `person.markus` and `person.mailina` in Home Assistant, combining multiple device trackers.

1.  **Data Collection**: Log current state of all potential trackers (WLAN, GPS, BLE) while users are away and once they return.
2.  **Configuration**: Update HA configuration (via `person` integration) to use both the Fritz!Box entities and the HA App entities.
3.  **Automation**: (Optional) Add notifications for status changes to verify reliability.

---

## Acceptance Criteria

- [ ] `person.markus` and `person.mailina` exist in HA.
- [ ] Status correctly reflects "not_home" when both devices are disconnected from WLAN and GPS is stale/away.
- [ ] Status correctly reflects "home" as soon as the first tracker (likely WLAN) connects.

---

## Test Plan

### Manual Test

1. Check HA UI for Person status while at work.
2. Check HA UI for Person status immediately upon arriving home.
3. Verify that "home" status is triggered by Fritz!Box connection.

### Automated Test

```bash
# Query person status via HA API
curl -s -X GET -H "Authorization: Bearer $HASS_TOKEN" \
     http://192.168.1.101:8123/api/states/person.markus
```
