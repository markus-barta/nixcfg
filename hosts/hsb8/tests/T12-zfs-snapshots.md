# T12: ZFS Snapshots

**Feature ID**: F12  
**Status**: ✅ Implemented  
**Location**: both (testable at jhw22 and ww87)

## Overview

Tests that ZFS automatic snapshots are configured and protecting data.

## Manual Test Procedure

### Step 1: Check for ZFS Snapshots

```bash
ssh mba@192.168.1.100
zfs list -t snapshot
```

**Expected**: Shows list of snapshots (if any have been created)

### Step 2: Check Sanoid Configuration

```bash
ssh mba@192.168.1.100
systemctl status sanoid
```

**Expected**: Service exists (may or may not be active depending on configuration)

### Step 3: Verify ZFS Snapshot Capability

```bash
ssh mba@192.168.1.100
sudo zfs snapshot zroot@test-snapshot
zfs list -t snapshot | grep test-snapshot
sudo zfs destroy zroot@test-snapshot
```

**Expected**: Can create and destroy snapshots

## Automated Test

```bash
./tests/T12-zfs-snapshots.sh
```

## Success Criteria

- ✅ ZFS snapshots can be created
- ✅ Snapshots can be listed
- ✅ Snapshots can be destroyed
- ✅ Automatic snapshot service configured (if enabled)

## Test Log

| Date       | Tester | Location | Result | Notes         |
| ---------- | ------ | -------- | ------ | ------------- |
| 2025-11-22 | -      | -        | ⏳     | Awaiting test |
|            |        |          |        |               |
