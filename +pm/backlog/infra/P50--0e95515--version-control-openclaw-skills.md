# Version Control OpenClaw Skills

**Host**: hsb0, miniserver-bp
**Priority**: P50
**Status**: Backlog
**Created**: 2026-02-15

---

## Problem

OpenClaw custom skills live in runtime data dirs (`/var/lib/openclaw-*/data/workspace/skills/`) and aren't version-controlled. Changes, updates, and skill definitions are only backed up via host backups, not tracked in nixcfg repo.

Current skills:

- **Merlin (hsb0)**: calendar, home-assistant, opus-gateway, openrouter-free-models, m365-email
- **Percy (msbp)**: m365-email, openrouter-free-models

## Solution

Version-control skill SKILL.md files in nixcfg repo under `hosts/<host>/docker/openclaw-*/skills/`. Deploy via activation script or compose volume mount.

## Implementation

- [ ] Design sync pattern: repo → runtime or runtime → repo?
- [ ] Decide: seed on first boot only, or overwrite on every deploy?
- [ ] Create `hosts/hsb0/docker/openclaw-merlin/skills/` with current SKILL.md files
- [ ] Create `hosts/miniserver-bp/docker/openclaw-percaival/skills/` with current SKILL.md files
- [ ] Add activation script or compose volume mount to deploy skills
- [ ] Document skill development workflow (edit in repo vs edit in runtime)
- [ ] Test: modify skill in repo, deploy, verify in container

## Acceptance Criteria

- [ ] All skill SKILL.md files tracked in nixcfg repo
- [ ] Skills deploy automatically on container (re)start
- [ ] Clear docs on when/how to edit skills (repo vs runtime)
- [ ] No risk of losing skill changes between backups

## Notes

- Runtime data also includes skill state (enabled/disabled, config) — keep that in `/var/lib`
- Only SKILL.md files need version control (skill logic, not state)
- Related: P40--3c1b0d8 (harmonization) — extracted this for focus
