# 2025-12-08 - hsb1 Runbook Secrets Complete

## Description

Complete the TODO placeholders in `hosts/hsb1/secrets/runbook-secrets.md`. These are human-readable secrets for documentation purposes, not consumed by NixOS.

## Source

- Found during: AUDITOR scan of hsb1 (Finding #9)
- File: `hosts/hsb1/secrets/runbook-secrets.md`

## Scope

Applies to: hsb1

## Current State

The `runbook-secrets.md` file has ~20 incomplete TODO items including:

| Section              | Missing                                  |
| -------------------- | ---------------------------------------- |
| Home Assistant       | Admin credentials, API token             |
| Node-RED             | Admin credentials                        |
| Scrypted             | Admin credentials                        |
| MQTT Broker          | smarthome user password                  |
| Tapo Cameras         | Camera credentials                       |
| Restic Backup        | Repository password, Hetzner credentials |
| 1Password References | Vault IDs and item references            |

## Acceptance Criteria

- [ ] Document Home Assistant admin credentials (or 1Password ref)
- [ ] Document Node-RED admin credentials (or 1Password ref)
- [ ] Document MQTT smarthome password (or 1Password ref)
- [ ] Document Scrypted admin credentials (or 1Password ref)
- [ ] Document Tapo camera credentials (or 1Password ref)
- [ ] Document Restic backup credentials (or 1Password ref)
- [ ] Add 1Password vault references where applicable
- [ ] Encrypt updated file: `just encrypt-runbook-secrets hsb1`

## Priority

🟡 MEDIUM - Operational documentation, important for disaster recovery

## Notes

- `runbook-secrets.md` is gitignored (plain text for editing)
- `runbook-secrets.age` is the encrypted version stored in git
- These are for human reference during emergency recovery
- Check existing `~/secrets/` files on hsb1 for current values
- Do NOT add actual passwords to git - use 1Password references
