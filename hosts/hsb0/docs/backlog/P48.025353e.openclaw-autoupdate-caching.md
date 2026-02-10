# openclaw-autoupdate-caching

**Host**: hsb0
**Priority**: P48
**Status**: Backlog
**Created**: 2026-02-05

---

## Problem

Updating OpenClaw requires manual process on each host (hsb1, imac0) with resource-intensive "probe build" to recalculate `pnpmDepsHash`. Takes 5-10 minutes per host and blocks terminal. Redundant work across fleet.

## Solution

Leverage hsb0 as fleet infrastructure core with NCPS (Nix Cache Proxy Sync) to pre-fetch and cache updates:

1. Scheduled systemd timer on hsb0 runs daily at 02:00 AM
2. Timer runs `update-openclaw.sh`, performs hash-probing build locally if new version found
3. Results (including massive node_modules) stored in local Nix cache/NCPS
4. Auto-commit and push updated `package.nix` to repository
5. Other hosts pull pre-built binaries from hsb0 in seconds instead of rebuilding

## Implementation

- [ ] Create systemd timer/service on hsb0 for daily OpenClaw updates
- [ ] Configure timer to run at 02:00 AM
- [ ] Ensure `update-openclaw.sh` has git commit/push permissions
- [ ] Test manual trigger: force build for new version on hsb0
- [ ] Verify objects appear in NCPS cache
- [ ] Test on hsb1: run `nix build` and confirm downloads from hsb0
- [ ] Monitor first automated run
- [ ] Update documentation

## Acceptance Criteria

- [ ] Systemd timer active on hsb0
- [ ] hsb0 successfully pushes version updates to git automatically
- [ ] hsb1 can pull updated config and use hsb0 binary cache
- [ ] Update time on hsb1 reduced from 8 minutes to <1 minute
- [ ] Timer visible in `systemctl list-timers | grep openclaw-update`

## Notes

- Depends on: P4000-openclaw-update-automation.md
- NCPS on hsb0 acts as fleet-wide cache
- Benefits all OpenClaw users (hsb1, imac0, future hosts)
