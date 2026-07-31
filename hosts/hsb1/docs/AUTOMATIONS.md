# Home Automation Rules & Anti-Patterns

**Server**: hsb1
**Location**: jhw22
**Created**: 2026-03-21

---

## Anti-Patterns — NEVER DO THIS

### WiFi presence → "nobody home" triggers

**NEVER** use `zone.home < 1` (or similar WiFi-based presence) to trigger destructive actions like turning off lights or devices.

**Why:** WiFi is unreliable in this environment (10+ competing networks). Phones drop off WiFi for minutes at a time. HA sees `zone.home = 0` → fires "everyone left" → turns off devices that shouldn't be touched.

**Incident (2026-03-20):** The automation `🧙🏻‍♂️ Everyone Left - All Lights Off` used `light.turn_off target: entity_id: "all"` when `zone.home < 1`. This turned off AWTRIX LED matrices (`light.awtrix_*_matrix`) multiple times per day, causing pixdcon displays to go dark. **Automation deleted.**

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

Turning these off breaks pixdcon scene rendering silently (AWTRIX accepts HTTP commands fine, just doesn't display).

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

### IR Remote / Syncbox / pixdcon (FLIRC on hsb1 — NIX-194)

Triggered by **HA MQTT device triggers** from device `flirc_hsb1` (the `ir-bridge` service on hsb1 publishes `home/hsb1/ir-bridge/action`). Full design + button map: PPM Knowledge `ir-sony-tv-bridge-hsb1`.

| Automation                         | Trigger (`flirc_hsb1`) | Action                          |
| ---------------------------------- | ---------------------- | ------------------------------- |
| FLIRC - Blau - PS5 Sync            | `blue` button          | Hue Sync Box → PS5 input + sync |
| FLIRC - Gelb - PC Sync             | `yellow` button        | Hue Sync Box → PC input + sync  |
| FLIRC - TV/Radio - Pixoo189 Toggle | `tv_radio` button      | pixoo-189 scene toggle          |

### Misc

| Automation                     | Trigger           | Action                |
| ------------------------------ | ----------------- | --------------------- |
| Set mba JHW22 theme at startup | HA start          | Sets UI theme         |
| Nuki aufladen Start/Stop       | Battery threshold | Nuki charging control |
| Gästezimmer D15<->D16          | Light state       | Sync paired lights    |

---

## Deleted Automations (with reason)

| Automation                          | Deleted    | Reason                                                                                                                |
| ----------------------------------- | ---------- | --------------------------------------------------------------------------------------------------------------------- |
| `🧙🏻‍♂️ Everyone Left - All Lights Off` | 2026-03-21 | WiFi presence unreliable; `entity_id: "all"` killed AWTRIX displays + caused false triggers. See anti-patterns above. |

---

## 🚘 Access gate (Zufahrtstor) — the one to read first

The most consequential automation on this host, and the least obvious: **there is
no single place that "the gate" lives.** It is a chain across two hosts, and it
broke silently for two days in July 2026 because nothing documented it and
nothing watched it (OPS-113).

### The chain

| #   | Hop                                                                                                                      | Where                                                                                         |
| --- | ------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------- |
| 1   | Telegram bot receives `/zufahrt` (pulse) or `/zufahrt5` (hold open 5 min), checks the sender against the permission list | Node-RED on **csb0**                                                                          |
| 2   | Publishes the whole message to `scom/jhw22/smarthome`                                                                    | mosquitto on **csb0**, reached at `mosquitto.barta.cm:8883` (TLS, Traefik `HostSNI`)          |
| 3   | Subscribes to that topic on the csb0 broker (`csb0+`), plus a second subscriber on the local broker                      | Node-RED on **hsb1**, tab `🏠 Smarthome`, group _Telegram bot and (local) smarthome commands_ |
| 4   | `/zufahrt` → `link out 133` → `link in 57 (open accessgate)`                                                             | hsb1, tab `🚘 Zufahrt`                                                                        |
| 5   | `do open` → `send Shelly command` → rate limiter (1 per 10 s, excess dropped)                                            | same tab                                                                                      |
| 6   | Publishes `{"method":"Switch.Set","params":{"id":0,"on":true}}` to `home/gz/zufahrt/rpc`                                 | mosquitto on **hsb1** (localhost)                                                             |
| 7   | Relay pulses; `auto_off` returns it after 2 s                                                                            | Shelly Plus 1 `wz-shp1-zufahrt`, `192.168.1.175`, topic prefix `home/gz/zufahrt`              |

Two other sources feed step 4 — the HomeKit accessory `n2h2n accessgate`
(a `GarageDoorOpener` on the Node-RED HomeKit bridge `nrhkb ms24`), and a long
press of the Vorraum Shelly button (`shellies/home/vr/shelly-button1`, which
holds the gate open for 5 minutes by re-sending open on a timer).

### 🔴 What this means when it breaks

- **The wall buttons are hardwired to the gate controller and bypass every hop
  above.** If someone reports "the gate works from inside but not from Telegram
  or HomeKit", nothing in this chain is implicated by the buttons still working.
  That is the single most misleading symptom here.
- **`Garage Door State Machine v8` only logs when `msg.__notify` is true.**
  HomeKit opens set it; Telegram `/zufahrt` does not. An absence of state-machine
  lines in the Node-RED log therefore means "no HomeKit open", **not** "no open".
- The state machine is a **model, not a sensor** — there is no position feedback
  from the gate. Its timings (40 s opening, 35 s open, 45 s closing) are
  assumptions.
- `mqtt out` must stay at **`retain: false`**. A retained `Switch.Set on:true`
  is re-delivered to the Shelly every time it reconnects to the broker, opening
  the gate on reboot, broker restart or a WiFi blip. This was live until
  2026-07-31.

### Diagnosing it

```sh
# Did the command reach hsb1 at all? (csb0 side logs every accepted command)
ssh -p 2222 mba@cs0.barta.cm 'docker logs csb0-nodered-1 --tail 20'

# Is hsb1's subscriber to the csb0 broker actually connected?
ssh mba@hsb1.lan 'docker logs nodered 2>&1 | grep "mqtt-broker:csb0+" | tail -3'

# Watch the last two hops live (a real open shows rpc -> ack -> output true -> timer false)
ssh mba@hsb1.lan 'bash -c "( set -a; source /run/agenix/hsb1-mqtt-client-env; set +a; \
  mosquitto_sub -h localhost -u \$MQTT_USER -P \$MQTT_PASS -v -t home/gz/zufahrt/# -t nodered-hsb1/# )"'

# Is the Shelly itself healthy? (read-only)
ssh mba@hsb1.lan 'curl -s http://192.168.1.175/rpc/MQTT.GetStatus; curl -s http://192.168.1.175/rpc/Switch.GetConfig?id=0'
```

---

## Node-RED Automations

The flow inventory below is generated from `flows.json`, not maintained by hand —
it drifted from 4 documented tabs to 32 real ones before anyone noticed, which is
part of why the gate outage took so long to trace. Regenerate with:

```sh
ssh mba@hsb1.lan 'python3 -c "
import json
f=json.load(open(\"/home/mba/docker/mounts/nodered/data/flows.json\"))
for n in f:
    if n[\"type\"]==\"tab\": print((\"[off] \" if n.get(\"disabled\") else \"\") + n[\"label\"])
"'
```

### Active tabs (28, as of 2026-07-31)

`📎 Global functions` · `⚙️ Tests` · `⚙️ Webserver` · `🏠 Smarthome` ·
`💾 mqtt:home/` · `💡 Lights` · `🪟 Blinds` · `🚪 Doors` · **`🚘 Zufahrt`** ·
`💡 Sternenhimmel [ki]` · `🌈💡 Lametric Sky` · `🖥️ Windows PC [wz]` ·
`🎛️ Syncbox [wz]` · `🎚️ Couchtisch [wz]` · `🔘 Button, Switch, Contact` ·
`☀️⚡️PV0 - Attika` · `☀️ PV1-Data, Estimate` · `⚡️ awattar` · `♨️ Boiler 24 [bz]` ·
`🌦️ Wetter, Sensor` · `🪟 Windows` · `🏃🏻‍➡️ Motion | Presence` · `🔑 Nuki, TXU /vr` ·
`📺 TV` · `❤️‍🩹 Network Health` · `💾 InfluxDB3` · `👶 Babycam Watchdog [NIX-151]` ·
`☀️🔋 USV, Sonnen-Akku`

Notable ones:

- **`🚘 Zufahrt`** — the access gate. See the section above before touching it.
- **`🏠 Smarthome`** — Telegram command ingress from csb0; also the smartlock and
  plug commands.
- **`🎛️ Syncbox [wz]`** — polls the Syncbox API, exposes HomeKit switches for inputs
- **`🔑 Nuki, TXU /vr`** — Nuki status → hue bulb colour indicator + AWTRIX indicator
- **`♨️ Boiler 24 [bz]`** — hot water state machine (heat when energy cheap, done by 06:00)
- **`❤️‍🩹 Network Health`** — Tado→Shelly→Pro4PM chain integrity, publishes to MQTT

### Disabled tabs (4)

`🚘 Tesla state` · `🚘 TG Charging` · `Disabled` · `⬛️ Pixoo [wz]`

`⬛️ Pixoo [wz]` and the old Awtrix Ulanzi control are both superseded by pixdcon.

---

## Guidelines for New Automations

1. **Explicit entity lists only** — never target "all" or entire areas blindly
2. **No WiFi presence triggers** — unreliable with 10+ competing networks
3. **Test with dry-run first** — HA Developer Tools → Services before automating
4. **Document here** — add to the table above when creating new automations
5. **Consider side effects** — check what `light.*`/`switch.*` entities exist via autodiscovery before writing area-based rules
