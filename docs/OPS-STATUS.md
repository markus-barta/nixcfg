# Operations Status

📍 TL;DR: Infrastructure inventory and backup status. Managed via **NixFleet**.

## NixFleet Overview

**NixFleet** is the central management tool for this infrastructure. It provides:

- **Fleet Dashboard**: Real-time status of all hosts.
- **Automated Deployments**: Unified `just` recipes for NixOS and Home Manager.
- **Backup Tracking**: (WIP) Monitoring of restic and ZFS snapshots.

---

## Host Status

| •   | Host          | OS    | Type    | Comment                                      |
| :-- | :------------ | :---- | :------ | :------------------------------------------- |
| 🏠  | hsb0          | NixOS | Server  | DNS/DHCP. Managed via NixFleet.              |
| 🏠  | hsb1          | NixOS | Server  | Smart Home Hub. Managed via NixFleet.        |
| 🏠  | hsb8          | NixOS | Server  | Parents' Home Server. Managed via NixFleet.  |
| 🌐  | csb0          | NixOS | Server  | Cloud Gateway. Managed via NixFleet.         |
| 🌐  | csb1          | NixOS | Server  | Monitoring/Fleet Host. Managed via NixFleet. |
| 🎮  | gpc0          | NixOS | Desktop | Gaming PC. Managed via NixFleet.             |
| 🖥️  | imac0         | macOS | Desktop | Workstation. Managed via NixFleet.           |
| 🖥️  | mba-imac-work | macOS | Desktop | Work iMac. Managed via NixFleet.             |
| 💻  | mba-mbp-work  | macOS | Desktop | MacBook Pro. Managed via NixFleet.           |

**Legend:** 🏠 Home | 🌐 Cloud | 🎮 Gaming | 🖥️ iMac | 💻 MacBook

---

## Backup Inventory

| Host       | Method        | Destination             | Validation / Monitoring                                   |
| :--------- | :------------ | :---------------------- | :-------------------------------------------------------- |
| **csb0**   | `restic-cron` | Hetzner Storage Box     | `docker exec csb0-restic-cron-hetzner-1 restic snapshots` |
| **csb1**   | `restic-cron` | Hetzner (Shared)        | `docker exec csb1-restic-cron-hetzner-1 restic snapshots` |
| **hsb0**   | ZFS Snapshots | Local Pool (`zroot`)    | `just test hsb0 T11` (Daily auto-snapshots)               |
| **hsb1**   | `restic-cron` | Hetzner Storage Box     | `docker exec restic-cron-hetzner restic snapshots`        |
| **hsb8**   | ZFS Snapshots | Local Pool (`zroot`)    | `just test hsb8 T12` (Manual snapshots)                   |
| **gpc0**   | ZFS Snapshots | Local Pool (`mbazroot`) | `zfs list -t snapshot` (No persistent data backup)        |
| **imac0**  | Time Machine  | External Drive          | macOS `tmutil latestbackup`                               |
| **mba-\*** | Time Machine  | External Drive          | macOS System Settings                                     |

---
