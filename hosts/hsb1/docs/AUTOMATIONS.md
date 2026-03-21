# Home Automation Rules & Anti-Patterns

**Server**: hsb1
**Location**: jhw22
**Created**: 2026-03-21

---

## Anti-Patterns — NEVER DO THIS

### WiFi presence → "nobody home" triggers

**NEVER** use `zone.home < 1` (or similar WiFi-based presence) to trigger destructive actions like turning off lights or devices.

**Why:** WiFi is unreliable in this environment (10+ competing networks). Phones drop off WiFi for minutes at a time. HA sees `zone.home = 0` → fires "everyone left" → turns off devices that shouldn't be touched.

**Incident (2026-03-20):** The automation `🧙🏻‍♂️ Everyone Left - All Lights Off` used `light.turn_off target: entity_id: "all"` when `zone.home < 1`. This turned off AWTRIX LED matrices (`light.awtrix_*_matrix`) multiple times per day, causing pidicon displays to go dark. **Automation deleted.**

**Rules:**

- No automation should ever target `entity_id: "all"` for any domain
- No automation should use WiFi presence count as a trigger for device control
- If presence-based automations are needed in the future: use multiple signals (BLE + WiFi + motion sensors), require sustained absence (>30min), and use explicit entity lists (never "all")

### Broad entity targeting

**NEVER** use `entity_id: "all"` or area-based targets without reviewing what entities exist in that scope.

**Why:** MQTT autodiscovery creates `light.*`, `switch.*`, `sensor.*` entities for devices that aren't traditional lights/switches. Examples:

- `light.awtrix_58197c_matrix` — LED matrix display (NOT a room light)
- `light.awtrix_5807d0_matrix` — LED matrix display
- `light.awtrix_*_indicator_*` — status LEDs on AWTRIX devices

Turning these off breaks pidicon scene rendering silently (AWTRIX accepts HTTP commands fine, just doesn't display).

---

## Active Automations (HA)

### Physical switches

| Automation                | Trigger                | Action                          |
| ------------------------- | ---------------------- | ------------------------------- |
| Ensis oben → hell/aus     | Hue wall switch top    | Toggle Ensis pendant bright/off |
| Ensis unten → gedimmt/aus | Hue wall switch bottom | Toggle Ensis pendant dim/off    |

### MQTT-controlled devices

| Automation                    | Trigger    | Action                       |
| ----------------------------- | ---------- | ---------------------------- |
| MQTT steuert Sonoff TXU01     | MQTT topic | Controls Sonoff switch       |
| MQTT steuert Nuki (VR)        | MQTT topic | Controls Nuki lock (Vorraum) |
| MQTT steuert Nuki (KE)        | MQTT topic | Controls Nuki lock (KE)      |
| MQTT steuert Nanoleaf Canvas  | MQTT topic | On/off/scene for Nanoleaf    |
| MQTT steuert KWS Energy Meter | MQTT topic | Controls energy meter        |

### Climate (Merlin automations)

| Automation                          | Trigger            | Action               |
| ----------------------------------- | ------------------ | -------------------- |
| Schlafzimmer Fensterbankheizung EIN | Schedule/condition | Turns on sz/ heater  |
| Schlafzimmer Fensterbankheizung AUS | Schedule/condition | Turns off sz/ heater |
| Kinderzimmer Fensterbankheizung EIN | Schedule/condition | Turns on ki/ heater  |
| Kinderzimmer Fensterbankheizung AUS | Schedule/condition | Turns off ki/ heater |
| Master-Schalter Badezimmer          | Switch event       | Controls bz/ devices |

### IR Remote / Syncbox

| Automation            | Trigger       | Action                    |
| --------------------- | ------------- | ------------------------- |
| FLIRC Blau → PS5 Sync | IR blue key   | TV on + Syncbox PS5 input |
| FLIRC Gelb → PC Sync  | IR yellow key | TV on + Syncbox PC input  |

### Misc

| Automation                     | Trigger           | Action                |
| ------------------------------ | ----------------- | --------------------- |
| Set mba JHW22 theme at startup | HA start          | Sets UI theme         |
| Nuki aufladen Start/Stop       | Battery threshold | Nuki charging control |
| Gästezimmer D15↔D16           | Light state       | Sync paired lights    |

---

## Deleted Automations (with reason)

| Automation                          | Deleted    | Reason                                                                                                                |
| ----------------------------------- | ---------- | --------------------------------------------------------------------------------------------------------------------- |
| `🧙🏻‍♂️ Everyone Left - All Lights Off` | 2026-03-21 | WiFi presence unreliable; `entity_id: "all"` killed AWTRIX displays + caused false triggers. See anti-patterns above. |

---

## Node-RED Automations

### Active tabs

- **Syncbox [wz]** — Polls Syncbox API, exposes HomeKit switches for inputs
- **Smartlock VR** — Nuki status → hue bulb color indicator + AWTRIX indicator
- **Boiler** — Hot water state machine (heat when energy cheap, complete by 06:00)
- **Heat chain integrity** — Monitors Tado→Shelly→Pro4PM chain, publishes to MQTT

### Disabled tabs

- **Awtrix Ulanzi** — Old Node-RED AWTRIX control (replaced by pidicon-light)

---

## Guidelines for New Automations

1. **Explicit entity lists only** — never target "all" or entire areas blindly
2. **No WiFi presence triggers** — unreliable with 10+ competing networks
3. **Test with dry-run first** — HA Developer Tools → Services before automating
4. **Document here** — add to the table above when creating new automations
5. **Consider side effects** — check what `light.*`/`switch.*` entities exist via autodiscovery before writing area-based rules
