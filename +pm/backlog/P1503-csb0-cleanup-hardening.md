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

Simplify structure: run `docker compose` from the repo. Use `/var/lib/csb0-docker` only for mutable data (acme.json, volumes). Align all paths to relative for config and absolute for data.

## Acceptance Criteria

- [ ] **Simplify `csb0` Structure**:
  - [x] Remove over-engineered symlinks from `configuration.nix`.
  - [x] Use `/var/lib/csb0-docker` strictly for mutable data (acme.json, volumes).
  - [ ] Run `docker compose` directly from the git repo.
- [ ] **Cleanup `csb0` Home**:
  - [x] Remove `/home/mba/docker-backup-20260117-124057.tar.gz`
  - [x] Remove `/home/mba/docker-backup-20260117-124053.tar.gz`
  - [ ] Delete legacy `/home/mba/docker` (⚠️ verify first!).
- [ ] **Hardening Traefik**:
  - [x] Fix `docker-compose.yml`: Ensure `traefik` uses `env_file: ["./traefik/variables.env"]` and NOT `environment:` for the token.
  - [ ] Re-deploy Traefik and verify `docker inspect` no longer shows the token.
- [ ] **Repair Restic Backups**:
  - [x] Delete erroneous directories in `/var/lib/csb0-docker/restic-cron/hetzner/` (Docker created them as dirs instead of mounting files).
  - [x] Restore relative paths in `docker-compose.yml` for bind mounts.
  - [x] Fix symlink paths in `hosts/csb0/configuration.nix` to align with repo structure (simplified to remove them).
- [ ] **Documentation**:
  - [ ] Update `hosts/csb0/docs/RUNBOOK.md` with new path `/var/lib/csb0-docker`.
  - [ ] Update `hosts/csb0/docs/RUNBOOK.md` to reflect `agenix` usage for Traefik variables.

---

## Meta

- **Origin:** P4501 Split
- **Risk:** 🟡 Medium (Deleting old docker dir)
