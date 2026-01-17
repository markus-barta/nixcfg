# P4501 - csb0/csb1 Cloudflare Token Rotation - Cleanup & QA

**Task:** csb0/csb1 Cloudflare Token Rotation - Cleanup & QA
**Status:** In Progress - Verification Complete, Documentation Pending
**Session Date:** 2026-01-17

---

## Context

**Completed Work (as of 2026-01-17):**

- ✅ Rotated Cloudflare API token (scope: `barta.cm` only, IP-filtered)
- ✅ Encrypted via agenix (`secrets/traefik-variables.age`)
- ✅ Refactored csb0 with proper directory structure (`/var/lib/csb0-docker/`)
- ✅ Token deployed to both csb0 and csb1
- ✅ Old token revoked from Cloudflare
- ✅ Git history cleaned with `git-filter-repo` (old token replaced with `***REDACTED***`)
- ✅ Force pushed to GitHub (history rewritten)
- ✅ Backup created: `../nixcfg-backup-20260117-143309.git`
- ✅ Verified services (csb0: home, cs0; csb1: grafana, influxdb, docmost)
- ✅ Verified absence of old repo `~/nixcfg` on hosts

---

## Remaining Work

### 1. Documentation Updates (MANDATORY)

- [ ] **`hosts/csb0/docs/RUNBOOK.md`**:
  - Document new directory structure (`/var/lib/csb0-docker/`)
  - Update secret management section (agenix)
- [ ] **`hosts/csb1/docs/RUNBOOK.md`**:
  - Document token rotation (2026-01-17)
  - Add TODO for docker files migration (see P4500)
- [ ] **`docs/SECRETS.md`**:
  - Document Cloudflare token scope (`barta.cm` only, IP-filtered)
  - List which hosts use which secrets (`secrets/traefik-variables.age` → csb0, csb1)
  - Document old token revoked on 2026-01-17

### 2. Cleanup Actions (Requires User Approval)

- [ ] **csb0 backup files**:
  - Remove: `/home/mba/docker-backup-20260117-124057.tar.gz`
  - Remove: `/home/mba/docker-backup-20260117-124053.tar.gz`
- [ ] **csb1 plain text secrets**:
  - 10 .env files found in `/home/mba/secrets/` and `/home/mba/docker/`.
  - Migrate to agenix (tracked in P4500).
  - Remove plain text files ONLY after verified migration.

### 3. Final QA

- [ ] Verify `.gitignore` covers `*.env` and `acme.json` across repo
- [ ] Final check of `git status` for any accidental secret leaks (none currently known)

### 4. Task Closure

- [ ] Mark `+pm/backlog/P6400-csb0-cloudflare-token-rotation.md` as complete
- [ ] Move this file (P4501) to `+pm/done/`

---

## Issues/Notes Discovered

1. **csb1 plain text secrets**: 10 .env files contain unencrypted secrets. Migration is tracked in P4500 (csb1 docker files to repo).
2. **Restored Secrets**: On 2026-01-17, 4 `.age` files were restored after being truncated to 578B by a faulty rekey (see chat history). Verified and fixed.

---

## Meta

- **Priority:** P6 (Low-Medium)
- **Effort:** Low (1-2 hours)
- **Origin:** Follow-up to P6400 token rotation
