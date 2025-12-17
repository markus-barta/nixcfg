# 2025-11-29 - Refactor mkServerHost Helper (CANCELLED)

## Description

Consider refactoring the mkServerHost helper to support external hokage consumer pattern directly, or deprecate it as hosts migrate.

## Why Cancelled

**No longer relevant** - `mkServerHost` is not used anymore!

All hosts now use the explicit `nixpkgs.lib.nixosSystem` pattern:

- hsb0, hsb1, hsb8, gpc0, csb0, csb1

The migration naturally deprecated mkServerHost without needing a dedicated refactor task.

## Original Scope

- Audit which hosts still use mkServerHost
- Decide: Enhance or deprecate
- Update documentation

## Resolution

- **Date**: 2025-12-01
- **Reason**: Organically resolved during host migrations
- **Action**: No action needed, mkServerHost already unused
