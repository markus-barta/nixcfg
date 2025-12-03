# hsb1 User Password Configuration Warning

## Description

Fix the NixOS evaluation warning about multiple password options being set for user 'mba' on hsb1.

## Warning

```
evaluation warning: The user 'mba' has multiple of the options
`initialHashedPassword`, `hashedPassword`, `initialPassword`, `password`
& `hashedPasswordFile` set to a non-null value.
```

## Current State

```nix
users.users."mba".hashedPassword = "$y$j9T$bi9LmgTpnV.EleK4RduzQ/$eLkQ9o8n/Ix7YneRJBUNSdK6tCxAwwSYR.wL08wu1H/"
users.users."mba".initialHashedPassword = ""  # Empty string is not null!
```

## Root Cause

`initialHashedPassword = ""` (empty string) is not the same as `null`. The empty string counts as "set", triggering the warning.

## Fix

Find where `initialHashedPassword` is being set and either:

1. Remove it entirely (if `hashedPassword` is the intended source)
2. Set it explicitly to `null`: `initialHashedPassword = lib.mkForce null;`

## Investigation

```bash
# Find where initialHashedPassword is set
grep -r "initialHashedPassword" hosts/hsb1/
grep -r "initialHashedPassword" modules/
```

Likely candidates:

- hokage module setting a default
- Local configuration override

## Acceptance Criteria

- [ ] Warning no longer appears during `nixos-rebuild`
- [ ] User 'mba' can still authenticate normally

## Priority

Low — cosmetic warning, no functional impact.
