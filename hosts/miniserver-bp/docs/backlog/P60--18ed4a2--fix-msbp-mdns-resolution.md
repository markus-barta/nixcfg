# fix-msbp-mdns-resolution

**Host**: miniserver-bp
**Priority**: P60
**Status**: Backlog
**Created**: 2026-02-18

---

## Problem

`miniserver-bp.local` (mDNS) does not resolve reliably from office network. The `_msbp-run` just helper and SYSOP SSH reference originally used `ssh mba@miniserver-bp.local` but this fails. Current workaround: hardcoded IP `10.17.1.40` in `_msbp-run` and RUNBOOK.

## Solution

Investigate why mDNS/Avahi is not advertising `miniserver-bp.local`. Fix Avahi config or add a static DNS entry on the office network so `miniserver-bp.local` resolves.

## Implementation

- [ ] Check if Avahi is enabled and running on miniserver-bp
- [ ] Verify mDNS hostname configuration
- [ ] Fix Avahi/mDNS or add static DNS fallback
- [ ] Update `_msbp-run` helper to use hostname instead of hardcoded IP
- [ ] Documentation update

## Acceptance Criteria

- [ ] `ping miniserver-bp.local` resolves from office network
- [ ] `_msbp-run` helper works with hostname

## Notes

- RUNBOOK already documents the workaround: "mDNS does not resolve reliably. Always use the IP directly."
- Low priority — hardcoded IP works fine for now
