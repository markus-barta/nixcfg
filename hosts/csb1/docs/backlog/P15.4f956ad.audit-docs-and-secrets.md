# audit-docs-and-secrets

**Host**: csb1
**Priority**: P15
**Status**: Backlog
**Created**: 2026-01-18

---

## Problem

csb1 still uses legacy paths and has 14 plain-text `.env` files. Documentation is completely out of sync with 2026-01-17 changes.

## Solution

Audit all secrets, update documentation to reflect current state, and clean up obsolete files after P2500 migration completes.

## Implementation

- [ ] Audit csb1 secrets: Identify all 14 `.env` files in `/home/mba/docker` and `/home/mba/secrets`
- [ ] Cross-reference with P2500 migration plan
- [ ] Update `hosts/csb1/docs/RUNBOOK.md` to reflect token rotation (2026-01-17)
- [ ] Update `docs/SECRETS.md` with Cloudflare token details (scope, IP filtering, agenix path)
- [ ] Document `secrets/traefik-variables.age` usage for both csb0 and csb1
- [ ] Remove obsolete files on csb1 once P2500 migration verified

## Acceptance Criteria

- [ ] All 14 `.env` files catalogued
- [ ] RUNBOOK.md reflects current configuration
- [ ] SECRETS.md updated with Cloudflare token details
- [ ] Obsolete files removed from csb1
- [ ] No plain-text secrets remain on host

## Notes

- Origin: P4501 Split
- Risk: 🟢 Low (documentation cleanup)
- Blocked by: P2500 (migration plan execution)
