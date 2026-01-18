# P1504 - csb1 documentation and plain-text secret audit (from P4501)

**Created**: 2026-01-18  
**Priority**: P1504 (Critical)
**Status**: Backlog

---

## Context

`csb1` is still using legacy paths and has 14 plain-text `.env` files. Documentation is completely out of sync with the 2026-01-17 changes.

## Acceptance Criteria

- [ ] **Audit `csb1` Secrets**:
  - Identify all 14 `.env` files found in `/home/mba/docker` and `/home/mba/secrets`.
  - Cross-reference with P2500 (migration plan).
- [ ] **Sync Documentation**:
  - Update `hosts/csb1/docs/RUNBOOK.md` to reflect token rotation on 2026-01-17.
  - Update `docs/SECRETS.md` with Cloudflare token details (scope, IP filtering, agenix path).
  - List `secrets/traefik-variables.age` usage for both `csb0` and `csb1`.
- [ ] **Cleanup**:
  - Remove any obsolete files on `csb1` once P2500 migration is verified.

---

## Meta

- **Origin:** P4501 Split
- **Risk:** 🟢 Low
