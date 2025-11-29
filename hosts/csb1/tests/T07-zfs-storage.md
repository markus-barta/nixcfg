# T07: ZFS Storage

**Feature ID**: F07  
**Status**: ⏳ Pending

## Overview

Tests that ZFS storage is properly configured and healthy. ZFS provides reliable storage with snapshots and compression for Docker data.

## Prerequisites

- SSH access to csb1 (port 2222)

## Manual Test Procedure

### Step 1: Check ZFS Pool Status

```bash
ssh -p 2222 mba@cs1.barta.cm
sudo zpool status
```

**Expected**: Pool state is `ONLINE`, no errors

### Step 2: Check Pool Health

```bash
ssh -p 2222 mba@cs1.barta.cm
sudo zpool list
```

**Expected**: Shows pool with reasonable usage (not 100% full)

### Step 3: Check ZFS Datasets

```bash
ssh -p 2222 mba@cs1.barta.cm
sudo zfs list
```

**Expected**: Shows root and docker datasets

### Step 4: Check Compression

```bash
ssh -p 2222 mba@cs1.barta.cm
sudo zfs get compression
```

**Expected**: Compression enabled (zstd or lz4)

### Step 5: Check Compression Ratio

```bash
ssh -p 2222 mba@cs1.barta.cm
sudo zfs get compressratio
```

**Expected**: Shows compression ratio (e.g., 1.5x or higher)

### Step 6: Check for Errors

```bash
ssh -p 2222 mba@cs1.barta.cm
sudo zpool status -v | grep -E "errors:|DEGRADED|OFFLINE"
```

**Expected**: `errors: No known data errors`, no DEGRADED/OFFLINE

### Step 7: Test Scrub (Optional)

```bash
ssh -p 2222 mba@cs1.barta.cm
sudo zpool scrub zpool
```

**Expected**: Scrub starts (long-running operation)

## Automated Test

Run the automated test script:

```bash
./tests/T07-zfs-storage.sh
```

## Success Criteria

- ✅ ZFS pool is ONLINE
- ✅ No errors or degraded disks
- ✅ Compression enabled
- ✅ Reasonable disk usage

## ZFS Configuration

- **Pool Name**: zpool (typically)
- **Compression**: zstd
- **Mount Points**: /, /nix, Docker data

## Troubleshooting

### Pool Degraded

Check disk status:

```bash
sudo zpool status -v
lsblk
```

### High Usage

```bash
sudo zfs list -o name,used,available,refer
du -sh /home/mba/docker/*
```

Clean up old data or Docker images:

```bash
docker system prune -a
```

### Scrub Errors

If scrub finds errors:

```bash
sudo zpool status -v
```

Check for failing disk, consider replacement.

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |

## Notes

- ZFS provides data integrity protection
- Regular scrubs recommended (automatic or manual)
- Compression saves space with minimal CPU overhead
- ZFS snapshots can be used for point-in-time recovery
