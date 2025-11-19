# hsb8 (msww87) - Technical Debt & Future Improvements

## 🔄 Refactoring Tasks

### mkServerHost Helper - External Hokage Consumer Support

**Priority**: 🟡 Medium (defer until more hosts migrate)  
**Effort**: ~2-3 hours  
**Status**: ⏳ Deferred

**Context**:

During the hsb8 migration (msww87 → hsb8 + hokage external consumer), we bypassed the `mkServerHost` helper and wrote a full `nixosSystem` definition directly in `flake.nix`. This works but duplicates some logic.

**Current Implementation** (hsb8):

```nix
# flake.nix - Direct nixosSystem (duplicates commonServerModules)
hsb8 = nixpkgs.lib.nixosSystem {
  inherit system;
  modules =
    commonServerModules
    ++ [
      inputs.nixcfg.nixosModules.hokage  # External hokage
      ./hosts/hsb8/configuration.nix
      disko.nixosModules.disko
    ];
  specialArgs = self.commonArgs // {
    inherit inputs;
    lib-utils = inputs.nixcfg.lib-utils;  # Required by external hokage
  };
};
```

**Desired Refactored Helper**:

```nix
# Extend mkServerHost to support external hokage consumers
mkServerHost =
  hostName: extraModules: externalHokageConfig:
  nixpkgs.lib.nixosSystem {
    inherit system;
    modules =
      commonServerModules
      ++ (if externalHokageConfig != null then
            [ inputs.nixcfg.nixosModules.hokage ]
          else
            [])
      ++ [ ./hosts/${hostName}/configuration.nix ]
      ++ extraModules;
    specialArgs = self.commonArgs // {
      inherit inputs;
    } // (if externalHokageConfig != null then
            { lib-utils = inputs.nixcfg.lib-utils; }
          else
            {});
  };

# Usage:
hsb8 = mkServerHost "hsb8" [ disko.nixosModules.disko ] { external = true; };
hsb0 = mkServerHost "hsb0" [ disko.nixosModules.disko ] null;  # Local hokage
```

**Benefits**:

- ✅ DRY (Don't Repeat Yourself)
- ✅ Consistent pattern for all servers
- ✅ Easier to add more external consumer hosts
- ✅ Less code duplication

**Why Deferred**:

1. **Single consumer**: Only hsb8 uses external hokage currently
2. **Works fine**: Current implementation is functional and explicit
3. **Clear migration path**: When hsb0/hsb1 migrate, refactor becomes valuable
4. **Guinea pig phase**: Want to validate pattern works before abstracting

**Trigger for Implementation**:

- When migrating hsb0 or hsb1 to external hokage consumer
- OR when adding a 3rd host with external hokage
- Whichever comes first

**Related Files**:

- `flake.nix` (lines ~100-115 mkServerHost helper)
- `flake.nix` (lines ~214-230 hsb8 definition)
- Future: hsb0, hsb1 when they migrate

**Acceptance Criteria**:

- [ ] Helper function supports both local and external hokage
- [ ] All server hosts use the helper (no ad-hoc nixosSystem definitions)
- [ ] Test build passes for all hosts
- [ ] External hokage consumers get lib-utils automatically
- [ ] Code is more maintainable and DRY

**Estimated Timeline**:

- Plan refactor: 30 minutes
- Implement helper: 1 hour
- Test all hosts: 30 minutes
- Update documentation: 30 minutes
- **Total**: ~2-3 hours

---

## 📝 Notes

- This backlog tracks technical debt and future improvements
- Items are prioritized but not urgent
- Re-evaluate priorities after each major migration
- Document lessons learned here

---

**Created**: 2025-11-19  
**Last Updated**: 2025-11-19  
**Next Review**: After hsb0 or hsb1 migration planning begins
