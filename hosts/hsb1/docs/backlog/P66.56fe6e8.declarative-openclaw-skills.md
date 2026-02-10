# declarative-openclaw-skills

**Host**: hsb1
**Priority**: P66
**Status**: Backlog
**Created**: 2026-02-02

---

## Problem

OpenClaw skills are currently managed imperatively within the workspace. In a NixOS-managed environment, this deviates from the declarative system philosophy.

## Solution

Define active skills (Docker, Home Assistant) directly in `configuration.nix` by linking skills from Nix store into OpenClaw workspace during service `preStart`.

## Implementation

- [ ] Identify needed skills (Docker, Home Assistant)
- [ ] Update `openclaw-gateway` service `preStart` script in configuration.nix
- [ ] Use `ln -sfT` to link skills from `${openclaw}/lib/openclaw/skills/` to `/home/mba/.openclaw/workspace/skills/`
- [ ] Ensure proper permissions for `mba` user
- [ ] Run `nixos-rebuild switch` on hsb1
- [ ] Verify symlinks created in `~/.openclaw/workspace/skills/`
- [ ] Test skill availability via OpenClaw (docker status, HA entities)

## Acceptance Criteria

- [ ] `openclaw-gateway` service preStart script updated with skill linking
- [ ] Skills appear as read-only symlinks in `~/.openclaw/workspace/skills/`
- [ ] OpenClaw recognizes and loads skills after service restart
- [ ] Can query docker status via OpenClaw
- [ ] Can query HA entities via OpenClaw

## Notes

- Depends on: P9400-hsb1-openclaw-deployment.md
- Automated test: `ls -l /home/mba/.openclaw/workspace/skills/docker | grep "/nix/store/"`
