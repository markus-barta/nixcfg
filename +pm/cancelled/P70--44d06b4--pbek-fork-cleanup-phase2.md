# 2025-12-07 - pbek Fork Cleanup Phase 2

## Status: BACKLOG (Low Priority)

## Summary

Continue cleanup of artifacts inherited from the pbek/nixcfg fork. Phase 1 removed QOwnNotes and unused packages. This phase covers migration artifacts and documentation.

## Phase 1 Completed (2025-12-07)

Deleted:

- `pkgs/qownnotes/` - pbek's note-taking app
- `pkgs/qc/` - QOwnNotes CLI
- `pkgs/cura5/` - 3D printing slicer
- `pkgs/gittyup/` - Git GUI
- `pkgs/curseforge/` - Gaming mod manager
- `pkgs/television/` - TUI file finder
- `tests/qownnotes.nix` - VM test
- `tests/common/` - Test helpers
- `scripts/update-qownnotes-release.sh` - Maintainer script
- `secrets/archived/qc-config.age` - QC config
- QOwnNotes exports from `flake.nix`

## Phase 2 - Migration Artifacts (Consider Archiving)

| Item                   | Path                                    | Action            |
| ---------------------- | --------------------------------------- | ----------------- |
| csb0 migration scripts | `hosts/csb0/migrations/`                | Archive or delete |
| csb1 migration scripts | `hosts/csb1/migrations/`                | Archive or delete |
| Migration snapshots    | `hosts/*/migrations/*/snapshots/*.json` | Delete            |
| Investigation docs     | `docs/private/investigation/`           | Archive or delete |
| Migration planning     | `docs/private/migration-2025-11/`       | Archive or delete |
| Archived docs          | `docs/private/archived/`                | Review and delete |

## Phase 2 - Outdated Baselines

| Item              | Path                                | Action               |
| ----------------- | ----------------------------------- | -------------------- |
| Old hsb1 baseline | `tests/baselines/20251204-hsb1.log` | Delete or regenerate |

## Phase 2 - Documentation Updates

- [ ] Update `docs/private/README.md` after cleanup
- [ ] Review `secrets/archived/README.md` for accuracy
- [ ] Check for broken links to deleted items

## Packages to Keep (Verified Needed)

| Package     | Path                | Reason                             |
| ----------- | ------------------- | ---------------------------------- |
| nixbit      | `pkgs/nixbit/`      | Used by hokage module              |
| ghostty     | `pkgs/ghostty/`     | Terminal emulator (verify if used) |
| lact        | `pkgs/lact/`        | AMD GPU control (for gpc0?)        |
| zen-browser | `pkgs/zen-browser/` | Firefox fork (verify if used)      |

## Notes

- Migration folders are historical but take up space
- Consider `git archive` before deletion for recovery
- Some docs may have value for reference during future migrations
