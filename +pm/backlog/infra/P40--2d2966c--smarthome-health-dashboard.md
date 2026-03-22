# Smart Home Health Dashboard

**Priority**: P40
**Status**: Done — UI polish only (see Notes)
**Created**: 2026-02-19
**Updated**: 2026-02-24

---

## Problem

No unified view of critical smart home infrastructure health. Key failure scenarios go undetected:

- Wi-Fi dropout breaks Shelly → Shelly chain (Tado thermostat → floor heating runaway)
- Zigbee device goes offline (boiler switch unreachable → no hot water)
- Node-RED or MQTT broker down → entire automation pipeline stalls
- No visibility into signal quality degradation before it becomes an outage

### Critical subsystems

**Warmwasser (Boiler):**

- Shelly 1PM `bz/boiler` measures boiler temperature via ext. DS18B20 sensor
- Zigbee `bz/powercontrol/boiler` ("Potenzialfreier Kontakt") switches boiler on/off
- Node-RED state machine: heats when energy is cheap, must complete before 06:00
- All three layers must work: Wi-Fi + Zigbee + Node-RED

**Fußbodenheizung (wc/ → vr/):**

- Tado thermostat in wc/ controls desired temp — **no MQTT, proprietary only**
- Tado contact output → read by Shelly 1 `wc/shelly1-tado-bridge` via `input/0`
- That Shelly signal → Shelly Pro 4PM `vr/shelly-pro-4-heizung1` output 1 = wc/ floor heating
- **Risk:** missed off-command (Wi-Fi dropout) → heating runs past target temp
- Currently no integrity check for this chain

---

## Solution

### Architecture

```
MQTT broker (hsb1)                   health-pixoo script (hsb1)     Pixoo64
──────────────────                   ───────────────────────────    ───────
z2m/<device>/availability  ─────────→  Node.js script              → HTTP POST
z2m/<device>  (LQI)         ─────────→    ping Fritz/repeaters       192.168.1.159
shellies/bz/boiler/...      ─────────→    HTTP RPC Pro 4PM
shellies/wc/tado-bridge/... ─────────→    renders 64×64 pixel art
Node-RED publishes chain state ──────→    tab-based display
```

**Key decisions:**

- **No HA as data middleman** — direct MQTT + ping + HTTP RPC. Fewer moving parts, more resilient.
- **Node-RED** owns heating chain integrity logic (already owns boiler state machine)
- **Node-RED publishes** chain health to MQTT topic (`jhw2211/health/heat-chain`)
- **HA Lovelace dashboard** = future addition, not in this phase
- **Tado** not monitored directly — HA integration unreliable, no MQTT. Monitor via `wc/shelly1-tado-bridge input/0` state only.
- **Script runtime**: Docker container on hsb1 alongside existing stack

### Pixoo visual style

- Demoscene retro-modern: C64/Amiga/Atari ST vibe meets modern smart home UI
- Horizontal gradient bars per device (dark→bright = signal quality)
- Warm amber/cyan/magenta palette, true-color RGB depth
- Scanline overlay for retro feel
- Ambient glow: green = nominal, red pulse = alert
- Pixel art icons for subsystems
- Font: Pico Mono — 5×3px per char + 1px spacing = ~4px effective width per char
  - 64px wide → ~16 chars per line max
  - 64px tall → ~10 text lines max
  - In practice: mix text + graphic elements

### Pixoo UX: Tab/View model

Too many devices (6 Wi-Fi + 6 Zigbee + services + heating chains) to show at once.
Solution: **tab-based views** — auto-cycling on alert, manual advance via button.

**Tab 0 — ÜBERSICHT (default)**

- One dot per subsystem, ambient background = overall health
- Stays here when all green; auto-cycles to detail tabs when alerts exist

```
┌────────────────────────────────┐
│ ◆ GESUNDHEIT    HH:MM          │  Row 0-5:  header + clock
│────────────────────────────────│
│  WLAN  ●●●●●●  [alle grün]     │  Row 6-12: Wi-Fi dot row (6 dots)
│  ZB    ●●●●●●  [alle grün]     │  Row 13-19: Zigbee dot row (6 dots)
│  SVC   ●●●     MQTT NR HA      │  Row 20-26: service liveness dots
│────────────────────────────────│
│  🔥 48°C  ✓  🌡 WC ✓           │  Row 27-37: heating summary
│────────────────────────────────│
│  [scanline ambient glow]       │  Row 38-63: ambient health color
└────────────────────────────────┘
```

**Tab 1 — WLAN DETAIL**

- One bar per device, German room code label + signal bar + dBm or ping status

```
┌────────────────────────────────┐
│ ◆ WLAN             [1/4]       │
│  bz-sh  ██░░░░░░░░  -86dBm    │  ← ⚠️ schwach
│  wc-sh  ██████░░░░  -72dBm    │
│  vr-4pm █████████░  -54dBm    │  ← HTTP RPC
│  vr-fb  ██████████  ✓ping     │  ← Gateway
│  dt-rep ██████████  ✓ping     │
│  tg-rep ██████████  ✓ping     │
└────────────────────────────────┘
```

**Tab 2 — ZIGBEE DETAIL**

- One bar per device, LQI-based bar (0-255 → 0-100%) + availability dot

```
┌────────────────────────────────┐
│ ◆ ZIGBEE           [2/4]       │
│  bz-boi ████████░░  LQI:171   │
│  bz-hzw ██████░░░░  LQI:142   │
│  wz-nw  █████████░  LQI:142   │
│  vk-wlk ████████░░  LQI:???   │
│  sz-hzg ███░░░░░░░  LQI:???   │
│  ki-hzg ██████████  LQI:???   │
└────────────────────────────────┘
```

**Tab 3 — HEIZUNG**

- Boiler state + Tado chain integrity

```
┌────────────────────────────────┐
│ ◆ HEIZUNG          [3/4]       │
│  BOILER  48°C  NR:OK  ✓        │
│  WC-Kette:                     │
│  SH→4PM  SYNC  ✓               │
│  4PM-A1: AUS                   │
│  sync: 14:32                   │
└────────────────────────────────┘
```

**Navigation:**

- All green → stays on Tab 0
- Alert → auto-cycles through affected detail tabs every ~10s
- Pixoo button → manual tab advance
- Script recovers gracefully if Pixoo or MQTT disconnects

---

## Implementation

> **2026-02-24:** Phases 1–4 complete. Script running in Docker on hsb1. All collectors, renderer, and tabs working. Remaining: HA automation + minor UI polish.

### Phase 1: Data sources — confirmed MQTT topics + polling

**Wi-Fi devices:**

| Label    | Device                  | IP              | Source                                      | Signal field    | Notes                                         |
| -------- | ----------------------- | --------------- | ------------------------------------------- | --------------- | --------------------------------------------- |
| `bz-sh`  | Shelly 1PM bz/boiler    | `192.168.1.161` | MQTT `shellies/bz/boiler/info`              | `wifi_sta.rssi` | Gen1; ext DS18B20 temp on `ext_temperature/0` |
| `wc-sh`  | Shelly 1 wc/tado-bridge | `192.168.1.168` | MQTT `shellies/wc/shelly1-tado-bridge/info` | `wifi_sta.rssi` | Gen1; Tado contact on `input/0`               |
| `vr-4pm` | Shelly Pro 4PM vr/      | `192.168.1.169` | HTTP RPC `GET /rpc/Shelly.GetStatus`        | `wifi.rssi`     | Gen2; MQTT broken, use HTTP polling           |
| `vr-fb`  | Fritz.box 7530 vr/      | `192.168.1.5`   | ping                                        | reachable       | Gateway SPOF                                  |
| `dt-rep` | Fritz Repeater dt/      | `192.168.1.8`   | ping                                        | reachable       | Dachterrasse                                  |
| `tg-rep` | Fritz Repeater tg/      | `192.168.1.9`   | ping                                        | reachable       | Tiefgarage, network canary                    |

**Zigbee devices (via Z2M MQTT):**

| Label    | Z2M topic                         | IEEE                 | Role                        | LQI now |
| -------- | --------------------------------- | -------------------- | --------------------------- | ------- |
| `bz-boi` | `z2m/bz/powercontrol/boiler`      | `0xa4c1385dae69475d` | Boiler on/off + power meter | 171     |
| `bz-hzw` | `z2m/bz/plug/zisp09`              | `0xa4c138fee3ab9c87` | Sprossenheizwand bz/        | 142     |
| `wz-nw`  | `z2m/wz/plug/zisp10`              | `0xa4c138649cc2807d` | Netzwerkschrank SPOF        | 142     |
| `vk-wlk` | `z2m/vk/waterleak/washingmachine` | `0x00158d00027b0d60` | Wasserleck Vorküche         | TBD     |
| `sz-hzg` | `z2m/sz/plug/zisp26`              | `0xa4c1389f03d48605` | Fensterbankheizung sz/      | TBD     |
| `ki-hzg` | `z2m/ki/plug/zisp37`              | `0xa4c13874f21c7bf8` | Fensterbankheizung ki/      | TBD     |

Availability: `z2m/<device>/availability` → `{"state":"online"|"offline"}`

**Service liveness:**

| Service     | Check method                                                 |
| ----------- | ------------------------------------------------------------ |
| MQTT broker | implicit — if script is subscribed, broker is alive          |
| Node-RED    | HTTP GET `http://localhost:1880` → 200 OK                    |
| HA          | HTTP GET `http://localhost:8123` → 200 OK (optional, future) |

### Phase 2: Heating chain integrity (Node-RED)

- [x] Add logic to existing Node-RED boiler flow:
  - Periodically (every 5 min) compare `wc/shelly1-tado-bridge input/0` vs `vr/shelly-pro-4-heizung1 switch:0 output`
  - If input=OFF but output=ON for >10min → publish alert to `jhw2211/health/heat-chain`
  - Payload: `{"state":"ok"|"mismatch"|"unknown", "checked_at":"ISO8601"}`
- [x] Boiler integrity: Node-RED already owns this — just publish current state to `jhw2211/health/boiler`
  - Payload: `{"state":"ok"|"error", "temp_c": 48.0, "nr_running": true}`

### Phase 3: Pixoo standalone script

- [x] New repo — `~/Code/health-pixoo` (Node.js)
  - Drawing primitives from `lib/pixoo-http.js` (ported from pixdcon)
  - Collectors: mqtt-collector, ping-collector, rpc-collector
  - Central state store + health helpers
  - Tab-based renderer: ÜBERSICHT, WLAN, ZIGBEE, HEIZUNG
  - Docker container on hsb1 (`ghcr.io/markus-barta/health-pixoo:latest`)
- [x] Demoscene aesthetic: gradient bars, scanlines, ambient glow, 3D dots
- [x] German short labels finalized
- [x] Added to `hosts/hsb1/docker/docker-compose.yml` (host network mode)

### Phase 4: Deployment

- [x] Pixoo64 (`192.168.1.159`) reachable from hsb1
- [x] Docker container deployed on hsb1
- [x] `hosts/hsb1/docs/RUNBOOK.md` updated (health-pixoo in container overview + secrets inventory)

---

## Future (not in this phase)

- **HA Lovelace dashboard** — phone/tablet health overview card (after Pixoo script is stable)
- **Fix Shelly Pro 4PM MQTT** — `online false` despite device reachable; investigate broker auth/config on device
- **Tado direct monitoring** — currently only via Shelly bridge; revisit if Tado exposes local API
- **Alert notifications** — push to Apprise/ntfy when critical device offline

---

## Acceptance Criteria

- [x] Pixoo64 shows Tab 0 overview when all systems nominal (green ambient)
- [x] Pixoo64 auto-cycles to detail tab when any device is offline/degraded
- [x] Wi-Fi bars reflect real RSSI/ping for all 6 devices
- [x] Zigbee bars reflect real LQI for all 6 devices
- [x] Node-RED publishes heating chain state to MQTT; Pixoo renders it
- [x] Script reconnects automatically after MQTT or Pixoo disconnect
- [x] No secrets committed to repo

## Open Questions

- [x] Heating chain check interval: 5min — confirmed
- [x] MQTT topic prefix: `jhw2211/health/` — home-scoped, consistent with existing `jhw2211/` namespace
- [x] Short labels for Pixoo tabs — German, room-code based (see Tab sketches above)

## Remaining Work

### UI Polish (low priority, not blocking)

- `vk-wlk` (Wasserleck) shows permanently offline — dead battery, fix separately
- `bz-sh` RSSI -86 dBm renders yellow — expected, acceptable

### Spin-offs

- NR self-heal + Telegram alert for heat-chain mismatch → `+pm/backlog/infra/P50--4c4417f--ha-alert-heat-chain-mismatch.md`

## Notes

- Room/device naming convention: `docs/INFRASTRUCTURE.md` → "Smart Home Naming Convention"
- pixdcon repo: `~/Code/pixdcon` — drawing primitives in `lib/pixoo-http.js`
- Reference scenes: `scenes/pixoo/dev/power_price.js` (gradient bars), `scenes/awtrix/timestats.js` (status dots)
- pixdcon container on hsb1 currently disabled — do NOT re-enable; standalone script only
- Shelly Pro 4PM (`192.168.1.169`): MQTT broken, HTTP RPC works fine
- Shelly bz/boiler RSSI = -86 dBm: known weak signal, worth a yellow threshold
- Tado: proprietary, no MQTT, HA integration unreliable — monitor only via Shelly bridge input
- `vk/waterleak/washingmachine` (Zigbee): offline since 2025-12-27 — battery dead or device lost. Fix separately.

### Pixoo64 protocol reference (from pixdcon)

**Init sequence** (must do once on startup):

1. `POST http://192.168.1.159/post` → `{ "Command": "Draw/ResetHttpGifId" }`
2. Wait 100ms
3. `POST` → `{ "Command": "Channel/SetIndex", "SelectIndex": 3 }` (custom channel)

**Send frame** (every render cycle):

1. Reset: `{ "Command": "Draw/ResetHttpGifId" }` (before every push!)
2. Encode 64×64×3 RGB buffer as base64
3. `POST` → `{ "Command": "Draw/SendHttpGif", "PicNum": 1, "PicWidth": 64, "PicHeight": 64, "PicOffset": 0, "PicID": <1-9999>, "PicSpeed": 1000, "PicData": "<base64>" }`

**Key constraints:**

- **No delta frames** — every push is full 64×64 (~16KB base64)
- **5 fps hardware max** — HTTP round-trip ~200-300ms is the natural governor
- **Custom Channel must be active** — if user manually switches on device, rendering goes invisible
- **No push retry** in pixdcon — if POST fails, scene loop retries on next cycle

**Brightness:** `{ "Command": "Channel/SetBrightness", "Brightness": 0-100 }`
**Health ping:** `{ "Command": "Channel/GetHttpGifId" }` (lightweight check)

**Drawing primitives to copy from `lib/pixoo-http.js`:**

- `clear()` — fill buffer black
- `_setPixel(x, y, r, g, b)` — direct write
- `_blendPixel(x, y, r, g, b, a)` — alpha-blended write
- `drawRectangleRgba(pos, size, color)` — filled rect (no outline primitive!)
- `drawLineRgba(start, end, color)` — Bresenham
- `drawTextRgbaAligned(text, pos, color, align)` — custom 3×5 bitmap font
- `drawImageWithAlpha(path, pos, size, alpha)` — PNG loader

**Font:** Custom 3×5px bitmap, NOT Pico Mono. 1px inter-char spacing = 4px per char effective.

- 64px ÷ 4px = **16 chars per line** max
- 64px ÷ 7px line height = **9 text lines** max

**Gradient helpers** (from `lib/gradient-renderer.js`):

- `drawVerticalGradientLine(device, start, end, startColor, endColor)`
- `drawHorizontalGradientLine(device, start, end, startColor, endColor)`
- `interpolateColor(startColor, endColor, factor)` — linear RGBA lerp
- Preset themes: `power` (yellow→red), `temperature` (blue→red), `ocean` (deep→light blue)

**Color constants** (from `lib/constants.js`):

- `COLOR_SUCCESS = [0,255,0,255]`, `COLOR_WARNING = [255,255,0,255]`, `COLOR_ERROR = [255,0,0,255]`
- `COLOR_INFO = [0,255,255,255]`
- Alpha: `ALPHA_OPAQUE=255`, `ALPHA_SEMI=178`, `ALPHA_TRANSPARENT=100`

**Additional helpers available:**

- `drawFilledCircle`, `drawCircleOutline`, `drawGlowCircle` (from `rendering-utils.js`)
- `drawGradientBackground(startColor, endColor, direction)` (from `graphics-engine.js`)
- `drawTextEnhanced` with shadow/outline/gradient effects (from `graphics-engine.js`)
