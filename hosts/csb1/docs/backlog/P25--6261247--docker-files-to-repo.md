# docker-files-to-repo

**Host**: csb1
**Priority**: P25
**Status**: Backlog
**Created**: 2026-01-17

---

## Problem

csb1 docker configuration files only exist on server (`/home/mba/docker/`), not in git. No version control, disaster recovery capability, or change tracking. Inconsistent with csb0 pattern.

## Solution

Migrate csb1 docker files to git repository matching csb0 pattern. Create `hosts/csb1/docker/` structure with proper systemd.tmpfiles rules for immutable config symlinks and mutable state separation.

## Implementation

- [ ] Create `hosts/csb1/docker/{traefik,restic-cron}` directories
- [ ] Copy files from csb1: docker-compose.yml, traefik configs, restic-cron scripts
- [ ] **Do NOT copy**: acme.json, variables.env, any .env files with credentials
- [ ] Add to git: `git add hosts/csb1/docker/ && git commit`
- [ ] Update `hosts/csb1/configuration.nix` with systemd.tmpfiles rules
- [ ] Update agenix secret path to `/var/lib/csb1-docker/traefik/variables.env`
- [ ] Backup current acme.json: `tar czf ~/docker-backup-$(date).tar.gz ~/docker/traefik/acme.json`
- [ ] Deploy: git pull, nixos-rebuild switch
- [ ] Verify symlinks: `readlink /home/mba/docker` → `/var/lib/csb1-docker`
- [ ] Restore acme.json and restart Traefik
- [ ] Test all services: grafana, influxdb, docmost, paperless
- [ ] Update README.md and RUNBOOK.md
- [ ] Remove backup files after verification

## Acceptance Criteria

- [ ] All config files in git (hosts/csb1/docker/)
- [ ] tmpfiles rules create proper structure
- [ ] Symlinks correct (repo → /var/lib/csb1-docker/)
- [ ] All services working (HTTP/2 responses)
- [ ] Documentation updated
- [ ] Legacy /home/mba/docker is now symlink

## Notes

- Origin: Identified during P6400 token rotation (2026-01-17)
- Pattern: Same as csb0 (see commit 087e78ec)
- Benefits: IaC, disaster recovery, change tracking, consistency
- Effort: Medium (2-3 hours)
- Depends on: P6400 completed, csb1 SSH accessible, Docker services stable
