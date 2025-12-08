# T00: NixOS Base System (hsb1)

Test that NixOS is properly installed and functioning.

## Host Information

| Property | Value           |
| -------- | --------------- |
| **Host** | hsb1            |
| **Role** | Home Automation |
| **IP**   | 192.168.1.101   |

## Prerequisites

- [ ] SSH access to hsb1 (192.168.1.101 or hsb1.lan)
- [ ] Network connectivity

## Automated Tests

Run: `./T00-nixos-base.sh`

## Manual Test Procedures

### Test 1: NixOS Version

**Steps:**

1. Check NixOS version:
   ```bash
   nixos-version
   ```

**Expected Results:**

- Version displayed (e.g., "25.05.xxx (Xantusia)")

**Status:** ⏳ Pending

### Test 2: Configuration Directory

**Steps:**

1. Check nixcfg exists:
   ```bash
   ls ~/nixcfg/hosts/hsb1/
   # or
   ls ~/Code/nixcfg/hosts/hsb1/
   ```

**Expected Results:**

- Directory exists with configuration.nix

**Status:** ⏳ Pending

### Test 3: System Generations

**Steps:**

1. List generations:
   ```bash
   ls /nix/var/nix/profiles/ | grep system
   ```

**Expected Results:**

- Multiple system generations exist
- Indicates successful rebuilds

**Status:** ⏳ Pending

### Test 4: System Status

**Steps:**

1. Check system status:
   ```bash
   systemctl is-system-running
   ```

**Expected Results:**

- Returns "running" or "degraded"

**Status:** ⏳ Pending

### Test 5: Bootloader

**Steps:**

1. Check GRUB:
   ```bash
   ls /boot/grub
   ```

**Expected Results:**

- GRUB directory exists

**Status:** ⏳ Pending

## Test Results Summary

| Test | Description             | Status |
| ---- | ----------------------- | ------ |
| T1   | NixOS Version           | ⏳     |
| T2   | Configuration Directory | ⏳     |
| T3   | System Generations      | ⏳     |
| T4   | System Status           | ⏳     |
| T5   | Bootloader              | ⏳     |

## Notes

- Base system test applicable to all NixOS hosts
- Run after every major system change or rebuild
