# csb0 - Cloud Server Barta 0

**Status**: ✅ Running (Hokage + Uzumaki)
**Type**: Cloud Server (Netcup VPS 1000 G11)
**OS**: NixOS 26.05 (Warbler)
**Config**: External Hokage (`github:pbek/nixcfg`) + Uzumaki modules
**Primary Domain**: cs0.barta.cm
**Last Deploy**: 2025-12-06 (reboot verified ✅)

---

## Quick Reference

| Item              | Value                                   |
| ----------------- | --------------------------------------- |
| **Hostname**      | csb0                                    |
| **Domain**        | cs0.barta.cm                            |
| **Dashboard**     | https://cs0.barta.cm/ (Zitadel-gated)   |
| **Dashboard IPs** | Redirect to canonical HTTPS dashboard   |
| **IP (v4)**       | 89.58.63.96                             |
| **Tailscale**     | 100.64.0.8                              |
| **SSH**           | `ssh -p 2222 mba@cs0.barta.cm` or `qc0` |
| **Provider**      | Netcup VPS 1000 G11                     |
| **Location**      | Vienna (VIE)                            |
| **Server ID**     | 607878                                  |

---

## ⚠️ Critical Services

| Service      | Domain           | Impact if Down                    |
| ------------ | ---------------- | --------------------------------- |
| **Node-RED** | home.barta.cm    | 🔴 Smart home automation stops    |
| **MQTT**     | -                | 🔴 IoT devices disconnect + csb1! |
| **Telegram** | -                | 🔴 Garage door control BROKEN     |
| **Backup**   | -                | 🔴 BOTH servers lose backups      |
| HostDash     | cs0.barta.cm     | Zitadel-gated service dashboard   |
| Traefik      | cs0.barta.cm/api | SSL/routing                       |
| Headscale    | hs.barta.cm      | VPN control server (mesh network) |
| Cypress      | -                | Solar scraping                    |

---

## Folder Structure

```
hosts/csb0/
├── configuration.nix       # Main NixOS configuration (Hokage)
├── hardware-configuration.nix
├── disk-config.zfs.nix
├── README.md              # This file
│
├── docs/                  # 📚 Documentation
│   ├── MIGRATION-PLAN-HOKAGE.md
│   └── RUNBOOK.md
│
├── tests/                 # ✅ Repeatable health checks (T00-T07)
│   ├── T00-nixos-base.sh
│   ├── T01-docker-services.sh
│   ├── T02-nodered.sh
│   ├── T03-mqtt.sh
│   ├── T04-traefik.sh
│   ├── T05-backup-system.sh
│   ├── T06-ssh-access.sh
│   └── T07-zfs-storage.sh
│
├── scripts/               # 🔧 Operational utilities
│   ├── netcup-api.sh      # API connectivity test
│   └── restart-safety.sh  # Pre-restart checklist
│
├── migrations/            # 📦 One-time migration scripts
│   └── 2025-11-hokage/    # Planned migration
│
└── secrets/               # 🔒 Sensitive data (gitignored)
    ├── runbook-secrets.md # Emergency procedures & credentials
    └── netcup-api-refresh-token.txt
```

---

## Services (Docker)

| Service      | Domain           | Purpose                         |
| ------------ | ---------------- | ------------------------------- |
| Node-RED     | home.barta.cm    | Smart home automation           |
| Mosquitto    | -                | MQTT broker (IoT + csb1)        |
| Telegram Bot | -                | Garage door, notifications      |
| HostDash     | cs0.barta.cm     | Zitadel-gated service dashboard |
| Traefik      | cs0.barta.cm/api | Reverse proxy & SSL             |
| Headscale    | hs.barta.cm      | Self-hosted Tailscale VPN       |
| Cypress      | -                | Solar data scraping             |
| Restic       | -                | Backup (BOTH servers!)          |

All services run via Docker Compose with Traefik handling SSL.

### Node-RED startup (OPS-603 / OPS-605)

`docker/compose-spec.nix` pins Node-RED `5.0.9-24` by image index digest and
generates `/opt/nixcfg/nodered-startup.sh`, mounted read-only. The existing
`nodered-scripts:/scripts` volume stays mounted; its old `startup.sh` is no longer
executed.

The wrapper checks `/data/node_modules` for telegrambot `19.0.3`, influxdb `0.7.0`
and cheerio `1.2.0`. It installs only missing or mismatched versions into the
persistent `nodered-data:/data` userDir. Once installed, restarts and recreates
need no npm access. Installs use a 30-second fetch timeout and one fetch retry;
these are per-request limits, not a deadline for the whole install. An install
failure logs `WARN: Node-RED add-on` and the wrapper still hands over to Node-RED.
This does **not** guarantee a working runtime:

- Missing telegrambot types on enabled tabs make Node-RED wait for missing types:
  **no flows start**, including the gate, lock and HTTP endpoints. Only the editor
  is available. The process stays up, so `restart: unless-stopped` does not retry
  installation; a manual restart is required.
- If `/data/settings.js` unconditionally requires cheerio in
  `functionGlobalContext`, missing cheerio makes Node-RED fail at startup and the
  container restart-loop, retrying npm on each start. If the require is guarded
  or absent, startup may succeed, but functions expecting `global.get('cheerio')`
  can still fail. The coordinator must check the actual settings before switching.

#### Pre-stage and first switch (coordinator only)

Run these steps on csb0 immediately before the separately announced switch.
They are not workstation build or switch instructions.

1. Check `/data/settings.js` for cheerio and influxdb references without exposing
   unrelated settings or credentials. Establish whether cheerio's require is
   guarded, and record the expected failure behaviour in the switch evidence.
   Record the previous NixOS generation for rollback.
2. Select the running container and back up the npm manifests privately in the
   persistent volume. Also snapshot the installed module names: npm can prune
   modules not recorded in `/data/package.json`, including existing `@influxdata`
   content. Record absent manifests rather than assuming they exist.

   ```bash
   nodered_container="$(docker ps -q \
     --filter label=com.docker.compose.project=csb0 \
     --filter label=com.docker.compose.service=nodered)"
   test -n "$nodered_container"
   nodered_backup="/data/ops605-pre-switch-$(date -u +%Y%m%dT%H%M%SZ)"
   docker exec "$nodered_container" sh -eu -c '
     umask 077
     mkdir "$1"
     for file in package.json package-lock.json; do
       if [ -f "/data/$file" ]; then
         cp -p "/data/$file" "$1/$file"
       else
         touch "$1/$file.absent"
       fi
     done
     ls -1 /data/node_modules > "$1/node_modules.before"
     if [ -d /data/node_modules/@influxdata ]; then
       ls -1 /data/node_modules/@influxdata > "$1/influxdata.before"
     fi
   ' sh "$nodered_backup"
   ```

3. Pre-install all three exact versions while the old process is still running:

   ```bash
   docker exec "$nodered_container" npm install --prefix /data --save-exact \
     --no-audit --no-update-notifier --no-fund --omit=dev \
     --fetch-timeout=30000 --fetch-retries=1 \
     node-red-contrib-telegrambot@19.0.3 node-red-contrib-influxdb@0.7.0 cheerio@1.2.0
   ```

   If installation fails, postpone the switch and investigate. The running process
   does not rescan its modules, so pre-staging does not load a second copy.
   **Do not restart the old container between pre-staging and the switch**: it
   would then see add-ons in both `/usr/src/node-red/node_modules` and `/data`.
   If abandoning the switch, use the rollback uninstall step below before any
   restart of the old container.

4. Check all three versions using the wrapper's probe (expected output, in order:
   `19.0.3`, `0.7.0`, `1.2.0`):

   ```bash
   for package in node-red-contrib-telegrambot node-red-contrib-influxdb cheerio; do
     docker exec "$nodered_container" node -p \
       "require('/data/node_modules/$package/package.json').version"
   done
   ```

   Compare `/data/package.json` and `/data/package-lock.json` with their backups,
   and compare `ls -1 /data/node_modules` and the `@influxdata` scope with the saved
   listings. Resolve unexpected removals before proceeding; keep these private
   snapshots for recovery. Proceed only if every version matches.

5. Switch through the approved host runbook. The first switch must **recreate**
   the container from the pinned image, discarding the old container-layer
   add-ons under `/usr/src/node-red/node_modules`. Add-ons then load only from
   `/data`, avoiding duplicate registration. With pre-staging verified, this first
   start needs no npm. Refresh `nodered_container` using the selection command above
   after recreation, repeat the probes and module comparison, and check logs for
   warnings, missing types and duplicate registrations. Confirm flows start using
   passive status/log checks; device or Telegram actions require separate approval.
   A coordinated restart without npm access should then leave all three probes
   matching and produce no install warnings.

#### Recovery after an install failure

Once the registry is reachable, refresh `nodered_container` with the selection
command above, run `docker restart "$nodered_container"`, and repeat the three
version probes. Check `docker logs --since 5m "$nodered_container"` for
`WARN: Node-RED add-on`, `Waiting for missing types`, settings errors and duplicate
registrations, and confirm that flows actually start. An up container or reachable
editor alone does not prove recovery. The wrapper retries missing or mismatched
packages on each start; it does not retry while Node-RED stays running.

#### Rollback of the first switch

The preserved `nodered-scripts:/scripts` volume and its old `startup.sh` are needed
for rollback. The previous generation uses `latest` and installs into
`/usr/src/node-red/node_modules`, so rollback needs npm access and must not leave
the same add-ons in `/data`.

During coordinated downtime, refresh `nodered_container` with the selection
command above. While the current container can still accept exec, remove the
userDir copies **before** switching back:

```bash
docker exec "$nodered_container" npm uninstall --prefix /data --no-audit --no-fund \
  node-red-contrib-telegrambot node-red-contrib-influxdb cheerio
```

After a successful uninstall, stop this container to prevent its wrapper from
reinstalling the packages on an intervening restart. Then roll back to the
recorded previous generation through the host runbook and
ensure Node-RED is recreated with the old entrypoint. This ordering matters:
generation activation automatically reconciles Compose, so rolling back first
could start the old installer while both copies still exist. If the container is
restart-looping, stop it and perform the same uninstall in a maintenance container
with the pinned image, the existing data volume and a shell entrypoint; do not
start Node-RED there. Compare the manifests/module listings with the pre-stage
backup and resolve unexpected removals. Check logs for missing types, settings
errors and duplicate registrations, and confirm flows start before ending downtime.

To bump, update the image tag and verified index digest together, update the exact
add-on versions in the wrapper, and run `python3 tests/T119-nodered-startup.py`
(updating its expected pins deliberately). Validate affected flows before switching.

---

## Common Operations

### Health Check

```bash
cd hosts/csb0/tests
for f in T*.sh; do ./$f; done
```

### Pre-Restart Safety

```bash
cd hosts/csb0/scripts
./restart-safety.sh
```

### Rollback

```bash
# Via SSH
sudo nixos-rebuild switch --rollback

# Via VNC (if SSH broken)
# 1. Netcup SCP → VNC Console
# 2. GRUB menu → Select previous generation
```

---

## Migration Status

**Goal**: Migrate from local mixins to external Hokage modules

**Status**: ✅ **COMPLETED** (2025-12-06)

| Item                     | Status      |
| ------------------------ | ----------- |
| External Hokage deployed | ✅ COMPLETE |
| Uzumaki new pattern      | ✅ COMPLETE |
| StaSysMo monitoring      | ✅ ENABLED  |
| Static IP lockout fix    | ✅ APPLIED  |
| Reboot verified          | ✅ PASS     |

### Incident Note (2025-12-06)

Initial deploy failed due to incorrect network configuration:

- Wrong subnet: `/24` instead of `/22`
- Wrong gateway: `85.235.65.1` instead of `85.235.64.1`

Fixed after DHCP analysis. See `docs/MIGRATION-PLAN-HOKAGE.md` for details.

---

## Backup (CRITICAL)

| Target          | Method | Content                |
| --------------- | ------ | ---------------------- |
| Hetzner Storage | restic | Docker volumes, config |

⚠️ **This server manages backups for BOTH csb0 AND csb1!**

See `secrets/runbook-secrets.md` for credentials and restore procedures.

---

## Network

### Static IP Configuration

| Setting        | Value                            |
| -------------- | -------------------------------- |
| **IP Address** | `89.58.63.96/22`                 |
| **Gateway**    | `89.58.60.1`                     |
| **DNS**        | `46.38.225.230`, `46.38.252.230` |
| **Interface**  | `ens3` (NM unmanaged)            |

⚠️ **CRITICAL**: Subnet is `/22` (NOT `/24`!) - Gateway is in `.64` subnet.

### SSH (Hardened)

- Port: **2222** (not 22)
- Password auth: Enabled (recovery fallback)
- Root login: Disabled
- Key auth: Primary method

### Firewall

| Port | Service         | Access     |
| ---- | --------------- | ---------- |
| 2222 | SSH             | Open       |
| 80   | HTTP (redirect) | Open       |
| 443  | HTTPS (Traefik) | Open       |
| 22   | SSH (standard)  | **Closed** |

---

## Related

- **csb1**: Docmost, Paperless, PPM (influx/grafana retired 2026-06-12, NIX-193)
- **hsb1**: Monitors csb0/csb1 via Netcup API (daily at 19:00)

---

## Emergency

See `secrets/runbook-secrets.md` for:

- VNC console access
- Netcup API commands
- Recovery procedures
- Backup restore
- All credentials

---

## SSH Fingerprints

```
# Run on server to get fingerprints:
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
ssh-keygen -lf /etc/ssh/ssh_host_rsa_key.pub
ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub
```
