# Upgrade nixpkgs for Go 1.25.5 Support

**Priority**: P8 (Backlog)  
**Status**: BLOCKED  
**Created**: 2025-12-28  
**Blocked by**: ncps pinned to older version (ff083aff)

## Problem

ncps (Nix Cache Proxy Server) updated to require Go 1.25.5, but current nixpkgs only provides Go 1.25.4.

This broke hsb0 builds with:

```
go: go.mod requires go >= 1.25.5 (running go 1.25.4; GOTOOLCHAIN=local)
```

## Current Workaround (2025-12-28)

Pinned ncps to last working version:

```bash
nix flake lock --override-input ncps github:kalbasit/ncps/ff083aff
```

This allows hsb0 to build, but prevents ncps updates.

## Desired State

- nixpkgs provides Go 1.25.5+
- ncps can update to latest (b7653d4+)
- hsb0 builds without version pins

## Impact

**Hosts affected**: hsb0 (🔴 HIGH - crown jewel)

ncps is critical for:

- Binary cache proxy (reduces build times)
- Bandwidth savings on home network
- Offline operation capability

## Solution

```bash
cd ~/Code/nixcfg

# Update nixpkgs to get newer Go
nix flake update nixpkgs

# Remove ncps pin from flake.lock
nix flake lock --override-input ncps github:kalbasit/ncps

# Test on hsb0
ssh mba@hsb0.lan "cd ~/Code/nixcfg && git pull && just switch"
```

## Acceptance Criteria

- [ ] nixpkgs provides Go 1.25.5+
- [ ] ncps builds without version pins
- [ ] hsb0 successfully switches to new generation
- [ ] ncps service still works after upgrade

## Testing Plan

1. Test on gpc0 first (🟢 LOW risk)
2. If successful, apply to hsb0
3. Verify ncps-warmer timer still works
4. Monitor for 24h

## Notes

- ncps version timeline:
  - `ff083aff` (Dec 17): Works with Go 1.25.4 ✅ (current pin)
  - `b7653d4` (Dec 27): Requires Go 1.25.5 ❌ (blocked)
- hsb0 incident: 2025-12-28 flake.lock merge conflict → ncps build failure
- Workaround applied during incident resolution

## Related

- Host: hsb0 (configuration.nix lines 463-549)
- Dependency: kalbasit/ncps input in flake.nix
- Service: ncps.service, ncps-warmer.timer
