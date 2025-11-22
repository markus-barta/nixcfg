# T08: ZFS Storage

**Feature ID**: F08  
**Status**: ✅ Implemented  
**Location**: Both jhw22 and ww87

## Overview

Tests that ZFS storage is functioning correctly with proper data integrity.

## Prerequisites

- Server has ZFS pool configured (zroot)
- SSH access to hsb8

## Manual Test Procedure

### Step 1: Check ZFS Pool Status

```bash
ssh mba@192.168.1.100
zpool status
```

**Expected**:

- Pool state: `ONLINE`
- No errors
- All disks healthy

### Step 2: Check ZFS Pool Usage

```bash
ssh mba@192.168.1.100
zpool list zroot
```

**Expected**: Shows capacity, usage, health status

### Step 3: Check ZFS Compression

```bash
ssh mba@192.168.1.100
zfs get compression zroot
```

**Expected**: Compression is enabled (`lz4` or similar)

### Step 4: Check ZFS Filesystems

```bash
ssh mba@192.168.1.100
zfs list
```

**Expected**: Shows all ZFS filesystems with proper mountpoints

### Step 5: Test ZFS Scrub Status

```bash
ssh mba@192.168.1.100
zpool status -v | grep scrub
```

**Expected**: Shows last scrub date or "none requested"

## Automated Test

Run the automated test script:

```bash
./tests/T08-zfs-storage.sh
```

## Success Criteria

- ✅ ZFS pool is online and healthy
- ✅ No ZFS errors
- ✅ Compression enabled
- ✅ Filesystems mounted correctly
- ✅ Disk usage is reasonable

## Troubleshooting

### Pool Degraded

```bash
ssh mba@192.168.1.100
zpool status -v
```

Check for disk errors or failures.

### High Disk Usage

```bash
ssh mba@192.168.1.100
zfs list -o space
```

Check space usage by filesystem.

### Scrub Errors

```bash
ssh mba@192.168.1.100
sudo zpool scrub zroot
```

Manually initiate a scrub to check data integrity.

## Test Log

| Date       | Tester | Location | Result | Notes                 |
| ---------- | ------ | -------- | ------ | --------------------- |
| 2025-11-22 | AI     | jhw22    | ✅     | Pool healthy, 7% used |
|            |        |          |        |                       |
