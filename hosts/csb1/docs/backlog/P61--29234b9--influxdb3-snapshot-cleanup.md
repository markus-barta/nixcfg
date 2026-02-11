# influxdb3-snapshot-cleanup

**Host**: csb1
**Priority**: P61
**Status**: Backlog
**Created**: 2025-12-17

---

## Problem

InfluxDB3 on csb1 caught in restart loop (2025-12-17) due to "Too many open files". InfluxDB3 creates WAL snapshot metadata files every ~30 minutes, never cleaned up. After 8 months: 10,371 files accumulated, exceeding default container fd limit (~1024).

## Solution

Schedule periodic cleanup of snapshot files. Already fixed immediate issue with ulimits increase and manual cleanup, but need automation to prevent recurrence.

## Implementation

- [ ] Create cleanup script in `~/docker/scripts/influxdb3-snapshot-cleanup.sh`
- [ ] Script: Delete snapshots older than 30 days (configurable)
- [ ] Test script manually: `docker run --rm -v csb1_influxdb_data:/data alpine find ...`
- [ ] Add monthly cron job: `0 3 1 * * ~/docker/scripts/influxdb3-snapshot-cleanup.sh`
- [ ] Log cleanup results for monitoring
- [ ] Consider adding to NixOS configuration if csb1 becomes fully declarative
- [ ] Document in RUNBOOK.md

## Acceptance Criteria

- [ ] Cleanup script created and tested
- [ ] Cron job scheduled (monthly, 3 AM on 1st)
- [ ] Logs show cleanup results
- [ ] File count stabilizes (not growing unbounded)
- [ ] Documentation updated

## Notes

- Fix applied (2025-12-17):
  - Increased ulimits to 65536 in docker-compose.yml
  - Manual cleanup: 10,371 → 620 files (kept last 14 days)
- Current state: ulimits prevent crash, but files will accumulate again
- Docker volume: `csb1_influxdb_data`
- Snapshot path: `/var/lib/influxdb3/csb1-main-node/snapshots/*.info.json`
- Priority: 🟢 Low (preventive maintenance, ulimits prevent immediate recurrence)
