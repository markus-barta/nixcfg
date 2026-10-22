# Runbook: csb0 (Smart Home Hub)

**Host**: csb0 (cs0.barta.cm / 89.58.63.96)  
**Role**: Smart Home Hub & IoT Automation Platform  
**Criticality**: HIGH - Smart home + backup manager for BOTH csb0 and csb1  
**Provider**: Netcup VPS (New Server 2026-01-10)

---

## Quick Connect

```bash
# Via alias
qc0

# Direct SSH
ssh mba@cs0.barta.cm -p 2222

# With IP
ssh mba@89.58.63.96 -p 2222
```

---

## Quick Reference Card

```
╔════════════════════════════════════════════════════════════╗
║ 🌀 csb0 - Smart Home Hub Emergency Reference               ║
╠════════════════════════════════════════════════════════════╣
║ SSH:       ssh mba@cs0.barta.cm -p 2222                    ║
║ IP:        89.58.63.96                                     ║
║ Netcup:    Customer # in 1Password (2FA)                   ║
║ VNC:       servercontrolpanel.de/SCP                       ║
╠════════════════════════════════════════════════════════════╣
║ 🌐 SERVICES                                                ║
║ • Node-RED:    https://home.barta.cm                       ║
║ • Bitwarden:   https://bitwarden.barta.cm (TEST ONLY)      ║
║ • Headscale:   https://hs.barta.cm (VPN control)           ║
║ • MQTT:        mosquitto.barta.cm:8883 (TLS)               ║
║ • Telegram:    t.me/csb0bot                                ║
╠════════════════════════════════════════════════════════════╣
║ ⚠️ CRITICAL SERVICES                                       ║
║ • Node-RED → Garage door control for family/neighbors!     ║
║ • Telegram bot → Smart home notifications & control        ║
║ • Backup cleanup → Manages BOTH csb0 and csb1!             ║
╠════════════════════════════════════════════════════════════╣
║ 🚨 IF DOWN                                                 ║
║ 1. SSH check: ssh mba@cs0.barta.cm -p 2222                 ║
║ 2. VNC console via Netcup SCP (if SSH fails)               ║
║ 3. Restore from backup (< 2h)                              ║
╚════════════════════════════════════════════════════════════╝
```

---

## Health Checks

### Quick Status

```bash
# One-liner: container count, disk usage, load
ssh mba@cs0.barta.cm -p 2222 "docker ps | wc -l && df -h / | tail -1 && uptime"
# Expected: 10 containers, <20% disk, load <1.0

# Check container health
ssh mba@cs0.barta.cm -p 2222 "docker ps --filter 'status=exited'"
# Should be empty (all running)

# Check services responding
curl -I https://home.barta.cm  # Node-RED (expect 200)
curl -I https://bitwarden.barta.cm  # Bitwarden (expect 200)
```

---

## Common Tasks

### Update & Switch Configuration

```bash
# Local
just build-host csb0
git push

# Remote
ssh mba@cs0.barta.cm -p 2222
cd ~/Code/nixcfg
git pull
just switch
```

### Docker Management

```bash
cd ~/Code/nixcfg/hosts/csb0/docker
docker-upf  # Custom fish abbreviation for force-recreate
```

---

## 🏗️ Uzumaki & Hokage Pattern

`csb0` is an **External Hokage Consumer**. It consumes the base server configuration from the global `hokage` module but applies local customizations via the `uzumaki` namespace.

- **Status**: Enabled (`uzumaki.enable = true`)
- **Role**: `server`
- **Indicator**: The `nixbit` command should be available and working.

---

## Docker Services

### Configuration & Data Paths

| Component        | Path                                                 |
| :--------------- | :--------------------------------------------------- |
| **Compose File** | `~/Code/nixcfg/hosts/csb0/docker/docker-compose.yml` |
| **Config (Git)** | `~/Code/nixcfg/hosts/csb0/docker/`                   |
| **Data (ZFS)**   | `/var/lib/csb0-docker/`                              |
| **Secrets**      | `/run/agenix/`                                       |

### All Containers

| Container                  | Purpose                          | Data Path (ZFS)                    |
| -------------------------- | -------------------------------- | ---------------------------------- |
| csb0-mosquitto-1           | MQTT broker (CRITICAL)           | `/var/lib/csb0-docker/mosquitto`   |
| csb0-nodered-1             | Smart home automation (CRITICAL) | `/var/lib/csb0-docker/nodered`     |
| csb0-traefik-1             | Reverse proxy                    | `/var/lib/csb0-docker/traefik`     |
| csb0-hostdash-1            | HostDash service dashboard       | `/etc/hostdash/csb0`               |
| csb0-uptime-kuma-1         | Monitoring                       | `/var/lib/csb0-docker/uptime-kuma` |
| headscale                  | VPN control server (Tailscale)   | Docker volume `headscale-data`     |
| csb0-restic-cron-hetzner-1 | Backup manager                   | -                                  |

### Backup & Restore Logic

1. **Cold Backups**: Stop containers before backup to ensure DB consistency.
2. **Path Mapping**: Restic `/backup/home/mba/docker/` maps to `/var/lib/csb0-docker/`.
3. **Secrets**: Managed via `agenix` Tier 1. Decrypted to `/run/agenix/`.

### Quick Commands

```bash
# View all containers
docker ps -a

# Restart a container
docker-upf  # (Force all) OR
docker restart <container-name>

# View logs
docker logs csb0-nodered-1 --tail 50
docker logs csb0-mosquitto-1 --tail 50
```

---

## Troubleshooting

### Decision Tree

```
Service Not Responding?
├─ Can SSH?
│  ├─ YES: Docker/service issue
│  │  ├─ docker ps → container running?
│  │  │  ├─ YES: Check logs: docker logs <container>
│  │  │  └─ NO: Start it: `sudo systemctl start compose-csb0` (OPS-116 — never raw `compose up`)
│  │  └─ Docker down? systemctl status docker
│  └─ NO: Server/network issue
│     ├─ Can ping 89.58.63.96?
│     │  ├─ YES: SSH service down → Use VNC console
│     │  └─ NO: Server down → Check Netcup panel
│     └─ Last resort: VNC console (Netcup SCP)
```

### Common Issues & Quick Fixes

```
Node-RED down → docker restart csb0-nodered-1
MQTT down → docker restart csb0-mosquitto-1 (⚠️ affects csb1!)
Headscale down → docker restart headscale (VPN clients reconnect automatically)
Backup failed → docker logs csb0-restic-cron-hetzner-1
Telegram bot → Re-register webhook (see SECRETS.md for token)
High load → Check docker stats (find heavy container)
SSL Error 526 (Cloudflare) → CF API token expired; rotate via csb1 RUNBOOK procedure
```

---

## 🚨 Disaster Recovery: ZFS Boot Loop (hostid mismatch)

If the server fails to boot with `cannot import 'zroot': pool was previously in use from another system`, follow these steps exactly:

### 1. Preparation

1. Download the ISO from this URL: https://nixos.org/download/ (eg. https://channels.nixos.org/nixos-25.11/latest-nixos-minimal-x86_64-linux.iso)
1. **Netcup SCP** -> **Media** -> **DVD Drive**.
1. **Upload custom ISO** (downloaded in step 1)
1. **Attach** the ISO and **Boot from DVD**.
1. **Start** the server.

### 2. The Fix (NixOS Shell)

Once the NixOS live environment boots to a prompt:

```bash
sudo -i
partprobe             # Ensure disks are scanned
zpool import -f zroot # Force import to reset the hostid lock
zpool export zroot    # Cleanly export to stamp it as safe
poweroff              # Shut down to safely detach DVD
```

### 3. Cleanup

1.  Wait for the server to reach "Offline" status in Netcup SCP.
2.  **Detach the DVD** or set **Boot Mode** back to **Hard Disk**.
3.  **Start** the server.

---

## Emergency Recovery

### Access Priority

1. **Primary**: SSH with key (`~/.ssh/id_rsa`)
2. **Backup**: SSH with mba password (see 1Password: "csb0 csb1 recovery")
3. **Emergency**: Netcup VNC console + mba password
4. **Recovery**: Netcup control panel access (with 2FA)

### Recovery Password

The `mba` user has a `hashedPassword` set in `configuration.nix` for emergency
VNC console access. Password stored in 1Password under "csb0 csb1 recovery".

### Network Configuration

| Setting   | Value                                  |
| --------- | -------------------------------------- |
| Static IP | `89.58.63.96/22`                       |
| Gateway   | `89.58.60.1`                           |
| DNS       | `46.38.225.230`, `46.38.252.230`       |
| MAC       | `2A:E3:9B:5B:92:23`                    |
| Interface | `ens3` (NixOS) / `eth0` (Ubuntu/Kexec) |

⚠️ **CRITICAL**: The interface is named `eth0` during the initial Ubuntu install and `nixos-anywhere` kexec phase, but renames to `ens3` once NixOS is fully booted. Both are listed in `networking.networkmanager.unmanaged` to prevent lockout.

### 🚨 Historical Incident: 2026-01-16 Old Server Decommissioned

**Event:** The old `csb0` server (`85.235.65.226`) was successfully decommissioned on Friday, 2026-01-16, following the migration to the new hardware (`89.58.63.96`).
**Action:** All DNS records and services have been transitioned. Documentation has been updated to reflect the new IP.

### 🚨 Historical Incident: 2026-01-10 Migration Lockout Prevention

**Symptom:** Potential lockout due to interface name mismatch (`eth0` vs `ens3`).
**Root Cause:** Ubuntu Minimal uses legacy naming; NixOS uses predictable naming.
**Fix:** Explicitly configure `ens3` but unmanage both names in NetworkManager. Verify `hostId` from `/etc/machine-id`.

### 🚨 Historical Incident: 2025-12-06 Network Lockout

**Symptom:** Server became unreachable immediately after `nixos-rebuild switch`.
**Root Cause:** The configuration assumed a `/24` subnet and a gateway at `.65.1` (based on `csb1` patterns). However, `csb0` is on a `/22` network where the gateway is at the start of the range: `85.235.64.1`.
**VNC Recovery Note:** The Netcup VNC console has severe keyboard mapping issues. Colons `:`, hyphens `-`, and pipes `|` often cannot be typed.
**Fix:** Always verify gateway via DHCP (`journalctl` or `ip route`) before applying static IP config.

### If SSH Fails

1. Login to Netcup SCP (<https://www.servercontrolpanel.de/SCP>)
2. Navigate to server, open VNC console
3. Login as `mba` with recovery password (see 1Password)

### VNC Console Recovery (Netcup)

⚠️ **Netcup VNC has German keyboard layout issues!**

**Keys that WORK:**

- Letters (a-z, A-Z), Numbers (0-9)
- Forward slash `/`, Period `.`, Spaces
- Dollar `$`, Parentheses `()`, Equals `=`, Underscore `_`
- Arrow keys, Tab completion (in bash, NOT busybox)

**Keys that DO NOT WORK:**

- Hyphen `-` (critical for commands!)
- Backslash `\`, Colon `:`, Pipe `|`

**If login prompt works** → Use mba password from 1Password

**If login broken** → Use `init=/bin/sh` recovery:

1. Reboot via Netcup panel
2. At GRUB, press `e` to edit boot entry
3. Add `init=/bin/sh` to end of linux line
4. Press Ctrl+X to boot
5. In minimal shell (`sh-5.3#`), find tools with glob:

```bash
# Find password tool
echo /nix/store/*shadow*/bin/passwd
# Example: /nix/store/117zjnjzaw0n22z0xinp17qpbdv3wsra-shadow-4.18.0/bin/passwd

# Set password (use Tab completion after partial path)
/nix/store/117z[Tab]/bin/passwd mba

# Find network tools
echo /nix/store/*iproute*/bin/ip

# Configure network (adjust path with Tab)
/nix/store/m1b[Tab]/bin/ip addr add 89.58.63.96/22 dev ens3
/nix/store/m1b[Tab]/bin/ip link set ens3 up
/nix/store/m1b[Tab]/bin/ip route add default via 89.58.60.1

# Continue normal boot
exec /nix/var/nix/profiles/system/init
```

**Note:** Busybox ash shell is worse than bash (no arrow-up, no Tab). If you accidentally enter it, type `exit` to return to bash.

### Netcup API Emergency Restart

```bash
# Get token and restart (see SECRETS.md for refresh token location)
TOKEN=$(curl -s 'https://servercontrolpanel.de/realms/scp/protocol/openid-connect/token' \
  -d 'client_id=scp' -d "refresh_token=$(cat ~/Code/nixcfg/hosts/csb0/secrets/netcup-api-refresh-token.txt)" \
  -d 'grant_type=refresh_token' | jq -r '.access_token') && \
  curl -X POST "https://servercontrolpanel.de/scp-core/api/v1/servers/607878/reset" \
  -H "Authorization: Bearer $TOKEN"
```

---

## Backup System

### 🚨 CRITICAL: csb0 is the Cleanup Manager

**⚠️ csb0 manages cleanup for BOTH csb0 and csb1 backups!**

- Both servers backup to the same Hetzner repository
- csb0 runs cleanup at 03:15 AM daily
- csb1's cleanup script exits early and defers to csb0

### Schedule

| Task    | Time                   | Container                  |
| ------- | ---------------------- | -------------------------- |
| Backup  | 01:30 AM daily         | csb0-restic-cron-hetzner-1 |
| Cleanup | 03:15 AM daily         | csb0-restic-cron-hetzner-1 |
| Check   | 05:30 AM monthly (1st) | csb0-restic-cron-hetzner-1 |

### What Gets Backed Up

```
✅ /var/lib/csb0-docker - ALL Docker volumes & data
✅ /home/mba/Code/nixcfg - System configuration (via git)
✅ /root - Root user data
✅ /etc - System configuration
❌ Exclusions: */cache/*, *.log*
```

### Check Backup Status

```bash
# View logs
docker logs csb0-restic-cron-hetzner-1 | tail -50

# List snapshots (see SECRETS.md for repository details)
docker exec csb0-restic-cron-hetzner-1 restic snapshots
```

---

## Service Dependencies

```
IoT Devices → MQTT (csb0) → hsb1 Node-RED consumers (influx path retired 2026-06-12, NIX-193)
            ↓
     Node-RED (csb0) → Telegram Bot → Users
            ↓
    Smart Home Controls
```

---

## Telegram Bot Architecture

### Bots Overview

| Bot              | Username              | Purpose                                     | Token Location                      |
| ---------------- | --------------------- | ------------------------------------------- | ----------------------------------- |
| **Building Bot** | `@janischhofweg22bot` | Smart home control (garage, doors, cameras) | `JHW22_BOT_TOKEN` in `telegram.env` |
| **CSB0 Bot**     | `@csb0bot`            | Legacy/test bot (NOT actively used)         | `CSB0_BOT_TOKEN` in `telegram.env`  |

### Active Bot: @janischhofweg22bot

This is the **production bot** used by building residents for:

- `/zufahrt` - Open driveway gate
- `/smartlock` - Control door lock
- `/keller` - Access cellar
- `/kamera` - View camera feeds
- `/pp20ein`, `/pp20aus` - Parking space controls

**User permissions** are defined in Node-RED flows (`flows.json` → `userConfig` object) by Telegram user ID.

### Cross-Server Communication

Both `csb0` and `hsb1` use the SAME `@janischhofweg22bot` token:

- **CSB0**: Handles interactive commands (via Node-RED Telegram nodes).
- **HSB1**: Sends notifications via Apprise (one-way).

---

## Headscale (VPN Control Server)

Self-hosted Tailscale control server. Manages mesh VPN for all infrastructure hosts.

- **URL**: <https://hs.barta.cm>
- **Container**: `headscale`
- **Config**: `~/Code/nixcfg/hosts/csb0/docker/headscale/config/config.yaml`
- **Data**: Docker volume `headscale-data` (SQLite DB + private keys)
- **DNS**: `hs.barta.cm` must be **DNS-only** in Cloudflare (NOT proxied - breaks WebSocket POSTs)
- **DERP map** (OPS-180/182): headscale ≤0.26 replaced the map with an _empty_ one when the 3-hourly `derp.urls` refresh failed (2026-08-21 netcup outage → fleet-wide "no relay"; symptom: `sudo tailscale debug derp-map` → `{"Regions": {}}`, health "could not connect to relay server"; quick fix `docker restart headscale`). Since 0.27 a failed refresh keeps the previous map, so the temporary `derp.paths` snapshot is gone — do not re-add one on ≥0.27 (paths overwrite the live map there; T43 guards it).

### Common Commands

```bash
# List users
docker exec headscale headscale users list

# List connected nodes
docker exec headscale headscale nodes list

# Create new user
docker exec headscale headscale users create <username>

# Generate pre-auth key (reusable, 24h expiry)
docker exec headscale headscale preauthkeys create --user <username> --reusable --expiration 24h

# Generate long-lived pre-auth key (store in 1Password!)
docker exec headscale headscale preauthkeys create --user <username> --reusable --expiration 87600h

# List existing pre-auth keys
docker exec headscale headscale preauthkeys list --user <username>

# Check config validity
docker exec headscale headscale configtest

# View logs
docker logs headscale --tail 50
```

### Upgrades (staged, OPS-182 / OPS-183)

One minor per reviewed stage at its latest patch (0.25.1 → 0.26.1 → 0.27.1 → 0.28.0 → 0.29.3);
the image tag is pinned in `docker/compose-spec.nix` (in the closure → `just switch` recreates
the container). The SQLite volume migrates forward only — never run an older image against a
migrated database; roll back by restoring the pre-stage backup together with the old tag.

```bash
# 1. inventory (record in the stage ticket)
docker exec headscale headscale version; docker exec headscale headscale users list
docker exec headscale headscale nodes list; docker exec headscale headscale routes list
# 2. cold backup of the data volume (stops the control plane; the data plane keeps running)
docker stop headscale
sudo mkdir -p /var/lib/csb0-docker/headscale-backups   # inside the nightly restic path
sudo tar -C /var/lib/docker/volumes/csb0_headscale-data/_data -czf \
  /var/lib/csb0-docker/headscale-backups/headscale-data-pre-<tag>-$(date +%Y%m%dT%H%M%S).tgz .
# 3. merge the pin PR, then on csb0:
cd ~/Code/nixcfg && git pull && just switch        # recreates headscale with the new image
docker logs headscale --tail 60                    # migration lines, 'listening and serving'
docker exec headscale headscale nodes list         # all nodes still there
# 4. from another node: sudo tailscale debug derp-map | jq '.Regions|length'  (28) and health clean
# rollback: docker stop headscale; restore the tgz into the volume; re-pin the old tag; switch
```

### ACL policy (OPS-266)

Stage 2 is active in the repository config: `policy.path: "/etc/headscale/policy-stage2.hujson"`. Stage 1 (`policy.hujson`) remains untouched on the same `./headscale/config:/etc/headscale` mount for rollback; it is one accept rule, `* -> *:*`. On headscale 0.29 `*` is the tailnet ranges only (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`). OPS verified Headscale 0.29.3 and an empty `headscale nodes list-routes` on csb0 on 2026-10-06: no advertised or approved routes on any node. The NixOS hosts' `useRoutingFeatures = "client"` setting alone does not establish fleet-wide absence of routes. Recheck live routes before applying either stage; with an empty route list, stage 1 preserves node-to-node allow-all reach.

The config directory is a bind mount of the git checkout. A pull updates the files on disk. Headscale reads `policy.path` at process start; SIGHUP reloads only the file at that same path. Switching the path requires `docker restart headscale`. `just switch` does not recreate the container for config-only changes when the compose spec is unchanged. Make path changes in the repository through the reviewed change flow, then pull on csb0; preserve `policy.hujson` as the stage-1 rollback file.

OPS-412 (Markus, Decision Desk 3ec4b0b3, 2026-10-21, outcome "always"): the external dedicated CI host joins as `agm2-ci` with `tag:agm-ci` (tagOwner `markus@`). Only the two builder Macs (`builder-mbp2606` 100.64.0.13, `builder-mbp2607` 100.64.0.14) may open tcp **2222** on it. The markus@/gerhard@ rule lists its destinations explicitly (`markus@:*`, `gerhard@:*`, `amy@:*`, `tag:paper-desk:*`), which equals today's node-to-node reach and excludes `tag:agm-ci`; a new user or tag must be added there by review. `tag:agm-ci` has no source rule, and peer maps follow the ACL, so no other node sees it. Registration is interactive: the node prints a registration key, which OPS registers on csb0 (`headscale auth register --user markus --auth-id <id>`); no pre-auth key leaves this host. Re-check the builder aliases after a builder re-registers (sequential allocator). **Rollback order (the CI node first):** any older policy (the pre-OPS-412 stage 2 with `markus@/gerhard@ → *:*`, or the stage-1 allow-all) would open the CI node more widely and let it initiate. So first have its owner stop the CI instance, then `docker exec headscale headscale nodes delete -i <id>` and confirm `nodes list` no longer shows `agm2-ci` / `tag:agm-ci`. Only then revert the OPS-412 PR, pull and SIGHUP, or switch to stage 1.

Amy-box joins with a pre-auth key tagged `tag:paper-desk`, owned by `amy@` in `tagOwners`. A tagged node uses the tag identity rather than `amy@`; stage 2 therefore permits both identities only to tcp `paper-desk:8470` (`100.64.0.6`). Check user-owned and tagged nodes separately.

```bash
# Stage 2 — active repository path; apply the reviewed change after stage 1 verification.
# Recheck live routes before pulling the config change:
docker exec headscale headscale nodes list-routes
# Must stay empty. If any route is advertised or approved, STOP activation:
# add its explicit route CIDR(s) to the markus@/gerhard@ destination rule
# through review before stage 2. Exit-node reach needs autogroup:internet:*.
# The reviewed repository config selects:
#   path: "/etc/headscale/policy-stage2.hujson"
# Never overwrite policy.hujson; retain it for rollback.
cd ~/Code/nixcfg && git pull
docker exec headscale headscale configtest
docker exec headscale headscale policy check --file /etc/headscale/policy-stage2.hujson
docker exec headscale headscale policy check --file /etc/headscale/policy.hujson
docker restart headscale
# A path change needs this restart; SIGHUP and config-only just switch are insufficient.
docker exec headscale headscale nodes list
# markus@ and gerhard@ reach markus@:* gerhard@:* amy@:* tag:paper-desk:* (explicit, OPS-412);
# routes need explicit CIDRs.
# amy@ AND tag:paper-desk reach only tcp 100.64.0.6:8470 and :8471 (executor, mailbox).
# Check both: not :4002, not ssh, not any other host.
# tag:agm-ci (OPS-412): only builder-mbp2606/7 open tcp 2222 on it; any other port or source fails;
# it initiates nothing and no other node lists it as a peer.
# return traffic is stateful; hsb0 needs no rule towards amy

# Rollback — restore policy.path in the repository, review, then pull:
#   path: "/etc/headscale/policy.hujson"
# Stage 1's allow-all contents are preserved; do not overwrite either policy file.
cd ~/Code/nixcfg && git pull
docker exec headscale headscale configtest
docker exec headscale headscale policy check --file /etc/headscale/policy.hujson
docker restart headscale
```

### Connect a New Device

> **Note:** The `--authkey` does NOT need a `--user` flag on the client side.
> The user is baked into the pre-auth key at creation time (`--user <username>`).
> Any device registering with that key automatically belongs to that user.

```bash
# macOS (use the .app CLI, NOT brew's tailscale)
/Applications/Tailscale.app/Contents/MacOS/Tailscale up --login-server https://hs.barta.cm --authkey <KEY>

# NixOS (requires services.tailscale.enable = true in configuration.nix)
sudo tailscale up --login-server https://hs.barta.cm --authkey <KEY>

# Linux (generic)
tailscale up --login-server https://hs.barta.cm --authkey <KEY>
```

**Prerequisites per platform:**

- **macOS**: Tailscale.app installed and running
- **NixOS**: Add `services.tailscale.enable = true;` to host config, deploy first

### Troubleshooting

```
Headscale unhealthy → docker logs headscale (check for DB or config errors)
TLS cert missing → Check Cloudflare DNS is DNS-only (gray cloud); restart Traefik
Nodes can't connect → Verify hs.barta.cm resolves to 89.58.63.96 (not Cloudflare IP)
After restart → Nodes reconnect automatically (no action needed)
```

---

## Maintenance

### Clean Up Disk Space

```bash
ssh mba@cs0.barta.cm -p 2222 "docker system prune -f"
```

### View Logs

```bash
# Current boot
ssh mba@cs0.barta.cm -p 2222 "journalctl -b -e"

# Follow logs
ssh mba@cs0.barta.cm -p 2222 "journalctl -f"
```

---

## Web Interfaces

| Service   | URL                                      |
| --------- | ---------------------------------------- |
| Node-RED  | <https://home.barta.cm>                  |
| Bitwarden | <https://bitwarden.barta.cm> (TEST ONLY) |
| Headscale | <https://hs.barta.cm>                    |
| MQTT      | mosquitto.barta.cm:8883 (TLS)            |

---

## Related Documentation

- [csb0 README](../README.md) - Full server documentation
- [SECRETS.md](../../docs/SECRETS.md) - All credentials (gitignored)
- [csb1 Runbook](../../csb1/docs/RUNBOOK.md) - Monitoring server

## HostDash SSO (OPS-366)

Restrict SSO to the operator domain: `hostdash-auth` uses
`--email-domain=barta.com` for HostDash and the JoeDesk board UI. In oauth2-proxy
v7.15.3 this matches the email claim's exact domain (case-insensitive). The OIDC
default rejects `email_verified=false`; an absent claim is accepted. Keep
`--insecure-oidc-allow-unverified-email` absent.

A second identity needs an agenix-managed `--authenticated-emails-file`; creating
that new secret requires the operator's explicit go. The file supplements the
domain allowlist. Never put personal addresses in this public repository.
The durable fix is a Zitadel project role check in inspr-services; OPS proposes
that change through an INSPR ticket in the owning project.

Offline gate: `python3 tests/T104-oauth2-proxy-email-domain.py`. After the switch,
OPS runs `python3 tests/T104-oauth2-proxy-email-domain.py --live`: anonymous GETs
to cs0 `/`, cs0 `/joe/`, and cs1 `/` must return 302 to the HTTPS IdP at
`auth.inspr.at`, or 401/403. Output is status codes only, in that order; `000`
means no response and fails the gate. Redirects are not followed.

Rollback: revert the OPS-366 change and switch on the affected host. This restores
the previous SSO policy; OPS owns execution and live verification.

## Joe household board (v2)

- URL: https://cs0.barta.cm/joe/ (oauth2-proxy)
- Inbox: POST https://cs0.barta.cm/joe/inbox (Bearer; agenix `joe-board-push-token`)
- Service: `joe-board` compose build `./joe-board`; data `/var/lib/joe-board`
- Security: `hosts/csb0/docker/joe-board/SECURITY.md`
- Producer: hsb0 `joe-board-pusher` every 30s (paper 4002 only)

### OPS-354 routing gates (preparation only)

Keep the OPS-354 PR **DRAFT and unmerged until Markus's cut-over go**: merging lets a later csb0 switch apply items 1 and 5.

Run `python3 tests/T76-joe-slash-routing.py` before review. On the approved
v2 source after the switch, run
`python3 tests/T76-joe-slash-routing.py --live --joedesk-source SOURCE`.
This delegates the canonical version, health allowlist, feed freshness and
anonymous/spoof matrix to JoeDesk's own smoke and additionally checks HEAD.
A health redirect is `auth_required`; db621bf's missing `/joe/healthz` cannot
pass. Near-health paths, UI/assets and six reads require unstamped SSO denials.
With an active v1 set, `python3 tests/T76-joe-slash-routing.py --live` instead
checks anonymous and spoofed `/joe/`, data/history and CSS reads behind SSO;
it requires neither a v2 checkout nor v2 public health. The active release set
also determines the full-mode image and pull policy (`never` for previous).

Item 1 deletes aliasing headers at `web-secure` before routing and strips user,
email, preferred username and groups identity headers before forwardAuth.
Static, live and workstation tests include underscore, dot and mixed aliases.
The pinned v2 server reads only the literal lowercased `x-auth-request-user`;
Node does not turn punctuation aliases into that key. oauth2-proxy v7.15.3
loads identity from its session; its header stripper also normalizes underscores
when removing managed headers, rather than using them as authentication.
See the [pinned header middleware](https://github.com/oauth2-proxy/oauth2-proxy/blob/v7.15.3/pkg/middleware/headers.go)
and [session loading](https://github.com/oauth2-proxy/oauth2-proxy/blob/v7.15.3/oauthproxy.go).
Traefik's [`aliasHeadersStrategy: delete`](https://doc.traefik.io/traefik/migrate/v3/#v3712)
requires v3.7.12 or newer; v3.6.20's underscore-only predecessor does not cover
dots. csb0 declares the floating `traefik` image, so its running version/support
is **unverified by this no-SSH preparation**. OPS must record the exact deployed
version and verify option support before switching; this ticket changes no pin.

Post-deploy item 6 requires a separate signed-in paper-only Fleet Config edit:
send synthetic `X-Auth-Request-User` and `X-Forwarded-User` through the trusted
public proxy using a private authenticated cookie jar. Check privately that
the new audit entry's actor equals the authenticated SSO identity, differs
from the synthetic identity, and has the expected successful revision/key.
Restore the original setting through the same Diff/Confirm/Propagate flow,
then verify its attributed audit entry too. Never print cookies, actor values,
config bodies or real data in evidence. Keep `authResponseHeaders` enabled;
this check complements the anonymous spoof matrix and remains an OPS gate.
Include `X_Auth_Request_User`, `X.Auth.Request.User`, `X-Forwarded_User` and
the preferred-username/groups/email variants in that signed-in request too.

T76 v2 live mode requires a clean Git source checkout at the exact active
flake.lock revision before it invokes that source's smoke. An immutable
source archive can run upstream smoke directly; use an exact Git checkout
for T76's additional source-identity gate.
CI wires T100, T101 and T102 beside T76. T101/T102 attempt immutable archives
through the same Nix GitHub fetch transport as full T76. If the private source
cannot be fetched, CI emits an explicit warning and source-dependent skips;
the remaining T101 guards still run. A skip is never producer/host-gate evidence.

### Linux evaluation evidence for the release-set-only item

On an authorized Linux evaluator with locked inputs already available, use
`nix eval --offline --no-update-lock-file --raw .#nixosConfigurations.csb0.config.system.build.toplevel.drvPath`
before and after applying only item 2, keeping item 1's routing identical on
both sides. Compare hsb0 in the same way. Keep the same Git HEAD/source-info
metadata for both evaluations (apply item 2 uncommitted to that baseline), so
a configurationRevision change from different commits does not confound the
comparison. Include the new JSON with `git add -N` for Git-backed flake
evaluation. This is an evaluation comparison, with no build or switch.
T100 compares the csb0 static spec against ed5e43d6, and hsb0 against main
096cc37f (#1063): image, full Compose spec, executor service, units, firewall, users
and real source derivation paths. It evaluates Linux packages in a disposable
local store without building. The whole-host toplevel derivation comparison
above remains a separate OPS gate; T100 does not claim it passed.

### OPS-354 cutover order and stopped-writer swap

The OPS-354 activation (with the OPS-408 r17 producer flip) sets `active = v2`;
it merges only as the cut-over's merge_sha under the hsb0/csb0 freeze and is not
itself permission to switch. The rollback board is db621bf (legacy `calendar`,
26.09.21.12.00, sequence 23, no matching tag). The
active v2 source is main a60f4c561b05fa26ee8fa1dd31ab725714399340
(JOED-60: health ranking only, no data change; supersedes 040d6756 / 261021083537.0.0 / sequence 27, live
2026-10-21 11:22Z, 6eacd6c7 / sequence 26 and d36b5295 / sequence 25), tree b06f92aadf1b8ee2e08414ab7252e2fbb105b5d0,
`inspr-calver-3` / 261021113113.0.0 / sequence 28. Version and sequence come
from that checkout's `release.json` and `release/preparation.json` (JOED-60; JOED-59 was the previous set).
Board-only rollback of this re-pin: revert the JOED-60 PR and switch csb0; with `pull_policy = never` the
retained tag `csb0-joe-board:source-040d6756e92dc7c4e05fcf63b865242819b3d0ce` (sequence 27) is reused, no build.
db621bf stays the v1 rollback.
Contracts manifest revision 9 has set SHA256
`000045fb7843a16be95f6a7e42d46d4b4ecb34b0efd39fc987bee444817fc9d5`;
`release/contracts.json` SHA256 is
`5c20c38be4602f6c142ece1c1abc65172306d504aa0a74d098e10bb15f78ef17`.
Reuse JOED-26's approved adoption scope; live adoption still requires the OPS
gates below. Upstream `release.json` still describes the source as a candidate;
the exact main commit and hashes identify this activated source.
JOED-20 producer/executor activation and evidence remain separately owned.

The `current` set keeps the v1 board db621bf; its pusher/executor records
match main 1034a7c511ad869056300eafb0ff1ebafcffe0d6 (#1063, including #1061/#1062) and image
`hsb0-joe-board-pusher:household-v2-switch-set-r16d-202610201800`. Main's staging,
local-mailbox wiring and source closure are retained. `previous` preserves
the older flat-net downstream pins; it is historical rollback metadata.

As in r6 (commit 1279da937f98e166207a734c2b2b3294259858db) and r7c
(commit 7314751188628197fef587e402dafc3815eeb5f5), compute each `source_tree`
from the exact main commit with `git rev-parse REV:SOURCE_PATH`, using the
recorded `source_path`. At 096cc37f this yields pusher tree
`4258cfee86aac796c226f93d23b4f38289cbcc6a` and executor tree
`d77428b41e00faa71d6cb52f0ace23ba487a4b9d`. These are Git tree IDs from
main, including its literal executor image; T100 separately proves the
release-set indirection evaluates identically. The retained r16d rollback image
is `hsb0-joe-board-pusher:household-v2-switch-set-r16-202610201700`.

R7e local preparation passed T100 with `--prove-current` and the exact d36b5295
source, including full hsb0 main equality and explicit r16 images; T101 passed
29/29 and T93 passed 851/851. The pusher suite passed 548/550 with two explicit
Linux-only skips (real flock and memory-cgroup/OOM isolation); its Python reader
suite passed 14/14. Image import closure and the actual r16-to-r15 rollback
fixture passed. The pusher Nix fixture now preserves the sibling csb0 release
JSON required by the host's release-set indirection. T102, T76 labels-only,
executor evaluation, the Bash 5 guard and the exact-source rehearsal dry-run
passed. T76's full offline flake check could not access the Nix daemon from
the macOS sandbox; it is not passed. The rehearsal used a temporary lab root
and recorded a non-Docker plan; Linux ownership, Docker/image smokes, whole-host
evaluation, live checks, review and cutover remain OPS gates. No push, SSH,
build or deployment was performed.

R7f local preparation merged exact main 096cc37f (#1063) while retaining
`joeSet` indirection and main's literal r16d stage image. The r6/r7c tree-pin
method above records the exact main trees, with no change to the active board,
`previous`, or the inactive v2 candidate. The existing JOED-26 adoption scope
and its pending live gates remain in force; this preparation does not migrate
the deployed board or reserve a new version.

T100 passed fully with `--prove-current` and exact d36b5295 source, including
hsb0 main equality and explicit r16d tags. T101 passed 29/29; T93 passed 851/851.
The pusher suite passed 560/562 with the same two Linux-only skips (real flock
and memory-cgroup/OOM isolation); its Python reader suite passed 14/14. Image
import closure, actual r16d-to-r16 retained-pair rollback, and the r16-to-r15
move-aside fixture passed. T102, T76 labels-only, executor evaluation, Bash 5
suite-runnability checks (101 entries), and the exact-source rehearsal dry-run
passed. Nix's disposable store needs a canonical temporary path on macOS;
the storage tests passed with the normal per-user temporary directory and its
matching group ownership. Full T76 remains unpassed: the macOS sandbox denies
the Nix daemon socket. Docker/image smokes, Linux ownership, whole-host
comparison, live checks and cutover remain separate OPS gates. Product review
remains pending: the read-only Claude attempt was unauthenticated and the Grok
fallback could not create its session under the sandbox. Paimos model routing
also could not resolve its API host. No product merge approval, push, SSH,
build or deployment is claimed.

Compared with dafe7909, revision 9 adds optional paper-account cash with a
per-field unavailability reason, per-field position reasons (including an
unmapped desk), and stricter unavailable-value semantics. The read model adds
a `paperCash` cell and accepts the older revision-7 state shape without losing
sequence or last-good values. Contract schema IDs stay v2. Dockerfile,
`server.mjs` routes/identity/health, `scripts/smoke-release.mjs`,
`scripts/prepare-data.mjs` and `release/data-migration.mjs` are byte-identical;
the existing fixture, backup/migrate/verify/restore and swap commands remain
applicable. Re-extracted identity function bytes and the db621bf host gate are
unchanged. Main's Phase A producer contracts are not revision-9 sign-off;
JOED-20 must still supply compatible downstream pins and real evidence.

1. On a workstation, run
   `just rehearse-joedesk SOURCE --dry-run`, then
   `just rehearse-joedesk SOURCE` using the exact published checkout with the
   legacy Git object available. The second command builds db621bf and a60f4c56
   images, stages JoeDesk's own v2 fixture, uses the same swap script as
   production, runs upstream forward smoke through `traefik:v3` and stub
   forwardAuth, checks signed-in spoof replacement/restoration, then restores
   v1 and tests the exact old image, private probes and authenticated reads.
   Only the lab host matcher, entrypoint/TLS and provider/endpoint references
   adapt to loopback; path/method rules, priorities and middleware order come
   from evaluated labels. The fixture server uses its original fixed receipt
   clock, explicitly a lab behavior. It is never freshness evidence for live
   data. Fleet names csb*, hsb*, agm\* and remote Docker contexts are refused.
   The engine name from `docker info` must also be outside those fleet prefixes.
   The default private lab parent is `~/.cache/joedesk-rehearsal/`, inside
   Colima's HOME mount; `--lab-root PATH` must be that parent or a directory
   beneath it, the system temporary directory (`os.tmpdir()`), or `/tmp`
   (`/private/tmp` on macOS), including their descendants. Paths are resolved
   before any source work or lab writes; other parents fail with
   `lab_root_outside_allowed_parents`. Before using
   any lab data, a disposable container must read its marker or the rehearsal
   fails with `lab_root_not_visible_to_docker`. The edge publishes loopback on
   bridge, then joins the internal-only board/auth network; JSON config is
   mounted as `/dynamic.yml`. Docker failures report only subcommand/exit code.
   Store data, backups and all staged/retained/restored swap siblings use one
   per-run `ops354-<uuid>-data` Docker named volume. Helpers mount it at `/lab`;
   both board versions mount it at `/var/lib`, preserving `/var/lib/joe-board`.
   A helper seeds read-only host fixtures into the volume. Every data read,
   backup, verify, swap and strict 1000:1000 / 0700/0600 ownership check runs
   inside containers, where Linux chown works even with a macOS Docker host.
   Host binds carry read-only inputs only. The guarded volume is removed in
   `finally`, even on failure; only source inputs/images remain on the host.
   The dry-run prints this volume command plan and runs T101's real offline
   tests; Docker ownership and smokes remain pending. Stdout is value-free.
   No real token, data, broker or cloud host is used.
2. Record successful rehearsal, Linux before/after drvPath equality for the
   release-set-only refactor, independent review, Amy's approved staged
   producer snapshot and executor reconciliation, and Tick/owner UI decisions.
   In one reviewed cutover commit, update flake URL/lock and the complete
   selected release set together; retain the exact v1 board/pusher images,
   executor runtime/source and NixOS generations on both hosts. Record image
   IDs as well as tags. Keep GC roots for the prior generations and the v2
   source containing `scripts/prepare-data.mjs`; that CLI is not copied into
   the application image. Do not GC or prune these rollback artifacts.
3. Freeze Fleet Config edits and stop **all** board writers, hsb0 pusher and
   stager, including other producer jobs. The executor keeps running: its own
   `/var/lib/paper-desk-executor` is rw, pusher state is ro; it is not a board writer. Pause both hosts' compose update
   timers/services and reconcile units; verify no relevant writer container
   runs. Use each host's existing rendered Compose file only for `stop` and
   status checks. Leave the paper Gateway untouched. On csb0, stop `joe-board`
   with `sudo docker compose -p csb0 -f /etc/compose/csb0/docker-compose.yml stop joe-board`.
   On hsb0, use project `docker`, file `/etc/compose/hsb0/docker-compose.yml`,
   project directory `hosts/hsb0/docker`, and stop `joe-board-pusher joe-household-v2-stage`.
   Pause `compose-csb0-update.timer`, `compose-csb0-update.service`,
   `compose-csb0.service` and the corresponding `compose-hsb0*` units first.
4. With retained immutable v2 SOURCE and Node 22+, create a **new private**
   backup using
   `node SOURCE/scripts/prepare-data.mjs backup --offline /var/lib/joe-board NEW_BACKUP v1`,
   then `node SOURCE/scripts/prepare-data.mjs verify --offline NEW_BACKUP`.
   Record the manifest SHA256, exact old image IDs and retained generations in
   the private rollback record described below; never commit that record.
   Stage a **new sibling** directory using
   `node SOURCE/scripts/prepare-data.mjs migrate-v2 --offline NEW_BACKUP /var/lib/joe-board.staged-v2 APPROVED_INGRESS_SNAPSHOT ACTUAL_UTC_RECEIPT`.
   The approved snapshot has no receivedAt; the receipt is its actual staging
   arrival in millisecond UTC form, not cutover time. The next producer seq
   must be higher, with non-regressing generation/evidence times. Old staging
   needs a new accepted observation before a fresh-feed smoke can pass.
5. Run the shared forward swap on csb0 only:
   `sudo node scripts/joedesk-data-swap.mjs forward --source SOURCE --staged /var/lib/joe-board.staged-v2 --gid 1000 --writers-stopped`.
   It verifies staged v2 through JoeDesk's backup/verify implementation, checks
   same-filesystem siblings, rejects links, uses no-follow descriptors to chown the staged directory and
   every file to 1000:1000, sets 0700/0600, and renames the current directory
   to a unique retained sibling before moving the stage to `/var/lib/joe-board`.
   It refuses overwrite and restores the retained directory if the second
   rename fails. A private retained-sibling receipt records recovery paths.
   Keep the writers stopped on any failure; inspect the receipt and retained
   siblings privately. The normal compose lock protects just this swap, then
   releases before the switch. Never wrap `just switch` in that lock.
   The lock is acquired internally; no operator `--lock-held` bypass exists.
   Any existing board container must be exited, including paused/restarting
   containers in the refusal check; absent containers are also safe to swap.
6. Through the normal reviewed fast-forward Git path and `just switch`, select
   the approved release on csb0 and the matching hsb0 pins, then start the
   approved producer/executor. No compose override, --override-input or hot
   patch. The activation script's `chown -R 1000:1000 /var/lib/joe-board` acts
   only on the directory currently at the fixed path and preserves modes; it
   does not prepare a staged sibling or replace the swap's required chown.
   The same chown is required when no NixOS activation occurs. Retained sibling
   directories and backup bytes remain available. Resume timers only after
   compatible pins and normal reconciliation are verified on both hosts.
7. Require a fresh accepted producer observation, then run the exact source's
   `node SOURCE/scripts/smoke-release.mjs https://cs0.barta.cm/joe/ inspr-calver-3 CANONICAL_VERSION`
   and `python3 tests/T76-joe-slash-routing.py --live --joedesk-source SOURCE`.
   Both must pass; a 302 means auth_required, a 404 is failure. Keep the exact
   source/version, image IDs and value-free evidence together privately. The
   canonical smoke must report all six reads, UI/assets and spoof probes as
   sso-rejected, exact-path health, expected schema/version and fresh feeds.
   Results may remain explicitly not wired; Amy still owns results sign-off.
   Complete the signed-in actor replacement/restoration check above and
   Tick/owner signed-in UI verification before claiming the cutover complete.

**After a v2 activation (OPS-408 r17), run the v2 archive pre-step on hsb0 first:** with the pusher and
stager stopped, move every `v2/pair-*`, `v2/current.json` and `v2/receipts.jsonl` into a dated 0700
sibling archive and copy `v1-cycles` there (keep `sequence-state.json`, the `.allocator.lock` inode and
the posting state). r16d rejects r17's `not_posted_v2_active` receipts. The OPS cut-over package does
this inside the hsb0 `hold` step that every guarded rollback requires; see the hsb0 RUNBOOK (r17).

### One-command v1 rollback

**Rolling back after a v2 activation:** the rollback commit must be on main FIRST. rollback-joedesk
fetches origin/main and refuses a rollback commit that is not its ancestor. Keep the rollback PR
("ROLLBACK ONLY") open with green CI during the cut-over, merge it (`gh pr merge --match-head-commit`)
to abort, then run `just rollback-joedesk`. This also keeps main matching reality.

Before cutover, retain a root/operator-owned mode-0600 JSON record at
`/var/lib/joedesk-rollback/record.json` (private directory mode 0700). Required
keys: `previous_set_sha256` (the exported `setDigest` of release.sets.previous),
`backup_manifest_sha256` (SHA256 of the exact verified v1 backup manifest),
`board_image_id`, `pusher_image_id` (full sha256 IDs; executor shares that runtime),
`csb0_generation`, `hsb0_generation` (retained positive generation numbers),
`v1_backup`, `prepare_source`, `cookie_jar`, `hsb0_checkout` (absolute private
paths), and `rollback_nixcfg_rev` (the full reviewed rollback commit).
Also require `pre_cutover_hsb0_nixcfg_rev`, `pre_cutover_pusher_source_tree`,
`pre_cutover_executor_source_tree` (full Git object IDs captured before phase1),
and `pre_cutover_pusher_image`, `pre_cutover_stage_image`,
`pre_cutover_executor_image`, `pre_cutover_stage_enabled` (a boolean).
Phase1 captures all three tags from live `docker ps --format` metadata on
hsb0 and compares them to Linux-only `nix eval` of the exact current revision.
The evaluated system output must equal `/run/current-system`; revision and
generation drift during capture fail closed. A disabled stage requires an
explicit null stage image and absence from the running container list.
`pusher_image_id` is the retained image ID for that recorded runtime, not an
assumption that the historical previous tag was running. Record these facts
from the pre-phase1 checkout and running image; never infer them at rollback.
`prepare_source` must be the retained immutable `/nix/store/` v2 source,
including its own preparation CLI. The cookie jar is a private signed-in
SSO session for legacy version/data checks; the command never prints it.
The rollback commit cannot be known before review: prepare and review it when
needed, then update this private record before running the command. A missing
record, generation, local image or exact commit is a hard stop.

The rollback commit selects `active = previous`, restores the recorded
board flake URL/lock and the recorded pre-phase1 hsb0 **runtime source bytes**,
while retaining unrelated nixcfg changes. csb0's declarative previous selector
uses `pull_policy = never` so the normal switch reuses the retained exact
image; it does not rebuild legacy's floating base into a different image.
Pusher and executor already use never. Never restore the entire old nixcfg
revision or silently discard intervening host changes. Review the affected
source paths and check the private record's trees against its recorded hsb0
revision. Variant B retains r16d while csb0 selects previous. Variant A (flat-net)
is allowed only when the record explicitly names those trees and image.
Both hosts must return to their actual pre-phase1 state; never rewind or
restore the running executor ledger from a backup or live copy.

On csb0, run `just rollback-joedesk` (or `--record` another `.json` file directly in `/var/lib/joedesk-rollback/`). The
command refuses every other host and noninteractive use, asks y/N before
each action, and prints exact cross-host commands instead of using SSH.
Before any stop, it fetches main and verifies that the exact recorded commit
is a fast-forward from HEAD and an ancestor of fetched main, selects previous,
and contains the required lock and runtime sources. The printed hsb0 commands
do the same preflight before stopping writers. After operator confirmation of
stopped remote writers, it pauses local reconciliation/update jobs, stops the
board, and uses `git merge --ff-only <recorded-rev>` rather than pulling a
possibly newer main. It rechecks HEAD, selected set, lock and runtime bytes.
Pusher source must match the full recorded tree, including additions; executor
runtime file lists and bytes must match the recorded pre-cutover revision and
HEAD (Nix wiring may differ). Before stopping and again before switching,
Linux-only `nix eval` at the exact rollback commit checks the effective Compose
pusher, stage and executor images, executor option and stage presence against
every recorded field. Comments and selector text cannot satisfy this check.
Missing fields, evaluation errors and Darwin execution refuse. No build or
lock-file update is performed. Pusher/stager stop; the executor keeps running throughout. It calls the
**same** swap script in rollback mode, which runs
`node SOURCE/scripts/prepare-data.mjs restore --offline BACKUP NEW_RESTORE v1`
into a new sibling, applies ownership/modes and performs the stopped-service
rename/recovery procedure. It then runs normal `just switch` and legacy smoke
before the hsb0 writers restart. No automatic rollback of a failed operator
step restarts writers; keep them stopped and investigate.

The legacy smoke binds the running container's exact image ID through the
local Docker **list** API (no inspect/env dump), verifies private `/healthz`
and `/readyz`, shipped package name/version/type, restored file hashes and
authenticated public `joe-version.js`, v1 data/history and Fleet Config.
db621bf does not copy `release.json` into `/app`; package identity plus the
exact retained image ID bind this check to v1. T101 runs the same file-check
logic against db621bf's actual Dockerfile COPY closure. It rejects anonymous
public data access. It never requests v2 `/joe/healthz`
or counts its 404 as success. The command prints the hsb0 fast-forward,
source/pin gate, image/generation checks and `just switch`; the operator
executes and verifies those separately, then confirms before timers resume.

### Production host gate (README item 4)

`just test-joedesk SOURCE` includes T102, which runs the actual legacy P1
function and replacement P3 host module from the release-set Git pins. The
canonical production `cs0.barta.cm` must pass; foreign host/suffix lookalikes
must fail, and both app entrypoints must call that gate. No application
source is copied into nixcfg and no allowlist is guessed from the hostname.
This client privacy stub does not replace SSO or private-port enforcement.
README item 4 adds no route exemption beyond the existing token inbox and
item 1's exact GET/HEAD health.

### Separate Results ingress (OPS-354 item 5) — live since 2026-10-21

OPS-354 item 5 deliberately exceeds README P6b item 4. It went live with the OPS-354
cut-over on 2026-10-21 (a token-less POST answers 401) and is the JOED-39 Results producer's
target. The live board a60f4c56 (sequence 28; like 040d6756, 6eacd6c7 and d36b5295 before it)
includes JOED-27's merged ingress implementation (b323c0a).
The proposed exact **POST** `/joe/inbox/results` router uses identity stripping and
app-level Bearer checking, without SSO. It does not use PathPrefix. T76 tests
the exact route, priority and strip-only chain, while `/joe/inbox/results/`
and `/joe/inbox/resultsx` still require SSO, including anonymous/spoofed live
GET/HEAD/POST probes. GET/HEAD and every other non-POST method on the exact
path also require SSO. Source publication does not establish producer/results
sign-off, OPS rehearsal or permission to activate this infrastructure proposal.
