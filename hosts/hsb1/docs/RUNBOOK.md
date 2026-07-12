# Runbook: hsb1 (Home Automation Server)

**Host**: hsb1 (192.168.1.101)  
**Role**: Home automation hub running Node-RED, Zigbee2MQTT, MQTT broker  
**Criticality**: MEDIUM - Home automation services

---

## Quick Connect

```bash
ssh mba@192.168.1.101
# or
ssh mba@hsb1.lan
```

---

## Common Tasks

### Update & Switch Configuration

```bash
ssh mba@192.168.1.101
cd ~/Code/nixcfg
git pull
just switch
```

### Fix Git Issues & Update

If git has merge conflicts or local changes blocking pull:

```bash
ssh mba@192.168.1.101
cd ~/Code/nixcfg
git status                           # Check what's wrong
git checkout -- .                    # Discard all local changes
# OR for specific file:
git checkout -- path/to/file
git pull
just switch
```

**Lockfile conflicts** (`devenv.lock`, `flake.lock`): these auto-resolve via
the repo's merge driver — but only if `just setup-git-drivers` has been run
once on this clone. To verify:

```bash
git config --local --get merge.ours.driver   # expect: true
```

If empty, run `just setup-git-drivers`. See
[`docs/AGENT-WORKFLOW.md`](../../../docs/AGENT-WORKFLOW.md#lockfile-merge-conflicts)
for the full story.

### Rollback to Previous Generation

```bash
ssh mba@192.168.1.101
sudo nixos-rebuild switch --rollback
```

---

## 🏠 Home Assistant Basics

- **Host**: `hsb1.lan` (192.168.1.101)
- **Runtime**: Docker container (`homeassistant`)
- **Web UI**: [http://192.168.1.101:8123](http://192.168.1.101:8123)
- **Config Path**: `~/docker/mounts/homeassistant/`
- **Dashboard Config**: `.storage/lovelace.<dashboard_id>` (JSON format)
- **Core Config**: `configuration.yaml`, `automations.yaml`, `scripts.yaml`

### Quick Check

```bash
# View HA logs
ssh mba@hsb1.lan "docker logs -f homeassistant --tail 50"

# List dashboard configs
ssh mba@hsb1.lan "ls ~/docker/mounts/homeassistant/.storage/lovelace.*"
```

---

## 📂 File Management

hsb1 is **declarative** — configuration is driven by `nixos-rebuild switch` from `~/Code/nixcfg` (this repo), not a "symlink everything to the repo" layer. The moving parts:

| What                   | How it's managed                                                                                        |
| ---------------------- | ------------------------------------------------------------------------------------------------------- |
| Docker stack           | compose at `hosts/hsb1/docker/docker-compose.yml`, launched by the `hsb1-stack` systemd unit            |
| Kiosk babycam launcher | Home-Manager: `hosts/hsb1/files/kiosk-autostart.sh` → `~/.config/openbox/autostart` (nix-store symlink) |
| Secrets                | agenix → `/run/agenix/hsb1-*` (no plaintext on disk)                                                    |
| System / services      | NixOS modules in `hosts/hsb1/` + shared `modules/`                                                      |

**Runtime data (unmanaged, not in git):** container mounts under `~/docker/mounts/` (HA config, Node-RED data, etc.).

**Golden rule:** never edit config on the host — edit in `~/Code/nixcfg`, commit, `git pull`, `sudo nixos-rebuild switch`.

---

## Health Checks

### Quick Status

```bash
ssh mba@192.168.1.101 "docker ps && zpool status | head -10"
```

### NCPS Binary Cache (hsb0)

Verified that the local cache is being used:

```bash
nix build nixpkgs#cowsay --no-link -L
# Should show: copying path '...' from 'http://hsb0.lan:8501'
```

### Container Status

```bash
ssh mba@192.168.1.101 "docker ps --format 'table {{.Names}}\t{{.Status}}'"
```

### ZFS Pool Status

```bash
ssh mba@192.168.1.101 "zpool status"
```

---

## Docker Services

### View All Containers

```bash
ssh mba@192.168.1.101 "docker ps -a"
```

### Restart a Container

```bash
ssh mba@192.168.1.101 "docker restart nodered"
ssh mba@192.168.1.101 "docker restart mosquitto"
ssh mba@192.168.1.101 "docker restart zigbee2mqtt"
```

### View Container Logs

```bash
ssh mba@192.168.1.101 "docker logs -f nodered --tail 100"
ssh mba@192.168.1.101 "docker logs -f mosquitto --tail 100"
```

### Restart All Docker Services

The stack is declarative (systemd unit `hsb1-stack`, compose at `hosts/hsb1/docker/docker-compose.yml`). Restart via the unit — do NOT `docker-compose down/up` from the retired `~/docker` dir:

```bash
ssh mba@hsb1.lan "sudo systemctl restart hsb1-stack"
```

---

## Media & Time Machine Storage

Two external USB ZFS pools, both on hsb1, both imported best-effort at boot
(`boot.zfs.extraPools` in `media-pool.nix` — an absent/asleep drive never
blocks `nixos-rebuild switch`). Config lives in `hosts/hsb1/media-pool.nix`,
`tm-pool.nix`, `tm-samba.nix`.

### `media` pool (4TB drive) — Plex library

Pool root mounted `/srv/media`, with one dataset per library:
`Movies`, `Videos`, `Fotos`, `Audio`, `Games`, `E-Books`. Pool-wide:
`compression=lz4`, `recordsize=1M` (large sequential media files),
`atime=off`, `copies=1`.

`copies=1` is deliberate. ZFS checksums still **detect** bit-rot; the second
copy of the non-movie folders lives on the archived 2026-06 backup disk, and
Movies are re-rippable. `copies=2` would only guard against localised rot on
an otherwise-healthy disk — it is no defence against whole-disk failure, since
both copies sit on the same drive. Detection + an offline copy beats it.
This makes the monthly scrub load-bearing: it is what turns "ZFS has
checksums" into an actual guarantee.

Plex reads it read-only (`docker-compose.yml` plex service,
`/srv/media:/media:ro`) — this replaced the previous Fritz!Box CIFS source
(`/mnt/fritzbox-media`, still declared in `configuration.nix` but no longer
mounted into Plex; safe to re-add as a second library path later if wanted).

> ⚠️ Never repoint Plex at an **empty** `/srv/media`. It will scan, mark every
> item missing, and — with "empty trash after every scan" — purge the library,
> taking watch history, ratings and collections with it.

```bash
# Pool health
ssh mba@192.168.1.101 "zpool status media"
ssh mba@192.168.1.101 "zfs list media"

# Trigger a Plex library rescan after adding files
ssh mba@192.168.1.101 "docker exec plex curl -s 'http://localhost:32400/library/sections/all/refresh'"
```

### `tm` pool (6TB drive) — Time Machine target

Two quota'd datasets, `tm/markus` and `tm/mailina`, `quota=2.5T` each (50:50
split of ~5.45TiB usable — the remaining ~450GB is deliberate headroom for
sanoid's daily snapshots, not unallocated waste). Quotas are **imperative**,
not disko-declared — changing the numbers requires a live `zfs set
quota=<new size> tm/<user>` to match whatever the nix comments say.

Samba (`tm-samba.nix`) exposes each dataset as its own share
(`tm-markus`, `tm-mailina`) via `vfs_fruit`, discoverable natively in each
Mac's System Settings → Time Machine (Avahi mDNS, no manual `smb://` entry
needed). Credentials: `hsb1-tm-smb-env` (see Secrets Inventory below).

```bash
# Pool + quota health
ssh mba@192.168.1.101 "zpool status tm"
ssh mba@192.168.1.101 "zfs list -o name,used,avail,quota,mountpoint tm/markus tm/mailina"

# Snapshot retention (sanoid — daily, 14-day)
ssh mba@192.168.1.101 "systemctl status sanoid.timer"
ssh mba@192.168.1.101 "zfs list -t snapshot -r tm"

# Confirm shares are visible
ssh mba@192.168.1.101 "smbclient -L localhost -U markus"
```

**Setup was imperative, one-time, outside of disko** (both pools are
external/removable drives, not the boot disk) — see the header comments in
`media-pool.nix` / `tm-pool.nix` for the exact `zpool create` / `zfs create`
/ `zfs set quota` commands used, if the pool ever needs rebuilding.

---

## fritz-tripwire (Diagnostic Snapshot for Fritz Mesh)

Captures TR-064 state of all 5 Fritz devices when one fails. Triggered by webhook from the existing Uptime Kuma on hsb0. Built to catch the ~weekly Fritz repeater hang we can't otherwise reproduce.

### Architecture

- **Probe**: Uptime Kuma on `hsb0:3001` runs ICMP monitors against `192.168.1.5–9` every 60s.
- **Trigger**: On a `down` event (3 retries failed), Kuma POSTs a JSON webhook to `http://hsb1.lan:9000/hooks/fritz-down`.
- **Capture**: `fritz-tripwire` container (this host) runs `run.sh`, which writes a timestamped snapshot to `~/docker/mounts/fritz-tripwire/incidents/fritz-<ip>-<ts>/`.

### Snapshot contents

| File                        | Source                                                      |
| --------------------------- | ----------------------------------------------------------- |
| `meta.json`                 | trigger context (ip, monitor name, msg, timestamp)          |
| `tcp-<ip>.txt`              | TCP probe to ports 80, 443, 49000 for each of the 5 devices |
| `tr064-deviceinfo-<ip>.xml` | TR-064 `GetInfo` — uptime, fw version                       |
| `tr064-devicelog-<ip>.xml`  | TR-064 `GetDeviceLog` — device-side event buffer            |

### Kuma setup (one-time, on hsb0)

1. Open http://hsb0.lan:3001
2. Add 5 **Ping** monitors, interval 60s, retries 3:
   - `Fritz .5 (fb7530)` → 192.168.1.5
   - `Fritz .6 (wz-repeater)` → 192.168.1.6
   - `Fritz .7 (bz-repeater)` → 192.168.1.7
   - `Fritz .8 (dt-repeater)` → 192.168.1.8
   - `Fritz .9 (kr-repeater)` → 192.168.1.9
3. Add Notification: type **Webhook**, POST URL `http://hsb1.lan:9000/hooks/fritz-down`, Body Format **Custom**, body:
   ```json
   {
     "ip": "{{ monitor.hostname }}",
     "monitor": "{{ monitor.name }}",
     "msg": "{{ msg }}"
   }
   ```
   Apply on Down: ON · Apply on Up: OFF.
4. Attach the notification to all 5 monitors.

### Test the wiring

```bash
ssh mba@hsb1.lan "curl -sX POST -H 'Content-Type: application/json' \
  -d '{\"ip\":\"192.168.1.7\",\"monitor\":\"manual-test\",\"msg\":\"test\"}' \
  http://localhost:9000/hooks/fritz-down"
# then check the newest incident dir:
ssh mba@hsb1.lan "ls -t ~/docker/mounts/fritz-tripwire/incidents/ | head -1"
```

### Reading a snapshot

```bash
ssh mba@hsb1.lan "cd ~/docker/mounts/fritz-tripwire/incidents/<dir> && \
  cat meta.json && \
  for f in tcp-*.txt; do echo --- \$f; cat \$f; done && \
  for f in tr064-deviceinfo-*.xml; do echo --- \$f; \
    grep -oE '<New(UpTime|SoftwareVersion)>[^<]*</New[A-Za-z]+>' \$f; done"
```

`NewUpTime` on the victim device tells you whether it self-rebooted (low) or was wedged for a long time without rebooting (high).

### Credentials

TR-064 credentials materialize from agenix at `/run/agenix/hsb1-fritz-tripwire-env` (bind-mounted read-only).

---

## Troubleshooting

### Node-RED Not Accessible

```bash
ssh mba@192.168.1.101
docker ps | grep nodered
docker logs nodered --tail 50
docker restart nodered
```

### FLIRC Receiver (Retired)

- FLIRC receiver was permanently moved off hsb1.
- Node-RED no longer expects `/dev/input/by-id/usb-flirc.tv_flirc-if01-event-kbd`.

### Zigbee Devices Not Responding

1. Check Zigbee2MQTT: `docker logs zigbee2mqtt --tail 50`
2. Check USB device: `lsusb`
3. Restart container: `docker restart zigbee2mqtt`

### MQTT Connection Issues

```bash
ssh mba@192.168.1.101
docker logs mosquitto --tail 50
# Test MQTT locally (requires auth - see SECRETS.md for password)
docker exec mosquitto mosquitto_sub -h localhost -u smarthome -P '<password>' -t '#' -v -C 5
```

### Zigbee Devices Unresponsive in HA (but work in Z2M)

**Symptom:** Devices show "unresponsive" in Apple Home / HA, but work fine in Zigbee2MQTT UI. HA entities show "This entity is no longer being provided by the mqtt integration."

**Root Cause:** Home Assistant lost connection to MQTT broker.

**Diagnosis:**

```bash
# Check if HA can reach MQTT broker
docker exec homeassistant sh -c 'nc -zv localhost 1883'

# Check HA logs for MQTT errors
docker logs homeassistant 2>&1 | grep -iE 'mqtt.*not.*connected|broker'

# Verify Z2M is publishing discovery (should show config messages)
docker exec mosquitto mosquitto_sub -h localhost -u smarthome -P '<password>' \
  -t 'homeassistant/+/+/+/config' -v -C 3
```

**Common Causes:**

1. **Hostname change** — HA MQTT broker configured with old hostname (e.g., `miniserver24` → `hsb1`)
2. **Container restart** — MQTT client failed to reconnect

**Fix:**

1. Go to HA: Settings → Devices & Services → MQTT → Configure
2. Change broker to `localhost` (preferred) or `192.168.1.101`
3. Save — entities should recover automatically

**Prevention:** Always use `localhost` for MQTT broker in HA (not hostnames). Z2M already uses IP (`192.168.1.101`) which is correct.

### Awattar Price Chart Broken ("Strompreis Unknown" / chart stuck "Loading…")

**Symptom:** Dashboard "Awattar" tile (`sensor.current_power_price`) shows `Unknown`; the apexcharts price chart shows "Loading…".

**Root cause:** The `epex_spot` HACS integration (mampfes/ha_epex_spot) **v4** retired the `Price`/`Net Price` sensors. `sensor.epex_spot_data_price` (+ `_net_price`) now report `unavailable` and lose their `data` forecast attribute; the widgets still referenced that dead sensor. (First broke 2026-06-02; the integration itself is fine — `_market_price`/`_total_price` keep updating hourly.)

**Live price sensors (v4)** — both expose `attributes.data` = hourly array `[{start_time, end_time, price_per_kwh}]`:

- `sensor.epex_spot_data_market_price` — raw EPEX spot price
- `sensor.epex_spot_data_total_price` — all-in (spot + grid fees/taxes per config) ← **in use since 2026-06-06**

**Fix (pure repoint, no logic change):**

```bash
cd ~/docker/mounts/homeassistant
ts=$(date +%Y%m%d%H%M%S)
cp configuration.yaml configuration.yaml.bak.$ts
cp .storage/lovelace.dashboard_main .storage/lovelace.dashboard_main.bak.$ts
# 1) template sensor current_power_price
sed -i "s/'sensor\.epex_spot_data_price'/'sensor.epex_spot_data_total_price'/" configuration.yaml
# 2) apexcharts series entity (data_generator keys start_time/price_per_kwh unchanged)
sed -i 's/"sensor\.epex_spot_data_price"/"sensor.epex_spot_data_total_price"/' .storage/lovelace.dashboard_main
# 3) validate
python3 -m json.tool .storage/lovelace.dashboard_main >/dev/null && echo "dashboard JSON ok"
docker exec homeassistant python3 -m homeassistant --script check_config -c /config 2>&1 | grep -iE "error|invalid|fail" || echo "config ok"
# 4) restart (required — dashboard JSON loads only at startup; ~60s)
docker restart homeassistant
```

**Future-proofing:** `watchtower-weekly` + HACS auto-update epex*spot, so a future major version may rename sensors again. If the chart breaks after an update, re-check which `sensor.epex_spot_data*\*`still carries`attributes.data` and repoint.

**Reading live HA state without an API token** (recorder DB, read-only):

```bash
docker exec -i homeassistant python3 - <<'PY'
import sqlite3
c=sqlite3.connect("file:/config/home-assistant_v2.db?mode=ro",uri=True)
for e in ("sensor.current_power_price","sensor.epex_spot_data_total_price"):
    r=c.execute("SELECT s.state FROM states s JOIN states_meta m ON s.metadata_id=m.metadata_id WHERE m.entity_id=? ORDER BY s.last_updated_ts DESC LIMIT 1",(e,)).fetchone()
    print(e, "=", r and r[0])
PY
```

> Large attributes (the `data` forecast array) are excluded from the recorder — use Developer Tools → States to inspect those. Full write-up: PPM NIX knowledge `hsb1-awattar-epex-spot-price`.

### UPS Monitoring

```bash
ssh mba@192.168.1.101 "apcaccess status"
```

---

## 🔴 Critical Known Issues (Gotchas)

### PAM/SSH Lockout (Restic Wrapper Bug)

**Symptom:** SSH access denied for all users, including with correct keys.
**Root Cause:** If `security.wrappers.restic.capabilities` is defined in multiple places (e.g., `common.nix` and `hokage`), the string can become duplicated (e.g., `cap_dac_read_search=+ep,cap_dac_read_search=+ep`).
**Impact:** `setcap` fails, `suid-sgid-wrappers.service` fails, `/run/wrappers/bin/unix_chkpwd` is NOT created. PAM fails to verify passwords/accounts.
**Fix:** Always use `lib.mkForce` for restic capabilities in `modules/common.nix`.
**Verification:** `ls -la /run/wrappers/bin/unix_chkpwd` must exist.

### Kiosk Autologin Failure

**Symptom:** OpenBox/LightDM login screen appears instead of VLC kiosk.
**Cause:** Display manager sometimes starts before user sessions are fully configured after a rebuild.
**Fix:** `sudo systemctl restart display-manager.service`.

---

## Emergency Recovery

### If SSH Fails

1. Physical access to Mac mini required
2. Connect keyboard and monitor
3. Login as `mba` or `root`

### Docker Compose Location

```bash
# Docker compose (Symlink to ~/Code/nixcfg/hosts/hsb1/docker/docker-compose.yml)
~/docker/docker-compose.yml
```

### Restore from Generation

```bash
# List available generations
sudo nix-env --list-generations -p /nix/var/nix/profiles/system

# Switch to specific generation
sudo nix-env --switch-generation N -p /nix/var/nix/profiles/system
sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
```

### Restore from Backup (Restic/Hetzner)

Docker volumes are backed up daily to Hetzner StorageBox via `restic-cron-hetzner` container.

**1. List available snapshots:**

```bash
# On hsb1, enter the restic container
docker exec -it restic-cron-hetzner sh

# List snapshots (inside container)
restic snapshots
```

**2. Restore specific files/directories:**

```bash
# Restore to a temp directory first
restic restore SNAPSHOT_ID --target /tmp/restore --include /data/nodered

# Or restore latest
restic restore latest --target /tmp/restore --include /data/homeassistant
```

**3. Copy restored data to Docker mounts:**

```bash
# Stop the container first
docker stop nodered

# Copy restored data
cp -r /tmp/restore/data/nodered/* ~/docker/mounts/nodered/data/

# Restart container
docker start nodered
```

**Backup repository location:**

- Hetzner StorageBox — SSH key + repo password now via agenix (`/run/agenix/hsb1-restic-ssh-key`, `/run/agenix/hsb1-restic-env`); also in 1Password
- Repository password: `RESTIC_PASSWORD` in `/run/agenix/hsb1-restic-env` (or 1Password)

---

## Maintenance

### Clean Up Disk Space

```bash
ssh mba@192.168.1.101 "cd ~/Code/nixcfg && just cleanup"
```

### Docker Cleanup

```bash
ssh mba@192.168.1.101 "docker system prune -f"
```

### ZFS Scrub (Manual)

```bash
ssh mba@192.168.1.101 "sudo zpool scrub zroot"
```

### View Logs

```bash
# Current boot
ssh mba@192.168.1.101 "journalctl -b -e"

# Follow logs
ssh mba@192.168.1.101 "journalctl -f"
```

---

## Web Interfaces

| Service        | URL                          |
| -------------- | ---------------------------- |
| Home Assistant | <http://192.168.1.101:8123>  |
| Node-RED       | <http://192.168.1.101:1880>  |
| Zigbee2MQTT    | <http://192.168.1.101:8888>  |
| Scrypted       | <http://192.168.1.101:10443> |
| Apprise        | <http://192.168.1.101:8001>  |

---

## Smarthome Stack

### Container Overview

| Container              | Image                                                     | Purpose                      | Port         |
| ---------------------- | --------------------------------------------------------- | ---------------------------- | ------------ | ---------------------------------------------- |
| homeassistant          | `ghcr.io/home-assistant/home-assistant:stable`            | Main automation hub          | 8123 (host)  |
| nodered                | `ghcr.io/markus-barta/node-red-miniserver24:main` ¹       | Automation flows + FLIRC IR  | 1880 (host)  |
| zigbee2mqtt            | `koenkk/zigbee2mqtt:latest`                               | Zigbee device bridge         | 8888         |
| mosquitto              | `eclipse-mosquitto:latest`                                | MQTT broker                  | 1883, 9001   |
| scrypted               | `ghcr.io/koush/scrypted`                                  | Camera/NVR/HomeKit bridge    | 10443 (host) |
| matter-server          | `ghcr.io/home-assistant-libs/python-matter-server:stable` | Matter protocol              | 5580 (host)  |
| health-pixoo           | `ghcr.io/markus-barta/health-pixoo:latest`                | Smart home health on Pixoo64 | host         |
| ~~pixdcon~~            | `ghcr.io/markus-barta/pixdcon:latest`                     | Pixoo display control        | 10829 (host) | **disabled** — commented out in docker-compose |
| apprise                | `caronc/apprise:latest`                                   | Multi-platform notifications | 8001         |
| opus-stream-to-mqtt    | `node:alpine`                                             | OPUS/EnOcean → MQTT bridge   | host         |
| smtp                   | `namshi/smtp`                                             | Mail relay (via Hover)       | bridge       |
| restic-cron-hetzner    | custom build                                              | Daily backups to Hetzner     | -            |
| watchtower-weekly      | `beatkind/watchtower:latest`                              | Weekly updates (Sat 5am)     | -            |
| ~~watchtower-pixdcon~~ | `beatkind/watchtower:latest`                              | Fast pixdcon updates (10s)   | -            | **disabled** — commented out in docker-compose |

### Key Paths

```bash
# Docker compose
~/docker/docker-compose.yml

# Container data mounts
~/docker/mounts/homeassistant/     # HA config
~/docker/mounts/nodered/data/      # Node-RED flows
~/docker/mounts/zigbee2mqtt/       # Z2M config + database
~/docker/mounts/mosquitto/         # MQTT config + data
~/docker/mounts/scrypted/volume/   # Camera configs
~/docker/mounts/pixdcon/data/      # Pixoo scenes/media
~/docker/mounts/matter-server/     # Matter credentials

# Secrets — all materialize from agenix at /run/agenix/hsb1-* on boot.
# ~/secrets and /etc/secrets are EMPTY (all plaintext shredded, NIX-158).
/run/agenix/hsb1-smarthome-env      # Shared HA/NR secrets
/run/agenix/hsb1-zigbee2mqtt-env    # Z2M network key
/run/agenix/hsb1-watchtower-env     # Notification URLs
/run/agenix/hsb1-mqtt-client-env    # MQTT broker/client credentials
/run/agenix/hsb1-tapo-c210-env      # Camera credentials
/run/agenix/hsb1-fritz-tripwire-env # Fritz!Box TR-064 credentials
/run/agenix/hsb1-funkeykid-api-env  # funkeykid API
/run/agenix/hsb1-opusweb-env        # opusweb
```

### Quick Debug Commands

```bash
# All container status
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# Follow specific container logs
docker logs -f homeassistant --tail 100
docker logs -f nodered --tail 100
docker logs -f zigbee2mqtt --tail 100

# Check Zigbee coordinator
docker exec zigbee2mqtt cat /app/data/configuration.yaml | grep -A5 serial

# MQTT test (subscribe to all topics)
docker exec mosquitto mosquitto_sub -h localhost -t '#' -v

# Restart entire stack (declarative — systemd unit, NOT a ~/docker compose)
sudo systemctl restart hsb1-stack

# Restart single container
docker restart homeassistant
docker restart nodered
docker restart zigbee2mqtt

# Check watchtower logs (update history)
docker logs watchtower-weekly --tail 50
```

### Update Schedule

- **watchtower-weekly**: Saturdays 5:00am — updates all containers with `scope=weekly`
- **watchtower-pixdcon**: Every 10 seconds — fast updates for pixdcon only
- **restic-cron-hetzner**: Daily 1:30am — backup to Hetzner StorageBox

### Network Modes

| Mode        | Containers                                                                         |
| ----------- | ---------------------------------------------------------------------------------- |
| **host**    | homeassistant, nodered, scrypted, matter-server, health-pixoo, opus-stream-to-mqtt |
| **bridge**  | zigbee2mqtt, mosquitto, apprise, smtp, restic-cron, watchtowers                    |
| **macvlan** | (available for static IP assignment on 192.168.1.0/24)                             |

### MQTT Broker Configuration

| Service            | Broker Setting  | Notes                                         |
| ------------------ | --------------- | --------------------------------------------- |
| **Home Assistant** | `localhost`     | ⚠️ Never use hostname — use `localhost` or IP |
| **Zigbee2MQTT**    | `192.168.1.101` | Uses IP (correct)                             |
| **Node-RED**       | `localhost`     | Via MQTT nodes                                |

If hostname changes, HA MQTT will break. Always use `localhost`.

> ¹ **Note**: The Node-RED Docker image is still named `node-red-miniserver24` (legacy name). This is the actual image name on GHCR and works correctly.

---

## 🔐 Secrets Inventory

All secrets now materialize from agenix at `/run/agenix/hsb1-*` on boot. `/etc/secrets` and `/home/mba/secrets` are EMPTY — all plaintext was shredded (NIX-158).

| agenix path (`/run/agenix/…`) | Purpose                                                     | Service                        |
| ----------------------------- | ----------------------------------------------------------- | ------------------------------ |
| `hsb1-smarthome-env`          | Main smart home credentials                                 | HA, Node-RED, health-pixoo     |
| `hsb1-zigbee2mqtt-env`        | Z2M MQTT credentials                                        | zigbee2mqtt                    |
| `hsb1-mqtt-client-env`        | MQTT broker/client credentials                              | mosquitto                      |
| `hsb1-watchtower-env`         | Notification URLs                                           | watchtower                     |
| `hsb1-fritz-tripwire-env`     | Fritz!Box credentials                                       | fritz-tripwire                 |
| `hsb1-tapo-c210-env`          | Camera/VLC credentials                                      | scrypted, kiosk babycam        |
| `hsb1-funkeykid-api-env`      | funkeykid API                                               | funkeykid                      |
| `hsb1-opusweb-env`            | opusweb                                                     | opusweb                        |
| `hsb1-pixdcon-env`            | Pixoo display control                                       | pixdcon (container disabled)   |
| `hsb1-tm-smb-env`             | TM Samba passwords (2 lines: `markus <pw>`, `mailina <pw>`) | tm-samba.nix activation script |

---

## Bluetooth Devices

### ACME BK03 Keyboard (Child's Keyboard Fun System)

**Device Details:**

- **Name**: ACME BK03
- **MAC Address**: `20:73:00:04:21:4F`
- **Type**: Human Interface Device (HID) - Keyboard
- **Class**: 0x00002540 (keyboard)
- **Modalias**: usb:v04E8p7021d0001

**Pairing Instructions:**

1. **Put keyboard in pairing mode:**
   - Turn on the keyboard (slide power switch to ON)
   - Press and hold **ESC + K** for 3 seconds
   - Red LED indicator will start blinking (pairing mode active for ~60 seconds)

2. **Pair with hsb1:**

```bash
ssh mba@hsb1.lan

# Start scanning (look for "ACME BK03" or MAC 20:73:00:04:21:4F)
bluetoothctl scan on

# In another terminal or after seeing the device:
bluetoothctl pair 20:73:00:04:21:4F
bluetoothctl trust 20:73:00:04:21:4F
bluetoothctl connect 20:73:00:04:21:4F
```

3. **Verify connection:**

```bash
# Check Bluetooth status
bluetoothctl info 20:73:00:04:21:4F

# Find input device path
cat /proc/bus/input/devices | grep -A 10 'ACME'
# Look for: H: Handlers=... eventXX

# The device will appear as /dev/input/eventXX (e.g., event17)
```

4. **Unpair/Remove:**

```bash
bluetoothctl remove 20:73:00:04:21:4F
```

**Notes:**

- Pairing mode times out after ~60 seconds - be quick!
- Device will appear as `/dev/input/eventXX` when connected
- Used for the funkeykid system (see P8000 task)
- Bluetooth keyboards don't appear in `/dev/input/by-id/` - use `/proc/bus/input/devices` to identify

---

## OpenClaw AI Assistant (Merlin) -- MIGRATED

Merlin migrated to **hsb0** (Docker) on 2026-02-14. All config, secrets, and packages removed from hsb1.

- **New location**: hsb0 Docker container `openclaw-merlin`
- **Runbook**: See [hsb0 RUNBOOK](../../hsb0/docs/RUNBOOK.md#-merlin-openclaw-ai-assistant)
- **Migration tracking**: moved to PPM (`pm.barta.cm`)

> **On-host state** (`~/.openclaw/`) kept as backup. Safe to delete after 2026-03-14.

---

## Merlin SSH Access (from hsb0)

Merlin (openclaw-gateway on hsb0) has SSH access to this host as the `merlin` user for direct HA/Node-RED management.

| Property | Value                                                                |
| -------- | -------------------------------------------------------------------- |
| User     | `merlin` (uid=1002)                                                  |
| Groups   | `wheel` (passwordless sudo) + `docker`                               |
| Auth     | SSH key only (`hsb0-merlin-ssh-key.age`)                             |
| Revoke   | Remove `users.users.merlin` block from `configuration.nix` + rebuild |

**⚠️ Important:** `/home/mba` is `0700` — Merlin must use `sudo` for any path under it:

```bash
# From openclaw-gateway container on hsb0:
docker exec openclaw-gateway ssh hsb1.lan "sudo docker restart homeassistant"
docker exec openclaw-gateway ssh hsb1.lan "sudo nano /home/mba/docker/mounts/homeassistant/configuration.yaml"
```

See full operational details: [OPENCLAW-RUNBOOK.md](../../hsb0/docs/OPENCLAW-RUNBOOK.md#merlin-ssh-access-to-hsb1)

---

## Related Documentation

- [SMARTHOME.md](./SMARTHOME.md#🏆-naming--ux-best-practices) - UX and Naming Best Practices (HomeKit/Z2M)
- [hsb1 README](../README.md) - Full server documentation
- [hsb0 Runbook](../../hsb0/docs/RUNBOOK.md) - DNS/DHCP server (dependency)
- [SECRETS.md](../secrets/SECRETS.md) - All service credentials (gitignored)
