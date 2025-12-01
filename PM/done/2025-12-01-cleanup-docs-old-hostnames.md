# 2025-12-01 - Cleanup: Old Hostname References in Documentation

## Description

Updated all main documentation files to use new hostnames instead of old ones.

## Hostname Mapping

| Old Name        | New Name |
| --------------- | -------- |
| `miniserver99`  | `hsb0`   |
| `miniserver24`  | `hsb1`   |
| `msww87`        | `hsb8`   |
| `mba-gaming-pc` | `gpc0`   |
| `imac-mba-home` | `imac0`  |

## What Was Done

### Phase 1: Critical Docs (docs/ folder) ✅

- [x] `docs/README.md` - Fixed broken link to hsb1
- [x] `docs/how-it-works.md` - Full rewrite with new hostnames
- [x] `docs/technical-overview.md` - Updated examples to use hsb1, removed mkServerHost
- [x] `docs/CI-CD-PIPELINE.md` - Updated to reflect current 6-host setup
- [x] `TOC.md` - Updated all host references
- [x] `README.md` (root) - Updated flake examples

### Phase 3: Verification ✅

- [x] `grep -r "miniserver" docs/ TOC.md README.md` - No matches
- [x] `grep -r "mba-gaming-pc" docs/ TOC.md README.md` - No matches
- [x] `grep -r "imac-mba-home" docs/ TOC.md README.md` - No matches
- [x] `grep -r "msww87" docs/ TOC.md README.md` - No matches

## Test Results

- Manual verification: All old hostnames removed from main docs ✅
- Date completed: 2025-12-01

## Notes

### Phase 2: Host-Specific Docs (Forward-Looking) ✅

- [x] `hosts/README.md` - Updated migration statuses (all hosts now ✅ Done)
- [x] `hosts/imac0/README.md` - Fixed all `imac-mba-home` references to `imac0`
- [x] `hosts/DEPLOYMENT.md` - Updated gpc0 system label
- [x] `hosts/hsb1/docs/RUNBOOK.md` - Added note about legacy Docker image name

### Skipped (Historical/Archive)

These files intentionally keep old names for historical accuracy:

- `hosts/*/archive/*.md` - Migration plans marked [DONE]
- `PM/done/*.md` - Completed PM items
- Host-specific migration plans that document the rename
- `hosts/hsb1/docs/MIGRATION-PLAN-HSB1.md` - Historical migration document
- `hosts/csb1/docs/MIGRATION-PLAN-HOKAGE.md` - Historical migration document
