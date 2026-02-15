# child-keyboard-fun

**Host**: hsb1
**Priority**: P80
**Status**: Backlog
**Created**: 2026-01-01

---

## Problem

Want child's dedicated Bluetooth keyboard (ACME BK03) to trigger fun sounds and smart home actions for engaging, interactive experience without interfering with main system.

## Solution

Set up ACME BK03 keyboard on hsb1 to trigger Node-RED flows that play sounds and optionally control smart home devices.

## Implementation

### Hardware Setup

- [ ] Pair ACME BK03 to hsb1:
  - Power on keyboard
  - Hold ESC + K for 3 seconds (red LED blinks)
  - Pair via Bluetooth settings
- [ ] Test keyboard input recognition
- [ ] Map keyboard to dedicated input device

### Software Setup

- [ ] Create Node-RED flow for keyboard events
- [ ] Set up sound file library
- [ ] Configure key → sound mappings
- [ ] Add optional smart home triggers (lights, scenes)
- [ ] Test all key combinations
- [ ] Create parent control interface

## Acceptance Criteria

- [ ] ACME BK03 paired and connected to hsb1
- [ ] Keyboard events captured in Node-RED
- [ ] Fun sounds play on key press
- [ ] Smart home actions work (if configured)
- [ ] No interference with main system input
- [ ] Parent can enable/disable functionality
- [ ] Documentation for adding new sounds/actions

## Notes

### Hardware

- **Keyboard**: ACME BK03 Bluetooth
- **Pairing**: ESC + K (3 sec), red LED blinks
- **Target**: hsb1 (home automation hub)

### Features

- Key press → fun sounds
- Optional smart home triggers (lights, scenes, etc.)
- Parent-controlled enable/disable

### Integration

- Node-RED for flow logic
- Home Assistant for smart home actions
- Audio playback via hsb1 audio output

### Related

- P8001: Audio fix for keyboard system
- Epic: Home Automation & Family UX
- Priority: 🟢 Low (fun feature, not critical)
