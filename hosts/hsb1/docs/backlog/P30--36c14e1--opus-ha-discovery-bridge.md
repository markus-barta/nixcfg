# opus-ha-discovery-bridge

**Host**: hsb1
**Priority**: P30
**Status**: Backlog
**Created**: 2026-02-20

---

## Problem

The current `opus-stream-to-mqtt` bridge is a legacy script that simply pipes the undocumented OPUS Gateway (EnOcean) HTTP stream to an MQTT topic. It requires manual, high-maintenance mapping of EnOcean telegrams/devices into Home Assistant.

Every time a new OPUS greenNet switch, dimmer, or roller blind is added to the gateway, manual configuration is required in Home Assistant to make it a first-class entity. This doesn't scale and makes managing the smart home tedious.

## Solution

Transform the legacy script into a modern **EnOcean-to-HA Discovery Service** (`opus-ha-bridge`). Instead of just piping a stream blindly, the service will dynamically "announce" every EnOcean device to Home Assistant using the **MQTT Discovery protocol**.

This enables "Zero-Configuration" — once a device is known to the OPUS gateway, it automatically appears as a native entity in Home Assistant.

## Implementation

- [ ] **Core Engine rewrite:**
  - [ ] **Initial Sync:** On startup, query the OPUS REST API (`/devices`) to build a device registry.
  - [ ] **Discovery Logic:** Map EnOcean EEPs (Equipment Profiles) to Home Assistant categories:
    - `D2-01-03` -> `light` (mqtt)
    - `D2-01-01` -> `switch` (mqtt)
    - `D2-05-02` -> `cover` (mqtt)
    - `D2-01-11` -> `binary_sensor` (Action events)
  - [ ] **MQTT Announce:** Publish config payloads to `homeassistant/<component>/<node_id>/config` with `retain: true`.
- [ ] **Stream Handling:**
  - [ ] Parse incoming stream payloads and publish to standard HA state topics.
  - [ ] Listen to HA command topics and translate them into REST API calls or MQTT writes back to the OPUS gateway.
- [ ] **Infrastructure & Deployment:**
  - [ ] Rewrite in Python (or structured TypeScript) for better API parsing.
  - [ ] Package as an OCI container or native Nix flake.
  - [ ] Update `hsb1` deployment in `nixcfg` to use the new discovery service.

## Acceptance Criteria

- [ ] New devices added to the OPUS gateway automatically appear in HA within 60 seconds (no bridge restart required).
- [ ] Dimmer values and roller blind positions are reported accurately in HA.
- [ ] Two-way control works seamlessly (HA can control the devices, and physical presses update HA).
- [ ] AI Assistants (Merlin) can interact with EnOcean devices exclusively through the standard Home Assistant API (e.g., `homeassistant.turn_on(entity_id="light.bz_decke_d18")`).

## Notes

- _Originally drafted by Merlin (AI Assistant) in `oc-workspace-merlin/workbench/BACKLOG_OPUS_EVOLUTION.md`_
- This completely replaces the work just completed in P40 (which secured the legacy script), elevating it to a modern smart home standard.
