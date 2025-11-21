# secrets/ - Future Improvements

**Created**: November 21, 2025  
**Last Updated**: November 21, 2025

---

## 📋 PROPOSED IMPROVEMENTS

### 🟡 MEDIUM PRIORITY: Restructure secrets/ Directory

**Status**: 💡 **PROPOSED** - Post-hsb0 migration

**Current Structure** (Flat):

```
secrets/
  github-token.age                    ← Shared
  atuin.age                           ← Shared
  neosay.age                          ← Shared
  static-leases-hsb0.age              ← Host-specific (includes hostname!)
  enable-ww87-hsb8.age                ← Host-specific (includes hostname!)
  secrets.nix
```

**Proposed Structure** (Nested):

```
secrets/
  shared/
    github-token.age                  ← Shared secrets
    atuin.age
    neosay.age
    pia-user.age
    pia-pass.age
  hsb0/
    static-leases.age                 ← No hostname needed! ✅
  hsb8/
    enable-ww87.age                   ← No hostname needed! ✅
  secrets.nix
```

**Why?**

**Hostname changes become trivial** - just rename the folder, no re-encryption needed:

```bash
# Current approach (7 steps, 10 minutes, complex)
git mv secrets/static-leases-miniserver99.age secrets/static-leases-hsb0.age
nano secrets/secrets.nix  # Add hsb0 SSH keys
nano secrets/secrets.nix  # Update binding miniserver99 → hsb0
agenix -e secrets/static-leases-hsb0.age  # Re-encrypt with new recipient keys!
nano hosts/hsb0/configuration.nix  # Update 2 references

# Proposed approach (1 step, 1 minute, simple)
git mv secrets/miniserver99 secrets/hsb0
nano hosts/hsb0/configuration.nix  # Update path: ../../secrets/hsb0/static-leases.age
# Done! No re-encryption needed! ✅
```

**Additional Benefits**:

- Clear separation: shared vs host-specific secrets
- Better scaling: new hosts get new folders
- Cleaner `secrets.nix` structure
- No filename conflicts

**Migration Steps**:

1. Create `secrets/shared/` directory
2. Move shared secrets to `secrets/shared/`
3. Create per-host directories: `secrets/hsb0/`, `secrets/hsb8/`
4. Move host-specific secrets to respective folders (rename to remove hostname)
5. Update `secrets/secrets.nix` paths
6. Update all host `configuration.nix` references
7. Test on miniserver24 (build verification)
8. Deploy to each host individually
9. Verify all secrets decrypt correctly

**When to Execute**: After hsb0 migration completes and stabilizes (24-48 hours post-deployment)

**Estimated Effort**: 2-3 hours

**Priority**: 🟡 **MEDIUM** - High value for future hostname changes

**Related**: This will make miniserver24 → hsb1 rename much easier!

---

**Last Updated**: November 21, 2025  
**Maintained By**: Markus Barta
