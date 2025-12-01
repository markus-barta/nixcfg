# 2025-12-01 - Disable Catppuccin Theming

## Description

Disable catppuccin theming via `hokage.catppuccin.enable = false`.

**Note**: The `catppuccin.follows` in flake.nix must stay — hokage depends on it as an input even when theming is disabled.

## Current State

### Workarounds We Have (Overkill)

We're using multiple workarounds to override catppuccin:

| Workaround                                     | Location     | Purpose                       |
| ---------------------------------------------- | ------------ | ----------------------------- |
| `hokage.programs.starship.enable = false`      | common.nix   | Disable hokage's starship     |
| `hokage.programs.atuin.enable = false`         | common.nix   | Disable atuin (causes issues) |
| `programs.starship.enable = lib.mkForce false` | common.nix   | Prevent home-manager conflict |
| `force = true` on config files                 | theme-hm.nix | Our Tokyo Night wins          |
| helix `theme = lib.mkForce "tokyonight_storm"` | common.nix   | Override hokage's catppuccin  |

### The Clean Solution

The external hokage module has `hokage.catppuccin.enable` option (defaults to `true`):

```nix
# From pbek/nixcfg modules/hokage/catppuccin.nix
options.hokage.catppuccin = {
  enable = lib.mkEnableOption "Catppuccin theme" // {
    default = true;
  };
};
```

**We can just set `hokage.catppuccin.enable = false`!**

## Acceptance Criteria

- [ ] Add `hokage.catppuccin.enable = false` to common.nix
- [ ] Test build: `nixos-rebuild build --flake .#hsb0`
- [ ] Remove redundant workarounds if catppuccin is fully disabled
- [ ] Verify fish syntax highlighting changes (currently catppuccin)
- [ ] Keep `catppuccin.follows` in flake.nix (hokage depends on it)

## Test Plan

### Manual Test

```bash
# 1. Add to common.nix
hokage.catppuccin.enable = false;

# 2. Build test
nixos-rebuild build --flake .#hsb0
```

### Automated Test

```bash
# After deployment, check starship config
grep -i catppuccin ~/.config/starship.toml
# Expected: no matches (Tokyo Night only)

# Check if fish still has catppuccin colors
# (visual inspection needed)
```

## Notes

- **Priority**: Low - current workarounds work fine
- `catppuccin.follows` must stay in flake.nix (hokage depends on it)
- Fish syntax highlighting is the last catppuccin artifact
