# csb0 - Cloud Server Barta 0

**Status**: ✅ Running (Hokage + Uzumaki)
**Type**: Cloud Server (Netcup VPS 1000 G11)
**OS**: NixOS 26.05 (Warbler)
**Config**: External Hokage (`github:pbek/nixcfg`) + Uzumaki modules
**Primary Domain**: cs0.barta.cm
**Last Deploy**: 2025-12-06 (reboot verified ✅)

---

## Quick Reference

| Item          | Value                                   |
| ------------- | --------------------------------------- |
| **Hostname**  | csb0                                    |
| **Domain**    | cs0.barta.cm                            |
| **IP (v4)**   | 89.58.63.96                             |
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

| Service      | Domain           | Purpose                    |
| ------------ | ---------------- | -------------------------- |
| Node-RED     | home.barta.cm    | Smart home automation      |
| Mosquitto    | -                | MQTT broker (IoT + csb1)   |
| Telegram Bot | -                | Garage door, notifications |
| Traefik      | traefik.barta.cm | Reverse proxy & SSL        |
| Headscale    | hs.barta.cm      | Self-hosted Tailscale VPN  |
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
