# 2025-12-08 - hsb0 Runbook Secrets Complete

## Description

Complete the TODO placeholders in `hosts/hsb0/secrets/runbook-secrets.md`. These are human-readable secrets for documentation purposes, not consumed by NixOS.

## Source

- Found during: AUDITOR scan of hsb0 (Finding #13)
- File: `hosts/hsb0/secrets/runbook-secrets.md`

## Scope

Applies to: hsb0

## Current State

The `runbook-secrets.md` file has incomplete TODO items at:

| Line | Section         | TODO                                      |
| ---- | --------------- | ----------------------------------------- |
| ~33  | Root Password   | Add root password or 1Password reference  |
| ~43  | Physical Access | Document physical location details        |
| ~54  | AdGuard Home    | Add admin password or 1Password reference |
| ~83  | 1Password       | Add vault references for secrets          |

## Acceptance Criteria

- [ ] Document root password (or 1Password reference)
- [ ] Document physical access details (location, key, etc.)
- [ ] Document AdGuard Home admin password (or 1Password reference)
- [ ] Add 1Password vault references where applicable
- [ ] Encrypt updated file: `agenix -e hosts/hsb0/runbook-secrets.age`

## Priority

🟡 MEDIUM - Operational documentation, not blocking

## Notes

- `runbook-secrets.md` is gitignored (plain text)
- `runbook-secrets.age` is the encrypted version stored in git
- These are for human reference during emergency recovery
- Do NOT add actual passwords to git - use 1Password references
