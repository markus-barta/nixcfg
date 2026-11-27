# hsb9 - Parents-in-law Home Automation Server

**Mac mini "Late 2009"** (Macmini3,1, Intel Core 2 Duo P7550) running NixOS for light home automation at parents-in-law.

---

## Quick Reference

| Item                 | Value                                                                                                                      |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| **Hostname**         | `hsb9`                                                                                                                     |
| **Model**            | Mac mini "Late 2009" (Macmini3,1)                                                                                          |
| **CPU**              | Intel Core 2 Duo P7550 @ 2.26 GHz (2 cores)                                                                                |
| **RAM**              | 4 GB DDR3                                                                                                                  |
| **Storage**          | Crucial CT250MX200SSD1 — 250 GB SATA SSD (ext4)                                                                            |
| **Static IP**        | `192.168.1.200` (live at parents-in-law since 2026-05-31)                                                                  |
| **Prior IP (jhw22)** | `192.168.1.203` (Markus' home migration-prep — retired)                                                                    |
| **MAC**              | _(not committed — `ip link show enp0s10` on host)_                                                                         |
| **NIC**              | NVIDIA MCP79 onboard (`enp0s10`, `forcedeth` driver)                                                                       |
| **SSH**              | `ssh mba@192.168.1.200` on-site, or by tailnet IP (`tailscale status`) — MagicDNS is off, `*.ts.barta.cm` does not resolve |
| **HostDash**         | `http://hsb9.lan/` or `http://192.168.1.200/`                                                                              |
| **Location**         | parents-in-law (live since 2026-05-31; was jhw22 migration-prep)                                                           |
| **PPM**              | NIX-138                                                                                                                    |

---

## Scope

Lighter than hsb8. Just home automation, no DNS/DHCP for the host network:

- MQTT broker (mosquitto)
- Zigbee2MQTT (SONOFF Zigbee 3.0 USB dongle migrated from existing Pi 3 setup)
- Home Assistant (Docker)
- HostDash (`hsb9-home` nginx container on port 80)
- Fernsehaufnahmen (`hsb9-media`, reached through the same nginx)
- HomeKit bridge
- A handful of light automations

---

## NIX-138 — Install-day notes

- Kernel pinned to **6.18** (matches msbp's stable Mac mini 2009 config).
  Default 6.12.63 had a forcedeth regression on this hardware.
- **DHCP is OFF, static IP is required**: `dhcpcd`'s broadcast-before-link-up
  wedges forcedeth's TX queue on this NIC. Static configuration sidesteps
  it. See NIX-138 comment thread for root cause.
- `b43` (WiFi) blacklisted — no firmware, we're wired-only.
- `forcedeth debug_tx_timeout=1` enabled for future diagnostic insurance.

---

## Location switch

Edit `configuration.nix`:

```nix
location = "parents-in-law"; # was "jhw22"
```

Then deploy. Gateway at parents-in-law is confirmed `192.168.1.1` (Fritz!Box);
DNS via Cloudflare (`1.1.1.1` / `1.0.0.1`). Live at `192.168.1.200` since
2026-05-31 (NIX-138).

## Fernsehaufnahmen (OPS-729)

Open `http://hsb9.lan/fernsehen/` on the home network (or use the host's
tailnet address with the same path). The German interface lists recordings,
plays them, edits their title and description, uploads videos with progress,
and moves individual recordings to a recoverable Papierkorb. It uses no
external assets or services. Compatible browser playback requires a suitable
codec, normally H.264 video and AAC audio; renaming a file does not convert it.
The HostDash tile is managed in its own repository.

The Python app has no published port. `hsb9-home` retains port 80 and the
complete HostDash document root, including `/config.js`, `/manifest.json` and
`/status/status.json`. nginx proxies `/fernsehen/` and directly serves only
flat `.mp4`, `.m4v` and `.mov` files under `/fernsehen/video/`, including HTTP
Range requests for seeking. Metadata, hidden files, trash and symlinks are not
served. Uploads stream to disk with request buffering disabled; neither Python
nor nginx buffers a whole recording. The app accepts raw PUT bodies with
Content-Length, as sent by the browser, rather than chunked transfer encoding.
The browser checks space before sending and shows space available for uploads
as “Noch frei”. During uploads it requests a screen wake lock where supported;
leave the page open and the device awake if the browser cannot grant it.
If the app is offline, nginx serves a small German retry page itself.

Uploads leave a reserve of `max(20 GiB, 10% of the data filesystem's total
capacity)`. The app checks unprivileged free space before creating a temporary
file and before each 1 MiB chunk; insufficient space or ENOSPC returns HTTP 507
and removes the temporary file. Each refusal logs one line without a filename.
`GET /fernsehen/api/videos` returns `videos`, `free_bytes` (filesystem free
space) and `reserve_bytes`; the UI displays their non-negative difference.
An administrator can override the reserve with the app environment variable
`MEDIA_RESERVE_BYTES`, a non-negative integer byte count. Compose uses the
default. Invalid overrides refuse startup. Check actual free space before
deployment; trash remains on the same filesystem and does not free space.

**Access boundary:** this deliberately has no login. The existing compose
binding is `80:80` on all host interfaces, and the existing NixOS firewall
allows TCP 80 without an interface restriction. This change adds no port or
firewall rule. LAN/tailnet-only reachability therefore depends on the upstream
router and tailnet policy; the host firewall itself does not enforce it.
No router forwarding or live firewall state was checked as part of this build.

### Files and metadata

Data lives at `/srv/media/fernsehaufnahmen`, with `.trash` beneath it. The app
always uses the container mount `/data` as its data root. tmpfiles
creates both directories as `0750`, UID `10429`, GID `101`. The app runs as
`10429:101`; GID 101 also lets nginx's worker read recordings through its
read-only data mount. Uploaded videos and metadata are `0640`. No setuid or
setgid bits are used. Code and nginx configuration come from read-only `/etc`
mounts, with generation changes forcing container recreation at switch.
The recordings are **not** a restic source; originals remain elsewhere.

`metadata.json` is one UTF-8 JSON object keyed by the exact video filename,
including its extension. Example with neutral data:

```json
{
  "Beispielaufnahme 1.mp4": {
    "title": "Beispielaufnahme 1",
    "description": "Eine kurze Beispielbeschreibung.",
    "channel": "Beispielsender",
    "recorded": "2026-01-02",
    "duration_min": 45,
    "added": "2026-01-03T12:00:00Z"
  }
}
```

Each entry may omit fields: title defaults to the filename stem with underscores
replaced by spaces, description/channel/recorded to empty strings,
duration_min to null, and added to the file's modification time in UTC.
`title` is text up to 200 characters, `description` up to 4000, and `channel`
up to 120. `recorded` is `YYYY-MM-DD` or `""`; `duration_min` is null or a
finite number from 0 to 100000. `added`, when supplied, is an ISO timestamp
with a timezone, preferably UTC as above. Unknown fields and invalid metadata
are rejected without replacing the existing file.

The single app process locks complete read/modify/write operations and writes
metadata using a same-directory temporary file, file fsync, atomic rename and
directory fsync. Stop `hsb9-media` before administratively seeding or replacing
metadata, then start it again; an external editor does not share its lock.
Metadata entries survive trashing, restoration and administrative file purges.
Do not add private recording information to this public repository.

### Add, restore and purge over SSH

Browser uploads accept `.mp4`, `.m4v` and `.mov`. Storage names are normalised
to Unicode NFC, repeated dots collapse, leading dots and surrounding spaces
are stripped, and stems are cut to fit 180 UTF-8 bytes. An empty stem becomes
a UUID. Slashes, backslashes and control characters are still rejected. The
original stem becomes the initial title (up to 200 characters). Other API
paths keep strict filename validation. Duplicate names, including NFC/NFD
equivalents, receive a unique filename and never replace an active or trashed
recording or a retained metadata name.
Interrupted transfers remove their own temporary file. On startup the app
removes stale regular `.upload-*` and `.metadata-*` files in the data root,
without following symlinks. These prefixes belong exclusively to the app;
administrative staging must use `.staging-*`. Compose uses an init process
for shutdown and child reaping. Only one app process may write this directory.

To add a prepared video over SSH, first upload it to the operator's staging
directory, then install it into the library (commands run on the host):

```sh
sudo install -o 10429 -g 101 -m 0640 -T -- /tmp/Beispielaufnahme-1.mp4 \
  /srv/media/fernsehaufnahmen/.staging-admin-1
sudo mv -n -- /srv/media/fernsehaufnahmen/.staging-admin-1 \
  /srv/media/fernsehaufnahmen/Beispielaufnahme-1.mp4
```

Choose a new destination name and check that it is absent from both the active
directory, `.trash` and metadata before installing. Choose a fresh hidden
staging name too: `install` can overwrite that staging destination. `mv -n`
publishes only the completed copy and refuses to overwrite an existing video.
A file without metadata appears immediately with its default title.
Seed optional channel/date/duration metadata while the app is stopped.

“Löschen” moves a recording to `.trash/<filename>`, retaining its metadata.
In Papierkorb, “Wiederherstellen” moves it back; a name conflict refuses the
operation. An administrator can also restore using `sudo mv -n --` from
`.trash/<filename>` to the active directory after checking the destination.
The UI has no permanent delete. Permanent purging is an explicit administrator
task over SSH: stop the app, inspect the selected trash file, then use the
operator's approved trash tool on that exact path. Removing its metadata entry
is optional and must preserve the rest of `metadata.json`; restart afterwards.

### Local validation and container smoke test

Use Python 3.13 or newer and Node.js for the app/UI tests. T127 uses a local
nginx binary or obtains it with `nix-shell -p nginx`, then runs a real
`nginx -t` against `docker/home.conf` with an isolated temporary wrapper.

```sh
(cd hosts/hsb9/docker/media && python3 -B -m unittest -v)
./tests/T127-hsb9-media.sh
nix shell nixpkgs#yq-go -c ./tests/compose_stack_gate.py hsb9
```

For a local Colima/Docker smoke test, run from the repository root. The data
volume is disposable synthetic test data; the production directory is not used.
The runtime below uses the same UID/GID, immutable root, dropped capabilities,
no-new-privileges, tmpfs and resource limits as compose:

```sh
docker volume create ops729-media-smoke
docker run --rm -v ops729-media-smoke:/data python:3.13-alpine3.23 \
  sh -c 'mkdir -p /data/.trash && chown 10429:101 /data /data/.trash && chmod 0750 /data /data/.trash'
docker run -d --init --name ops729-media-smoke --restart unless-stopped \
  --user 10429:101 --read-only --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=32m,mode=1777 \
  --pids-limit 64 --memory 256m --cpus 1.0 \
  --label com.centurylinklabs.watchtower.enable=true \
  --label com.centurylinklabs.watchtower.scope=weekly \
  -p 127.0.0.1:18080:8080 \
  -v "$PWD/hosts/hsb9/docker/media:/app:ro" \
  -v ops729-media-smoke:/data:rw \
  python:3.13-alpine3.23 python3 -B /app/app.py
curl -f http://127.0.0.1:18080/fernsehen/healthz
```

Use `http://127.0.0.1:18080/fernsehen/` to test upload, edit, trash and restore.
Direct app access cannot play videos: playback is intentionally served by
nginx. For the complete path, put an `nginx:alpine` container on the same test
network as the app, give the app the network alias `hsb9-media`, mount
`docker/home.conf` at `/etc/nginx/conf.d/default.conf:ro`, the same test volume
at `/data:ro`, and a HostDash output at `/usr/share/nginx/html:ro`. Publish only
that nginx on `127.0.0.1:18081:80`. Confirm the start page and its assets, upload
a neutral compatible video, play and seek in Safari/macOS and iPad, then test
edit → trash → restore. Check `curl -I -H 'Range: bytes=0-31'` against its video
URL returns 206 and Content-Range. Requests for `metadata.json`, `.trash/` and
non-video files under `/fernsehen/video/` must fail. The coordinator owns browser
QA, remote NixOS builds, review gates and the later `just switch` deployment.
