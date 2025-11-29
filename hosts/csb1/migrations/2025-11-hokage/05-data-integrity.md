# T12: Data Integrity Test

**Feature ID**: F12  
**Status**: ⏳ Pending  
**Purpose**: Verify critical data and databases survived migration

## Overview

Verifies that critical data files, databases, and configurations are intact after migration.

## Prerequisites

- SSH access to csb1 (port 2222)
- Docker running

## Critical Data Locations

### Docker Volumes (Persistent Data)

| Volume                 | Service   | Purpose             |
| ---------------------- | --------- | ------------------- |
| `csb1_grafana_data`    | Grafana   | Dashboards, configs |
| `csb1_influxdb_data`   | InfluxDB  | Time series metrics |
| `csb1_paperless_data`  | Paperless | Documents           |
| `csb1_paperless_media` | Paperless | Document files      |
| `csb1_docmost_data`    | Docmost   | Wiki pages          |

### ZFS Datasets

- `/srv/docker` - Docker data root
- `/srv/backup` - Backup staging

### Configuration Files

- `/etc/nixos/` - NixOS configuration
- Docker compose files in containers

## Manual Verification

### Step 1: Grafana Dashboards

```bash
ssh -p 2222 mba@cs1.barta.cm
# Check Grafana has dashboards
docker exec csb1-grafana-1 ls /var/lib/grafana/dashboards/ 2>/dev/null || echo "No dashboard dir"
```

### Step 2: InfluxDB Data

```bash
# Check InfluxDB has data
docker exec csb1-influxdb-1 ls -la /var/lib/influxdb3/
```

### Step 3: Paperless Documents

```bash
# Check document count
docker exec csb1-paperless-1 ls /usr/src/paperless/media/documents/originals/ 2>/dev/null | wc -l
```

### Step 4: Docmost Pages

```bash
# Check database exists
docker exec csb1-docmost-db-1 psql -U docmost -c "SELECT count(*) FROM pages;" 2>/dev/null
```

## Automated Test

```bash
./tests/T12-data-integrity.sh
```

## Success Criteria

- ✅ All Docker volumes exist
- ✅ Grafana data directory present
- ✅ InfluxDB data directory present
- ✅ Paperless documents accessible
- ✅ Docmost database has data

## Warning Signs

- ❌ Missing volumes = Data loss!
- ❌ Empty data directories = Possible volume mount issue
- ❌ Database connection errors = DB container not started

## Recovery

If data is missing:

1. **Check volume mounts**: `docker volume ls` and `docker inspect <container>`
2. **Check ZFS snapshots**: `zfs list -t snapshot`
3. **Restore from backup**: Use restic snapshots (see secrets/RUNBOOK.md)

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |
