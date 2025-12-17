# mba-imac-work Offsite Deployment

**Created**: 2025-12-14  
**Priority**: Low  
**Status**: COMPLETE

## Problem

mba-imac-work is at the BYTEPOETS office and not accessible from home network. It still has the v1 NixFleet agent configuration.

## When Available

Next time at the office, deploy the v2 agent:

```bash
cd ~/Code/nixcfg && git pull
home-manager switch --flake ".#markus@mba-imac-work"
```

## Verification

```bash
launchctl list | grep nixfleet
cat /tmp/nixfleet-agent.log | tail -20
```

## Notes

- Configuration already updated in nixcfg (commit f144ca5f)
- Will auto-deploy when home-manager switch is run
- No action needed until at office
