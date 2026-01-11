# User Password Configuration Warning (hsb1, csb0)

## Description

Fix the NixOS evaluation warning about multiple password options being set for user 'mba' on multiple hosts.

## Warning

```
evaluation warning: The user 'mba' has multiple of the options
`initialHashedPassword`, `hashedPassword`, `initialPassword`, `password`
& `hashedPasswordFile` set to a non-null value.
```

## Affected Hosts

- **hsb1**: `hashedPassword` + `initialHashedPassword = ""`
- **csb0**: `hashedPassword` + `initialHashedPassword = ""`

## Current State

```nix
# hsb1
users.users."mba".hashedPassword = "$y$j9T$bi9LmgTpnV.EleK4RduzQ/$eLkQ9o8n/Ix7YneRJBUNSdK6tCxAwwSYR.wL08wu1H/"
users.users."mba".initialHashedPassword = ""  # Empty string is not null!

# csb0
users.users."mba".hashedPassword = "$6$ee9NiRR00Ev9wlEZ$kFD53waKDKf5YHC.Tzwm68Iwhjey7om9Yld4i9cUBLa40HdpL8.umjtIpWnjCmzKzgsGUgS3y.Tx2UQOUp5AN."
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
grep -r "initialHashedPassword" hosts/
grep -r "initialHashedPassword" modules/
```

Likely candidates:

- **Hokage module** setting a default `initialHashedPassword = "";`
- Affects multiple hosts using Hokage
- Root cause: Empty string vs null in Hokage module

## Acceptance Criteria

- [ ] Warning no longer appears during `nixos-rebuild`
- [ ] User 'mba' can still authenticate normally

## Priority

Low — cosmetic warning, no functional impact.
