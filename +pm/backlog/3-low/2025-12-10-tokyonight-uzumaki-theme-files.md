# Extract Starship/Zellij to tokyonight-uzumaki theme files

**Created**: 2025-12-10
**Priority**: Low
**Type**: Refactoring

## Summary

For naming consistency, consider extracting the Starship and Zellij theme configurations to dedicated files with the `tokyonight-uzumaki` naming convention.

## Current State

- **Eza**: `theme/eza-themes/tokyonight-uzumaki.yml` (static file)
- **Starship**: Generated dynamically inline in `theme-hm.nix` from `starship-template.toml`
- **Zellij**: Generated dynamically inline in `theme-hm.nix`

## Suggested Changes

### Option A: Rename template files

- `starship-template.toml` → `tokyonight-uzumaki-starship.toml`

### Option B: Extract Zellij to file

- Extract Zellij theme from `theme-hm.nix` to `theme/tokyonight-uzumaki-zellij.kdl`
- Import and process in `theme-hm.nix`

## Notes

- Low priority since current setup works fine
- Mainly for naming consistency across the theme system
- Starship/Zellij are dynamically generated per-host (colors vary), so file extraction may not add much value
- The eza theme is static (same for all hosts), making a dedicated file more valuable there
