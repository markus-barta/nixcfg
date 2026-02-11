# nixos-migration

**Host**: miniserver-bp
**Priority**: P89
**Status**: Done
**Created**: 2026-01-13
**Updated**: 2026-02-11

---

## Problem

miniserver-bp runs Ubuntu 24.04 on Mac Mini 2009. Need declarative configuration management and consistency with fleet.

## Solution

Migrate to NixOS using nixos-anywhere. Preserve hostname, IP, and WireGuard for jump host functionality.

## Implementation

### Phase 1: Environment Validation (COMPLETED ✅)

- [x] Verify OS: Ubuntu 24.04.2 LTS, kernel 6.8.0-90
- [x] Check disk: 489G total, 426G free, ext4
- [x] Verify SSH keys: ed25519, rsa, ecdsa present
- [x] Check network: enp0s10 with 10.17.1.40/16 (DHCP)
- [x] Note WireGuard: Active and configured

### Phase 2: Pre-Installation Prep

- [x] Backup current SSH host keys
- [x] Document WireGuard config (disable initially, re-enable post-install)
- [x] Test nixos-anywhere from workstation
- [x] Prepare disk-config for 500GB disk

### Phase 3: NixOS Installation

- [x] Deploy: `nixos-anywhere --flake .#miniserver-bp root@10.17.1.40`
- [x] Verify boot and SSH access (port 2222)
- [x] Confirm hostname: miniserver-bp
- [x] Confirm IP: 10.17.1.40/16
- [x] Test uzumaki module (fish shell, user mba)

### Phase 4: Post-Installation

- [x] Re-enable WireGuard (manual, not in initial config)
- [x] Test jump host functionality
- [x] Update documentation
- [x] Archive Ubuntu backup

## Acceptance Criteria

- [x] NixOS deployed successfully
- [x] Hostname preserved: miniserver-bp
- [x] IP preserved: 10.17.1.40/16
- [x] SSH working on port 2222
- [x] User mba with fish shell
- [x] WireGuard functional (post-manual-config)
- [x] Documentation updated

## Notes

### Critical Requirements

- **Hostname**: miniserver-bp (MUST NOT CHANGE)
- **IP**: 10.17.1.40/16 (MUST NOT CHANGE)
- **WireGuard**: Disable initially, enable manually after install
- **User**: mba (UID 1000), fish shell
- **SSH**: Same authorized keys as csb0/csb1

### Hardware

- Mac Mini 2009, 489G disk, enp0s10 interface
- Ubuntu kernel: 6.8.0-90-generic

### Role

- Test server + future jump host
- Priority: 🟡 Medium (ready for installation when convenient)
