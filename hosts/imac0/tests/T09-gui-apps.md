# T09: GUI Apps (WezTerm)

Test GUI application installation and Spotlight indexing.

## Key Concept: macOS Aliases vs Symlinks

```
┌─────────────────────────────────────────────────────────────────┐
│  WHY ALIASES, NOT SYMLINKS?                                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Symlink to /nix/store → ❌ NOT indexed by Spotlight            │
│  macOS Alias           → ✅ INDEXED by Spotlight                │
│                                                                 │
│  home-manager creates:                                          │
│    ~/Applications/Home Manager Apps/WezTerm.app (symlink→nix)   │
│                                                                 │
│  Our activation script creates:                                 │
│    ~/Applications/WezTerm.app (macOS alias → HM Apps version)   │
│                                                                 │
│  Result: ⌘+Space → "WezTerm" → Found!                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- GUI Apps configured via home-manager
- `home.activation.linkMacOSApps` creates aliases (not symlinks)

## Manual Test Procedures

### Test 1: WezTerm in Home Manager Apps

**Steps:**

```bash
ls -la ~/Applications/Home\ Manager\ Apps/WezTerm.app
```

**Expected:** Symlink pointing to `/nix/store/...`

### Test 2: WezTerm Alias in ~/Applications

**Steps:**

```bash
# Check it's a file (alias), not symlink
ls -la ~/Applications/WezTerm.app
# Should show: -rw-r--r--  (file, ~1KB size)
# NOT:         lrwxr-xr-x  (symlink)

# Verify file size (aliases are 500-2000 bytes)
stat -f%z ~/Applications/WezTerm.app
```

**Expected:** File (not symlink) with size ~1000-1500 bytes

### Test 3: Spotlight Indexing

**Steps:**

```bash
# Check Spotlight can find it
mdfind "kMDItemDisplayName == 'WezTerm*'"
```

**Expected:** Shows `/Users/xxx/Applications/WezTerm.app`

### Test 4: Launch from Spotlight

**Steps:**

1. Press ⌘+Space
2. Type "WezTerm"
3. Press Enter

**Expected:** WezTerm launches

## Troubleshooting

**If Spotlight doesn't find WezTerm:**

1. Check alias exists: `ls -la ~/Applications/WezTerm.app`
2. If symlink (l in permissions): run `home-manager switch` to recreate as alias
3. Force Spotlight reindex: `sudo mdutil -E /`

## Summary

- Total Tests: 4
- Focus: macOS alias creation for Spotlight indexing

## Related

- Activation script: `home.activation.linkMacOSApps` in home.nix
- Documentation: `docs/MACOS-SETUP.md` section 5.3
