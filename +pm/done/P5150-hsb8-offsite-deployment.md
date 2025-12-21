# hsb8 Offsite Deployment

**Created**: 2025-12-14  
**Priority**: Medium  
**Status**: Pending

## Problem

hsb8 is currently offsite and not reachable from the home network. It still has the v1 NixFleet agent configuration (or rather, it has no NixFleet agent configuration at all).

## Status: DONE ✅

Completed 2025-12-21 via WireGuard VPN to ww87.

## Access

hsb8 is accessible via Fritz!Box WireGuard VPN at ww87:

```bash
# Connect WireGuard tunnel first, then:
ssh mba@192.168.1.100
```

## Deployment Command

```bash
ssh mba@192.168.1.100 "cd ~/nixcfg && git pull && sudo nixos-rebuild switch --flake .#hsb8"
```

**Note:** Repo is at `~/nixcfg` (not `~/Code/nixcfg`)

## Verification

```bash
ssh mba@192.168.1.100 "systemctl status nixfleet-agent"
```

## Notes

- NixFleet agent v2.1.0 running successfully
- WireGuard VPN configured for remote access
