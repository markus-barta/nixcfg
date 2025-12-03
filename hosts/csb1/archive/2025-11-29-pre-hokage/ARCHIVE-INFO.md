# Archive: csb1 Pre-Hokage Migration

**Date**: 2025-11-29  
**Source**: `mba@cs1.barta.cm:~/nixcfg`  
**Purpose**: Safety backup before migrating to external Hokage modules

## What This Contains

This is a complete copy of the **pbek/nixcfg** repository as it existed on csb1 before the Hokage migration. This is the "old" configuration system using local mixins.

## Key Files

- `flake.nix` - Main flake with all host definitions
- `hosts/csb1/configuration.nix` - csb1 specific config
- `modules/mixins/` - Local mixin modules (being replaced by Hokage)

## Why This Exists

The Hokage migration moves from:

- **Old**: Local mixins in `modules/mixins/`
- **New**: External Hokage modules from `github:pbek/nixcfg`

This archive preserves the old configuration for reference if needed.

## Note

The `secrets/` folder contains encrypted `.age` files from the original repo.
These are encrypted and safe to store, but not part of the new structure.
