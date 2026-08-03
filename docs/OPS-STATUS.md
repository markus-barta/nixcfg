# Operations Status

📍 TL;DR: Infrastructure inventory and backup status. NixFleet decommissioned — **FleetCom** (DSC26-52) is the successor.

## Fleet Management

**NixFleet** has been decommissioned (DSC26-53). Its successor **FleetCom** is in development.

Previously provided:

- Fleet Dashboard: Real-time status of all hosts.
- Automated Deployments: Unified `just` recipes for NixOS and Home Manager.
- Backup Tracking: (WIP) Monitoring of restic and ZFS snapshots.

---

## Infrastructure Inventory

| •   | Host    | OS      | Type      | Backup Method    | Status | Destination         | Updated          |
| :-- | :------ | :------ | :-------- | :--------------- | :----: | :------------------ | :--------------- |
| 🌐  | csb0    | NixOS   | Server    | `restic-cron`    |   🟢   | Hetzner Storage Box | 2026-01-11 13:55 |
| 🌐  | csb1    | NixOS   | Server    | `restic-cron`    |   🟢   | Hetzner (Shared)    | 2026-01-11 13:55 |
| 🎮  | stm2607 | SteamOS | Appliance | TBD (OPS/Pharos) |   🔴   | (OPS-17)            | 2026-07-23       |
| 🏠  | hsb0    | NixOS   | Server    | `restic-cron`    |   🟢   | Hetzner (Shared)    | 2026-08-03 14:35 |
| 🏠  | hsb1    | NixOS   | Server    | `restic-cron`    |   🟡   | Hetzner (Shared)    | 2026-01-11 15:55 |
| 🏠  | hsb8    | NixOS   | Server    | `restic-cron`    |   🟢   | Hetzner (Shared)    | 2026-08-03 20:45 |
| 🏠  | hsb9    | NixOS   | Server    | `restic-cron`    |   🟢   | Hetzner (Shared)    | 2026-08-03 20:45 |
| 💻  | mbp0    | macOS   | Portable  | Time Machine     |   ⚪   | External Drive      | 2026-01-11 11:45 |
| 💻  | mbp2607 | macOS   | Portable  | Time Machine     |   ⚪   | External Drive      | 2026-08-02 19:50 |

<!-- 🏢  miniserver-bp moved out of this repo on 2026-05-02 (INSPR-24) -->
<!-- 🎮  gpc0 retired 2026-07 → stm2607 (SteamOS appliance, OPS/Pharos, OPS-17). nixcfg teardown COMPLETED 2026-07-26 (OPS-22) — do not re-add. -->

**Legend:** 🏠 Home | 🌐 Cloud | 🏢 Office | 🎮 Gaming | 🖥️ iMac | 💻 MacBook
**Status:** 🔴 Snapshot/None | 🟡 Restic (Unverified) | 🟢 Restic (Verified) | ⚪ Time Machine (Ext)
