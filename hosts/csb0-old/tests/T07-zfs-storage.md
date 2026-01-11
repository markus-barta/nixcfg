# T07: ZFS Storage (csb0)

Test ZFS pool health and configuration.

## Host Information

| Property | Value      |
| -------- | ---------- |
| **Host** | csb0       |
| **Pool** | zroot      |
| **Disk** | Netcup VPS |

## Prerequisites

- [ ] SSH access to csb0
- [ ] ZFS pool imported

## Automated Tests

Run: `./T07-zfs-storage.sh`

## Test Procedures

### Test 1: ZFS Installed

**Command:** `which zpool`

**Expected:** Path to zpool binary

### Test 2: ZFS Pool Online

**Command:** `sudo zpool status -x`

**Expected:** "all pools are healthy"

### Test 3: No ZFS Errors

**Command:** Check for DEGRADED/FAULTED/OFFLINE/UNAVAIL

**Expected:** 0 issues

### Test 4: Disk Usage

**Command:** `sudo zpool list -H -o capacity`

**Expected:** < 80% used

### Test 5: Compression Enabled

**Command:** `sudo zfs get compression -H -o value zroot`

**Expected:** zstd or lz4 (not "off")

## Test Results Summary

| Test | Description   | Status |
| ---- | ------------- | ------ |
| T1   | ZFS Installed | ⏳     |
| T2   | Pool Online   | ⏳     |
| T3   | No Errors     | ⏳     |
| T4   | Disk Usage    | ⏳     |
| T5   | Compression   | ⏳     |

## Useful Commands

```bash
# Pool status
sudo zpool status

# Dataset list
sudo zfs list

# Scrub (manual)
sudo zpool scrub zroot
```

## Notes

- VPS disk is single drive (no redundancy)
- Backups to Hetzner provide data protection
- Compression saves space on limited VPS storage
