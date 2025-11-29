# T05: Backup System

**Feature ID**: F05  
**Status**: ⏳ Pending

## Overview

Tests that the backup system is running and successfully backing up data to Hetzner Storage Box using restic.

## Prerequisites

- SSH access to csb1 (port 2222)

## Manual Test Procedure

### Step 1: Check Container Running

```bash
ssh -p 2222 mba@cs1.barta.cm
docker ps | grep restic
```

**Expected**: `csb1-restic-cron-hetzner-1` container running

### Step 2: Check Container Logs

```bash
ssh -p 2222 mba@cs1.barta.cm
docker logs csb1-restic-cron-hetzner-1 --tail 100
```

**Expected**: Shows successful backup runs, no critical errors

### Step 3: Check Last Backup Time

```bash
ssh -p 2222 mba@cs1.barta.cm
docker logs csb1-restic-cron-hetzner-1 | grep "backup was successful" | tail -1
```

**Expected**: Recent timestamp (within last 24 hours)

### Step 4: List Snapshots

```bash
ssh -p 2222 mba@cs1.barta.cm
docker exec csb1-restic-cron-hetzner-1 \
  restic -r sftp:<storage-box-url>:/ snapshots
```

**Expected**: Shows list of backup snapshots

Note: See `secrets/RUNBOOK.md` for full storage box URL.

### Step 5: Verify Latest Snapshot

```bash
ssh -p 2222 mba@cs1.barta.cm
docker exec csb1-restic-cron-hetzner-1 \
  restic -r sftp:<storage-box-url>:/ snapshots --json --last | jq
```

**Expected**: Recent snapshot with expected paths

### Step 6: Check Backup Schedule

```bash
ssh -p 2222 mba@cs1.barta.cm
docker inspect csb1-restic-cron-hetzner-1 | grep -i cron
```

**Expected**: Shows backup schedule (daily at 01:30 AM)

### Step 7: Test Restore (Dry Run)

```bash
ssh -p 2222 mba@cs1.barta.cm
docker exec csb1-restic-cron-hetzner-1 \
  restic -r sftp:<storage-box-url>:/ mount /tmp/backup &
# Then browse /tmp/backup
ls /tmp/backup/snapshots/latest/
```

**Expected**: Can browse backed up files

## Automated Test

Run the automated test script:

```bash
./tests/T05-backup-system.sh
```

## Success Criteria

- ✅ Backup container running
- ✅ Recent successful backup (within 24 hours)
- ✅ Snapshots available
- ✅ Data can be restored

## Backup Schedule

- **Time**: Daily at 01:30 AM
- **Destination**: Hetzner Storage Box
- **Retention**: See cleanup policy in container config

## Data Backed Up

- Docker volumes (all services)
- Configuration files
- User data directories

## Troubleshooting

### Container Not Running

```bash
cd /home/mba/docker
docker-compose up -d restic-cron-hetzner
docker logs csb1-restic-cron-hetzner-1 --tail 100
```

### Backup Failed

```bash
# Check logs for error
docker logs csb1-restic-cron-hetzner-1 --tail 200 | grep -i error

# Check storage box connectivity
docker exec csb1-restic-cron-hetzner-1 \
  ssh -p 23 <user>@<storage-box> ls /
```

### No Recent Backups

- Check if container running
- Check cron schedule
- Manually trigger backup:

```bash
docker exec csb1-restic-cron-hetzner-1 /usr/local/bin/run_backup.sh
```

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |
