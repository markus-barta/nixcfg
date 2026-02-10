# runbook-secrets-complete

**Host**: hsb0
**Priority**: P60
**Status**: Backlog
**Created**: 2025-12-08

---

## Problem

`hosts/hsb0/secrets/runbook-secrets.md` has incomplete TODO placeholders. These are human-readable secrets for emergency recovery documentation.

## Solution

Complete all TODO items in runbook-secrets.md and re-encrypt with agenix.

## Implementation

- [ ] Document root password (or 1Password reference) at line ~33
- [ ] Document physical access details (location, key) at line ~43
- [ ] Document AdGuard Home admin password (or 1Password reference) at line ~54
- [ ] Add 1Password vault references where applicable at line ~83
- [ ] Encrypt updated file: `agenix -e hosts/hsb0/runbook-secrets.age`
- [ ] Verify encrypted file size (should be 5KB+)

## Acceptance Criteria

- [ ] All TODO items completed
- [ ] No actual passwords in plain text (use 1Password references)
- [ ] Encrypted runbook-secrets.age updated in git
- [ ] Plain text runbook-secrets.md NOT committed (gitignored)

## Notes

- Source: AUDITOR scan of hsb0 (Finding #13)
- File: `hosts/hsb0/secrets/runbook-secrets.md`
- These are for human reference during emergency recovery only
- runbook-secrets.md is gitignored (plain text)
- runbook-secrets.age is the encrypted version stored in git
