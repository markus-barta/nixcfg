# Runbook: csb1 (Monitoring & Documentation Server)

**Host**: csb1 (cs1.barta.cm / 152.53.64.166)  
**Role**: Monitoring, Metrics & Documentation Platform  
**Criticality**: MEDIUM - Monitoring dashboards, document management  
**Provider**: Netcup VPS 1000 G11 (Vienna)

---

## Quick Connect

```bash
# Via alias
qc1

# Direct SSH
ssh mba@cs1.barta.cm -p 2222

# With IP
ssh mba@152.53.64.166 -p 2222
```

---

## Quick Reference Card

```
╔════════════════════════════════════════════════════════════╗
║ 🌀 csb1 - Monitoring & Docs Emergency Reference            ║
╠════════════════════════════════════════════════════════════╣
║ SSH:       ssh mba@cs1.barta.cm -p 2222                    ║
║ IP:        152.53.64.166                                   ║
║ Netcup:    Customer # 227044 (2FA required)                ║
║ VNC:       servercontrolpanel.de/SCP                       ║
╠════════════════════════════════════════════════════════════╣
║ 🌐 SERVICES                                                ║
║ • PAIMOS (PM): https://pm.barta.cm                         ║
║ • Paperless:   https://paperless.barta.cm                  ║
║ • Docmost:     https://docmost.barta.cm                    ║
║ • Excalidraw:  https://draw.barta.cm                       ║
╠════════════════════════════════════════════════════════════╣
║ ⚠️  CRITICAL DEPENDENCIES                                  ║
║ • Cleanup → Managed by csb0 (not here!)                    ║
╠════════════════════════════════════════════════════════════╣
║ 🚨 IF DOWN                                                 ║
║ 1. SSH check: ssh mba@cs1.barta.cm -p 2222                 ║
║ 2. VNC console via Netcup SCP (if SSH fails)               ║
║ 3. Restore from backup (< 2h)                              ║
╚════════════════════════════════════════════════════════════╝
```

---

## Health Checks

### Quick Status

```bash
# One-liner: container count, disk usage, load
ssh mba@cs1.barta.cm -p 2222 "docker ps | wc -l && df -h / | tail -1 && uptime"
# Expected: 16 containers, <50% disk, load <1.0

# Check container health
ssh mba@cs1.barta.cm -p 2222 "docker ps --filter 'status=exited'"
# Should be empty (all running)

# Check services responding
curl -I https://paperless.barta.cm  # Paperless (expect 200)
curl -I https://docmost.barta.cm  # Docmost (expect 200)
curl -I https://draw.barta.cm  # Excalidraw (expect 200)
```

---

## Common Tasks

### Update & Switch Configuration

```bash
ssh mba@cs1.barta.cm -p 2222
cd ~/nixcfg  # or ~/Code/nixcfg
git pull
just switch
```

### Rollback to Previous Generation

```bash
ssh mba@cs1.barta.cm -p 2222
sudo nixos-rebuild switch --rollback
```

---

## 🏗️ Uzumaki & Hokage Pattern

`csb1` is an **External Hokage Consumer**. It consumes the base server configuration from the global `hokage` module but applies local customizations via the `uzumaki` namespace.

- **Status**: Enabled (`uzumaki.enable = true`)
- **Role**: `server`
- **Indicator**: The `nixbit` command should be available and working.

---

## NixFleet Dashboard (DECOMMISSIONED)

NixFleet has been decommissioned (DSC26-53). Successor: **FleetCom** (DSC26-52).

**To fully remove**: stop the nixfleet container on csb1 and comment out in docker-compose.yml:

```bash
ssh mba@cs1.barta.cm -p 2222 "cd ~/docker && docker compose stop nixfleet"
# Then comment out nixfleet service in ~/docker/docker-compose.yml
```

---

## Docker Services

### All Containers (15 running)

| Container                   | Purpose                    |
| --------------------------- | -------------------------- |
| csb1-docmost-1              | Documentation wiki         |
| csb1-docmost-db-1           | PostgreSQL for Docmost     |
| csb1-docmost-redis-1        | Redis cache                |
| csb1-paperless-1            | Document management        |
| csb1-paperless-db-1         | PostgreSQL for Paperless   |
| csb1-paperless-redis-1      | Redis                      |
| csb1-paperless-tika-1       | Document parsing           |
| csb1-paperless-gotenberg-1  | PDF conversion             |
| csb1-traefik-1              | Reverse proxy              |
| csb1-hostdash-1             | HostDash service dashboard |
| csb1-docker-proxy-traefik-1 | Traefik proxy              |
| csb1-restic-cron-hetzner-1  | Backup (cleanup on csb0!)  |
| csb1-smtp-1                 | Mail relay                 |
| csb1-excalidraw-1           | Whiteboard (draw.barta.cm) |
| ppm                         | PAIMOS PM (pm.barta.cm)    |
| minio                       | S3 for ppm attachments     |
| paimos-www                  | paimos.com static (caddy)  |
| inspr-www                   | inspr.at static (caddy)    |

### Quick Commands

```bash
# View all containers
docker ps -a

# Restart a container
docker restart csb1-paperless-1

# View logs

# Restart all services
cd ~/docker && docker-compose down && docker-compose up -d
```

### Janus Staged Engine Smoke

The `janus-engine-staged` compose profile stays disabled and non-Traefik. Its
non-prod smoke uses the signed digest-pinned engine image, Docker-volume
non-prod age material, a non-prod metadata overlay, and a permit-bound
`janusd run` launched through the staged compose service; no production secret
or host SSH key is used.
The staged image pin in `docker-compose.yml` is the source of truth; do not
duplicate its release or digest here.

```bash
cd ~/Code/nixcfg
just janus-engine-pin-check
just janus-engine-smoke
```

Expected evidence:

```text
value_returned=false output=redacted permit_consumed=true
```

`just janus-engine-pin-check` is read-only and also runs in GitHub Actions on a
daily schedule plus relevant pin/workflow changes.

To keep a staged Rust engine instance running internally after the smoke:

```bash
just janus-engine-up
just janus-engine-status
```

The running container is profile-gated, networkless (`network_mode: none`), not
on Traefik, and still uses only the non-prod smoke volumes. It is an MCP stdio
process with a Docker healthcheck, not the public `vault.barta.cm` route. Stop
it with `just janus-engine-down`.

To prove a local MCP client path into the running staged container:

```bash
just janus-engine-mcp-smoke
```

This uses `docker exec -i janus-engine-staged janus-warden` over MCP stdio and
checks `initialize`, `tools/list`, `health`, and `list_secrets` without exposing
values or adding a network listener.

To prove the negative side of that boundary:

```bash
just janus-engine-mcp-negative-smoke
```

This uses the same local MCP stdio path and verifies that raw resolve/reveal
tools are not advertised, raw `JANUS_SMOKE` names are denied, caller-supplied
destination/executor/TTL overrides are denied, and no negative response exposes
a value or permit id.

To prove the approved-use execution boundary rejects bad permits:

```bash
just janus-engine-run-negative-smoke
```

This issues real non-prod permits through Warden, then uses `janusd run` to
verify malformed and unknown permit ids, consumed permit reuse, wrong executor,
wrong destination, expired permit metadata, and unreviewed command args all
fail without secret-bearing command output.

To run the current staged engine assurance gate:

```bash
just janus-engine-assurance
```

This primes the non-prod smoke state once, keeps `janus-engine-staged` running,
then runs the current value-free boundary matrix:

| Boundary                        | Evidence                                                                                                     |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Permit-bound positive execution | `janus-engine-smoke` proves one reviewed `request_use` + `janusd run` path, redacted output, consumed permit |
| Local MCP client path           | `mcp-exec-smoke.sh` proves `initialize`, exact `tools/list`, `health`, and `list_secrets` stay value-free    |
| MCP default-deny boundary       | `mcp-negative-smoke.sh` proves raw resolve/reveal, raw names, and caller policy overrides are denied         |
| Approved-use execution boundary | `run-negative-smoke.sh` proves malformed, unknown, reused, wrong-bound, expired, and unreviewed permits fail |

### Upgrade PAIMOS (pm.barta.cm)

Image source: `ghcr.io/markus-barta/paimos:latest` (published by the
`ci.yml` workflow on every push to main).

```bash
# On csb1 — safety backup first, then pull + swap:
ssh mba@cs1.barta.cm -p 2222
TS=$(date +%Y-%m-%d-%H%M)
mkdir -p ~/backups/paimos-$TS
docker save ghcr.io/markus-barta/paimos:latest | gzip > ~/backups/paimos-$TS/paimos-latest.tar.gz
docker run --rm -v ppm_data:/data -v ~/backups/paimos-$TS:/backup alpine \
  tar czf /backup/ppm_data.tar.gz -C /data .

# Pull + recreate:
/etc/paimos-deploy.sh
# Equivalent: (cd ~/docker && docker compose pull ppm && docker compose up -d ppm)

# Verify:
docker ps --filter name=ppm --format '{{.Image}} {{.Status}}'
curl -fsSI https://pm.barta.cm/ | head -1
docker logs ppm --tail 50
```

Rollback on failure: `docker load -i ~/backups/paimos-<TS>/paimos-latest.tar.gz`,
pin the compose `image:` line back to the saved tag, `docker compose up -d ppm`.

Data rollback (only on migration corruption — additive-only schema, very rare):
`docker compose stop ppm && docker run --rm -v ppm_data:/data -v ~/backups/paimos-<TS>:/backup alpine sh -c "rm -rf /data/* && tar xzf /backup/ppm_data.tar.gz -C /data" && docker compose up -d ppm`.

---

## Troubleshooting

### Decision Tree

```
Service Not Responding?
├─ Can SSH?
│  ├─ YES: Docker/service issue
│  │  ├─ docker ps → container running?
│  │  │  ├─ YES: Check logs: docker logs <container>
│  │  │  └─ NO: Start it: cd ~/docker && docker-compose up -d
│  │  └─ Docker down? systemctl status docker
│  └─ NO: Server/network issue
│     ├─ Try password SSH (see SECRETS.md)
│     ├─ Can ping 152.53.64.166?
│     │  ├─ YES: SSH service down → Use VNC console
│     │  └─ NO: Server down → Check Netcup panel
│     └─ Last resort: VNC console (Netcup SCP)

```

### Common Issues & Quick Fixes

```
Paperless down → docker restart csb1-paperless-1
Backup failed → docker logs csb1-restic-cron-hetzner-1
High load → Check docker stats (find heavy container)
SSL Error 526 (Cloudflare) → CF API token expired; see below
```

### SSL / TLS Certificate Renewal (Cloudflare DNS-01)

Traefik uses `secrets/traefik-variables.age` (shared with csb0) for ACME DNS-01 via Cloudflare API.

**Symptom:** Cloudflare Error 526 on all `*.barta.cm` services; Traefik logs show:
`status code 403 — 9109: Invalid access token`

**Token rotation (last done: 2026-03-06, stored in 1Password as "dns-token-2026-03-06"):**

1. Cloudflare Dashboard → Profile → API Tokens → Create Token
   - Permission: `Zone / DNS / Edit` scoped to `barta.cm` (no TTL, no IP filter)
2. Save new token to 1Password; name entry with date
3. Re-encrypt: `cd ~/Code/nixcfg && agenix -e secrets/traefik-variables.age`
4. Commit + push; deploy both csb0 and csb1
5. `docker restart csb1-traefik-1` to trigger immediate cert renewal
6. Verify: `docker logs csb1-traefik-1 --tail 50 2>&1 | grep -i acme`

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

Static IP `152.53.64.166/24` is configured declaratively in NixOS.
Gateway: `152.53.64.1` | DNS: `8.8.8.8`, `8.8.4.4`

### 🚨 Historical Incident: 2025-12-05 Network Loss

**Symptom:** Server became unreachable immediately after `nixos-rebuild switch`.
**Root Cause:** The configuration used NetworkManager (`networking.networkmanager.enable = true`) but did not define a static IP declaratively. On a fresh generation switch, the imperative connection profile was lost, and NetworkManager didn't know how to bring up the interface.
**Recovery:** Had to boot with `init=/bin/sh`, manually bring up `ens3` with `ip addr add` and `ip link set`, and then start `sshd -o UsePAM=no` to regain access and fix the configuration.
**Fix:** Always define static networking declaratively for servers (`networking.interfaces.ens3...`) and set a `hashedPassword` for the `mba` user for VNC console recovery.

### If SSH Fails

1. Login to Netcup SCP (https://www.servercontrolpanel.de/SCP)
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
/nix/store/m1b[Tab]/bin/ip addr add 152.53.64.166/24 dev ens3
/nix/store/m1b[Tab]/bin/ip link set ens3 up
/nix/store/m1b[Tab]/bin/ip route add default via 152.53.64.1

# Continue normal boot
exec /nix/var/nix/profiles/system/init
```

**Note:** Busybox ash shell is worse than bash (no arrow-up, no Tab). If you accidentally enter it, type `exit` to return to bash.

### Netcup API Emergency Restart

```bash
# Get token and restart (see SECRETS.md for refresh token location)
TOKEN=$(curl -s 'https://servercontrolpanel.de/realms/scp/protocol/openid-connect/token' \
  -d 'client_id=scp' -d "refresh_token=$(cat ~/Code/nixcfg/hosts/csb1/secrets/netcup-api-refresh-token.txt)" \
  -d 'grant_type=refresh_token' | jq -r '.access_token') && \
curl -X POST "https://servercontrolpanel.de/scp-core/api/v1/servers/646294/reset" \
  -H "Authorization: Bearer $TOKEN"
```

### Single Service Restore (Example: Docmost)

```bash
docker-compose down docmost
docker exec csb1-restic-cron-hetzner-1 restic restore latest \
  --target /tmp/restore --path /backup/var/lib/docker/volumes/csb1_docmost_data
sudo cp -a /tmp/restore/backup/var/lib/docker/volumes/csb1_docmost_data/* \
  /var/lib/docker/volumes/csb1_docmost_data/
docker-compose up -d docmost
```

---

## Backup System

### ⚠️ Shared Repository with csb0

- Both servers backup to the same Hetzner repository
- Snapshots identified by hostname (csb0 vs csb1)
- **Cleanup managed by csb0** (runs at 03:15 AM daily)

### Schedule

| Task    | Time                   | Container                  |
| ------- | ---------------------- | -------------------------- |
| Backup  | 01:30 AM daily         | csb1-restic-cron-hetzner-1 |
| Cleanup | N/A (done on csb0)     | -                          |
| Check   | 05:30 AM monthly (1st) | csb1-restic-cron-hetzner-1 |

### What Gets Backed Up

```
✅ /var/lib/docker/volumes - ALL Docker volumes
   └─ Docmost, Paperless data
✅ /home - All user home directories
✅ /root - Root user data
✅ /etc - System configuration
❌ Exclusions: */cache/*, *.log*
```

### Check Backup Status

```bash
# View logs
docker logs csb1-restic-cron-hetzner-1 | tail -50

# List snapshots
docker exec csb1-restic-cron-hetzner-1 restic snapshots
```

---

## Service Dependencies

```
(influx/grafana retired 2026-06-12, NIX-193 — archive on hsb1)
```

---

## Maintenance

### Clean Up Disk Space

```bash
ssh mba@cs1.barta.cm -p 2222 "docker system prune -f"
```

### View Logs

```bash
# Current boot
ssh mba@cs1.barta.cm -p 2222 "journalctl -b -e"

# Follow logs
ssh mba@cs1.barta.cm -p 2222 "journalctl -f"
```

---

## Web Interfaces

| Service    | URL                        | Auth                          |
| ---------- | -------------------------- | ----------------------------- |
| Paperless  | https://paperless.barta.cm | Paperless login               |
| Docmost    | https://docmost.barta.cm   | Docmost login                 |
| Excalidraw | https://draw.barta.cm      | Cloudflare Access (email OTP) |

### Excalidraw Access Management

Protected via **Cloudflare Zero Trust** → Access → Applications → `Excalidraw`.

- Auth method: One-time PIN (email)
- Policy: email allowlist (family + friends)
- To add/remove users: Cloudflare Zero Trust dashboard → Access → Applications → Excalidraw → Edit policy

---

## Services to Archive Post-Migration

### Hedgedoc ❌ DECOMMISSIONED

- **Status**: Will not be migrated
- **Volumes to archive**: `csb1_hedgedoc-app-uploads`, `csb1_hedgedoc-db-data`

---

## Related Documentation

- [csb1 README](../README.md) - Full server documentation
- [SECRETS.md](../secrets/SECRETS.md) - All credentials (gitignored)
- [DEPRECATED-RUNBOOK.md](../secrets/DEPRECATED-RUNBOOK.md) - Old runbook with inline secrets
- [csb0 Runbook](../../csb0/docs/RUNBOOK.md) - Smart home hub (dependency)
