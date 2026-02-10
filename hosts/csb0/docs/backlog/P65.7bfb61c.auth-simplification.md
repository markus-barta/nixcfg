# auth-simplification

**Host**: csb0
**Priority**: P65
**Status**: Backlog
**Created**: 2025-12-06

---

## Problem

Complex cryptographic authentication code exists in Node-RED but was never fully used. Currently using simple Telegram ID-based authentication which is effective. Crypto code (~100+ lines per function) is unused in production.

## Solution

Remove unused crypto verification functions, simplify to Telegram ID checks only.

## Implementation

- [ ] Create backup of flows: `cp flows.json flows.json.backup-$(date +%Y%m%d)`
- [ ] Identify all crypto authentication nodes (Webserver tab, Telegram tab)
- [ ] Document current Telegram ID auth mechanism
- [ ] Remove unused crypto verification functions:
  - Function nodes: "verify and open" (2x in Webserver tab)
  - Base64 public key handling
  - Crypto library imports
- [ ] Simplify code to only Telegram ID checks
- [ ] Test all access control after simplification
- [ ] Update documentation to reflect actual auth method
- [ ] Remove old backup if tests pass

## Acceptance Criteria

- [ ] Crypto code identified and removed
- [ ] Only Telegram ID auth remains
- [ ] All access control tested and working
- [ ] Code cleaner and more maintainable
- [ ] Documentation updated

## Notes

- Files: `/home/mba/docker/nodered/data/flows.json`
- Backup before changes critical (involves auth code)
- Benefits: Cleaner code, easier maintenance, faster execution
- Current method (Telegram ID) is simple and effective
- Priority: 🟢 Low (cleanup task, needs careful testing)
- Effort: High (3-4 hours with testing)
- Origin: Migrated from `hosts/csb0/secrets/BACKLOG.md` (2025-12-06)
