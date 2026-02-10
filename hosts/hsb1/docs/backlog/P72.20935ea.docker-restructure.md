# docker-restructure

**Host**: hsb1
**Priority**: P72
**Status**: Backlog
**Created**: 2025-12-01
**Updated**: 2026-01-06

---

## Problem

hsb1 Docker and scripts managed in separate git repo (`miniserver24-docker.git`) and unversioned directories. Two repos to maintain, no single source of truth, inconsistent with fleet.

## Solution

Migrate `~/docker/` and `~/scripts/` into nixcfg repository (`hosts/hsb1/docker/` and `hosts/hsb1/scripts/`). Separate runtime data into Named Docker Volumes.

## Implementation

- [ ] Review current structure: 12 containers, 18 mount directories (3.5GB data)
- [ ] Create `hosts/hsb1/docker/` in nixcfg repo
- [ ] Copy docker-compose.yml, configs (not mounts/ data)
- [ ] Create `hosts/hsb1/scripts/` and migrate 16 script files
- [ ] Update docker-compose.yml to use Named Volumes for data
- [ ] Migrate data from `~/docker/mounts/` to Docker volumes
- [ ] Add systemd.tmpfiles rules for symlink structure
- [ ] Test all 12 containers after migration
- [ ] Archive old `miniserver24-docker.git` repo
- [ ] Update documentation

## Acceptance Criteria

- [ ] All Docker configs in `hosts/hsb1/docker/` (nixcfg repo)
- [ ] All scripts in `hosts/hsb1/scripts/` (nixcfg repo)
- [ ] Named Volumes used for runtime data
- [ ] All 12 containers working after migration
- [ ] Old repo archived
- [ ] Documentation updated

## Notes

- Current: 12 containers (HA, Zigbee2MQTT, Mosquitto, Node-RED, Scrypted, Matter, etc.)
- Runtime data: 3.5GB in mounts/ (keep separate from config)
- Status: Well-prepared, not urgent
- Priority: 🟢 Low (current setup working fine)
