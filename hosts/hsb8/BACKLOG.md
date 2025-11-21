# hsb8 - Technical Debt & Future Improvements

**Server**: hsb8 (formerly msww87)  
**Created**: November 19, 2025  
**Last Updated**: November 21, 2025  
**Current Status**: ✅ Production Ready

---

## 📋 ACTIVE BACKLOG

### 🟢 LOW PRIORITY: Refactor mkServerHost Helper (Optional)

**Status**: 💡 **CONSIDERATION** - Not urgent

**Context**:

hsb8 currently uses an ad-hoc `nixosSystem` definition instead of the `mkServerHost` helper function due to external hokage consumer pattern requirements.

**Current Implementation**:

```nix
# flake.nix - hsb8 uses explicit nixosSystem
hsb8 = nixpkgs.lib.nixosSystem {
  inherit system;
  modules = commonServerModules ++ [
    inputs.nixcfg.nixosModules.hokage  # External hokage
    ./hosts/hsb8/configuration.nix
    disko.nixosModules.disko
  ];
  specialArgs = self.commonArgs // {
    inherit inputs;
  };
};
```

**Other Servers Still Use**:

```nix
# flake.nix - miniserver24, miniserver99, mba-gaming-pc
miniserver24 = mkServerHost "miniserver24" [ disko.nixosModules.disko ];
miniserver99 = mkServerHost "miniserver99" [ disko.nixosModules.disko ];
```

**Options**:

1. **Option A**: Keep ad-hoc `nixosSystem` as standard for external hokage consumers
   - **Pros**: Explicit, clear what's happening, no abstraction complexity
   - **Cons**: More verbose, duplicates some boilerplate

2. **Option B**: Extend `mkServerHost` to support external hokage pattern
   - **Pros**: DRY principle, consistent with other servers
   - **Cons**: Adds complexity to helper function, may be over-engineering

3. **Option C**: Create new helper `mkExternalHokageHost`
   - **Pros**: Explicit distinction between local and external patterns
   - **Cons**: More helpers to maintain

**Recommendation**: **Option A** (keep current ad-hoc pattern)

**Rationale**:

- Current solution is clean and works well
- Explicit `nixosSystem` makes external hokage consumer pattern clear
- Adding abstraction may not provide significant value
- When more servers migrate to external hokage, revisit

**Trigger**: When 3+ servers use external hokage consumer pattern

**Estimated Effort**: 2-3 hours (if pursued)

**Priority**: 🟢 **LOW** - Current solution is maintainable

---

## 🔍 FUTURE CONSIDERATIONS

### Deployment to Parents' Home (ww87)

**Status**: ⏸️ **ON HOLD** - Test location working well

**Context**:

hsb8 is currently running at jhw22 (Markus' home) in test mode. Eventually, it should be deployed to ww87 (parents' home) for production use.

**Current Configuration**:

```nix
# hosts/hsb8/configuration.nix
location = "jhw22";  # Test mode
```

**Target Configuration**:

```nix
# hosts/hsb8/configuration.nix
location = "ww87";  # Production at parents' home
```

**Requirements Before Deployment**:

1. Test all services at jhw22 for extended period (30+ days)
2. Verify enable-ww87 script works correctly
3. Coordinate with parents for deployment window
4. Physical transport of hardware to ww87
5. Update location configuration and deploy

**Script Available**: `enable-ww87` (one-command deployment tool)

**Estimated Time**: 2-3 hours (including transport and setup)

**Priority**: 🟡 **MEDIUM** - When ready for production at parents' home

---

## 📊 COMPLETED ITEMS

### ✅ External Hokage Consumer Migration

**Completed**: November 21, 2025  
**Report**: [archive/HOKAGE-MIGRATION-2025-11-21.md](./archive/HOKAGE-MIGRATION-2025-11-21.md)

Successfully migrated from local hokage module to external hokage consumer pattern from `github:pbek/nixcfg`. Zero downtime, all services operational.

### ✅ Hostname Migration (msww87 → hsb8)

**Completed**: November 19-20, 2025  
**Report**: See MIGRATION-PLAN.md (lines 1-100)

Successfully renamed from `msww87` to `hsb8` following new unified naming scheme. Updated folder structure, DHCP leases, DNS resolution, and all documentation.

---

## 📝 NOTES

**Repository References**:

- Main README: [../README.md](../README.md)
- Configuration: [configuration.nix](./configuration.nix)
- Deployment Script: [enable-ww87.md](./enable-ww87.md)

**Related Servers**:

- miniserver99 (hsb0): DNS/DHCP server
- miniserver24 (hsb1): Home automation
- To be migrated to external hokage pattern (use hsb8 as reference)

---

**Last Updated**: November 21, 2025  
**Maintained By**: Markus Barta
