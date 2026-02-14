# ical-sync-fix

**Host**: hsb0 (Docker container `openclaw-merlin`)
**Priority**: P40
**Status**: Backlog
**Created**: 2026-02-13
**Moved from**: hsb1 (2026-02-14, post-migration cleanup)

---

## Problem

vdirsyncer/iCal sync broken on Merlin:

- "Server disconnected" - iCloud drops connection during sync
- "Not Found" for collections - Collection-ID may have changed or permissions invalid
- Last successful sync: before 10.02, no new events since

## Solution

Fix iCloud CalDAV sync inside the hsb0 Docker container:

1. Check current vdirsyncer config
2. Renew iCloud app-specific password/token
3. Verify collection IDs
4. Test vdirsyncer sync

## Implementation

- [ ] Exec into container: `docker exec -it openclaw-merlin sh`
- [ ] Check vdirsyncer status: `vdirsyncer sync --dry-run`
- [ ] Check config: `cat ~/.config/vdirsyncer/config`
- [ ] Renew iCloud app-specific password (via appleid.apple.com)
- [ ] Update agenix secret: `hsb0-openclaw-icloud-password.age`
- [ ] Rebuild container: `docker compose build openclaw-merlin && docker compose up -d openclaw-merlin`
- [ ] Test sync: `docker exec openclaw-merlin vdirsyncer sync`
- [ ] Verify khal: `docker exec openclaw-merlin khal list today`

## Acceptance Criteria

- [ ] vdirsyncer sync completes without errors
- [ ] Calendar events appear in khal
- [ ] Merlin can query calendar

## Notes

**Target**: Merlin (hsb0 Docker)

**Configs** (mounted as Docker volumes):

- vdirsyncer: `/var/lib/openclaw-merlin/vdirsyncer/config` → `/home/node/.config/vdirsyncer/config`
- khal: `/var/lib/openclaw-merlin/khal/config` → `/home/node/.config/khal/config`
- Password source: `/run/agenix/hsb0-openclaw-icloud-password`
