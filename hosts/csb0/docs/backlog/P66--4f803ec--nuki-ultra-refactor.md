# nuki-ultra-refactor

**Host**: csb0
**Priority**: P66
**Status**: Backlog
**Created**: 2025-12-06

---

## Problem

Node-RED still references old Danalock but physical hardware is now Nuki Ultra smartlock. Functionality works but using old naming.

## Solution

Update Node-RED configuration and documentation to reflect Nuki Ultra hardware.

## Implementation

- [ ] Update Node-RED flow action codes in flows.json:
  - Change `d-l-o` (danalock open) → `n-u-o` (Nuki Ultra open) or similar
  - Change `d-l-c` (danalock close) → `n-u-c` (Nuki Ultra close) or similar
- [ ] Update HTTP endpoint documentation
- [ ] Test all access methods after changes:
  - HTTP endpoints
  - NFC triggers
  - Telegram commands
- [ ] Update web UI if it references Danalock
- [ ] Check if Nuki API has better integration options
- [ ] Update comments in Node-RED flows
- [ ] Update documentation

## Acceptance Criteria

- [ ] Action codes updated in Node-RED
- [ ] All access methods tested and working
- [ ] Documentation reflects Nuki Ultra hardware
- [ ] Comments updated in flows

## Notes

- Files: `/home/mba/docker/nodered/data/flows.json` (Webserver tab)
- Web UI: `/home/mba/docker/nodered/webserver/`
- Current state: Working but cosmetically incorrect
- Priority: 🟡 LOW (mostly cosmetic)
- Effort: Medium (1-2 hours)
- Origin: Migrated from `hosts/csb0/secrets/BACKLOG.md` (2025-12-06)
