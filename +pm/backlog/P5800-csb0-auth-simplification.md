# 2025-12-06 - csb0 Authentication Code Simplification

## Description

Complex cryptographic authentication code exists in Node-RED but was never fully used. Currently using simple Telegram ID-based authentication which is effective.

## Current State

- Flows contain cryptographic key verification functions (base64 public keys, crypto lib)
- Actually using: Simple Telegram ID-based authentication
- Crypto code: ~100+ lines per function, unused in production
- Working solution: Telegram ID is simpler and effective

## Acceptance Criteria

- [ ] Identify all crypto authentication nodes in flows
- [ ] Document current Telegram ID auth mechanism
- [ ] Create backup of flows before changes
- [ ] Remove unused crypto verification functions
- [ ] Simplify code to only Telegram ID checks
- [ ] Test all access control after simplification
- [ ] Update documentation to reflect actual auth method

## Files to Update

- `/home/mba/docker/nodered/data/flows.json` (Webserver tab, Telegram tab)
- Function nodes: "verify and open" (2x in Webserver tab)
- Any permission check functions

## Benefits

- Cleaner, more maintainable code
- Easier to understand
- Faster execution (less crypto overhead)
- Matches actual production usage

## Priority

🟡 MEDIUM - Involves auth code, needs careful testing

## Effort

High (3-4 hours with testing)

## Origin

Migrated from `hosts/csb0/secrets/BACKLOG.md` (2025-12-06)
