# secrets-management

**Host**: imac0
**Priority**: P59
**Status**: Done
**Created**: 2025-12-01
**Completed**: 2026-01-07

---

## Problem

No structured secrets management for personal workstation. API keys, camera tokens, and environment variables stored inconsistently. Need age-based encryption for macOS workstation secrets.

## Solution

Implement `~/Secrets/` flat structure with age encryption using existing SSH key. Three-tier separation:

- Tier 1: System services (`secrets/` with agenix)
- Tier 2: Runbook docs (`hosts/*/runbook-secrets.age`)
- Tier 3: Personal workstation secrets (`~/Secrets/` - this task)

## Implementation

- [x] Create `~/Secrets/{encrypted,decrypted,scripts}` structure
- [x] Configure `.gitignore` (decrypted/ ignored)
- [x] Create scripts: encrypt.sh, decrypt.sh, list.sh
- [x] Get age public key: `age-keygen -y ~/.ssh/id_rsa`
- [x] Make scripts executable
- [x] Git init and configure remote (SSH or HTTPS)
- [x] Test with sample secret (tapo-test)
- [x] Migrate existing secrets (camera tokens, API keys)
- [x] Add justfile commands (private-\* prefix)
- [x] Document in `docs/SECRETS.md`

## Acceptance Criteria

- [x] `~/Secrets/` directory structure created
- [x] Scripts functional with age public key
- [x] Git repo initialized with configurable remote
- [x] Camera token tested and working
- [x] Just commands work (private-encrypt-commit, private-pull-decrypt)
- [x] Documentation complete

## Notes

- Scope: API keys, camera tokens, personal env vars
- Encryption: SSH key (~/.ssh/id_rsa) with passphrase
- Pattern: Decrypt and keep (manual control)
- Security: Encrypted files in git, decrypted gitignored
- Documentation: `docs/SECRETS.md`
- Effort: 1-2 hours
