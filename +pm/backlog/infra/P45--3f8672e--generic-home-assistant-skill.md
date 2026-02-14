# Generic Home Assistant Skill

**Created**: 2026-02-02  
**Priority**: P4500 (Medium)  
**Status**: Backlog  
**Depends on**: Merlin running on hsb0 (Docker) -- migration complete

---

## Problem

Currently, there is no generic skill to control Home Assistant entities from OpenClaw on `hsb0` (Docker). We want a solution that allows controlling all lights, switches, and sensors without creating individual skills for each device.

---

## Solution

Build or configure a generic Home Assistant skill that interacts with the Home Assistant REST API.

1.  **Authentication**: Use a Long-Lived Access Token (LLAT) managed via `agenix` (mounted at `/run/secrets/hass-token` inside container, from `/run/agenix/hsb0-openclaw-hass-token` on host).
2.  **Discovery**: Implement/use a mechanism to fetch all entities via `GET /api/states`.
3.  **Command Execution**: Map natural language intents to HA service calls (e.g., `light.toggle`, `switch.turn_on`).
4.  **Security**: Ensure the token is only accessible by the OpenClaw service user.

---

## Acceptance Criteria

- [ ] OpenClaw can list Home Assistant entities.
- [ ] Commands like "Switch off the living room light" or "Toggle the LED strip" work reliably.
- [ ] Token is handled securely via `agenix`.

---

## Test Plan

### Manual Test

1. Verify the token is readable at the specified path.
2. Ask OpenClaw: "What is the status of my lights?"
3. Ask OpenClaw: "Turn on the LED strip in the dining room."

### Automated Test

```bash
# Verify API connectivity via curl using the agenix token
# From hsb0 host (HA is on hsb1 at 192.168.1.101):
curl -X GET -H "Authorization: Bearer $(cat /run/agenix/hsb0-openclaw-hass-token)" \
     -H "Content-Type: application/json" \
     http://192.168.1.101:8123/api/states/light.ledstrip_esszimmer
```
