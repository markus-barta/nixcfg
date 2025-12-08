# Host Colors: Single Source of Truth Refactor

## Problem

When changing host colors (e.g., swapping imac0 and mba-mbp-work), updates are needed in **7 files** with hardcoded references:

1. `modules/uzumaki/theme/theme-palettes.nix` - hostPalette map (SOURCE OF TRUTH) + descriptions + diagram
2. `modules/uzumaki/fish/functions.nix` - hostcolors function has hardcoded hex colors and labels
3. `docs/MACOS-SETUP.md` - documentation example showing hostPalette
4. `modules/uzumaki/README.md` - documentation showing hostPalette example
5. `hosts/README.md` - host overview table with color names
6. `hosts/*/tests/T01-theme.sh` - host-specific test headers
7. `hosts/*/tests/T01-theme.md` - host-specific test documentation

## Goal

Change host color assignment in **one place only** (`theme-palettes.nix`) and have everything else auto-update.

## Proposed Solution

### 1. Fish `hostcolors` Function

Instead of hardcoded colors, dynamically read from theme-palettes.nix using `nix eval`:

```fish
# Example approach - evaluate Nix to get host colors
set -l host_data (nix eval --json --file $nixcfg/modules/uzumaki/theme/theme-palettes.nix hostPalette)
# Parse JSON and display with actual colors
```

This is similar to how `runbook-secrets.sh` already does it (see `load_host_colors` function).

### 2. Documentation

Options:

- Generate docs from Nix (complex)
- Accept some manual maintenance for docs (pragmatic)
- Add CI check that docs match source of truth

### 3. Test Files

- Tests are host-specific, so some hardcoding is acceptable
- Could add validation that test expectations match actual palette

## Effort

- Medium complexity
- Main work: Rewrite `hostcolors` fish function to use `nix eval`
- Reference implementation exists in `scripts/runbook-secrets.sh`

## Related

- `hostsecrets` function already wraps a bash script that reads from theme-palettes.nix
- `runbook-secrets.sh` has working `load_host_colors()` implementation
