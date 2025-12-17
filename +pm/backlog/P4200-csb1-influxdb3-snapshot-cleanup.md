# csb1 InfluxDB3 Snapshot Cleanup Maintenance

## Description

Schedule periodic cleanup of InfluxDB3 snapshot files on csb1 to prevent file descriptor exhaustion.

## Background

On 2025-12-17, InfluxDB3 on csb1 was caught in a restart loop due to "Too many open files" error. Root cause:

- InfluxDB3 creates WAL snapshot metadata files every ~30 minutes
- These `.info.json` files in `/snapshots/` were never being cleaned up
- After 8 months of operation (since Apr 2025), accumulated **10,371 files**
- Default container file descriptor limit (~1024) was exceeded

## Fix Applied

1. **Increased ulimits** in `~/docker/docker-compose.yml`:

```yaml
influxdb:
  ulimits:
    nofile:
      soft: 65536
      hard: 65536
```

2. **Manual cleanup** of old snapshots:

```bash
# Keep last 14 days, deleted ~9,800 files
docker run --rm -v csb1_influxdb_data:/data alpine sh -c \
  'find /data/csb1-main-node/snapshots/ -name "*.json" -mtime +14 -delete'
```

Post-cleanup: 10,371 → 620 files

## Current State

- ✅ Ulimits increased to 65536 (prevents crash even with many files)
- ✅ Manual cleanup completed (620 files remaining)
- ⚠️ No automated cleanup scheduled — files will accumulate again

## Acceptance Criteria

- [ ] Create cron job or systemd timer on csb1 to clean up snapshots monthly
- [ ] Keep last 30 days of snapshots (configurable)
- [ ] Log cleanup results for monitoring
- [ ] Consider adding to NixOS configuration if csb1 is ever fully declarative

## Suggested Implementation

Add to csb1 crontab or create a script in `~/docker/scripts/`:

```bash
#!/usr/bin/env bash
# influxdb3-snapshot-cleanup.sh
docker run --rm -v csb1_influxdb_data:/data alpine sh -c \
  'find /data/csb1-main-node/snapshots/ -name "*.json" -mtime +30 -delete'
```

Monthly cron: `0 3 1 * * ~/docker/scripts/influxdb3-snapshot-cleanup.sh`

## Priority

Low — ulimits increase prevents immediate recurrence. Cleanup is preventive maintenance.

## Related

- InfluxDB3 Core (quay.io/influxdb/influxdb3-core:latest)
- Docker volume: `csb1_influxdb_data`
- Snapshot files: `/var/lib/influxdb3/csb1-main-node/snapshots/*.info.json`
