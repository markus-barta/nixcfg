# runbook-secrets-complete

**Host**: hsb1
**Priority**: P63
**Status**: Backlog
**Created**: 2025-12-08

---

## Problem

`hosts/hsb1/secrets/runbook-secrets.md` has ~20 incomplete TODO items. These are human-readable secrets for emergency recovery documentation.

## Solution

Complete all TODO placeholders in runbook-secrets.md covering Home Assistant, Node-RED, Scrypted, MQTT, Tapo cameras, Restic backup, and 1Password references. Then re-encrypt with agenix.

## Implementation

- [ ] Document Home Assistant admin credentials (or 1Password ref)
- [ ] Document Node-RED admin credentials (or 1Password ref)
- [ ] Document MQTT smarthome password (or 1Password ref)
- [ ] Document Scrypted admin credentials (or 1Password ref)
- [ ] Document Tapo camera credentials (or 1Password ref)
- [ ] Document Restic backup credentials (or 1Password ref)
- [ ] Add 1Password vault references where applicable
- [ ] Encrypt updated file: `just encrypt-runbook-secrets hsb1`
- [ ] Verify encrypted file size (should be 5KB+)

## Acceptance Criteria

- [ ] All ~20 TODO items completed
- [ ] No actual passwords in plain text (use 1Password references)
- [ ] Encrypted runbook-secrets.age updated in git
- [ ] Plain text runbook-secrets.md NOT committed (gitignored)
- [ ] Check existing `~/secrets/` files on hsb1 for current values

## Notes

- Source: AUDITOR scan of hsb1 (Finding #9)
- File: `hosts/hsb1/secrets/runbook-secrets.md`
- These are for human reference during emergency recovery
- Priority: 🟡 MEDIUM (important for disaster recovery)
