# T11: ZFS Snapshots

**Feature ID**: F11  
**Status**: ✅ Implemented

## Overview

Tests that ZFS snapshot functionality works correctly, providing point-in-time backups for disaster recovery.

## Prerequisites

- Server has ZFS pool configured (zroot)
- SSH access to hsb0

## Manual Test Procedure

### Step 1: List Existing Snapshots

```bash
ssh mba@192.168.1.99
zfs list -t snapshot
```

**Expected**: Shows list of snapshots (may be empty initially)

### Step 2: Create a Test Snapshot

```bash
ssh mba@192.168.1.99
sudo zfs snapshot zroot/root@test-$(date +%Y%m%d-%H%M%S)
```

**Expected**: Command completes without errors

### Step 3: Verify Snapshot was Created

```bash
ssh mba@192.168.1.99
zfs list -t snapshot | grep test-
```

**Expected**: Shows the newly created snapshot

### Step 4: Check Snapshot Size

```bash
ssh mba@192.168.1.99
zfs list -t snapshot -o name,used,refer
```

**Expected**: Shows snapshots with their space usage

### Step 5: Destroy Test Snapshot

```bash
ssh mba@192.168.1.99
sudo zfs list -t snapshot | grep test- | awk '{print $1}' | xargs -I {} sudo zfs destroy {}
```

**Expected**: Snapshot is removed

### Step 6: Verify Snapshot was Destroyed

```bash
ssh mba@192.168.1.99
zfs list -t snapshot | grep test-
```

**Expected**: No test snapshots found

## Automated Test

Run the automated test script:

```bash
./tests/T11-zfs-snapshots.sh
```

## Success Criteria

- ✅ Can list snapshots
- ✅ Can create snapshots
- ✅ Snapshots appear in list
- ✅ Can destroy snapshots
- ✅ Destroyed snapshots are removed

## Troubleshooting

### Cannot Create Snapshot

Check disk space:

```bash
ssh mba@192.168.1.99
zpool list zroot
```

### Snapshot Not Appearing

```bash
ssh mba@192.168.1.99
zfs list -t all | grep zroot
```

### Cannot Destroy Snapshot

Check if snapshot has clones:

```bash
ssh mba@192.168.1.99
zfs get -r clones zroot
```

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |

## Notes

- ZFS snapshots are point-in-time copies of filesystems
- Snapshots are space-efficient (only store changes)
- Can be used for rollback after configuration changes
- Can be used for disaster recovery
- Consider setting up automated snapshot rotation (e.g., with `sanoid`)
- Critical for a production DNS/DHCP server to have backup points
