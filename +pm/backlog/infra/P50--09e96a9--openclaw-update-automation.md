# openclaw-update-automation

**Priority**: P50
**Status**: Backlog
**Created**: 2026-02-15

---

## Problem

OpenClaw updates daily. Updates are manual SSH + rebuild on each host. Easy to forget, no version tracking, no health checks.

## Approach

Three-tier: check → update → verify. All via `just` recipes. Assumes both hosts use docker-compose (depends on P40--3c1b0d8).

## Tiers

**Tier 1 — Check** (safe, can run on timer)

- Compare running version vs `npm view openclaw version`
- Report delta, optionally notify

**Tier 2 — Update** (triggered by user)

- `docker compose build --no-cache && docker compose up -d` per host
- Sequential: hsb0 first (canary), then miniserver-bp
- Log old→new version

**Tier 3 — Verify** (automatic post-update)

- Container running? Port 18789 responding? Telegram bot alive?
- Rollback to previous image on failure

## Implementation

- [ ] `just openclaw-check` — version diff across hosts
- [ ] `just openclaw-update <host|all>` — rebuild + restart
- [ ] `just openclaw-verify <host|all>` — health checks
- [ ] Version logging (e.g. `/var/lib/openclaw-*/version.txt`)
- [ ] Docs update

## Acceptance Criteria

- [ ] `just openclaw-check` reports version delta
- [ ] `just openclaw-update hsb0` rebuilds + restarts Merlin
- [ ] `just openclaw-verify hsb0` confirms healthy
- [ ] Works for both hosts

## Notes

- Depends on P40--3c1b0d8 (msbp migrate to compose)
- Old backlog P48--025353e is stale (Nix-era) — superseded by this
