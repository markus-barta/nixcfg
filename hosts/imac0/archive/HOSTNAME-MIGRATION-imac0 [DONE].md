# imac0 Hostname Migration [COMPLETED]

**Migration Date**: November 23, 2025  
**Status**: ✅ COMPLETE - Repository & Config Updated  
**Old Hostname**: `imac-mba-home`  
**New Hostname**: `imac0`

---

## Executive Summary

Successfully migrated macOS workstation from verbose `imac-mba-home` to unified naming scheme `imac0`. All repository references, flake configuration, and documentation updated. Manual steps (macOS hostname change, DHCP lease update) documented for completion.

## Migration Checklist

### ✅ Repository Changes (Completed)

- [x] Renamed folder: `hosts/imac-mba-home/` → `hosts/imac0/`
- [x] Updated `flake.nix`: `homeConfigurations."markus@imac0"`
- [x] Updated Quick Reference in `docs/README.md`
- [x] Updated all command examples in documentation
- [x] Updated all path references
- [x] Tested configuration build (dry-run passed)
- [x] Committed and pushed changes

### ⏳ Manual Steps (User Action Required)

#### 1. Update macOS Hostname

```bash
# Set LocalHostName (used for Bonjour .local)
sudo scutil --set LocalHostName imac0

# Verify
scutil --get LocalHostName
# Should output: imac0

# Also set ComputerName for UI consistency
sudo scutil --set ComputerName "imac0"
```

#### 2. Apply New Configuration

```bash
cd ~/Code/nixcfg

# Apply with new flake reference
home-manager switch --flake .#markus@imac0

# Verify hostname in new terminal
hostname -s  # Should show: imac0
```

#### 3. Update DHCP Static Lease

**On hsb0/hsb8 servers:**

Edit encrypted DHCP static leases and change:

```diff
- wz-imac-home-mba   # 192.168.1.150
+ imac0              # 192.168.1.150
```

**Files to update:**

- `hosts/hsb0/secrets/static-leases-hsb0.age` (if exists)
- `hosts/hsb8/secrets/static-leases-hsb8.age`

**Steps:**

```bash
# On local machine (with age key access)
cd ~/Code/nixcfg

# Edit hsb8's DHCP leases
cd hosts/hsb8
agenix -e ./secrets/static-leases-hsb8.age
# Change wz-imac-home-mba → imac0, save and exit
cd ../..

# Edit hsb0's DHCP leases (if exists)
cd hosts/hsb0
agenix -e ./secrets/static-leases-hsb0.age
# Change wz-imac-home-mba → imac0, save and exit
cd ../..

# Commit and push
git add hosts/hsb*/secrets/static-leases-*.age
git commit -m "secrets: update DHCP lease name imac-mba-home → imac0"
git push

# On each server (hsb8, hsb0)
cd ~/nixcfg
git pull
sudo nixos-rebuild switch
```

## Changes Made

### Repository Structure

```
hosts/
├── imac-mba-home/  ❌ (removed)
└── imac0/          ✅ (new)
    ├── README.md
    ├── home.nix
    ├── config/
    ├── docs/
    ├── scripts/
    ├── tests/
    └── archive/
```

### flake.nix

**Before:**

```nix
homeConfigurations."markus@imac-mba-home" = home-manager.lib.homeManagerConfiguration {
  modules = [ ./hosts/imac-mba-home/home.nix ];
};
```

**After:**

```nix
homeConfigurations."markus@imac0" = home-manager.lib.homeManagerConfiguration {
  modules = [ ./hosts/imac0/home.nix ];
};
```

### Documentation Updates

- Quick Reference table: hostname `imac-mba-home` → `imac0`
- Config location: `~/Code/nixcfg/hosts/imac-mba-home/` → `~/Code/nixcfg/hosts/imac0/`
- All command examples updated
- Changelog entry added

## Benefits

### Before: `imac-mba-home`

- ❌ Long (13 characters)
- ❌ Inconsistent with server naming (miniserver99, msww87)
- ❌ Includes redundant info (mba, home both implied)

### After: `imac0`

- ✅ Short (5 characters)
- ✅ Consistent with unified scheme (`hsb0`, `pcg0`)
- ✅ Scalable (imac1, imac2 for future devices)
- ✅ Clear category identifier (`imac` = workstation type)

## Unified Naming Scheme

| Type        | Pattern     | Example | Description                     |
| ----------- | ----------- | ------- | ------------------------------- |
| Home Server | `hsb[0-9]`  | `hsb0`  | Home server (was miniserver99)  |
| Home Server | `hsb[0-9]`  | `hsb8`  | Home server (was msww87)        |
| Workstation | `imac[0-9]` | `imac0` | iMac workstation (Markus, home) |
| Gaming PC   | `pcg[0-9]`  | `pcg0`  | Gaming PC (was mba-gaming-pc)   |

**Pattern**: `<type><sequence>` where:

- `type` = 3-4 letter category code
- `sequence` = 0-9 for multiple devices in category

## Testing

### Build Validation

```bash
$ nix build '.#homeConfigurations."markus@imac0".activationPackage' --dry-run
warning: Git tree '/Users/markus/Code/nixcfg' is dirty
evaluation warning: `programs.zsh.initExtra` is deprecated, use `programs.zsh.initContent` instead.

✅ Build successful
```

### Verification Steps

Once manual steps completed:

```bash
# 1. Check hostname
hostname -s  # Should be: imac0

# 2. Check DNS
ping imac0.local  # Should resolve

# 3. Check Nix profile
home-manager generations | head -5
# Should show: markus@imac0

# 4. Check DHCP lease (on hsb8)
ssh mba@hsb8.lan
sudo journalctl -u adguardhome | grep imac0
# Should show: imac0 assigned 192.168.1.150
```

## Timeline

| Time  | Action                         | Status |
| ----- | ------------------------------ | ------ |
| 14:30 | Started hostname migration     | ✅     |
| 14:35 | Renamed folder (git mv)        | ✅     |
| 14:37 | Updated flake.nix              | ✅     |
| 14:40 | Updated all documentation      | ✅     |
| 14:45 | Tested build (dry-run)         | ✅     |
| 14:50 | Committed and pushed           | ✅     |
| 15:00 | Created migration archive doc  | ✅     |
| TBD   | Update macOS hostname (manual) | ⏳     |
| TBD   | Apply new config (manual)      | ⏳     |
| TBD   | Update DHCP lease (manual)     | ⏳     |

## Related Migrations

- **hsb8** (completed): `msww87` → `hsb8` - First migration, established pattern
- **hsb0** (in progress): `miniserver99` → `hsb0` - Currently being migrated
- **hsb1** (pending): `miniserver24` → `hsb1` - Not started
- **pcg0** (pending): `mba-gaming-pc` → `pcg0` - Not started

## Reference

**Migration Pattern**: See `hosts/hsb8/archive/MIGRATION-hsb8 [DONE].md` for full server migration example

**Commit**: `11be9a2a` - refactor(imac): hostname migration imac-mba-home → imac0

---

**Status**: ✅ Repository migration complete, manual steps documented  
**Next**: User completes manual steps (macOS hostname + DHCP + apply config)  
**Last Updated**: November 23, 2025  
**Maintainer**: Markus Barta
