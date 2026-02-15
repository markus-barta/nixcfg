# auto-update-check

**Priority**: P50
**Status**: Backlog
**Created**: 2026-02-14

---

## Problem

OpenClaw container includes multiple skills with external dependencies (gogcli, cli-microsoft365). Currently no automated way to check for updates — requires manual monitoring of upstream releases.

## Solution

Add update check script that runs before container rebuilds and notifies of new versions.

## Implementation

- [ ] Create `scripts/check-container-deps.sh` — checks gogcli, cli-microsoft365 versions
- [ ] Integrate into existing workflows or create `just` recipe
- [ ] Document in RUNBOOK

## Acceptance Criteria

- [ ] Script detects newer gogcli releases
- [ ] Script detects newer cli-microsoft365 releases
- [ ] Documented in relevant RUNBOOK

## Notes

- Focus on skills with external binaries (gogcli, @pnp/cli-microsoft365)
- OpenClaw itself handled separately via `clawhub update`
