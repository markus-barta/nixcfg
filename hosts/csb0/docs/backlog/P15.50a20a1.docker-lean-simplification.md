# docker-lean-simplification

**Host**: csb0
**Priority**: P15
**Status**: Backlog
**Created**: 2026-01-18

---

## Problem

Current csb0 Docker setup is over-engineered with custom Nix-managed directory (`/var/lib/csb0-docker`), complex symlinks, and mixed ownership causing "unsafe path transition" errors, broken Restic mounts, and OCI runtime failures.

## Solution

Pivot to "Standard Docker Lean" pattern:

- **Config**: Run directly from git repo (`~/Code/nixcfg/hosts/csb0/docker/`) using relative bind mounts
- **Data**: Use Named Docker Volumes managed by Docker (`/var/lib/docker/volumes`)
- **Infrastructure**: Remove all `tmpfiles.rules` attempting manual Docker structure management

## Implementation

- [ ] Refactor docker-compose.yml: Convert nodered, mosquitto, uptime-kuma to Named Volumes
- [ ] Move `acme.json` from `/var/lib/csb0-docker/traefik/` to `./traefik/acme.json` (gitignored)
- [ ] Remove `systemd.tmpfiles.rules` related to `csb0-docker` in configuration.nix
- [ ] Migrate data from `/var/lib/csb0-docker/<service>` into new named volumes (bridge container if needed)
- [ ] Set `acme.json` permissions to `0600`
- [ ] Run `docker compose up -d` and verify all services retain state
- [ ] Verify Restic backups still cover `/var/lib/docker/volumes`
- [ ] Update documentation

## Acceptance Criteria

- [ ] All services using Named Volumes
- [ ] No tmpfiles.rules for Docker management
- [ ] Services retain history and sessions after migration
- [ ] acme.json has correct permissions (0600)
- [ ] Backups covering new volume location

## Notes

- Depends on: P1503 (Done)
- Risk: Data migration requires careful `cp -a` while containers stopped
- `/var/lib/csb0-docker` will be removed after successful migration
- Repo on host: `/home/mba/Code/nixcfg/` (single source of truth)
