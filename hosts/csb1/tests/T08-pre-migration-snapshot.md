# T08: Pre-Migration Snapshot

**Feature ID**: F08  
**Status**: ⏳ Pending  
**Purpose**: Capture baseline system state before migration for comparison

## Overview

Creates a comprehensive snapshot of the current system state before migration. This snapshot will be used by T09 to verify the migration was successful.

## Prerequisites

- SSH access to csb1 (port 2222)
- Write access to `tests/snapshots/` directory

## What Gets Captured

### System State

- NixOS version
- Current generation number
- System uptime
- Kernel version

### Docker State

- Running container list with image versions
- Container health status
- Docker networks
- Docker volumes
- Disk usage per container

### Service State

- Service URLs and HTTP status codes
- SSL certificate expiry dates
- Grafana dashboard count
- InfluxDB bucket list

### Storage State

- ZFS pool status
- ZFS disk usage
- Compression ratio

### Security State

- SSH authorized keys fingerprints
- SSH hardening settings

## Manual Procedure

```bash
# Create snapshot directory
mkdir -p hosts/csb1/tests/snapshots

# Run snapshot script
./tests/T08-pre-migration-snapshot.sh

# Verify snapshot created
ls -la tests/snapshots/
cat tests/snapshots/pre-migration-*.json
```

## Automated Test

```bash
./tests/T08-pre-migration-snapshot.sh
```

## Output File

Saves to: `tests/snapshots/pre-migration-YYYY-MM-DD-HHMMSS.json`

## Success Criteria

- ✅ Snapshot file created
- ✅ All system metrics captured
- ✅ All container states captured
- ✅ All service URLs checked
- ✅ File is valid JSON

## When to Run

1. **Before starting migration** - Create baseline
2. **After confirming migration date** - Final pre-migration snapshot
3. **Keep multiple snapshots** - In case you need to compare

## Related Tests

- T09: Post-Migration Comparison (uses this snapshot)

## Test Log

| Date | Tester | Result | Snapshot File |
| ---- | ------ | ------ | ------------- |
|      |        | ⏳     |               |
