# csb0 - Cloud Server Barta 0

**Status**: ⏳ READY TO DEPLOY - External Hokage migration
**Type**: Cloud Server (Netcup VPS 1000 G11)
**OS**: NixOS 25.11 (Xantusia)
**Uptime**: 267+ days (last checked 2025-12-05)
**Primary Domain**: cs0.barta.cm

---

## Quick Reference

| Item          | Value                                   |
| ------------- | --------------------------------------- |
| **Hostname**  | csb0                                    |
| **Domain**    | cs0.barta.cm                            |
| **IP (v4)**   | 85.235.65.226                           |
| **SSH**       | `ssh -p 2222 mba@cs0.barta.cm` or `qc0` |
| **Provider**  | Netcup VPS 1000 G11                     |
| **Location**  | Vienna (VIE)                            |
| **Server ID** | 607878                                  |

---

## ⚠️ Critical Services

| Service      | Domain           | Impact if Down                    |
| ------------ | ---------------- | --------------------------------- |
| **Node-RED** | home.barta.cm    | 🔴 Smart home automation stops    |
| **MQTT**     | -                | 🔴 IoT devices disconnect + csb1! |
| **Telegram** | -                | 🔴 Garage door control BROKEN     |
| **Backup**   | -                | 🔴 BOTH servers lose backups      |
| Traefik      | traefik.barta.cm | SSL/routing                       |
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
│   └── SSH-KEY-SECURITY-NOTE.md
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
    ├── RUNBOOK.md         # Emergency procedures
    └── netcup-api-refresh-token.txt
```

---

## Services (Docker)

| Service      | Domain           | Purpose                    |
| ------------ | ---------------- | -------------------------- |
| Node-RED     | home.barta.cm    | Smart home automation      |
| Mosquitto    | -                | MQTT broker (IoT + csb1)   |
| Telegram Bot | -                | Garage door, notifications |
| Traefik      | traefik.barta.cm | Reverse proxy & SSL        |
| Cypress      | -                | Solar data scraping        |
| Restic       | -                | Backup (BOTH servers!)     |

All services run via Docker Compose with Traefik handling SSL.

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

**Status**: ⏳ **READY TO DEPLOY** (csb1 successful ✅)

| Item                     | Status         |
| ------------------------ | -------------- |
| Flake evaluates          | ✅ PASS        |
| Password auth safety net | ✅ Added       |
| uzumaki/server.nix       | ✅ Imported    |
| SSH key security         | ✅ lib.mkForce |

See `docs/MIGRATION-PLAN-HOKAGE.md` for full plan.

---

## Backup (CRITICAL)

| Target          | Method | Content                |
| --------------- | ------ | ---------------------- |
| Hetzner Storage | restic | Docker volumes, config |

⚠️ **This server manages backups for BOTH csb0 AND csb1!**

See `secrets/RUNBOOK.md` for credentials and restore procedures.

---

## Network

### SSH (Hardened)

- Port: **2222** (not 22)
- Password auth: Disabled (after migration)
- Root login: Disabled
- Key auth only

### Firewall

| Port | Service         | Access     |
| ---- | --------------- | ---------- |
| 2222 | SSH             | Open       |
| 80   | HTTP (redirect) | Open       |
| 443  | HTTPS (Traefik) | Open       |
| 22   | SSH (standard)  | **Closed** |

---

## Related

- **csb1**: Grafana, InfluxDB (receives MQTT from csb0)
- **hsb1**: Monitors csb0/csb1 via Netcup API (daily at 19:00)

---

## Emergency

See `secrets/RUNBOOK.md` for:

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
