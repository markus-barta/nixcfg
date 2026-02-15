# openclaw-update-automation

**Priority**: P50
**Status**: Backlog
**Created**: 2026-02-15

---

## Problem

OpenClaw updates daily. Updates are manual SSH + rebuild on each host. Easy to forget, no version tracking, no health checks.

## Approach

Single update script, two triggers: weekly systemd timer (Saturday 9am) + on-demand via `just openclaw-update`. Script does: rebuild → restart → health check → version log → notify on failure.

Risk is low — personal AI assistants, not production. Auto-update is fine.

## Script: `openclaw-update.sh`

Per host, does:

1. Log current version (`openclaw --version` inside container)
2. `docker compose build --no-cache`
3. `docker compose up -d`
4. Health check: container running + port 18789 responds
5. Log new version to `/var/lib/openclaw-*/version.txt`
6. On failure: notify via Telegram

## Triggers

- **Weekly**: systemd timer, Saturday 09:00, on each host
- **On-demand**: `just openclaw-update <host|all>` from workstation (SSH)

## Implementation

- [ ] Create `openclaw-update.sh` script (shared, deployed to each host)
- [ ] Systemd timer + service unit on hsb0
- [ ] Systemd timer + service unit on miniserver-bp (after P40--3c1b0d8)
- [ ] `just openclaw-update` recipe (SSH wrapper)
- [ ] Optional: `just openclaw-status` — version check across hosts
- [ ] Docs update

## Acceptance Criteria

- [ ] Saturday 9am auto-rebuild works on hsb0
- [ ] `just openclaw-update hsb0` triggers rebuild on demand
- [ ] Health check catches failures + notifies via Telegram
- [ ] Version logged before/after each update
- [ ] Works for both hosts

## Notes

- Depends on P40--3c1b0d8 (msbp migrate to compose) for miniserver-bp
- hsb0 can be implemented now (already on docker-compose)
- Old backlog P48--025353e is stale (Nix-era) — superseded by this
- P50--1bd1075 (auto-update-check) merged into this — `@latest` npm deps auto-update on rebuild; optionally check pinned deps like gogcli for new releases
