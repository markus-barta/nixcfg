# Tailscale & Network Setup for hsb2

**Host**: hsb2
**Priority**: P70
**Status**: Done
**Created**: 2026-02-10

---

## Problem

hsb2 runs Raspbian (not NixOS), so cannot be configured declaratively via nixcfg. Need manual Tailscale installation and network setup to integrate with fleet.

## Solution

1. Install Tailscale on Raspbian manually
2. Join headscale network
3. Test LAN/Tailscale connectivity
4. Document manual setup steps for future reference

## Implementation

- [x] SSH to hsb2: `ssh mba@192.168.1.95` ✅ (already done by user)
- [x] Install Tailscale: `curl -fsSL https://tailscale.com/install.sh | sh` ✅ (already done by user)
- [x] Generate auth key from csb0 ✅ (already done by user)
- [x] Join network: `sudo tailscale up --login-server https://hs.barta.cm --authkey <KEY>` ✅ (already done by user)
- [x] Verify connectivity: `tailscale status` ✅ (confirmed: 100.64.0.5)
- [x] Test from another host: `ssh mba@hsb2.ts.barta.cm` ✅
- [x] Add hsb2 to `modules/shared/ssh-fleet.nix` ✅
- [x] Add hsb2 fish/bash alias ✅
- [x] Document in `hosts/hsb2/README.md` ✅

## Acceptance Criteria

- [x] hsb2 appears in `tailscale status` on all nodes ✅ (100.64.0.5)
- [x] Can SSH via `ssh hsb2.ts.barta.cm` ✅
- [x] LAN connection still works (192.168.1.95) ✅
- [x] Documentation updated ✅

## Notes

- hsb2 is ARMv6l (512MB RAM) - keep Tailscale config minimal
- WiFi-only (no ethernet) - ensure stable connection before setup
- Manual setup means this host won't benefit from declarative config updates
