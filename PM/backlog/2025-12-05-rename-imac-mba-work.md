# Rename imac-mba-work to mba-imac-work

**Created**: 2025-12-05
**Priority**: Low
**Type**: Refactoring

## Summary

Rename `imac-mba-work` host to `mba-imac-work` to follow the naming convention where work machines start with `mba-` prefix.

## Current State

- Host directory: `hosts/imac-mba-work/`
- Hostname on machine: `imac-mba-work`
- flake.nix registration: `markus@imac-mba-work`
- theme-palettes.nix: `"imac-mba-work" = "darkGray"`

## Target State

- Host directory: `hosts/mba-imac-work/`
- Hostname on machine: `mba-imac-work`
- flake.nix registration: `markus@mba-imac-work`
- theme-palettes.nix: `"mba-imac-work" = "darkGray"`

## Tasks

- [ ] Rename directory `hosts/imac-mba-work/` → `hosts/mba-imac-work/`
- [ ] Update `flake.nix` registration
- [ ] Update `modules/uzumaki/theme/theme-palettes.nix`
- [ ] Update `home.nix` → `theme.hostname`
- [ ] Update all internal references in `hosts/mba-imac-work/`:
  - [ ] `README.md`
  - [ ] `docs/*.md`
  - [ ] `tests/README.md`
- [ ] Update any cross-references from other hosts
- [ ] On the actual iMac:
  - [ ] Rename hostname via System Settings or `scutil`
  - [ ] Re-apply config: `home-manager switch --flake ".#markus@mba-imac-work"`
  - [ ] Verify theme color still works

## Notes

- Low priority since the machine is already configured and working
- Can be done during next maintenance window on the work iMac
- New naming convention: `mba-{device}-work` for work machines
