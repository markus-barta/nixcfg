# 2025-12-01 - Disable Catppuccin Theming

## Status: ✅ COMPLETE (2025-12-07)

## Summary

Set `hokage.catppuccin.enable = false` to cleanly disable catppuccin theming instead of using scattered workarounds.

## The Solution

```nix
# In hosts/*/configuration.nix
hokage.catppuccin.enable = false;
```

**Verified working on hsb1 (2025-12-07)** - All workarounds successfully removed!

## Acceptance Criteria

- [x] Add `hokage.catppuccin.enable = false` to hsb1 (pilot test)
- [x] Test build on hsb1 - ✅ PASSED
- [x] Test removing workarounds on hsb1 - ✅ PARTIAL (see regression below)
  - [x] Removed `starship.enable = lib.mkForce false` from common.nix
  - [x] Removed `theme = lib.mkForce` from helix (common.nix)
  - [x] Removed `force = true` from starship.toml (theme-hm.nix)
  - [x] ~~Removed `source = lib.mkForce` from zellij~~ **REVERTED** (see regression)
  - [x] Removed `force = true` from zellij (theme-hm.nix)
  - [x] Removed `force = true` from lazygit (theme-hm.nix)
- [x] Roll out `hokage.catppuccin.enable = false` to all NixOS hosts
- [x] ~~Consolidate scattered TODOs~~ → All now point to this file

## ⚠️ Regression: Zellij Still Needs lib.mkForce

**Discovered on gpc0 (2025-12-07):** Hokage provides zellij config **regardless of catppuccin.enable setting**. The zellij config comes from hokage's base module, not the catppuccin module.

**Fix applied:** Restored `lib.mkForce` for zellij source in `theme-hm.nix`:

```nix
home.file.".config/zellij" = lib.mkIf config.theme.zellij.enable {
  source = lib.mkForce (pkgs.writeTextDir "config.kdl" ...);  # mkForce REQUIRED
  recursive = true;
};
```

## Deployment Status

| Host          | Config | Deployed         |
| ------------- | ------ | ---------------- |
| hsb1          | ✅     | ✅ Verified      |
| hsb0          | ✅     | ⏳ Manual deploy |
| hsb8          | ✅     | ⏳ Manual deploy |
| gpc0          | ✅     | ✅ Verified      |
| csb0          | ✅     | ⏳ Manual deploy |
| csb1          | ✅     | ⏳ Manual deploy |
| imac0         | N/A    | N/A (uzumaki)    |
| imac-mba-work | N/A    | N/A (uzumaki)    |
| mba-mbp-work  | N/A    | N/A (uzumaki)    |

> **Note**: macOS hosts use uzumaki module directly via Home Manager and don't use hokage.

## Summary: What Still Needs lib.mkForce

| Item              | mkForce Needed? | Reason                                          |
| ----------------- | --------------- | ----------------------------------------------- |
| Helix theme       | ❌ No           | catppuccin.enable = false disables it           |
| Starship config   | ❌ No           | catppuccin.enable = false disables it           |
| Lazygit config    | ❌ No           | catppuccin.enable = false disables it           |
| **Zellij source** | ✅ **YES**      | Hokage provides zellij regardless of catppuccin |

## Notes

- `catppuccin.follows` in flake.nix must STAY (hokage depends on it as input)
- Fish syntax highlighting: see `2025-12-07-fish-tokyo-night-syntax.md`
