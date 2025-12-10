# Rename imac-mba-work to mba-imac-work [DONE]

**Created**: 2025-12-05
**Completed**: 2025-12-10
**Priority**: Low
**Type**: Refactoring

## Summary

Renamed `imac-mba-work` host to `mba-imac-work` to follow the naming convention where work machines start with `mba-` prefix.

## Changes Made

### Repository Changes (21 files updated)

- [x] Renamed directory `hosts/imac-mba-work/` → `hosts/mba-imac-work/`
- [x] Updated `flake.nix` registration
- [x] Updated `modules/uzumaki/theme/theme-palettes.nix` (hostPalette, hostDisplayOrder, palette description)
- [x] Updated `home.nix` → `theme.hostname`
- [x] Updated all internal references in `hosts/mba-imac-work/`:
  - [x] `README.md`
  - [x] `docs/RUNBOOK.md`
  - [x] `docs/manual-setup.md`
  - [x] `docs/MIGRATION-GUIDE.md`
  - [x] `tests/README.md`
  - [x] `tests/run-all-tests.sh`
  - [x] `tests/T07-karabiner-elements.md`
- [x] Updated cross-references from other hosts/docs:
  - [x] `hosts/README.md`
  - [x] `hosts/DEPLOYMENT.md`
  - [x] `hosts/mba-mbp-work/README.md`
  - [x] `docs/README.md`
  - [x] `docs/OPS-STATUS.md`
  - [x] `docs/INFRASTRUCTURE.md`
  - [x] `TOC.md`
  - [x] `README.md`
  - [x] `tests/collect-baselines.sh`
  - [x] `modules/uzumaki/macos.nix`
  - [x] `modules/uzumaki/macos-common.nix`

### Machine Steps (to be done on work iMac)

- [ ] Rename hostname via System Settings or `scutil`
- [ ] Re-apply config: `home-manager switch --flake ".#markus@mba-imac-work"`
- [ ] Verify theme color still works

## Instructions for macOS Hostname Change

On the work iMac, run these commands:

```bash
# Method 1: Using scutil (recommended)
sudo scutil --set ComputerName "mba-imac-work"
sudo scutil --set LocalHostName "mba-imac-work"
sudo scutil --set HostName "mba-imac-work"

# Verify
hostname
scutil --get ComputerName
scutil --get LocalHostName
scutil --get HostName

# Pull latest nixcfg changes
cd ~/Code/nixcfg
git pull

# Apply new configuration
home-manager switch --flake ".#markus@mba-imac-work"
```

Alternatively, use System Settings:

1. System Settings → General → Sharing
2. Click "Edit" next to the computer name
3. Change to "mba-imac-work"
4. Apply config as above

## Notes

- New naming convention: `mba-{device}-work` for work machines
- Consistent with `mba-mbp-work` (MacBook Pro work)
