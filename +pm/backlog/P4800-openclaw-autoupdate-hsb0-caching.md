# Automate OpenClaw Updates and Caching via hsb0/NCPS

**Created**: 2026-02-05  
**Priority**: P4800 (Medium)  
**Status**: Backlog  
**Depends on**: P4000-openclaw-update-automation.md

---

## Problem

Updating OpenClaw currently requires a manual process on `hsb1` that triggers a resource-intensive "probe build" to recalculate `pnpmDepsHash`. This takes 5-10 minutes and blocks the terminal. Since multiple devices in the fleet (hsb1, imac0, etc.) use OpenClaw, this redundant work is inefficient.

---

## Solution

Leverage the `hsb0` server (acting as the fleet's infrastructure core) and its **NCPS (Nix Cache Proxy Sync)** to pre-fetch and cache updates.

1.  **Scheduled Check**: Implement a systemd timer on `hsb0` that runs daily at 02:00 AM.
2.  **Auto-Patching**: The timer runs `update-openclaw.sh`. If a new version is found, it performs the hash-probing build locally on `hsb0`.
3.  **Local Cache**: By building on `hsb0`, the results (and the massive node_modules folder) are automatically stored in the local Nix cache/NCPS.
4.  **Auto-Commit**: If successful, `hsb0` commits and pushes the updated `package.nix` back to the repository.
5.  **Fast Deploys**: When the user runs `just switch` on `hsb1` later that day, Nix pulls the pre-built binaries from `hsb0` in seconds instead of rebuilding for 8 minutes.

---

## Acceptance Criteria

- [ ] Systemd timer/service active on `hsb0`.
- [ ] `hsb0` successfully pushes version updates to Git without human intervention.
- [ ] `hsb1` can pull the updated config and use the binary cache from `hsb0` for instant updates.

---

## Test Plan

### Manual Test

1. Force a build on `hsb0` for a new version.
2. Verify objects appear in NCPS.
3. Run `nix build` on `hsb1` and verify it downloads from `hsb0`.

### Automated Test

```bash
# Check if the update timer is active on hsb0
systemctl list-timers | grep openclaw-update
```
