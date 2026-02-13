# ical-sync-fix

**Host**: hsb1
**Priority**: P40
**Status**: Backlog
**Created**: 2026-02-13

---

## Problem

vdirsyncer/iCal sync broken on Merlin (hsb1):

- "Server disconnected" - iCloud drops connection during sync
- "Not Found" for collections - Collection-ID may have changed or permissions invalid
- Last successful sync: before 10.02, no new events since

## Solution

Fix iCloud CalDAV sync on hsb1:

1. Check current vdirsyncer config
2. Renew iCloud app-specific password/token
3. Verify collection IDs
4. Test vdirsyncer sync

## Implementation

- [ ] SSH to hsb1: `ssh mba@hsb1.ts.barta.cm` (via Tailscale)
- [ ] Check vdirsyncer status: `vdirsyncer sync --dry-run`
- [ ] Check config: `cat ~/.config/vdirsyncer/config`
- [ ] Renew iCloud app-specific password (via appleid.apple.com)
- [ ] Update agenix secret: `hsb1-openclaw-icloud-password.age`
- [ ] Test sync: `vdirsyncer sync`
- [ ] Verify khal: `khal list today`

## Acceptance Criteria

- [ ] vdirsyncer sync completes without errors
- [ ] Calendar events appear in khal
- [ ] Merlin can query calendar

## Notes

**Target**: Merlin (hsb1)

**Configs**:

- vdirsyncer: `~/.config/vdirsyncer/config`
- khal: `~/.config/khal/config`
- Password source: `/run/agenix/hsb1-openclaw-icloud-password`
