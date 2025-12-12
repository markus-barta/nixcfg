# 2025-12-06 - csb0 Nuki Ultra Smart Lock Refactor

## Description

Node-RED still references old Danalock but hardware is now Nuki Ultra smartlock. Needs configuration update.

## Current State

- Node-RED actions still use: `d-l-o` (danalock open), `d-l-c` (danalock close)
- Physical hardware: Nuki Ultra smartlock
- Functionality: Working but using old naming

## Acceptance Criteria

- [ ] Update Node-RED flow action codes
  - Change `d-l-o` → `n-u-o` (Nuki Ultra open) or similar
  - Change `d-l-c` → `n-u-c` (Nuki Ultra close)
- [ ] Update HTTP endpoint documentation
- [ ] Test all access methods (HTTP, NFC, Telegram)
- [ ] Update web UI if it references Danalock
- [ ] Check if Nuki API has better integration options
- [ ] Update comments in Node-RED flows

## Files to Update

- `/home/mba/docker/nodered/data/flows.json` (Webserver tab)
- Any web UI files in `/home/mba/docker/nodered/webserver/`

## Priority

🟡 LOW - Cosmetic mostly, functionality works

## Effort

Medium (1-2 hours)

## Origin

Migrated from `hosts/csb0/secrets/BACKLOG.md` (2025-12-06)
