# NixFleet Deployment to csb1

**Created**: 2025-12-10
**Completed**: 2025-12-10
**Priority**: High
**Status**: ✅ Complete

---

## Summary

Successfully deployed NixFleet v0.1-alpha fleet management dashboard to csb1 with agents on all accessible hosts.

---

## What Was Done

### Dashboard Deployment

- [x] Dashboard deployed to csb1 via Docker Compose
- [x] Accessible at https://fleet.barta.cm
- [x] TOTP + password authentication working
- [x] Tokyo Night Plus theme applied

### Agent Deployment

- [x] NixOS module created: `modules/nixfleet-agent.nix`
- [x] Home Manager module created: `modules/home/nixfleet-agent.nix`
- [x] Agents deployed on all reachable hosts:
  - csb0 ✅ (cloud)
  - csb1 ✅ (cloud)
  - hsb0 ✅ (home)
  - hsb1 ✅ (home)
  - imac0 ✅ (desktop)
  - gpc0 ✅ (confirmed working, now offline)
- [x] Hosts pending (not reachable):
  - hsb8 (remote network - parents' home)
  - mba-mbp-work (work laptop - needs token file)
  - imac-mba-work (work iMac - needs token file)

### Features Working

- [x] Host registration with metadata
- [x] Real-time status and heartbeat
- [x] Git hash version tracking with outdated indicator
- [x] Pull, Switch, Test commands
- [x] Git hash caching (avoids calling git every 10s)
- [x] safe.directory fix for root-owned git operations

### Secret Management

- [x] API token encrypted with agenix
- [x] Token deployed to all NixOS hosts via `age.secrets`
- [x] macOS hosts use `~/.config/nixfleet/token`

---

## Key Fixes During Deployment

1. **Git hash "unknown"** - Fixed by adding `-c safe.directory` to bypass ownership check when root accesses user-owned repo
2. **macOS PATH issues** - Fixed by explicitly adding `home-manager` to PATH in launchd config
3. **Host ID validation** - Fixed by using `hostname -s` for short hostname
4. **Caching** - Implemented git hash caching to avoid repeated git calls

---

## Update Procedure

```bash
# Update dashboard
ssh -p 2222 mba@cs1.barta.cm "cd ~/Code/nixcfg && git pull && cd ~/docker/nixfleet && ./update.sh"

# Update NixOS hosts
ssh mba@HOST "cd ~/Code/nixcfg && git pull && sudo nixos-rebuild switch --flake .#HOST"

# Update macOS hosts
cd ~/Code/nixcfg && git pull && home-manager switch --flake .#HOST
```
