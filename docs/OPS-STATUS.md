# Operations Status

📍 TL;DR: Infrastructure inventory and backup status. Managed via **NixFleet**.

## NixFleet Overview

**NixFleet** is the central management tool for this infrastructure. It provides:

- **Fleet Dashboard**: Real-time status of all hosts.
- **Automated Deployments**: Unified `just` recipes for NixOS and Home Manager.
- **Backup Tracking**: (WIP) Monitoring of restic and ZFS snapshots.

---

## Infrastructure Inventory

| •   | Host          | OS    | Type    | Backup Method | Status | Destination             | Updated          |
| :-- | :------------ | :---- | :------ | :------------ | :----: | :---------------------- | :--------------- |
| 🌐  | csb0          | NixOS | Server  | `restic-cron` |   🟢   | Hetzner Storage Box     | 2026-01-11 13:55 |
| 🌐  | csb1          | NixOS | Server  | `restic-cron` |   🟢   | Hetzner (Shared)        | 2026-01-11 13:55 |
| 🎮  | gpc0          | NixOS | Desktop | ZFS Snapshots |   🔴   | Local Pool (`mbazroot`) | 2026-01-11 11:45 |
| 🏠  | hsb0          | NixOS | Server  | `restic-cron` |   🟡   | Hetzner (Shared)        | 2026-01-11 15:55 |
| 🏠  | hsb1          | NixOS | Server  | `restic-cron` |   🟡   | Hetzner (Shared)        | 2026-01-11 15:55 |
| 🏠  | hsb8          | NixOS | Server  | ZFS Snapshots |   🔴   | Local Pool (`zroot`)    | 2026-01-11 11:45 |
| 🖥️  | imac0         | macOS | Desktop | Time Machine  |   ⚪   | External Drive          | 2026-01-11 11:45 |
| 🖥️  | mba-imac-work | macOS | Desktop | Time Machine  |   ⚪   | External Drive          | 2026-01-11 11:45 |
| 💻  | mba-mbp-work  | macOS | Desktop | Time Machine  |   ⚪   | External Drive          | 2026-01-11 11:45 |
| 🏢  | miniserver-bp | NixOS | Server  | ZFS Snapshots |   🔴   | Office Jump Host        | 2026-01-11 11:55 |

**Legend:** 🏠 Home | 🌐 Cloud | 🏢 Office | 🎮 Gaming | 🖥️ iMac | 💻 MacBook
**Status:** 🔴 Snapshot/None | 🟡 Restic (Unverified) | 🟢 Restic (Verified) | ⚪ Time Machine (Ext)
