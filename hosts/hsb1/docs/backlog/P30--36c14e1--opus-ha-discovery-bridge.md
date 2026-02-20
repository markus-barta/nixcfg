# opus-ha-discovery-bridge

**Host**: hsb1
**Priority**: P30
**Status**: In Progress
**Created**: 2026-02-20

---

## Problem

The current `opus-stream-to-mqtt` bridge is a legacy script that simply pipes the undocumented OPUS Gateway (EnOcean) HTTP stream to an MQTT topic. It requires manual, high-maintenance mapping of EnOcean telegrams/devices into Home Assistant.

Every time a new OPUS greenNet switch, dimmer, or roller blind is added to the gateway, manual configuration is required in Home Assistant to make it a first-class entity. This doesn't scale and makes managing the smart home tedious.

## Solution

Transform the legacy script into a modern **EnOcean-to-HA Discovery Service** (`opus-ha-bridge`). Instead of just piping a stream blindly, the service will act as a bidirectional intelligent gateway. It will dynamically "announce" every EnOcean device to Home Assistant using the **MQTT Discovery protocol**.

This enables "Zero-Configuration" — once a device is known to the OPUS gateway, it automatically appears as a native entity in Home Assistant with two-way control.

## Technical Architecture

- **Language:** Python 3.12+ (using `requests` for REST/HTTP stream, `paho-mqtt` for MQTT). Python is chosen for its excellent JSON manipulation, robust MQTT client, and ease of packaging in Nix.
- **Repository:** `markus-barta/opus-ha-bridge` (New repository, deprecating `opus-stream-to-mqtt`).
- **Nix Integration:** Packaged as a native Nix flake (`buildPythonApplication`). This allows it to run natively as a `systemd.service` on `hsb1` rather than inside a Docker container, simplifying dependency management and secret injection via Agenix.

### Data Flow

1. **Discovery (REST -> MQTT):** Bridge polls OPUS `/devices` endpoint -> Parses EEPs -> Publishes to `homeassistant/<type>/<node_id>/config`.
2. **State Updates (HTTP Stream -> MQTT):** Bridge consumes OPUS `/devices/stream` -> Translates EnOcean state -> Publishes to `opus/state/<node_id>`.
3. **Control Commands (MQTT -> REST):** Bridge subscribes to `opus/cmd/<node_id>` -> Receives HA command -> Executes POST request to OPUS REST API to actuate the physical device.

## Implementation Plan

- [ ] **Phase 1: Foundation & Discovery**
  - [ ] Initialize Python repository (`markus-barta/opus-ha-bridge`) with basic `paho-mqtt` and `requests` scaffolding.
  - [ ] Implement OPUS REST API client to fetch the device list (`/devices`).
  - [ ] Implement EEP translation logic (mapping `D2-01-xx` to HA domains: `light`, `switch`, `cover`).
  - [ ] Implement MQTT Discovery publisher (send JSON configs to `homeassistant/+/+/config`).
- [ ] **Phase 2: State Stream Translation**
  - [ ] Re-implement the long-polling HTTP stream connection (from the legacy JS script).
  - [ ] Parse incoming EnOcean telemetry payloads and translate them into standardized JSON state payloads.
  - [ ] Publish translated states to the `state_topic` defined in Phase 1 discovery.
- [ ] **Phase 3: Bidirectional Control**
  - [ ] Subscribe to `command_topic` defined in Phase 1 discovery (e.g., `opus/cmd/+`).
  - [ ] Implement command translator (convert HA commands like `{"state": "ON", "brightness": 128}` into OPUS REST API POST payloads).
- [ ] **Phase 4: NixOS Deployment**
  - [ ] Create `flake.nix` in the project repository using `poetry2nix` or standard `buildPythonApplication`.
  - [ ] Add the project as a flake input to `nixcfg`.
  - [ ] Create a `systemd.services.opus-ha-bridge` module in `nixcfg/hosts/hsb1/configuration.nix`.
  - [ ] Inject the existing `opus-stream-hsb1.age` agenix secrets securely via `EnvironmentFile`.
  - [ ] Stop the legacy Docker container and start the new native service.

## Acceptance Criteria

- [ ] New devices added to the OPUS gateway automatically appear in HA within 60 seconds (no bridge restart required).
- [ ] Dimmer values and roller blind positions are reported accurately in HA.
- [ ] Two-way control works seamlessly (HA can control the devices, and physical presses update HA).
- [ ] AI Assistants (Merlin) can interact with EnOcean devices exclusively through the standard Home Assistant API (e.g., `homeassistant.turn_on(entity_id="light.bz_decke_d18")`).
- [ ] The service runs as a native NixOS `systemd.service` without Docker.

## Notes

- _Originally drafted by Merlin (AI Assistant) in `oc-workspace-merlin/workbench/BACKLOG_OPUS_EVOLUTION.md`_
- This completely replaces the work just completed in P40 (which secured the legacy script), elevating it to a modern smart home standard.
