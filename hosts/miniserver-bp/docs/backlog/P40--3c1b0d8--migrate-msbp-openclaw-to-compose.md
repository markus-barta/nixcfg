# migrate-msbp-openclaw-to-compose

**Host**: miniserver-bp
**Priority**: P40
**Status**: Backlog
**Created**: 2026-02-15

---

## Problem

Percy runs via NixOS `oci-containers` — adds systemd mask/unmask hassle, requires `nixos-rebuild` for container tweaks, no direct `docker compose` workflow. hsb0 (Merlin) uses plain docker-compose and it's simpler.

## Changes

1. Create `hosts/miniserver-bp/docker/docker-compose.yml` (model after hsb0's)
2. Move existing `Dockerfile` into that docker dir (already there)
3. Remove `virtualisation.oci-containers` block from `configuration.nix` (~lines 230-256)
4. Keep activation script for dir creation + `openclaw.json` seeding
5. Keep agenix secrets, mount them via compose volumes (same paths)
6. Map M365 + gogcli secrets via compose env_file or volume mounts
7. Update OPENCLAW-RUNBOOK.md (new start/stop/update commands)

## Acceptance Criteria

- [ ] `docker compose up -d` starts Percy on port 18789
- [ ] Telegram bot responds
- [ ] M365 + gogcli integrations work
- [ ] No `oci-containers` reference in configuration.nix
- [ ] RUNBOOK updated
