# hsb8 - Technical Debt & Future Improvements

**Server**: hsb8 (formerly msww87)  
**Created**: November 19, 2025  
**Last Updated**: November 21, 2025  
**Current Status**: ✅ Renamed & Running, ✅ **External Hokage Consumer ACTIVE**  
**Priority**: ~~Medium~~ **COMPLETED** - Now using external hokage from github:pbek/nixcfg

---

## ✅ COMPLETED: External Hokage Consumer Pattern Migration

**Status**: ✅ **MIGRATION COMPLETE** - Now using EXTERNAL hokage from github:pbek/nixcfg

**Migration Completed**: November 21, 2025

**Summary**:

hsb8 successfully migrated from local `../../modules/hokage` to external hokage consumer pattern using `inputs.nixcfg.nixosModules.hokage` from github:pbek/nixcfg.

**What's Actually Running NOW** (as of Nov 21, 2025 - Post-Migration):

```nix
# hosts/hsb8/configuration.nix - CURRENT STATE ✅
imports = [
  ./hardware-configuration.nix
  # ../../modules/hokage  ← REMOVED! No longer using local import
  ./disk-config.zfs.nix
];
```

```nix
# flake.nix - CURRENT STATE ✅
hsb8 = nixpkgs.lib.nixosSystem {
  inherit system;
  modules = commonServerModules ++ [
    inputs.nixcfg.nixosModules.hokage  # ✅ External hokage from pbek/nixcfg
    ./hosts/hsb8/configuration.nix
    disko.nixosModules.disko
  ];
  specialArgs = self.commonArgs // {
    inherit inputs;
  };
};
```

```bash
# Verified on live server (Nov 21, 2025 - After deployment):
$ ssh mba@hsb8.lan 'hostname && nixos-version'
> hsb8
> 25.11.20251117.89c2b23 (Xantusia)

$ ssh mba@hsb8.lan 'systemctl is-system-running'
> running  # ✅ System healthy with external hokage
```

**What Was the Target** (Achieved):

```nix
# flake.nix - SHOULD ADD THIS INPUT
inputs = {
  # ... existing inputs ...
  nixcfg.url = "github:pbek/nixcfg";  # ← MISSING!
};
```

```nix
# hosts/hsb8/configuration.nix - TARGET STATE
imports = [
  ./hardware-configuration.nix
  # ../../modules/hokage  ← REMOVE local import
  ./disk-config.zfs.nix
];
# External hokage imported via flake.nix specialArgs
```

```nix
# flake.nix - TARGET STATE
hsb8 = nixpkgs.lib.nixosSystem {
  inherit system;
  modules =
    commonServerModules
    ++ [
      inputs.nixcfg.nixosModules.hokage  # ← External hokage
      ./hosts/hsb8/configuration.nix
      disko.nixosModules.disko
    ];
  specialArgs = self.commonArgs // {
    inherit inputs;
    lib-utils = inputs.nixcfg.lib-utils;  # ← Required by external hokage
  };
};
```

---

## 📋 Migration Execution Summary

**Completed**: November 21, 2025

### ✅ Phase 1: Add External Hokage Input

- Added `nixcfg.url = "github:pbek/nixcfg"` to flake.nix
- Locked to commit f51079c (2025-11-21)
- Commit: `e886391`

### ✅ Phase 2: Update hsb8 Configuration

- Removed `../../modules/hokage` import from configuration.nix
- Commit: `6159036`

### ✅ Phase 3: Update flake.nix hsb8 Definition

- Replaced `mkServerHost` with ad-hoc `nixosSystem`
- Added `inputs.nixcfg.nixosModules.hokage`
- Uses local `lib-utils` from `self.commonArgs`
- Commit: `9113c8d`
- Fix commit: `92fc68e` (corrected lib-utils reference)

### ✅ Phase 4: Test Build on miniserver24

- Built successfully on miniserver24 (i7, 16GB RAM, 9.1GB free)
- All checks passed

### ✅ Phase 5: Deploy to hsb8

- Deployed via SSH to hsb8
- System activated successfully
- Zero downtime

### ✅ Phase 6: Verify External Hokage Active

- Configuration verified: No local hokage import
- flake.nix verified: Using `inputs.nixcfg.nixosModules.hokage`
- System health: All services running
- Tools verified: fish, zellij available

---

## 🟢 FUTURE CONSIDERATION: Refactor mkServerHost Helper (Optional)

**Context**: hsb8 now uses ad-hoc `nixosSystem` definition instead of `mkServerHost`.

**Option**: When migrating 2nd/3rd hosts (hsb0/hsb1/miniserver24/miniserver99) to external hokage, consider refactoring `mkServerHost` to support both patterns, or keep the ad-hoc pattern as standard for external hokage consumers.

**Current State**: Not urgent - ad-hoc definition works well and is explicit

**Trigger**: When migrating 2nd host to external hokage (hsb0, hsb1, or miniservers)

**Priority**: 🟢 **LOW** - Current solution is clean and maintainable

---

## 📊 Reference: External Hokage Consumer Examples

From Patrizio's nixcfg repository:

**Example flake.nix**:  
https://github.com/pbek/nixcfg/blob/main/examples/hokage-consumer/flake.nix

**Example server configuration.nix**:  
https://github.com/pbek/nixcfg/blob/main/examples/hokage-consumer/server/configuration.nix

**Key Points from Examples**:

1. **flake.nix input**: `nixcfg.url = "github:pbek/nixcfg";`
2. **Import hokage**: `inputs.nixcfg.nixosModules.hokage`
3. **Pass lib-utils**: `lib-utils = inputs.nixcfg.lib-utils;` in specialArgs
4. **Remove local import**: Delete `../../modules/hokage` from configuration.nix
5. **Lock the input**: Use `nix flake lock` to pin version

---

## ✅ Benefits of External Hokage Consumer

1. **Upstream Updates**: Get hokage improvements from Patrizio automatically
2. **No Fork Maintenance**: Don't need to merge upstream changes manually
3. **Standardized**: Follow proven external consumer pattern (see Patrizio's examples)
4. **Cleaner Separation**: Your customizations separate from base module
5. **Future-Proof**: Easy to add customizations via Uzumaki namespace (future)

**Note**: csb0 and csb1 are NOT managed by this flake - they exist as separate servers with their own configurations and need their own hokage migration (documented in their respective folders).

---

## 🎯 Success Criteria - ALL COMPLETED ✅

- [x] `nixcfg.url` input added to flake.nix ✅
- [x] `flake.lock` has locked nixcfg version (f51079c) ✅
- [x] Local `../../modules/hokage` import removed from hsb8/configuration.nix ✅
- [x] External hokage imported via flake.nix (`inputs.nixcfg.nixosModules.hokage`) ✅
- [x] `lib-utils` available via specialArgs (from `self.commonArgs`) ✅
- [x] Test build passes on miniserver24 ✅
- [x] Deployment successful (zero downtime) ✅
- [x] System verification: Configuration files confirmed using external hokage ✅
- [x] System still works (hostname: hsb8, all services running) ✅
- [x] Documentation updated (this file + MIGRATION-PLAN.md) ✅

---

## 📝 Notes

**Why Was This Initially Deferred?**

During the initial hsb8 rename (Nov 19, 2025), the migration was simplified to:

- ✅ Rename only: msww87 → hsb8 (folder + hostname)
- ⏸️ Hokage migration: Deferred to reduce risk

**Why Was It Done?**

1. hsb8 was stable and working after rename
2. External hokage consumer pattern is proven (see Patrizio's examples)
3. hsb8 rename was complete (safe time to proceed)
4. Follows upstream hokage development practices
5. Makes future hsb0/hsb1 migrations easier (they can follow same pattern)

**Risk Assessment**: 🟡 **MEDIUM** (Actual: ✅ **ZERO ISSUES**)

- hsb8 is not production-critical (parents don't rely on it yet)
- Easy rollback available (NixOS generations)
- Physical access available (at your home)
- Could test thoroughly before deploying to parents (ww87 location)

**Migration Execution Time**: ~30 minutes (November 21, 2025, late afternoon)

**Result**: ✅ **SUCCESSFUL** - Zero downtime, all services operational

---

**Created**: November 19, 2025  
**Migration Completed**: November 21, 2025  
**Status**: ✅ **COMPLETE** - hsb8 now using external hokage from github:pbek/nixcfg  
**Owner**: Markus Barta
