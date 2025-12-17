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

## Plan (make the palette consumable everywhere)

1. Produce one canonical machine-readable export

- Add a single derivation/attr (e.g., `hostPaletteExport`) in `theme-palettes.nix` that emits JSON with hex, rgb, and label data for every host. Keep it stable and documented.

2. Ship a tiny CLI entrypoint

- Add `nix run .#host-colors` (or similar) that prints table/JSON so consumers don’t need to know the path to the Nix file. Mirror what `runbook-secrets.sh` already does.

3. Point every consumer to the CLI/export

- `fish hostcolors` and any other shell helpers read via `nix run .#host-colors -- --format=table/json`.
- Scripts/tests (`hosts/*/tests/T01-theme.*`) ingest the JSON once and compare expected palettes.
- Docs pull a generated snippet (JSON → md table) so they stay in sync.

4. Add a consistency check

- A lightweight `just check-host-colors` (or CI hook) that re-generates the doc/table/test fixtures and fails if git is dirty.

5. Keep ergonomics + offline story

- Cache the JSON in the Nix store; allow `--cached` mode so fish functions stay fast without network evaluation.

## Where else this applies

- Any place that shows host identity: shell prompts (starship), tmux/zellij status, SSH MOTD banners, runbooks, and onboarding docs.
- Similar pattern can be reused for other shared data (host roles, region tags) to avoid multi-file edits.

## Effort

- Medium: most work is wiring the Nix export + CLI and swapping consumers to it.
- Validation/doc generation adds small extra lift but avoids future churn.

## Related

- `hostsecrets` function already wraps a bash script that reads from theme-palettes.nix
- `runbook-secrets.sh` has working `load_host_colors()` implementation
