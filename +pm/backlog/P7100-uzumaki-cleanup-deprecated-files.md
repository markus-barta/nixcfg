# 2025-12-07 - Uzumaki Module Cleanup: Remove Deprecated Files

## Status: BACKLOG

## Summary

Clean up deprecated/legacy files from the uzumaki module restructure. All hosts have been migrated to the new `uzumaki.enable = true` pattern, but old files remain.

## Context

The uzumaki module restructure (2025-12-04) is **COMPLETE**:

- All 9 hosts use `uzumaki.enable = true` with role-based configuration
- The new module structure (`default.nix`, `options.nix`, `fish/`, `theme/`, `stasysmo/`) is working
- Old import patterns (`uzumaki/server.nix`, `uzumaki/desktop.nix`, etc.) are no longer used

## Files to Remove

| File                               | Reason                                        | Safe to Delete |
| ---------------------------------- | --------------------------------------------- | -------------- |
| `modules/uzumaki/server.nix`       | Replaced by `default.nix` with role="server"  | ✅ Yes         |
| `modules/uzumaki/desktop.nix`      | Replaced by `default.nix` with role="desktop" | ✅ Yes         |
| `modules/uzumaki/macos.nix`        | Replaced by `home-manager.nix`                | ✅ Yes         |
| `modules/uzumaki/common.nix`       | Duplicated in `fish/functions.nix`            | ✅ Yes         |
| `modules/uzumaki/macos-common.nix` | Not imported anywhere, legacy                 | ✅ Yes         |

## Verification

Before deleting, confirm no imports exist:

```bash
# Should return 0 results for host files (only docs/comments allowed)
grep -r "uzumaki/server.nix" hosts/ --include="*.nix"
grep -r "uzumaki/desktop.nix" hosts/ --include="*.nix"
grep -r "uzumaki/macos.nix" hosts/ --include="*.nix"
grep -r "macos-common.nix" hosts/ --include="*.nix"
grep -r "uzumaki/common.nix" hosts/ --include="*.nix"
```

## Acceptance Criteria

- [ ] Verify no active imports of deprecated files
- [ ] Delete deprecated files (5 files)
- [ ] Update `modules/uzumaki/README.md` - remove references to legacy files
- [ ] Update documentation referencing old patterns:
  - [ ] `+pm/done/2025-12-04-uzumaki-module-restructure/architecture-current.md`
  - [ ] `hosts/*/docs/MIGRATION-PLAN-HOKAGE.md` files
- [ ] Run builds on at least 2 hosts to verify no breakage
- [ ] Commit with clear message

## Effort

- **Priority:** Low - housekeeping
- **Effort:** Small - just file deletions and doc updates
- **Risk:** Low - files confirmed unused
