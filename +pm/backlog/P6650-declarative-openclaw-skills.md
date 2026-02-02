# Declarative OpenClaw Skills in NixOS

**Created**: 2026-02-02  
**Priority**: P6650 (Medium/Low)  
**Status**: Backlog  
**Depends on**: P9400-hsb1-openclaw-deployment.md

---

## Problem

Currently, OpenClaw skills are managed imperatively within the workspace. In a NixOS-managed environment like `hsb1`, this is not ideal as it deviates from the declarative nature of the system. We want to define active skills (like Docker, Home Assistant) directly in the Nix configuration.

---

## Solution

Modify the `openclaw-gateway` service definition in `configuration.nix` (hsb1) to link skills from the Nix store into the OpenClaw workspace during the `preStart` phase.

1.  Identify needed skills (Docker, Home Assistant).
2.  Update `preStart` script to use `ln -sfT` for linking skill directories from `${openclaw}/lib/openclaw/skills/` to `/home/mba/.openclaw/workspace/skills/`.
3.  Ensure proper permissions for the `mba` user.

---

## Acceptance Criteria

- [ ] `openclaw-gateway` service preStart script updated with skill linking.
- [ ] Skills appear as (read-only) symlinks in `~/.openclaw/workspace/skills/`.
- [ ] OpenClaw recognizes and loads the skills after service restart.

---

## Test Plan

### Manual Test

1. Run `nixos-rebuild switch` on hsb1.
2. Check `ls -la ~/.openclaw/workspace/skills/`.
3. Verify skill availability via OpenClaw (e.g., asking for docker status or HA entities).

### Automated Test

```bash
# Verify symlink exists and points to nix store
ls -l /home/mba/.openclaw/workspace/skills/docker | grep "/nix/store/"
```
