# investigate-gogcli-bundled

**Host**: miniserver-bp
**Priority**: P50
**Status**: Backlog
**Created**: 2026-02-13

---

## Problem

Is the gog (Google Workspace) skill bundled in OpenClaw, or does it require the standalone gogcli binary installed in the Dockerfile?

**Observation**: `openclaw skills list` shows gog as "ready" from `openclaw-bundled` source. However, in a previous session, gog only worked after installing gogcli binary in the Dockerfile.

## Solution

Test whether gog works without the gogcli binary:

1. Remove gogcli from Dockerfile
2. Rebuild container
3. Test gog skill

## Implementation

- [ ] Remove gogcli install lines from `hosts/miniserver-bp/docker/Dockerfile`
- [ ] Rebuild container: `docker build -t openclaw-percaival:latest .`
- [ ] Restart container
- [ ] Test: `docker exec openclaw-percaival openclaw skills list` - check if gog is ready
- [ ] Test: `docker exec openclaw-percaival gog auth list` - check if binary exists

## Acceptance Criteria

- [ ] gog skill works WITHOUT gogcli binary in Dockerfile = keep Dockerfile simple
- [ ] OR gog skill requires gogcli binary = document why, keep in Dockerfile

## Notes

**Current state**: Dockerfile installs gogcli v0.9.0, but OpenClaw shows gog as "ready" from bundled source. Need to verify if Dockerfile install is redundant.
