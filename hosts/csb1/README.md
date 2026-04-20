# csb1 - Cloud Server Barta 1

**Status**: ✅ Running (Hokage + Uzumaki)
**Type**: Cloud Server (Netcup VPS 1000 G11)
**OS**: NixOS 26.05 (Warbler)
**Config**: External Hokage (`github:pbek/nixcfg`) + Uzumaki modules
**Primary Domain**: cs1.barta.cm
**Last Deploy**: 2025-12-06 (reboot verified ✅)

---

## Quick Reference

| Item          | Value                                   |
| ------------- | --------------------------------------- |
| **Hostname**  | csb1                                    |
| **Domain**    | cs1.barta.cm                            |
| **IP (v4)**   | 152.53.64.166                           |
| **IP (v6)**   | 2a0a:4cc0:80:2d5:e8e8:c7ff:fe68:03c7    |
| **SSH**       | `ssh -p 2222 mba@cs1.barta.cm` or `qc1` |
| **Provider**  | Netcup VPS 1000 G11                     |
| **Location**  | Vienna (VIE)                            |
| **Server ID** | 646294                                  |
| **FQDN**      | v2202407214994279426.bestsrv.de         |
| **Exposure**  | Internet-exposed (ports 80, 443, 2222)  |

---

## Features

| ID  | Technical         | User-Friendly                         | Test |
| --- | ----------------- | ------------------------------------- | ---- |
| F00 | NixOS Base System | Stable foundation with generations    | T00  |
| F01 | Docker Services   | Container orchestration (15 services) | T01  |
| F02 | Grafana           | Monitoring dashboards                 | T02  |
| F03 | InfluxDB          | Time series database for IoT data     | T03  |
| F04 | Traefik           | Reverse proxy with auto SSL           | T04  |
| F05 | Backup System     | Restic to Hetzner (shared with csb0)  | T05  |
| F06 | SSH Access        | Hardened SSH on port 2222             | T06  |
| F07 | ZFS Storage       | Reliable storage with compression     | T07  |
| F08 | Paperless-ngx     | Document management                   | -    |
| F09 | Docmost           | Documentation wiki                    | -    |

---

## Folder Structure

```
hosts/csb1/
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
│   ├── T02-grafana.sh
│   ├── T03-influxdb.sh
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
│   └── 2025-11-hokage/    # ✅ Completed 2025-11-29
│
├── archive/               # 📂 Historical configurations
│   └── 2025-11-29-pre-hokage/  # Pre-migration backup
│
└── secrets/               # 🔒 Sensitive data (gitignored)
    ├── runbook-secrets.md # Emergency procedures & credentials
    └── netcup-api-refresh-token.txt
```

---

## Services (Docker)

| Service       | Domain             | Purpose                          |
| ------------- | ------------------ | -------------------------------- |
| PAIMOS (ppm)  | pm.barta.cm        | Project management (paimos v1.x) |
| Grafana       | grafana.barta.cm   | Monitoring dashboards            |
| InfluxDB      | influxdb.barta.cm  | Time series database             |
| Docmost       | docmost.barta.cm   | Documentation/wiki               |
| Paperless-ngx | paperless.barta.cm | Document management              |
| Hedgedoc      | hdoc.barta.cm      | Collaborative markdown           |
| Traefik       | -                  | Reverse proxy & SSL              |

All services run via Docker Compose with Traefik handling SSL (15 containers).

---

## Common Operations

### Health Check

```bash
# Run all health tests
cd hosts/csb1/tests
for f in T*.sh; do ./$f; done
```

### Update Configuration

```bash
ssh -p 2222 mba@cs1.barta.cm
cd ~/nixcfg
git pull
sudo nixos-rebuild switch --flake .#csb1
```

### Pre-Restart Safety

```bash
cd hosts/csb1/scripts
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

## Migration History

### Hokage + Uzumaki Migration (2025-12-06) ✅

Migrated to external Hokage + new Uzumaki pattern with StaSysMo.

| Milestone                   | Status |
| --------------------------- | ------ |
| External Hokage deployed    | ✅     |
| Uzumaki new pattern         | ✅     |
| StaSysMo monitoring enabled | ✅     |
| Static IP lockout fix       | ✅     |
| Reboot verified             | ✅     |

See `docs/MIGRATION-PLAN-HOKAGE.md` for incident report (2025-12-05).

---

## Backup

| Target          | Method | Content                |
| --------------- | ------ | ---------------------- |
| Hetzner Storage | restic | Docker volumes, config |

See `secrets/runbook-secrets.md` for credentials and restore procedures.

---

## Network

### Static IP Configuration

| Setting        | Value                 |
| -------------- | --------------------- |
| **IP Address** | `152.53.64.166/24`    |
| **Gateway**    | `152.53.64.1`         |
| **DNS**        | `8.8.8.8`, `8.8.4.4`  |
| **Interface**  | `ens3` (NM unmanaged) |

### SSH (Hardened)

- Port: **2222** (not 22)
- Password auth: **enabled** (recovery fallback)
- Root login: **disabled**
- Key auth: Primary method (mba + hsb1/miniserver24)

### Firewall

| Port | Service         | Access     |
| ---- | --------------- | ---------- |
| 2222 | SSH             | Open       |
| 80   | HTTP (redirect) | Open       |
| 443  | HTTPS (Traefik) | Open       |
| 22   | SSH (standard)  | **Closed** |

---

## Related

- **csb0**: Node-RED, MQTT broker (feeds data to Grafana/InfluxDB)
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
ED25519: SHA256:XdDgST6kJOAsTOiiBCe04sEK5KbX1qDeS9DkeGAUa5s
RSA:     SHA256:FZiajhINn73JIXq5gCFWBdQLlwvPzLbHCyWcv5mdkJ4
ECDSA:   SHA256:U/94/tD0laaeI48MaxA0wqGE1LHq6OlBE3WH8jYN5OM
```
