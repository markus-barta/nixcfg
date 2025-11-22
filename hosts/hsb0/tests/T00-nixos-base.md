# T00: NixOS Base System

**Feature ID**: F00  
**Status**: ✅ Implemented

## Overview

Tests that the NixOS base system is properly installed and functioning, providing the foundation for declarative configuration and reliable system management on the DNS/DHCP infrastructure server.

## Prerequisites

- SSH access to hsb0 (192.168.1.99 or hsb0.lan)

## Manual Test Procedure

### Step 1: Verify NixOS Version

```bash
ssh mba@192.168.1.99
nixos-version
```

**Expected**: Shows NixOS version (e.g., `25.11.20251117.89c2b23 (Xantusia)`)

### Step 2: Check System State Version

```bash
ssh mba@192.168.1.99
grep stateVersion /etc/nixos/configuration.nix
```

**Expected**: Shows declared state version

### Step 3: Verify Declarative Configuration

```bash
ssh mba@192.168.1.99
ls -la ~/Code/nixcfg/hosts/hsb0/
```

**Expected**: Shows configuration.nix, hardware-configuration.nix, disk-config.zfs.nix

### Step 4: Check NixOS Generations

```bash
ssh mba@192.168.1.99
ls -1 /nix/var/nix/profiles/ | grep "system-.*-link" | wc -l
```

**Expected**: Shows number of system generations (rollback capability)

### Step 5: Verify System is Running

```bash
ssh mba@192.168.1.99
systemctl is-system-running
```

**Expected**: Returns `running` or `degraded` (degraded is OK if some non-critical services aren't started)

### Step 6: Check Boot Loader

```bash
ssh mba@192.168.1.99
ls -la /boot/grub/
```

**Expected**: GRUB bootloader files present

## Automated Test

Run the automated test script:

```bash
./tests/T00-nixos-base.sh
```

## Success Criteria

- ✅ NixOS is installed and reporting version
- ✅ System has declarative configuration
- ✅ Multiple generations available (rollback possible)
- ✅ System is running normally
- ✅ GRUB bootloader configured

## Troubleshooting

### System Degraded

```bash
ssh mba@192.168.1.99
systemctl --failed
```

Check which services failed.

### No Generations

This would be unusual - every NixOS system should have at least one generation.

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |

## Notes

This "Basics" feature encompasses:

- NixOS operating system
- GRUB bootloader (BIOS support for Mac mini 2011)
- Declarative configuration management
- Generation-based rollback capability
- Firmware update infrastructure (fwupd)
- ZFS host ID configuration

These are foundational elements that enable all other features, especially critical for a production DNS/DHCP server.
