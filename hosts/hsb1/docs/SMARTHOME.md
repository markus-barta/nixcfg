# Smart Home Architecture & Best Practices

**Server**: hsb1 (Home Server Barta 1)  
**Location**: jhw22 (Home)  
**Last Updated**: November 28, 2025  
**Migration**: Completed 2025-11-28 (was miniserver24)

---

## Aqara Nightlight (OPS-496)

`aqara-nightlight.service` is a native Python service for light and the 25
built-in sounds on two LAN gateways. It uses nixpkgs `python-miio`, not HA or
Zigbee2MQTT. The page labels **KI-18FB** (`plug`, `192.168.1.106`,
Kinderzimmer nightlight) and **WZ-594F** (`round`, `192.168.1.108`) map to stable
API handles. On first visit the responsive page starts in Kind with KI-18FB
selected; hub choice, Kind/Erwachsen and Hell/Dunkel are device preferences.
Switching out of Kind or opening its loud tones requires a one-second hold.
Brightness and colour drags coalesce at one command per second and send the final release value; readback is marked ≈ because hardware values can lag. The default
Nachtlicht is **5C0701 at 44%** for both hubs; tone volume starts at 15%.
The HTML is a separate self-contained file packaged by Nix and read once at
service startup (`AQARA_PAGE_FILE`); it uses system fonts and inline SVG with
no external assets.

Same-origin localStorage keys `nightlight-hub`, `nightlight-mode`,
`nightlight-theme`, `nightlight-tab-plug`, `nightlight-tab-round` and
`nightlight-preview-paused` hold only requested interface choices. The page reads them on
load and writes them when the user changes a choice; they remain until site data
is cleared. Storage failures retain the first-visit defaults. Requests go only
to this service's same-origin API; saved Nachtlicht presets remain on the server.

UI: <http://192.168.1.101:8765/> (LAN), <http://100.64.0.7:8765/> (tailnet),
and <http://127.0.0.1:8765/> on hsb1. Port 8765 has no other checked-in hsb1
listener. There is no public proxy, DNS route or login. The host firewall is
disabled for HomeKit: its `allowedTCPPorts` entry is documentation only.
Explicit loopback/LAN/tailnet binds, systemd `IPAddressDeny=any` with
loopback/LAN/tailnet and both hub addresses allowed, and an HTTP peer
allowlist enforce the service boundary. IP rules apply in both directions;
the gateways remain reachable on UDP 54321. The host declares no outbound
port restriction; systemd's address rules do not restrict destination ports.
The HTTP Host allowlist accepts `127.0.0.1`, `localhost`, `192.168.1.101`,
`hsb1`, `hsb1.lan` and `100.64.0.7`, each with or without `:8765`. A present
`Sec-Fetch-Site` must be `same-origin` or `none`; a present `Origin` must
match the request's allowed HTTP Host. Invalid Host, Origin or fetch metadata
returns **403**. These checks are defence in depth because browsers can omit
Origin and fetch metadata on plain HTTP. Every acting endpoint (`/set`,
`/tone`, `/stop`, `/preset`, `/apply`, `/settings`, `/seen`, `/signal-test`, `/desk`, `/desk-test`) requires exactly one
`X-Nightlight: 1` header; absent, duplicated or invalid headers return **403**.
Existing actions accept **GET or POST**. `/desk` and `/desk-test` require POST
with exactly one `X-Nightlight-Mode: erwachsen` and a JSON body; query strings
are refused. **GET-with-header is deprecated**
compatibility for Home Assistant's existing `rest_command`; new callers and
the UI use POST. The custom header is the CSRF protection. `/`, `/get` and
`/presets`, `/config` and `/signal` remain read-only GETs without it. POST to these read-only paths returns 405. Cross-origin scripts need a preflight to send the custom header; **OPTIONS
returns 403** without CORS permission headers. CSP `frame-ancestors 'none'`
and `X-Frame-Options: DENY` prevent framing of the HTML UI. Unlisted tunnel
Hosts or ports are rejected too. Linux `IP_FREEBIND` keeps LAN/loopback
available while the tailnet address is absent. Empty or wildcard bind
addresses fail startup before any listener opens.

| Method      | Path           | Parameters                                            | Behavior                                           |
| ----------- | -------------- | ----------------------------------------------------- | -------------------------------------------------- |
| GET         | `/`            | —                                                     | Responsive Nachtlicht/Desk UI                      |
| GET or POST | `/set`         | `hub`, `rgb`, `bri`                                   | Manual light; one 300 ms echo                      |
| GET         | `/get`         | `hub`                                                 | Approximate RGB/illumination readback              |
| GET or POST | `/tone`        | `hub`, `id`, optional `vol`, `ms=200..3000`           | Play; optional timed stop                          |
| GET or POST | `/stop`        | `hub`                                                 | Stop; cancel timed stop                            |
| GET         | `/presets`     | —                                                     | Ordered `[{id,name,rgb,bri}]` per hub              |
| GET or POST | `/preset`      | `hub`, `id` plus colour/name/reset/delete, or `new=1` | Save/manage up to six places; no light command     |
| GET or POST | `/apply`       | `hub`, `preset=<id>`                                  | Apply any saved place; HA-compatible JSON          |
| GET         | `/config`      | —                                                     | Per-hub Verwendung, rules, thresholds and sound    |
| GET or POST | `/settings`    | `hub`, setting fields                                 | Persist use, rules or sound                        |
| GET         | `/signal`      | `hub`                                                 | Resolved signal, counts and last hub ACK           |
| GET or POST | `/seen`        | `hub`                                                 | Quiet until a new held generation                  |
| GET or POST | `/signal-test` | `hub`, `rule`, optional rule fields                   | Ten-second preview, then live signal               |
| POST        | `/desk`        | JSON desk metadata, optional write-only `key`         | Add/save/replace/remove, capability check required |
| POST        | `/desk-test`   | JSON desk metadata, optional write-only `key`         | Counts-only capability check, no persistence       |

All acting calls need `X-Nightlight: 1`; existing action parameters remain in the
query string for both methods. Desk credentials travel only in the JSON body.
Prefer `-H 'X-Nightlight: 1' -X POST` with curl. `/apply`
works from `127.0.0.1` with the header and no Origin or extra CSRF token,
including HA's legacy GET caller. An unknown or missing saved preset returns
`ok:false` without sending anything to the hub.

`/var/lib/aqara-nightlight/presets.json` is the server's source of truth for
both the page and HA's Kinderzimmer double-press/Gute-Nacht actions. A missing
file supplies the defaults for both hubs; an absent entry in an existing file
is unsaved. Saves use a separate stable `presets.json.lock` and an atomic,
private file replacement, with file/directory sync. Corrupt state fails closed
rather than silently applying defaults or overwriting it. The old single-Nachtlicht file migrates atomically and losslessly to named slots
`nacht`, `p2`–`p6`; IDs stay fixed and `nacht` cannot be deleted. The page offers
an Erwachsen-only “Speichern als …” sheet with rename, delete confirmation,
default reset and save-only Undo; HA configuration
remains LOCAL-OPS-owned. See the [runbook](RUNBOOK.md#aqara-nightlight-ops-496)
for complete examples.

The 25 tone IDs/names remain in the Python source and UI: 0–8 (Alarm),
10–15 (Türklingel), 20–29 (Wecker). Keep live tests at volume 10–15, short,
and always stop afterwards. Brightness clamps to 0–100. Tone volume defaults
to 15 and clamps to **0–40** in both the API and CLI; the UI also caps it at 40.
API responses preserve `ok`, `hub`, command-specific fields and `versuche`;
command failures return `ok: false` and a fixed `error` message with HTTP 200,
as in the prototype; HTTP security/method checks return 403/405 instead.
The page distinguishes a 403 as ‘Vom Server abgelehnt · Seite neu laden’ with
reload and no retry. Other command failures offer manual retry; late replies
do not replace a newer command's status. The CSP permits only the packaged
script's SHA-256 hash, inline styles and same-origin connections/SVG references.
No handshake token or raw library exception is logged.

KI-18FB defaults to Nachtlicht use; WZ-594F defaults to Desk-Signal use. Version 33
settings store zero or more desks, three shared urgency rules, Ruhe/Unbekannt,
optional per-desk overrides, multiple-colour policy, four-hour urgency thresholds
and automatic audio. Desk colours come from the desk. The highest urgency wins;
multiple desks at that urgency cycle their colours at one colour per Takt or use
an explicit shared colour. Single-desk overrides set brightness/mode/Takt;
simultaneous desks use the shared urgency behaviour. Until OPS-502 supplies the
documented `desk-counts.json` input, the Desk hub stays **Unbekannt** at 5%, and
each desk row says **keine Daten**. A fresh installation starts with zero desks,
also Unbekannt. There is no poller or outbound Desk call in this revision.
Key tests/saves fail closed until a reviewed counts-only capability verifier
exists; connectivity alone cannot prove restricted scope. Runtime key storage
and request boundaries are covered with obvious fake credentials offline.
Automatic sound starts off, is capped at 15%, never repeats a consumed held
generation, and is limited to once per ten minutes. Vienna quiet hours
20:00–07:30 disable animation/audio and hold lit rules at 5%.

Each hub has a lock and a dedicated bounded signal worker. Blink/alternate ticks
send one attempt, skip busy hubs, and have a 2–5 s Takt. Manual commands pause the
engine through their reply and retain the existing four-attempt reliability
path. Explicit 1.5 s discovery and response timeouts bound transport at 19.4 s
including lock wait and echo; the page times out after 30 s. Tap controls lock
immediately; the overlay appears after 250 ms with actual streamed retry
progress. Drags wait for replies, coalesce and stay at one per second.

The shared counter reserves blocks of 256 monotonic wire IDs, with file and
directory sync per block; restart discards unused IDs. It bypasses python-miio's
internal 9999 wrap. Preserve `msgid`, `msgid.lock`, presets and settings; never
restore an older counter. Old code cannot read new preset arrays, so rollback
requires a reviewed compatibility plan. See the [runbook](RUNBOOK.md#round-4-api-and-timing)
for API details, retry budgets, the exact feed schema and poller ownership.

**Integration ownership:** DEVOPS verified on **2026-10-29** that hsb1's live
HA `config_entries` contain no `xiaomi_aqara` or `xiaomi_miio` entries. The
checked-in repo also has no configuration for these integrations. HA uses a live
bind mount at `/home/mba/docker/mounts/homeassistant`, including UI-managed
`.storage`, outside this checkout. Retain the dated verification and recheck
live configuration without dumping credentials if ownership changes before
activation. OPS must ensure no independent miio controller targets these
hubs and stop the Mac prototype before enabling this service.
Separate counters would collide. Leave HA configuration unchanged; an actual
conflict needs host-owner resolution. See the
[runbook](RUNBOOK.md#aqara-nightlight-ops-496) for the handoff checklist.

## 🏠 Home Assistant (HA) Deep Dive

### Runtime Context

HA runs as a privileged Docker container on `hsb1` using `network_mode: host` to ensure full mDNS/HomeKit discovery.

- **Image**: `ghcr.io/home-assistant/home-assistant:stable`
- **Data Root**: `/home/mba/docker/mounts/homeassistant/`

### Configuration Structure

- `configuration.yaml`: Main entry point. Includes other files and defines the `homekit` bridge.
- `automations.yaml` / `scripts.yaml`: Managed via UI but stored here.
- `.storage/`: **CRITICAL** - contains the internal registry and UI-managed dashboards.
  - `core.entity_registry`: Mapping of unique IDs to `entity_id`.
  - `lovelace.dashboard_main`: The JSON config for the "Main" dashboard.
  - `lovelace_dashboards`: Metadata about all custom dashboards.

### Dashboard Management (Lovelace)

While YAML mode is possible, we use the default **Storage Mode** for the Main dashboard.

- **Path**: `.storage/lovelace.dashboard_main`
- **Format**: JSON (not YAML!)
- **Key Entity**: `lock.nuki_vr` (configured as a `tile` card in the Main dashboard).

### MQTT Integration

HA connects to the `mosquitto` container on `localhost:1883`.

- ⚠️ **Gotcha**: If HA is moved or the hostname changes, ensure the MQTT integration is set to `localhost` or the fixed IP `192.168.1.101`.

---

## 📊 Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            SMART HOME STACK                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌───────────┐  │
│  │   Zigbee     │───▶│  Zigbee2MQTT │───▶│   Mosquitto  │───▶│   Home    │  │
│  │   Devices    │    │   (Z2M)      │    │    (MQTT)    │    │ Assistant │  │
│  │   (133+)     │    │   :8888      │    │    :1883     │    │   :8123   │  │
│  └──────────────┘    └──────────────┘    └──────────────┘    └─────┬─────┘  │
│                                                                    │        │
│  ┌──────────────┐    ┌──────────────┐                         ┌────▼────┐   │
│  │   Node-RED   │◀──▶│   Mosquitto  │                         │ HomeKit │   │
│  │   :1880      │    │              │                         │ Bridge  │   │
│  └──────────────┘    └──────────────┘                         │ :51828  │   │
│                                                               └────┬────┘   │
│  ┌──────────────┐    ┌──────────────┐                              │        │
│  │   Scrypted   │───▶│   HomeKit    │◀─────────────────────────────┘        │
│  │   (Cameras)  │    │   (Apple)    │                                       │
│  └──────────────┘    └──────────────┘                                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 🐳 Docker Services

| Service                 | Port       | Purpose                                                | Critical |
| ----------------------- | ---------- | ------------------------------------------------------ | -------- |
| **apprise**             | 8001       | Notifications                                          | 🟡 Med   |
| **fritz-tripwire**      | 9000       | Fritz!Box anomaly witness                              | 🟡 Med   |
| **funkeykid**           | 8081       | Educational keyboard service                           | 🟡 Med   |
| **homeassistant**       | 8123       | Smart home platform                                    | 🔴 Yes   |
| **hsb1-home**           | 80         | HostDash static dashboard                              | 🟢 Low   |
| **matter-server**       | varies     | Matter protocol                                        | 🟡 Med   |
| **mosquitto**           | 1883, 9001 | MQTT broker                                            | 🔴 Yes   |
| **nodered**             | 1880       | Automation flows                                       | 🟠 High  |
| **opus-stream-to-mqtt** | N/A        | OPUS/EnOcean to MQTT bridge                            | 🟢 Low   |
| **opusweb**             | 3102       | OPUS web application                                   | 🟡 Med   |
| **pharos-beacon**       | N/A        | Fleet observation reporter                             | 🟡 Med   |
| **pixdcon**             | 10829      | Pixoo display control                                  | 🟡 Med   |
| **plex**                | 32400      | Media server                                           | 🟡 Med   |
| **restic-cron-hetzner** | N/A        | Backups                                                | 🟠 High  |
| **scrypted**            | 10443      | Camera/HomeKit bridge                                  | 🔴 Yes   |
| **smtp**                | 25         | Mail relay                                             | 🟢 Low   |
| **turbogmailify**       | N/A        | Residue mail bridge: Hover INBOX → Gmail API (OPS-196) | 🟢 Low   |
| **zigbee2mqtt**         | 8888       | Zigbee device management                               | 🔴 Yes   |

---

## 📁 File Locations

### Docker Configuration

```
~/docker/
├── Makefile                    # Legacy: DO NOT RUN (no compose file here)
├── mounts/                     # Runtime data (not a compose source)
│   ├── homeassistant/
│   │   ├── configuration.yaml  # ← Main HA config
│   │   ├── automations.yaml
│   │   └── .storage/           # Entity registry, etc.
│   ├── zigbee2mqtt/
│   │   ├── configuration.yaml  # ← Device friendly names
│   │   ├── database.db         # Device database
│   │   └── state.json          # Current device states
│   ├── nodered/
│   │   └── data/flows.json     # Node-RED automations
│   └── mosquitto/
│       └── config/mosquitto.conf
├── restic-cron/                # Legacy retained pending NIX-407 inventory
└── smtp/                        # Legacy retained pending NIX-407 inventory
```

The declarative source is `hosts/hsb1/docker/compose-spec.nix`; Nix renders it
to `/etc/compose/hsb1/docker-compose.yml`, and `compose-hsb1.service`
reconciles it. Do not recreate `~/docker/docker-compose.yml` or run the legacy
Makefile; NIX-407 owns the file-by-file inventory and recoverable cleanup
decision for both retained home trees.

### Secrets

```
/run/agenix/  (decrypted at boot by agenix; no plaintext on disk)
├── hsb1-smarthome-env    # MQTT + service API credentials; no HA access token (verified 2026-08-12)
├── hsb1-zigbee2mqtt-env  # Z2M MQTT credentials
├── hsb1-mqtt-client-env  # MQTT broker credentials
└── hsb1-tapo-c210-env    # Camera passwords
```

---

## 🔧 Adding a New Zigbee Device

### Step 1: Pair the Device

```bash
# Enable pairing mode (via Z2M web UI or MQTT)
docker exec mosquitto mosquitto_pub -t "zigbee2mqtt/bridge/request/permit_join" -m '{"value": true}'

# Watch for new devices
docker logs -f zigbee2mqtt | grep -i "interview"
```

### Step 2: Rename in Zigbee2MQTT

Edit `~/docker/mounts/zigbee2mqtt/configuration.yaml`:

```yaml
devices:
  "0x54ef4410014966cf": # IEEE address from logs
    friendly_name: gz/presence/fp300 # Use room/type/model format
    description: |
      🔷 Aqara FP300 Multi-Presence Sensor
      🏠 Gästezimmer • Anwesenheit
```

**Naming Convention**: See [Naming & UX Best Practices](#🏆-naming--ux-best-practices) for details.

### Step 3: Verify in Home Assistant

```bash
# Check entity registry
cat ~/docker/mounts/homeassistant/.storage/core.entity_registry | \
  jq '.data.entities[] | select(.unique_id | contains("ADDRESS"))'

# Or use the HA API
curl -s http://localhost:8123/api/states | jq '.[].entity_id' | grep -i "device"
```

### Step 4: Add to HomeKit (if needed)

Edit `~/docker/mounts/homeassistant/configuration.yaml`:

1. **Add to `include_entities`** (whitelist):

```yaml
homekit:
  - name: "HASS Bridge YAML"
    port: 51828
    filter:
      include_entities:
        # ... existing entries ...
        - binary_sensor.0x54ef4410014966cf_presence # gz/presence/fp300
        - sensor.0x54ef4410014966cf_temperature
        - sensor.0x54ef4410014966cf_humidity
```

2. **Add to `entity_config`** (friendly names):

```yaml
entity_config:
  # ... existing entries ...

  binary_sensor.0x54ef4410014966cf_presence:
    name: "Gästezimmer Anwesenheit"
    # gz/presence/fp300 - Aqara FP300 Multi-Presence

  sensor.0x54ef4410014966cf_temperature:
    name: "Gästezimmer Temperatur"
```

3. **Restart Home Assistant**:

```bash
docker restart homeassistant
# Wait ~30s, check logs for errors
docker logs homeassistant --tail 50 2>&1 | grep -i homekit
```

---

## 🔥 Heating — tado (LOCAL via HomeKit, no cloud)

**Since 2026-08-02 (OPS-131)** the tado system is fully local. The cloud
integration was removed (device-code re-auth PITA + 100 req/day rate limit since
2026-01); the IB01 bridge is HomeKit-paired **directly to HA**
(`homekit_controller`), and the thermostats are re-exposed to Apple Home through
the HASS Bridge (`homekit:` block in `configuration.yaml`).

```
RU02 thermostats ──(868 MHz)── IB01 bridge ──(HomeKit/IP, local)── HA
                                                                    │
                                              Apple Home ──(HASS Bridge)──┘
```

- **Entities**: `climate.wohnzimmer`, `climate.schlafzimmer`, `climate.badezimmer`,
  `climate.kinderzimmer`, `climate.gastezimmer`, `climate.gastebad`,
  `climate.vorkuche`, `climate.wc` — same IDs as the old cloud entities, so
  dashboards + statestream topics (`homeassistant/climate/<room>/…`) are unchanged.
- **Devices** named `<Room> Tado` (room repeated on purpose — survives Apple
  room-loss). Bridge = `Vorraum Tado Bridge` (`IB3250129664`).
- Room ↔ Heizkreis ↔ RU02-serial mapping: Markus's heating spreadsheet
  (Heizkreis-Doku); wiring side is Pro4PM-Heizkreise (see OPS-31).
- 🔴 **HomeKit setup code**: sticker on the IB01 side, saved in 1Password.
  tado cannot regenerate it — losing it means a new bridge.
- 🔴 The bridge pairs to exactly **ONE** controller. It is paired to **HA** —
  never pair it to Apple Home directly again; Apple gets the thermostats via the
  HASS Bridge.
- The tado app/cloud is unused and unauthenticated. The cloud integration's
  rediscovery card in HA is set to "Ignore".
- Migration backup: `/home/mba/ha-config-backup-20260802-ops131.tgz`
  (pre-rename `.storage` + `configuration.yaml`; delete after the 30-day soak).

---

## 🏠 Room Abbreviations

| Code | German       | English            |
| ---- | ------------ | ------------------ |
| `bz` | Badezimmer   | Bathroom           |
| `ki` | Kinderzimmer | Children's room    |
| `vr` | Vorraum      | Hallway            |
| `sz` | Schlafzimmer | Bedroom            |
| `ez` | Esszimmer    | Dining room        |
| `ku` | Küche        | Kitchen            |
| `vk` | Vorküche     | Pre-kitchen        |
| `te` | Terrasse     | Terrace            |
| `dt` | Dachterrasse | Roof terrace       |
| `tg` | Tiefgarage   | Underground garage |
| `wc` | WC           | Toilet             |
| `gz` | Gästezimmer  | Guest room         |
| `gw` | Gäste WC     | Guest toilet       |

---

## 🔍 Debugging Commands

### Check Device State (MQTT)

```bash
# Get current state of a device
docker exec mosquitto mosquitto_sub -t "zigbee2mqtt/DEVICE_NAME" -C 1 -W 5

# Subscribe to all messages from a device
docker exec mosquitto mosquitto_sub -v -t "zigbee2mqtt/DEVICE_NAME/#"
```

### Check Device in Z2M Database

```bash
# Find device by address
cat ~/docker/mounts/zigbee2mqtt/database.db | tr "}" "\n" | grep "ADDRESS"

# Check state.json for current values
cat ~/docker/mounts/zigbee2mqtt/state.json | jq '."0xADDRESS"'
```

### Check Home Assistant Entities

```bash
# Find entities for a device
cat ~/docker/mounts/homeassistant/.storage/core.entity_registry | \
  jq '.data.entities[] | select(.unique_id | contains("ADDRESS")) | {entity_id, original_name}'
```

### View Logs

```bash
docker logs zigbee2mqtt --tail 50 | grep -i "ADDRESS"
docker logs homeassistant --tail 100 2>&1 | grep -i "homekit\|error"
docker logs nodered --tail 50
```

---

## 📋 HomeKit Bridge Configuration

**Location**: `~/docker/mounts/homeassistant/configuration.yaml`

### Structure

```yaml
homekit:
  - name: "HASS Bridge YAML"
    port: 51828 # Custom port (default is 51827)
    filter:
      include_entities:
        # Contact Sensors
        - binary_sensor.XXX_contact

        # Motion & Presence
        - binary_sensor.XXX_presence
        - binary_sensor.XXX_occupancy

        # Environmental
        - sensor.XXX_temperature
        - sensor.XXX_humidity

        # Climate
        - climate.XXX

        # Lights
        - light.XXX

        # Switches (can be configured as valves)
        - switch.XXX

        # Locks
        - lock.XXX

    entity_config:
      switch.XXX:
        name: "Friendly Name"
        type: valve # Configure switch as HomeKit valve
```

### Special Entity Types

- **Valves**: Use `type: valve` for irrigation switches
- **Locks**: Get a warning recommending accessory mode (can ignore)
- **Sensors**: Automatically detected based on device class

---

## 🏆 Naming & UX Best Practices

### HomeKit Naming

When exposing entities to HomeKit via Home Assistant, always **prefix the literal room name** to the entity name in `entity_config`.

- ✅ **DO**: `Terrasse D28`, `Esszimmer Ensis Oben`
- ❌ **DON'T**: `D28`, `Ensis Oben`

**Benefits:**

1. **Searchability**: Easier to identify devices in global search or lists.
2. **Error Detection**: If a device is moved to the wrong room in HomeKit, the prefix makes the mismatch immediately obvious.
3. **Smart Display**: HomeKit automatically trims the room name from the UI if it matches the room the device is assigned to (e.g., "Terrasse D28" in the "Terrasse" room displays simply as "D28").

### Zigbee2MQTT Naming

Use the convention: `room/type/device_name` (e.g., `bz/light/mirror`, `ku/plug/coffee`).
See [Room Abbreviations](#🏠-room-abbreviations) for codes.

---

## 🤖 AI Agent Best Practices

### Before Making Changes

1. **Always backup first**:

   ```bash
   cp ~/docker/mounts/homeassistant/configuration.yaml \
      ~/docker/mounts/homeassistant/configuration.yaml.bak
   ```

2. **Check current state**:

   ```bash
   grep -n "PATTERN" ~/docker/mounts/homeassistant/configuration.yaml
   ```

3. **Validate YAML after changes**:
   ```bash
   python3 -c "import yaml; yaml.safe_load(open('FILE'))"
   ```

### Making Edits

1. **Use Python for complex edits** (fish shell doesn't support heredocs):

   ```bash
   ssh server 'bash -c "python3 << EOF
   # Python script here
   EOF"'
   ```

2. **Use sed for simple line additions** (be careful with escaping):

   ```bash
   sed -i '/PATTERN/a NEW_LINE' file
   ```

3. **Always verify changes before restarting**:
   ```bash
   grep -A5 "PATTERN" configuration.yaml
   ```

### After Changes

1. **Restart the affected service**:

   ```bash
   docker restart homeassistant  # or zigbee2mqtt, nodered, etc.
   ```

2. **Check logs for errors**:

   ```bash
   docker logs SERVICE --tail 50 2>&1 | grep -i "error\|warning"
   ```

3. **Verify functionality**:
   ```bash
   # Check if HomeKit bridge loaded
   docker logs homeassistant 2>&1 | grep -i "homekit" | tail -5
   ```

---

## 🔐 Security Notes

- **MQTT credentials**: Stored in `/run/agenix/hsb1-mqtt-client-env` (agenix managed)
- **hsb1 service environment**: A value-free key-name inventory on 2026-08-12 confirmed that `hsb1-smarthome-env` holds MQTT and service API credentials, not a Home Assistant access token.
- **OpenClaw's Home Assistant token**: agenix `hsb0-openclaw-hass-token` on **hsb0**, mounted at `/run/secrets/hass-token` in the `openclaw-gateway` container and shared by both agents (see [`hosts/hsb0/docs/OPENCLAW-RUNBOOK.md`](../../hsb0/docs/OPENCLAW-RUNBOOK.md#home-assistant)). The independent csb0 fleet-alert poller uses `HA_TOKEN_HSB1` from agenix `csb0-ops-alerts-env`.
- **Camera passwords**: Stored in `/run/agenix/hsb1-tapo-c210-env` (agenix managed)
- **Never commit secrets to git**

---

## 📱 Device Types & Entities

### Presence/Motion Sensors (Aqara)

| Model     | Entities Created                                                                       |
| --------- | -------------------------------------------------------------------------------------- |
| **FP1**   | `_presence`, `_device_temperature`                                                     |
| **FP1E**  | `_presence`, `_motion`, `_device_temperature`                                          |
| **FP300** | `_presence`, `_pir_detection`, `_temperature`, `_humidity`, `_illuminance`, `_battery` |
| **P1**    | `_occupancy`, `_illuminance`, `_device_temperature`                                    |

### Contact Sensors

| Model                 | Entities               |
| --------------------- | ---------------------- |
| **Aqara Door/Window** | `_contact`, `_battery` |

### Climate

| Type                   | Entities                                   |
| ---------------------- | ------------------------------------------ |
| **Generic Thermostat** | `climate.NAME` (uses switch + temp sensor) |

### Irrigation

| Type                | Entities                                   |
| ------------------- | ------------------------------------------ |
| **Gardeneer Valve** | `switch.ADDRESS`, `sensor.ADDRESS_battery` |

---

## 🎛️ Syncbox & IR Remote Control (Wohnzimmer)

### Architecture

```
physical IR remote --IR--> FLIRC USB on hsb1 --evdev--> ir-bridge.py (native systemd)
  │  TV keys   → Sony IRCC over HTTP → Bravia 192.168.1.137 (fast path, HA-independent)
  │  EVERY key → MQTT home/hsb1/ir-bridge/action + HA MQTT-Discovery device `flirc_hsb1`
  ▼
Home Assistant — device triggers (domain mqtt, type button_short_press, subtype <key>)
  ├── 🟦 blue   → automation "FLIRC - Blau - PS5 Sync" → Hue Sync Box PS5 input + sync
  ├── 🟨 yellow → automation "FLIRC - Gelb - PC Sync"  → Hue Sync Box PC input + sync
  └── tv_radio  → pixoo-189 scene toggle (see AUTOMATIONS.md)

Node-RED Tab "🎛️ Syncbox [wz]"  (independent path, also active)
  ├── Polls Syncbox every 5s  GET https://192.168.1.111/api/v1/execution/
  ├── Bearer token: env var SYNCBOX_BEARER_TOKEN (Node-RED env)
  ├── HomeKit bridge: n2h2n syncBox sync (on/off toggle)
  ├── HomeKit bridge: n2h2n syncBox Input1-4 (per-input switches)
  │     Input1 = frei (low bw)  Input2 = PC (high bw)
  │     Input3 = switch (low bw) Input4 = PS5 (high bw)
  └── "from ir remote - syncbox sync" link in
        → switch on hdmiSource → input2 (PC) / input4 (PS5)
        → bravia-ircc WakeUp → delay → Hdmi2  (Sony TV via Node-RED bravia node)
```

### Key Details

| What                  | Value                                                                          |
| --------------------- | ------------------------------------------------------------------------------ |
| Syncbox IP            | `192.168.1.111`                                                                |
| Syncbox API           | `https://192.168.1.111/api/v1/execution/` (self-signed TLS)                    |
| Auth                  | Bearer token in Node-RED env `SYNCBOX_BEARER_TOKEN`                            |
| FLIRC bridge          | hsb1 native systemd `ir-bridge` (`hosts/hsb1/ir-bridge.nix`)                   |
| IR bridge witness     | `ir-bridge-watch.timer` → Telegram (`hosts/hsb1/ir-bridge-watch.nix`, OPS-223) |
| HA MQTT device        | `flirc_hsb1` · action topic `home/hsb1/ir-bridge/action`                       |
| HA automations        | `automation.flirc_ps5_sync`, `automation.flirc_pc_sync`                        |
| Node-RED tab          | `🎛️ Syncbox [wz]`                                                              |
| Sony TV Node-RED node | `bravia-tv` → `wz-sony-tv`                                                     |

### FLIRC bridge (NIX-194)

The FLIRC is on **hsb1** via the native `ir-bridge` systemd service — IR → {Sony IRCC, MQTT}. Smart keys reach HA as **MQTT-Discovery device triggers** (device `flirc_hsb1`), not the old `sensor.flirc_bridge_last_key`. Full design + button map: PPM Knowledge `ir-sony-tv-bridge-hsb1`. (History: the FLIRC ran on a Pi-Zero "hsb2" Jan–Jun 2026; the old Node-RED `GLOBAL_FLIRC_RECEIVER` direct-USB path is obsolete.)

### Custom HA Component

`custom_components/huesyncbox` — provides the Syncbox integration (select entities for input, sync mode, entertainment area, intensity, LED indicator).

---

## 🔊 VLC Kiosk Audio Control (Babycam)

### Architecture (slightly insane but works™)

```
┌─────────────────┐     ┌──────────────┐     ┌─────────────────────────┐
│  Aqara Button   │────▶│   Node-RED   │────▶│   MQTT Topic            │
│  (double-press) │     │   (flow)     │     │   home/hsb1/kiosk-vlc-  │
└─────────────────┘     └──────────────┘     │   volume                │
                                             └───────────┬─────────────┘
                                                         │
                        ┌────────────────────────────────▼─────────────────┐
                        │  mqtt-volume-control.service (systemd)           │
                        │  - Subscribes to MQTT topic                      │
                        │  - Validates volume (0-512)                      │
                        │  - Sends telnet command to VLC                   │
                        └────────────────────────────────┬─────────────────┘
                                                         │
                        ┌────────────────────────────────▼─────────────────┐
                        │  VLC (kiosk user, fullscreen)                    │
                        │  - Telnet interface on localhost:4212            │
                        │  - Password from /run/agenix/hsb1-tapo-c210-env  │
                        │  - Shows RTSP camera stream                      │
                        └──────────────────────────────────────────────────┘
```

### Components

| Component           | Location                                  | Purpose                                |
| ------------------- | ----------------------------------------- | -------------------------------------- |
| **Aqara Button**    | Physical device                           | Triggers volume toggle on double-press |
| **Node-RED Flow**   | `~/docker/mounts/nodered/data/flows.json` | Listens for button, publishes MQTT     |
| **MQTT Topic**      | `home/hsb1/kiosk-vlc-volume`              | Message bus for volume commands        |
| **systemd service** | `mqtt-volume-control.service`             | Bridge between MQTT and VLC telnet     |
| **VLC Telnet**      | `localhost:4212`                          | Accepts `volume N` commands            |
| **VLC Display**     | X11 kiosk session                         | Shows camera on attached monitor       |

### MQTT Message Format

```bash
# Mute (volume 0)
mosquitto_pub -h hsb1 -u USER -P PASS -t "home/hsb1/kiosk-vlc-volume" -m "0"

# Full volume (512)
mosquitto_pub -h hsb1 -u USER -P PASS -t "home/hsb1/kiosk-vlc-volume" -m "512"

# 50% volume (256)
mosquitto_pub -h hsb1 -u USER -P PASS -t "home/hsb1/kiosk-vlc-volume" -m "256"
```

### Files Involved

| File                               | Purpose                                            |
| ---------------------------------- | -------------------------------------------------- |
| `/run/agenix/hsb1-mqtt-client-env` | MQTT credentials (MQTT_HOST, MQTT_USER, MQTT_PASS) |
| `/run/agenix/hsb1-tapo-c210-env`   | VLC telnet password                                |
| `configuration.nix`                | systemd service definition                         |
| `flows.json`                       | Node-RED automation                                |

### Troubleshooting

```bash
# Check service status
systemctl status mqtt-volume-control

# View service logs
journalctl -t mqtt-volume-control -f

# Test MQTT manually
mosquitto_pub -h hsb1 -t "home/hsb1/kiosk-vlc-volume" -m "256"

# Test VLC telnet directly
echo -e "PASSWORD\nvolume 256\nquit" | nc localhost 4212
```

### ✅ Migration Complete (2025-11-28)

Hostname changed `miniserver24` → `hsb1`:

- **systemd service**: Listens on `home/hsb1/kiosk-vlc-volume` ✅
- **Node-RED flows**: Updated to `home/hsb1/kiosk-vlc-volume` ✅
- **DNS alias**: `miniserver24` still resolves (legacy, remove after 2025-12-28)

---

## 🔄 System Updates & Restarts

### After NixOS Rebuild

The kiosk display (babycam) may go blank after `nixos-rebuild switch`:

```bash
# Restart display manager to restore kiosk
sudo systemctl restart display-manager.service

# Verify VLC is running
pgrep -a vlc
```

### Known Non-Critical Warnings

These warnings appear after rebuild but are harmless:

| Warning                            | Cause                     | Impact                    |
| ---------------------------------- | ------------------------- | ------------------------- |
| `suid-sgid-wrappers.service`       | Restic capability setting | None (restic still works) |
| `systemd-zram-setup@zram0.service` | ZRAM swap restart         | None (16GB RAM is plenty) |

### Shell Differences (fish vs bash)

The default shell is **fish**. When sourcing `.env` files:

```bash
# ❌ Won't work in fish
source /run/agenix/hsb1-mqtt-client-env

# ✅ Use bash instead
bash -c 'source /run/agenix/hsb1-mqtt-client-env && echo $MQTT_HOST'
```

---

## 🔄 Common Workflows

### Add Presence Sensor to HomeKit

1. Pair device → Z2M assigns address
2. Rename in Z2M config (room/presence/model)
3. Find HA entities: `binary_sensor.ADDRESS_presence`
4. Add to HomeKit `include_entities`
5. Add to HomeKit `entity_config` with German name
6. Restart HA, verify in logs

### Troubleshoot Missing Device

1. Check Z2M logs: `docker logs zigbee2mqtt | grep ADDRESS`
2. Check database: `grep ADDRESS ~/docker/mounts/zigbee2mqtt/database.db`
3. Check state: `cat state.json | jq '."0xADDRESS"'`
4. Check MQTT: `mosquitto_sub -t "zigbee2mqtt/DEVICE/#"`

### Update Device Configuration

1. Edit Z2M `configuration.yaml` for device settings
2. Edit HA `configuration.yaml` for HomeKit exposure
3. Restart appropriate container
4. Verify in logs

---

## 📚 Related Documentation

- [Zigbee2MQTT Docs](https://www.zigbee2mqtt.io/)
- [Home Assistant HomeKit](https://www.home-assistant.io/integrations/homekit/)
- [Node-RED Docs](https://nodered.org/docs/)

---

**Maintainer**: Markus Barta  
**Server**: hsb1 (192.168.1.101)  
**133+ Zigbee Devices** | **11 Docker Containers** | **HomeKit Bridge** | **Babycam Kiosk**
