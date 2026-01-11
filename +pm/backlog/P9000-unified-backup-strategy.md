# P9000: Unified Backup Strategy & Tiered Verification

## 🎯 Vision

- **Universal Target**: All hosts (NixOS, macOS, Linux) backup to Hetzner Storage Box.
- **Declarative Orchestration**: "Tick a box" in NixFleet/Nix config to enable backups automagically.
- **Automated Verification**: Integrity checks beyond "process finished" (Mount & Checksum).

## 🚀 Strategy: Tiered Rollout

We prioritize verification and migration based on host criticality.

### Tier 1: Critical Core (Markus Home + Cloud)

_Status: Active restic-cron (csb/hsb1) or ZFS (hsb0)_

- [ ] **csb0**: Audit `restic-cron` logic + shared cleanup with csb1.
- [ ] **csb1**: Audit `restic-cron` logic.
- [ ] **hsb0**: Plan migration from ZFS-only to Restic/Hetzner.
- [ ] **hsb1**: Audit `restic-cron` logic.

### Tier 2: Remote Infrastructure

_Status: ZFS snapshots or manual check needed_

- [ ] **hsb8** (Parents): Plan migration to Restic/Hetzner.
- [ ] **miniserver-bp** (Office): Verify "no persistent data" assumption and enable basic config backup.

### Tier 3: Workstations & Gaming (Low Priority)

_Status: Time Machine or None_

- [ ] **imac0 / mba-\***: Standardize on Restic to Hetzner alongside Time Machine.
- [ ] **gpc0**: Implement config + home dir backup (excluding heavy game data).

## 🛠️ Implementation Tasks

- [ ] **Audit Implementation**: Find out exactly what is included/excluded in current `restic-cron` containers.
- [ ] **Deep Validation**: Define process for "Mount & Checksum" verification.
- [ ] **Automation**: Create `just verify-backup <host>` recipes (likely in `hokage` or `uzumaki` modules).
- [ ] **Integration**: Prepare NixFleet for backup status reporting.

## 📋 Additional Infra Debt (Discovered during Audit)

- [ ] **Traefik Declarative Fix**: `csb0` Traefik config (`static.yml`, `dynamic.yml`) is currently manually managed/copied. Integrate into Nix/Uzumaki modules.
- [ ] **Restic Secret Standardization**: Audit `restic-hetzner-env` and `restic-hetzner-ssh-key` usage across `csb0` and `csb1`. Ensure `agenix` is the single source of truth and `docker-compose` maps them correctly.

## 📝 Notes

- Validation must be "100% valid" (not just log checking).
- Vision is to make adding/removing hosts as easy as a checkbox in NixFleet.
