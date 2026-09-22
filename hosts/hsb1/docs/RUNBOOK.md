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

## Tailnet Witness (tailnet-watch, OPS-185)

`tailnet-watch.timer` runs every ten minutes and reads **this host's** view of
the mesh: `tailscale status --json` (must parse, `BackendState` = `Running`,
every `.Health` entry is a problem) and `tailscale debug derp-map` (zero regions
= the 2026-08-21 empty-DERP-map outage). Second witness next to csb1's: hsb1 sits
at home on a different provider, so it can still page while netcup is dark.
Shared OPS-107 engine (two consecutive runs before paging, recovery clears);
Telegram target from agenix `hsb1-tailnet-watch-env` (`WATCHTOWER_NOTIFICATION_URL`,
same channel as csb1). Edit the secret with `agenix -e secrets/hsb1-tailnet-watch-env.age`.

```bash
systemctl status tailnet-watch.timer --no-pager
sudo systemctl start tailnet-watch.service
journalctl -u tailnet-watch.service --since "1 hour ago" --no-pager
```

## Residue mail monitor (OPS-196)

`mailbridge-watch.timer` runs every five minutes. It refreshes Gmail access in
memory, checks the bridge container and recent import-error counts, and uses
IMAP STATUS for every configured source and Failed folder. It never fetches
message bodies or moves/deletes mail. Counts, fixed error categories and
timestamps are stored root-only in `/var/lib/mailbridge-watch/status.json`.
An absent/unreadable configured folder is unknown, not an empty queue.

The shared fleet-alerts engine confirms faults twice, retries failed delivery,
deduplicates alerts and reports recovery through the existing Telegram target.
A queue that has not observably decreased for two hours is actionable; this
allows for upstream's batch-end deletion. `tailnet-watch` independently checks
the snapshot age (15-minute limit), completeness and notification failures
under distinct incident keys, so an existing fault cannot mask a later outage.
Both witnesses still depend on this host and their existing alert channel;
a total host/channel outage needs the fleet's external monitoring.

`GRANT_ISSUED_AT` in `mailbridge-watch.nix` must be the actual issuance time of
the replacement grant after verified Google Production publication. Until
recorded, the monitor reports unverified publication. After eight days, a
healthy check with empty source/Failed queues records the first
`day8_verified_at`; later failures keep that evidence and clear `day8_check_ok`.
That proves continuing authorization and empty observed queues, not that a
particular message exists in Gmail; initial recovery requires live delivery
and backlog-drain evidence in OPS-196. No recurring Console check is needed.

For genuine provider revocation, the operator runs
`python3 scripts/mailbridge-consent.py /path/to/private/turbogmailify.toml`
with Python 3.11+ on their workstation. The existing config and its containing
directory must be owner-only. The helper prints a local URL to open in the
existing Helium window on the MacBook display; it does not launch a browser.
Choose the existing target Gmail account and complete the attended consent.
The loopback callback uses state and PKCE, requests only `gmail.insert`, and
saves the fresh offline grant atomically with a private rollback copy. It
prints only the issuance timestamp; never paste credentials or callback URLs
into an agent session. It refuses other Google projects or a changed config.

Encryption remains human-only: use the canonical OPS onboarding runbook's
agenix step, then review/merge the encrypted change and issuance timestamp.
Switch hsb1 before recreating the bridge so its file bind sees the new agenix
inode. Validate real Gmail delivery and the source/Failed counts before an
idle restart test. The helper itself neither encrypts nor deploys or moves mail.

```bash
systemctl status mailbridge-watch.timer --no-pager
journalctl -u mailbridge-watch.service --since '1 hour ago' --no-pager
sudo cat /var/lib/mailbridge-watch/status.json  # aggregate health only
```

The pinned bridge image's provenance points to upstream
`a34610a9e881c2b4388a04d8d987f6bc7fe330f8`. It queues successful UIDs only after
a Gmail import returns HTTP 200, then deletes at the end of the folder pass.
An interrupted pass can duplicate accepted mail; restart only when idle after
the queue drains. Its EXPUNGE is mailbox-wide for already-deleted messages:
concurrent clients marking mail deleted are outside a no-loss guarantee.
Import-attempt logs alone are not success evidence. Keep Hover forwarding.
Production removes Google's fixed Testing expiry, not revocation after account
security changes. Follow the canonical OPS onboarding runbook for attended
consent/encryption after a real revocation; do not schedule re-consent/restarts.

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

### Tesla Fleet / Model X integration (diagnostics)

- **Integration**: `tesla_fleet` (official Tesla Fleet API). Setup/migration playbook → **PPM NIX-206**.
- **Vehicles**: Tesla **Model X** + Model Y (one shared Fleet app on `ev.barta.cm`).
- **Private key**: `~/docker/mounts/homeassistant/tesla_fleet.key` (mode 600).

Fast "is it alive?" check — all read-only; never dump `core.config_entries` raw (it holds OAuth tokens):

```bash
# Integration present? (project domain/title only)
ssh mba@hsb1.lan 'docker exec homeassistant python3 -c "
import json;d=json.load(open(\"/config/.storage/core.config_entries\"))
[print(e[\"domain\"],\"|\",e.get(\"title\")) for e in d[\"data\"][\"entries\"] if e[\"domain\"]==\"tesla_fleet\"]"'

# Which vehicles are registered? (device registry — no secrets)
ssh mba@hsb1.lan 'docker exec homeassistant python3 -c "
import json;d=json.load(open(\"/config/.storage/core.device_registry\"))
[print(x.get(\"manufacturer\"),\"|\",x.get(\"model\")) for x in d[\"data\"][\"devices\"] if (x.get(\"manufacturer\") or \"\").lower()==\"tesla\"]"'

# Recent integration errors
ssh mba@hsb1.lan "docker logs homeassistant 2>&1 | grep -i tesla_fleet | tail -20"
```

**Benign noise:** intermittent `tesla_fleet … Cannot connect to host fleet-api.prd.eu.vn.cloud.tesla.com … [Timeout while contacting DNS servers]` = transient DNS/network blip on the EU vehicle-data endpoint. **NOT** an auth failure — no action unless continuous. Setup/auth failures look different: OAuth `400` / `invalid_grant` / `invalid_client` (see NIX-206).

---

## 📂 File Management

hsb1 is **declarative** — configuration is driven by `nixos-rebuild switch` from `~/Code/nixcfg` (this repo), not a "symlink everything to the repo" layer. The moving parts:

| What                   | How it's managed                                                                                                                                                     |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Docker stack           | `hosts/hsb1/docker/compose-spec.nix` → `/etc/compose/hsb1/docker-compose.yml` (nix-store symlink), reconciled by `compose-hsb1.service`                              |
| Kiosk babycam launcher | Home Manager declares `hosts/hsb1/files/kiosk-autostart.sh`; `/home/kiosk/.config/openbox/autostart` is a live nix-store symlink used by `babycam-watchdog` recovery |
| Secrets                | agenix → `/run/agenix/hsb1-*` (no plaintext in the repository or home-directory configuration)                                                                       |
| System / services      | NixOS modules in `hosts/hsb1/` plus shared `modules/`                                                                                                                |

### Legacy home-directory decision (NIX-134)

The 2026-09-01 read-only audit found both `/home/mba/docker` and `/home/mba/scripts` as ordinary directories, not managed symlinks. They are retained; deleting either as part of a documentation correction would be unsafe.

- `/home/mba/docker` remains the runtime-data root. The declarative spec still bind-mounts data under `~/docker/mounts/`; selected relative build contexts resolve from `~/Code/nixcfg/hosts/hsb1/docker`. Its top level also retains a legacy `Makefile`, `restic-cron/`, and `smtp/`. The Makefile invokes Compose from the wrong directory even though `~/docker/docker-compose.yml` no longer exists: do not run it. NIX-407 owns the file-by-file inventory and recoverable quarantine/removal decision for both retained home trees; until then they stay in place.
- `/home/mba/scripts` is retained as unclassified legacy material. No current NixOS unit references that top-level directory; NIX-407 inventories it before anything is moved or deleted.
- The old `/home/kiosk/scripts` path is absent. The autostart path is present as a Home Manager nix-store symlink; the initial unprivileged probe reported it absent only because `/home/kiosk` is mode `0700`. Verify kiosk-owned paths with read-only `sudo` rather than treating `Permission denied` as absence.

**Golden rule:** author configuration in `~/Code/nixcfg`, merge it, update the checkout, and run the reviewed `just switch` path. Never hand-edit the rendered `/etc/compose` file or operate a compose stack from `~/docker`.

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

This deliberately interrupts all 17 services. Use the closure-pinned compose file and the repository directory only to resolve retained relative paths; never run Compose from `~/docker`:

```bash
ssh mba@hsb1.lan \
  "sudo docker compose -p docker -f /etc/compose/hsb1/docker-compose.yml \
  --project-directory /home/mba/Code/nixcfg/hosts/hsb1/docker restart"
```

To converge the declarative specification without restarting healthy unchanged containers, use `sudo systemctl restart compose-hsb1.service`. That unit runs `up -d --remove-orphans` and force-recreates only `hsb1-home` after the main reconcile.

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

Plex reads it read-only (`compose-spec.nix` plex service,
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

Two datasets, `tm/markus` and `tm/mailina`, each with **two caps** (OPS-226,
after "Das Backup-Volume ist voll" on 2026-09-22):

| dataset      | refquota (= TM's cap, mirrored by Samba `max size`) | quota (hard, incl. snapshots) |
| ------------ | --------------------------------------------------- | ----------------------------- |
| `tm/markus`  | 2253G (Samba `2200G`)                               | 3277G                         |
| `tm/mailina` | 1434G (Samba `1400G`)                               | 2048G                         |

All numbers live in `hosts/hsb1/tm-caps.nix`; `tm-pool.nix` asserts at eval
time that Samba's cap sits ≥ 32G under the refquota. Time Machine only ever
sees the Samba cap, so it thins its own old backups before ZFS can refuse a
write (it fills that space by design — `referenced ≈ refquota` is normal).
The refquota→quota gap is the budget for sanoid's 7 daily snapshots of the
churning sparsebundle — and because TM deleting a backup does **not** free
blocks a snapshot still holds, `tm-watch` prunes the oldest `autosnap_*`
snapshots itself when the headroom under quota drops below 100G (keeping the
newest). That is the layer that keeps "Backup-Volume ist voll" away; the caps
alone cannot. Both ZFS caps are **imperative**, not disko-declared — changing
a number in `tm-caps.nix` requires the matching live command:

```bash
ssh mba@192.168.1.101 "sudo zfs set refquota=2253G quota=3277G tm/markus && sudo zfs set refquota=1434G quota=2048G tm/mailina"
```

`tm-watch.timer` (30 min, Telegram) pages when the live caps differ from
`tm-caps.nix`, snapshots eat half the budget, it had to prune on two
consecutive runs, headroom stays under 100G with nothing left to prune, the
pool passes 85 %, smbd has no process, or a Mac's last **completed** backup
(from `com.apple.TimeMachine.SnapshotHistory.plist` inside its bundle) is older
than 5 days.

**Changing caps / deploying a cap change** — order matters, or TM sees more
space than ZFS grants: (1) record `zfs get referenced,refquota,quota,usedbysnapshots`
for both datasets; (2) switch hsb1 (Samba restarts; TM re-reads the volume
size on its next connection); (3) run the `zfs set` above; (4) `journalctl -u
tm-watch -n 3` → `ok — 0 active problem(s)`; (5) both Macs complete a backup.

**"Backup-Volume ist voll" anyway?** `zfs get -p referenced,refquota,quota,usedbysnapshots tm/<user>` and `journalctl -u tm-watch -n 20` (it says what it pruned and why it could not). If `referenced + usedbysnapshots ≈ quota`, raise `quota` (`sudo zfs set quota=<bigger> tm/<user>`, pool free permitting, then tm-caps.nix). If `referenced ≈ refquota` and TM still complains, TM failed to thin (usually one backup left that is bigger than the cap) — raise refquota **and** `maxSizeG` in tm-caps.nix together, switch, `zfs set`.

Samba (`tm-samba.nix`) exposes each dataset as its own share
(`tm-markus`, `tm-mailina`) via `vfs_fruit`, discoverable natively in each
Mac's System Settings → Time Machine (Avahi mDNS, no manual `smb://` entry
needed). Credentials: `hsb1-tm-smb-env` (see Secrets Inventory below).

```bash
# Pool + cap health
ssh mba@192.168.1.101 "zpool status tm"
ssh mba@192.168.1.101 "zfs get -o name,property,value referenced,refquota,quota,usedbysnapshots,available tm/markus tm/mailina"
ssh mba@192.168.1.101 "systemctl list-timers tm-watch.timer; journalctl -u tm-watch -n 3"

# Snapshot retention (sanoid — daily, 7-day)
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

### FLIRC / IR bridge (remote dead)

The FLIRC is back on hsb1 (since 2026-06-05); `ir-bridge.service` drives the Sony TV + HA (`hosts/hsb1/ir-bridge.nix`). `ir-bridge-watch.timer` (OPS-223) pages Telegram when the FLIRC node is missing, the unit is down, or the TV's Sony API answers 404/5xx.

1. **Bridge active but deaf** — `ls /dev/input/by-id/ | grep flirc` empty and the journal repeats `FLIRC … unavailable — retrying in 30s`: the stick failed USB enumeration (`journalctl -k | grep 'usb 1-2.1.4'` shows `error -62` / `-110`, OPS-222). Replug it; the bridge reopens it within 30 s, no restart needed.
2. **Keys logged but `IRCC … failed: HTTP 404`** — the TV's REST API is down while the TV is otherwise reachable (2026-09-21, ~69 days TV uptime). Restart the TV (hold power on the remote → Restart, or mains). Verify: `curl -s -H 'Content-Type: application/json' -d '{"method":"getPowerStatus","id":50,"params":[],"version":"1.0"}' http://192.168.1.137/sony/system` → `{"result":[{"status":"active"}],…}`; `{"error":[404,…]}` means still down.
3. **`IRCC <key> failed: HTTP 500`** — that key's code is wrong for this TV. Codes come from the TV's own `system.getRemoteControllerInfo` table (OPS-225); never from a generic list.

Full design + button map: PPM Knowledge `ir-sony-tv-bridge-hsb1` (NIX).

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

**Future-proofing:** HACS can update epex*spot, so a future major version may rename sensors again. If the chart breaks after an update, re-check which `sensor.epex_spot_data*`still carries`attributes.data` and repoint.

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
# Declarative source (edit here, through the normal PR path)
~/Code/nixcfg/hosts/hsb1/docker/compose-spec.nix

# Rendered runtime spec (read-only nix-store symlink; never hand-edit)
/etc/compose/hsb1/docker-compose.yml
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

| Service             | Purpose                                                |
| ------------------- | ------------------------------------------------------ |
| apprise             | Notification service                                   |
| fritz-tripwire      | Fritz!Box anomaly witness                              |
| funkeykid           | Educational keyboard service                           |
| homeassistant       | Main automation hub                                    |
| hsb1-home           | HostDash static dashboard                              |
| matter-server       | Matter protocol                                        |
| mosquitto           | MQTT broker                                            |
| nodered             | Automation flows and FLIRC IR                          |
| opus-stream-to-mqtt | OPUS/EnOcean to MQTT bridge                            |
| opusweb             | OPUS web application                                   |
| pharos-beacon       | Fleet observation reporter                             |
| pixdcon             | Pixoo display control                                  |
| plex                | Media server                                           |
| restic-cron-hetzner | Daily backups to Hetzner                               |
| scrypted            | Camera/NVR/HomeKit bridge                              |
| smtp                | Mail relay                                             |
| turbogmailify       | Residue mail bridge: Hover INBOX → Gmail API (OPS-196) |
| zigbee2mqtt         | Zigbee device bridge                                   |

### Key Paths

```bash
# Declarative compose source and rendered runtime spec
~/Code/nixcfg/hosts/hsb1/docker/compose-spec.nix
/etc/compose/hsb1/docker-compose.yml

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

# Reconcile the declarative stack; unchanged containers stay running
sudo systemctl restart compose-hsb1.service

# Deliberately restart all 17 services from the closure-pinned specification
sudo docker compose -p docker -f /etc/compose/hsb1/docker-compose.yml \
  --project-directory /home/mba/Code/nixcfg/hosts/hsb1/docker restart

# Restart single container
docker restart homeassistant
docker restart nodered
docker restart zigbee2mqtt

# Check the declarative weekly updater
systemctl status compose-hsb1-update.service
journalctl -u compose-hsb1-update.service --since today
```

### Update Schedule

- **compose-hsb1-update.timer**: Saturdays at 05:00 with up to 15 minutes of jitter; pulls eligible images and reconciles the same declarative spec
- **restic-cron-hetzner**: Daily 1:30am — backup to Hetzner StorageBox

### Network Modes

| Mode       | Containers                                                                                                    |
| ---------- | ------------------------------------------------------------------------------------------------------------- |
| **host**   | funkeykid, homeassistant, matter-server, nodered, opus-stream-to-mqtt, pharos-beacon, pixdcon, plex, scrypted |
| **bridge** | apprise, fritz-tripwire, hsb1-home, mosquitto, opusweb, restic-cron-hetzner, smtp, zigbee2mqtt                |

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
| `hsb1-smarthome-env`          | Main smart home credentials                                 | HA, Node-RED, funkeykid        |
| `hsb1-zigbee2mqtt-env`        | Z2M MQTT credentials                                        | zigbee2mqtt                    |
| `hsb1-mqtt-client-env`        | MQTT broker/client credentials                              | mosquitto                      |
| `hsb1-fritz-tripwire-env`     | Fritz!Box credentials                                       | fritz-tripwire                 |
| `hsb1-tapo-c210-env`          | Camera/VLC credentials                                      | scrypted, kiosk babycam        |
| `hsb1-funkeykid-api-env`      | funkeykid API                                               | funkeykid                      |
| `hsb1-opusweb-env`            | opusweb                                                     | opusweb                        |
| `hsb1-pixdcon-env`            | Pixoo display control                                       | pixdcon                        |
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
