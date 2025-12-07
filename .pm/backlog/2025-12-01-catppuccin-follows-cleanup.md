# 2025-12-01 - Disable Catppuccin Theming

## Status: BACKLOG (Low Priority)

## Summary

Set `hokage.catppuccin.enable = false` to cleanly disable catppuccin theming instead of using scattered workarounds.

**Current state**: Workarounds work fine. This is a cleanup task, not a fix.

## The Problem

We're using multiple workarounds to override catppuccin with Tokyo Night:

| Workaround                                     | Location       | Purpose              |
| ---------------------------------------------- | -------------- | -------------------- |
| `programs.starship.enable = lib.mkForce false` | common.nix:322 | Prevent HM conflict  |
| `theme = lib.mkForce "tokyonight_storm"`       | common.nix:378 | Override helix theme |
| `force = true` on config files                 | theme-hm.nix   | Our Tokyo Night wins |
| TODOs about catppuccin                         | 5+ locations   | Scattered notes      |

## The Clean Solution

The external hokage module HAS the option (confirmed in pbek-nixcfg):

```nix
# pbek-nixcfg/modules/hokage/catppuccin.nix
options.hokage.catppuccin = {
  enable = lib.mkEnableOption "Catppuccin theme" // { default = true; };
};
```

**We just need to set it!**

## Acceptance Criteria

- [x] Add `hokage.catppuccin.enable = false` to hsb1 (pilot test)
- [x] Test build on hsb1 - ✅ PASSED (2025-12-07)
  - Starship: No catppuccin, Tokyo Night green palette
  - Helix: tokyonight_storm theme
  - Fish functions: All working
  - Running generation 141
- [x] Test removing workarounds on hsb1 - ✅ PASSED (2025-12-07)
  - Removed `starship.enable = lib.mkForce false` from common.nix
  - Starship still works with Tokyo Night theme
  - No catppuccin contamination
- [ ] Roll out to all hosts if successful
- [ ] Remove remaining workarounds (helix mkForce, force=true)
- [x] ~~Consolidate scattered TODOs~~ → All now point to this file

## Implementation

```nix
# In modules/common.nix or per-host configuration.nix
hokage.catppuccin.enable = false;
```

Then test if workarounds can be removed.

## Notes

- **Priority**: Low - workarounds work perfectly fine
- **Risk**: Low - just disabling a theme
- `catppuccin.follows` in flake.nix must STAY (hokage depends on it as input)
- Fish syntax highlighting: see `2025-12-07-fish-tokyo-night-syntax.md`
