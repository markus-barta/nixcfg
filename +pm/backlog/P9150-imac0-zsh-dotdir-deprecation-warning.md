# imac0 Zsh dotDir Deprecation Warning

**Created**: 2026-01-13  
**Priority**: P9150 (Low)  
**Status**: Backlog

---

## Problem

Home Manager is showing deprecation warnings for `programs.zsh.dotDir` on imac0:

```
trace: warning: The default value of `programs.zsh.dotDir` will change in future versions.
You are currently using the legacy default (home directory) because `home.stateVersion` is less than "26.05".
To silence this warning and lock in the current behavior, set:
  programs.zsh.dotDir = config.home.homeDirectory;
To adopt the new behavior (XDG config directory), set:
  programs.zsh.dotDir = "${config.xdg.configHome}/zsh";
```

The warning appears twice during `home-manager switch` for imac0.

---

## Solution

Evaluate whether to:

1. Keep current behavior: Set `programs.zsh.dotDir = config.home.homeDirectory;`
2. Adopt new XDG behavior: Set `programs.zsh.dotDir = "${config.xdg.configHome}/zsh";`

Then update the imac0 home-manager configuration to explicitly set this value and silence the warning.

---

## Acceptance Criteria

- [ ] Determine whether to keep legacy or adopt XDG behavior
- [ ] Update imac0 home-manager configuration with explicit `programs.zsh.dotDir` setting
- [ ] Run `home-manager switch` and verify warning is gone
- [ ] No functional changes to zsh configuration

---

## Test Plan

### Manual Test

1. Run `just switch` for imac0
2. Verify no zsh dotDir warnings appear in output
3. Verify zsh still works correctly (shell loads, functions available)

### Automated Test

```bash
# Test home-manager switch completes without zsh warnings
home-manager switch --flake .#imac0 2>&1 | grep -i "zsh.*dotDir" || echo "No zsh dotDir warnings found"
```

---

## Related

- Host: imac0 (macOS home iMac)
- Module: home-manager zsh configuration
