# 2025-12-01 - Disable Catppuccin Theming

## Status: IN PROGRESS (hsb1 verified, rollout pending)

## Summary

Set `hokage.catppuccin.enable = false` to cleanly disable catppuccin theming instead of using scattered workarounds.

## The Solution

The external hokage module HAS the option:

```nix
# In hosts/*/configuration.nix
hokage.catppuccin.enable = false;
```

**Verified working on hsb1 (2025-12-07)** - All workarounds successfully removed!

## Acceptance Criteria

- [x] Add `hokage.catppuccin.enable = false` to hsb1 (pilot test)
- [x] Test build on hsb1 - ✅ PASSED
- [x] Test removing workarounds on hsb1 - ✅ ALL PASSED (2025-12-07)
  - [x] Removed `starship.enable = lib.mkForce false` from common.nix
  - [x] Removed `theme = lib.mkForce` from helix (common.nix)
  - [x] Removed `force = true` from starship.toml (theme-hm.nix)
  - [x] Removed `source = lib.mkForce` from zellij (theme-hm.nix)
  - [x] Removed `force = true` from zellij (theme-hm.nix)
  - [x] Removed `force = true` from lazygit (theme-hm.nix)
- [ ] Roll out `hokage.catppuccin.enable = false` to all hosts
- [x] ~~Consolidate scattered TODOs~~ → All now point to this file

## Remaining Hosts to Update

| Host                               | Status             |
| ---------------------------------- | ------------------ |
| hsb1                               | ✅ Complete        |
| hsb0, hsb8, gpc0                   | ⏳ Pending         |
| csb0, csb1                         | ⏳ Pending         |
| imac0, imac-mba-work, mba-mbp-work | ⏳ Pending (macOS) |

## Implementation

Add to each host's `configuration.nix`:

```nix
hokage.catppuccin.enable = false;
```

## Notes

- **All workarounds verified removable** on hsb1 (2025-12-07)
- `catppuccin.follows` in flake.nix must STAY (hokage depends on it as input)
- Fish syntax highlighting: see `2025-12-07-fish-tokyo-night-syntax.md`
