# T09: Post-Migration Verification

**Feature ID**: F09  
**Status**: ⏳ Pending  
**Purpose**: Verify migration success by comparing to pre-migration snapshot

## Overview

Compares current system state against the pre-migration snapshot (T08) to ensure all services, containers, and configurations survived the migration.

## Prerequisites

- SSH access to csb1 (port 2222)
- Pre-migration snapshot in `tests/snapshots/` directory
- Migration completed

## What Gets Verified

### System State

- ✅ NixOS booted successfully
- ✅ Generation number increased (new config applied)
- ⚠️ Uptime reset (expected after reboot)

### Docker State

- ✅ All containers still running
- ✅ Same container count (or documented changes)
- ✅ No containers in restart loop
- ✅ All volumes still present

### Service State

- ✅ All service URLs responding
- ✅ Same HTTP status codes as before
- ✅ SSL certificates still valid

### Storage State

- ✅ ZFS pool still healthy
- ✅ Data intact

### Security State

- ✅ SSH access working
- ✅ Same authorized keys (no omega keys injected!)
- ✅ Passwordless sudo working

## Manual Procedure

```bash
# List available snapshots
ls -la tests/snapshots/

# Run comparison against most recent snapshot
./tests/T09-post-migration-verify.sh tests/snapshots/pre-migration-YYYY-MM-DD-HHMMSS.json
```

## Automated Test

```bash
# Uses most recent pre-migration snapshot
./tests/T09-post-migration-verify.sh

# Or specify snapshot file
./tests/T09-post-migration-verify.sh tests/snapshots/pre-migration-2025-11-29-120000.json
```

## Success Criteria

### Must Pass (Blocking)

- ✅ SSH access working
- ✅ All containers running
- ✅ All services responding
- ✅ No omega keys injected
- ✅ ZFS pool healthy

### Expected Differences (OK)

- ⚠️ Uptime reset (reboot happened)
- ⚠️ Generation number increased
- ⚠️ NixOS version may have changed

### Failure Conditions (Rollback!)

- ❌ SSH access broken
- ❌ Containers missing
- ❌ Services not responding
- ❌ omega keys found (security breach!)
- ❌ Data missing

## When to Run

1. **Immediately after migration** - Quick sanity check
2. **After 1 hour** - Services stable?
3. **After 24 hours** - Backup ran successfully?
4. **After 48 hours** - All clear, migration successful!

## Related Tests

- T08: Pre-Migration Snapshot (creates the baseline)
- T10: Rollback Test (if this fails)

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |
