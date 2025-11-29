# T00: NixOS Base System

**Feature ID**: F00  
**Status**: ⏳ Pending

## Overview

Tests that the NixOS base system is properly installed and functioning, providing the foundation for declarative configuration and reliable system management on the cloud server.

## Prerequisites

- SSH access to csb1 (port 2222)

## Manual Test Procedure

### Step 1: Verify NixOS Version

```bash
ssh -p 2222 mba@cs1.barta.cm
nixos-version
```

**Expected**: Shows NixOS version (e.g., `24.11.20240926.1925c60 (Vicuna)`)

### Step 2: Check System State Version

```bash
ssh -p 2222 mba@cs1.barta.cm
grep stateVersion /etc/nixos/configuration.nix
```

**Expected**: Shows declared state version

### Step 3: Verify Declarative Configuration

```bash
ssh -p 2222 mba@cs1.barta.cm
ls -la ~/nixcfg/hosts/csb1/
```

**Expected**: Shows configuration.nix, hardware-configuration.nix, disk-config.zfs.nix

### Step 4: Check NixOS Generations

```bash
ssh -p 2222 mba@cs1.barta.cm
ls -1 /nix/var/nix/profiles/ | grep "system-.*-link" | wc -l
```

**Expected**: Shows number of system generations (rollback capability)

### Step 5: Verify System is Running

```bash
ssh -p 2222 mba@cs1.barta.cm
systemctl is-system-running
```

**Expected**: Returns `running` or `degraded` (degraded is OK if some non-critical services aren't started)

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

## Troubleshooting

### System Degraded

```bash
ssh -p 2222 mba@cs1.barta.cm
systemctl --failed
```

Check which services failed.

### Cannot Connect via SSH

- Check port 2222 (not default 22)
- Verify firewall allows connection
- Use VNC console via Netcup panel

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |

## Notes

This "Basics" feature encompasses:

- NixOS operating system
- Declarative configuration management
- Generation-based rollback capability
- ZFS storage
- Docker container runtime
