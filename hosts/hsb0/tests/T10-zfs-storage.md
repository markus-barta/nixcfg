# T10: ZFS Storage

**Feature ID**: F10  
**Status**: ✅ Implemented

## Overview

Tests that ZFS storage is functioning correctly with proper data integrity, compression, and health monitoring on the zroot pool.

## Prerequisites

- Server has ZFS pool configured (zroot)
- SSH access to hsb0

## Manual Test Procedure

### Step 1: Check ZFS Pool Status

```bash
ssh mba@192.168.1.99
zpool status
```

**Expected**:

- Pool state: `ONLINE`
- No errors
- Disk healthy

### Step 2: Check ZFS Pool Usage

```bash
ssh mba@192.168.1.99
zpool list zroot
```

**Expected**: Shows capacity (232GB), usage (~3%), health status (ONLINE)

### Step 3: Check ZFS Compression

```bash
ssh mba@192.168.1.99
zfs get compression zroot
```

**Expected**: Compression is enabled (`lz4`)

### Step 4: Check ZFS Filesystems

```bash
ssh mba@192.168.1.99
zfs list
```

**Expected**: Shows all ZFS filesystems:

- `zroot/root` → `/`
- `zroot/nix` → `/nix`
- `zroot/home` → `/home`

### Step 5: Test ZFS Scrub Status

```bash
ssh mba@192.168.1.99
zpool status -v | grep scrub
```

**Expected**: Shows last scrub date or "scrub in progress"

### Step 6: Verify Auto-Scrub is Enabled

```bash
ssh mba@192.168.1.99
systemctl status zfs-scrub@zroot.timer
```

**Expected**: Timer is active for periodic scrubbing

## Automated Test

Run the automated test script:

```bash
./tests/T10-zfs-storage.sh
```

## Success Criteria

- ✅ ZFS pool is online and healthy
- ✅ No ZFS errors
- ✅ Compression enabled (lz4)
- ✅ Filesystems mounted correctly
- ✅ Disk usage is reasonable (<10%)
- ✅ Auto-scrub enabled

## Troubleshooting

### Pool Degraded

```bash
ssh mba@192.168.1.99
zpool status -v
```

Check for disk errors or failures.

### High Disk Usage

```bash
ssh mba@192.168.1.99
zfs list -o space
```

Check which filesystem is consuming space.

### ZFS Errors

```bash
ssh mba@192.168.1.99
zpool events -v
```

Review ZFS event log for errors.

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |

## Notes

- ZFS pool: zroot (Samsung SSD 840 Series, 232.9 GB)
- Host ID: dabfdb02 (critical for ZFS import)
- Compression: lz4 (fast, good compression ratio)
- Auto-scrub: enabled via `services.zfs.autoScrub.enable = true`
- ZFS provides data integrity, compression, and snapshot capabilities
- Critical for a production DNS/DHCP server that must be reliable
