# P1503 - csb0 cleanup & secret hardening (from P4501)

**Created**: 2026-01-18  
**Priority**: P1503 (Critical)
**Status**: In Progress
**Depends on**: P1501 (Done)

---

## Problem

Token rotation is done, but `csb0` is in a messy intermediate state.

- `/var/lib/csb0-docker` is created but `/home/mba/docker` still exists with duplicate data.
- Traefik leaks the token in `docker inspect`.
- Old backup tarballs are cluttering `~`.
- **CRITICAL**: Restic backup container is mounting directories instead of files (broken mounts).

## Solution

Align all paths to `/var/lib/csb0-docker`, fix Traefik environment exposure, and repair the Restic mount configuration.

## Acceptance Criteria

- [x] **Cleanup `csb0` Home**:
  - Remove `/home/mba/docker-backup-20260117-124057.tar.gz`
  - Remove `/home/mba/docker-backup-20260117-124053.tar.gz`
  - Verify `/var/lib/csb0-docker` is the source of truth for all services.
  - Delete legacy `/home/mba/docker` (⚠️ verify first!).
- [ ] **Hardening Traefik**:
  - Fix `docker-compose.yml`: Ensure `traefik` uses `env_file: ["./traefik/variables.env"]` and NOT `environment:` for the token.
  - Re-deploy Traefik and verify `docker inspect` no longer shows the token.
- [x] **Repair Restic Backups**:
  - Delete erroneous directories in `/var/lib/csb0-docker/restic-cron/hetzner/` (Docker created them as dirs instead of mounting files).
  - Restore relative paths in `docker-compose.yml` for bind mounts.
  - Fix symlink paths in `hosts/csb0/configuration.nix` to align with repo structure.
- [ ] **Documentation**:
  - Update `hosts/csb0/docs/RUNBOOK.md` with new path `/var/lib/csb0-docker`.
  - Update `hosts/csb0/docs/RUNBOOK.md` to reflect `agenix` usage for Traefik variables.

---

## Meta

- **Origin:** P4501 Split
- **Risk:** 🟡 Medium (Deleting old docker dir)
