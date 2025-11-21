# hsb8 - Technical Debt & Future Improvements

**Server**: hsb8 (formerly msww87)  
**Created**: November 19, 2025  
**Last Updated**: November 21, 2025  
**Current Status**: ✅ Renamed & Running, ❌ Hokage Migration NOT Done  
**Priority**: Medium (working fine, but should follow external hokage consumer pattern)

---

## 🔴 HIGH PRIORITY: Migrate to External Hokage Consumer Pattern

**Status**: ❌ **NOT MIGRATED YET** - Still using LOCAL hokage module

**Current Reality**:

hsb8 was successfully renamed from `msww87`, but the hokage external consumer migration was **deferred/never completed**.

**What's Actually Running** (as of Nov 21, 2025):

```nix
# hosts/hsb8/configuration.nix - CURRENT STATE
imports = [
  ./hardware-configuration.nix
  ../../modules/hokage          # ← LOCAL hokage module (OLD PATTERN)
  ./disk-config.zfs.nix
];
```

```nix
# flake.nix - CURRENT STATE (line 214)
hsb8 = mkServerHost "hsb8" [ disko.nixosModules.disko ];
# ↑ Uses mkServerHost which imports LOCAL hokage
```

```bash
# Verified on live server (Nov 21, 2025):
$ ssh mba@hsb8.lan 'nix-store -q --references /run/current-system | grep -E "(hokage|nixcfg|pbek)"'
> No hokage external reference found
# ↑ Confirms: NO external hokage consumer active
```

**What Should Be Running** (Target - External Hokage Consumer):

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

## 📋 TODO: Complete Hokage External Consumer Migration

### Phase 1: Add External Hokage Input

```bash
cd ~/Code/nixcfg

# 1. Add nixcfg input to flake.nix (after line 22, after plasma-manager)
nano flake.nix
# ADD:
#     nixcfg.url = "github:pbek/nixcfg";

# 2. Lock the input
nix flake lock --update-input nixcfg

# 3. Commit
git add flake.nix flake.lock
git commit -m "feat: add nixcfg input for external hokage consumer pattern"
```

### Phase 2: Update hsb8 Configuration

```bash
# 1. Remove local hokage import from configuration.nix
cd hosts/hsb8
nano configuration.nix

# FIND (line 42):
#   imports = [
#     ./hardware-configuration.nix
#     ../../modules/hokage         # ← REMOVE THIS LINE
#     ./disk-config.zfs.nix
#   ];

# CHANGE TO:
#   imports = [
#     ./hardware-configuration.nix
#     ./disk-config.zfs.nix
#   ];

# 2. Commit
git add configuration.nix
git commit -m "refactor(hsb8): remove local hokage import (will use external)"
```

### Phase 3: Update flake.nix hsb8 Definition

```bash
cd ~/Code/nixcfg
nano flake.nix

# FIND (line 214):
#   hsb8 = mkServerHost "hsb8" [ disko.nixosModules.disko ];

# REPLACE WITH (ad-hoc nixosSystem for external hokage):
#   hsb8 = nixpkgs.lib.nixosSystem {
#     inherit system;
#     modules =
#       commonServerModules
#       ++ [
#         inputs.nixcfg.nixosModules.hokage  # External hokage
#         ./hosts/hsb8/configuration.nix
#         disko.nixosModules.disko
#       ];
#     specialArgs = self.commonArgs // {
#       inherit inputs;
#       lib-utils = inputs.nixcfg.lib-utils;  # CRITICAL for external hokage
#     };
#   };

# Commit
git add flake.nix
git commit -m "refactor(hsb8): migrate to external hokage consumer pattern"
```

### Phase 4: Test Build Locally

```bash
cd ~/Code/nixcfg

# Test the build
nix flake check
nixos-rebuild build --flake .#hsb8 --show-trace

# If successful, push
git push
```

### Phase 5: Deploy to hsb8

```bash
# Option A: Deploy from your Mac
nixos-rebuild switch --flake .#hsb8 \
  --target-host mba@hsb8.lan \
  --use-remote-sudo

# Option B: Deploy from server
ssh mba@hsb8.lan
cd ~/nixcfg
git pull
sudo nixos-rebuild switch --flake .#hsb8
```

### Phase 6: Verify External Hokage Active

```bash
# Check for external hokage reference
ssh mba@hsb8.lan 'nix-store -q --references /run/current-system | grep -E "(pbek|nixcfg)"'
# SHOULD show: /nix/store/...-source-pbek-nixcfg-... or similar

# Verify system still works
ssh mba@hsb8.lan 'hostname && nixos-version'
ssh mba@hsb8.lan 'systemctl status'
```

---

## 🟡 MEDIUM PRIORITY: Refactor mkServerHost Helper (After Migration)

**Only do this AFTER Phase 1-6 above are complete!**

Once hsb8 uses external hokage, we have ad-hoc `nixosSystem` definition. Later, when migrating hsb0/hsb1, refactor `mkServerHost` to support both local and external hokage patterns.

**See**: Original BACKLOG.md content (lines 36-60 in previous version) for refactoring ideas

**Trigger**: When migrating 2nd host (hsb0 or hsb1) to external hokage

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

## 🎯 Success Criteria

- [ ] `nixcfg.url` input added to flake.nix
- [ ] `flake.lock` has locked nixcfg version
- [ ] Local `../../modules/hokage` import removed from hsb8/configuration.nix
- [ ] External hokage imported via flake.nix
- [ ] `lib-utils` passed in specialArgs
- [ ] Test build passes locally
- [ ] Deployment successful
- [ ] System verification: `nix-store -q --references /run/current-system | grep nixcfg` shows external reference
- [ ] System still works (hostname, services, network all OK)
- [ ] Documentation updated (this file + MIGRATION-PLAN.md)

---

## 📝 Notes

**Why Was This Deferred?**

During the initial hsb8 rename (Nov 19, 2025), the migration was simplified to:

- ✅ Rename only: msww87 → hsb8 (folder + hostname)
- ❌ Hokage migration: Deferred to reduce risk

**Why Do It Now?**

1. hsb8 is stable and working
2. External hokage consumer pattern is proven (see Patrizio's examples)
3. hsb8 rename is complete (safe time to do this)
4. Follows upstream hokage development practices
5. Makes future hsb0/hsb1 migrations easier (they can follow same pattern)

**Risk Level**: 🟡 **MEDIUM**

- hsb8 is not production-critical (parents don't rely on it yet)
- Easy rollback (NixOS generations)
- Physical access available (at your home)
- Can test thoroughly before deploying to parents (ww87 location)

**Best Time to Execute**: Weekend afternoon, 2-3 hours available

---

**Last Updated**: November 21, 2025  
**Next Action**: Execute Phase 1-6 migration steps above  
**Owner**: You
