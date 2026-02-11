# vlc-kiosk-declarative

**Host**: hsb1
**Priority**: P93
**Status**: Backlog
**Created**: 2026-01-13

---

## Problem

VLC kiosk mode currently managed manually. Need declarative NixOS configuration for TV display.

## Solution

Configure VLC kiosk mode declaratively in `hosts/hsb1/configuration.nix` using systemd service.

## Implementation

- [ ] Create systemd service for VLC kiosk
- [ ] Configure VLC to launch in fullscreen/kiosk mode
- [ ] Set up media playlist or stream URL
- [ ] Configure auto-start on boot
- [ ] Set display output settings
- [ ] Add to NixOS configuration
- [ ] Test kiosk mode startup
- [ ] Document in RUNBOOK.md

## Acceptance Criteria

- [ ] VLC kiosk service defined in configuration.nix
- [ ] Auto-starts on boot in kiosk mode
- [ ] Fullscreen on correct display
- [ ] Media plays automatically
- [ ] No manual intervention needed
- [ ] Documentation updated

## Notes

- Current: Manually managed VLC kiosk
- Target: Fully declarative via NixOS systemd service
- Related: Consider combining with P5500 (Docker restructure)
- Priority: 🟢 Low (current manual setup works)
