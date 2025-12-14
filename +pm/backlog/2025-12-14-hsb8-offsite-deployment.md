# hsb8 Offsite Deployment

**Created**: 2025-12-14  
**Priority**: Medium  
**Status**: Pending

## Problem

hsb8 is currently offsite and not reachable from the home network. It still has the v1 NixFleet agent configuration.

## When Available

Next time hsb8 is online (brought back home or VPN established), deploy the v2 agent:

```bash
ssh mba@hsb8.lan "cd ~/Code/nixcfg && git pull && sudo nixos-rebuild switch --flake .#hsb8"
```

## Verification

```bash
ssh mba@hsb8.lan "systemctl status nixfleet-agent && journalctl -u nixfleet-agent -n 10"
```

## Notes

- Configuration already updated in nixcfg (commit f144ca5f)
- Will auto-deploy when host is next rebuilt
- No action needed until host is reachable
