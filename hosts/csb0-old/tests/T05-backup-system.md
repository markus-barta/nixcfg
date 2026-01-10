# T05: Backup System (csb0)

Test restic backup to Hetzner StorageBox.

> ⚠️ **CRITICAL**: csb0 manages backups for BOTH csb0 AND csb1!

## Host Information

| Property     | Value                       |
| ------------ | --------------------------- |
| **Host**     | csb0                        |
| **Service**  | restic-cron-hetzner         |
| **Schedule** | Backup 01:30, Cleanup 03:15 |
| **Target**   | Hetzner StorageBox          |

## Prerequisites

- [ ] SSH access to csb0
- [ ] Hetzner StorageBox accessible

## Automated Tests

Run: `./T05-backup-system.sh`

## Test Procedures

### Test 1: Restic Container Running

**Command:** `docker ps --format "{{.Names}}" | grep restic`

**Expected:** Container found

### Test 2: Container Stable

**Command:** `docker inspect --format "{{.RestartCount}}" <container>`

**Expected:** < 5 restarts

### Test 3: Recent Backup Activity

**Command:** Check logs for backup/snapshot entries

**Expected:** Recent backup activity in logs

### Test 4: No Critical Errors

**Command:** Check logs for error/fatal

**Expected:** < 3 errors in recent logs

## What Gets Backed Up

```
✅ /var/lib/docker/volumes - Docker volumes
✅ /home - All Docker bind mounts
✅ /root - Root user data
✅ /etc - System configuration
❌ Exclusions: */cache/*, *.log*
```

## Manual Verification

```bash
# List snapshots
docker exec csb0-restic-cron-hetzner-1 restic snapshots

# Check repository stats
docker exec csb0-restic-cron-hetzner-1 restic stats
```

## Test Results Summary

| Test | Description        | Status |
| ---- | ------------------ | ------ |
| T1   | Container Running  | ⏳     |
| T2   | Container Stable   | ⏳     |
| T3   | Recent Activity    | ⏳     |
| T4   | No Critical Errors | ⏳     |

## Notes

- csb0 runs cleanup for BOTH servers at 03:15
- csb1's cleanup script defers to csb0
- Both backup to same Hetzner repository
