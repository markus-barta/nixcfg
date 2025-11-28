# T08: Nerd Fonts

Test Nerd Font installation and rendering.

## Prerequisites

- Hack Nerd Font installed via Nix
- Fonts linked to ~/Library/Fonts/

## Manual Test Procedures

### Test 1: Font Files Exist

**Steps:**

```bash
ls -la ~/Library/Fonts/ | grep -i hack
```

**Expected Results:**

- Hack Nerd Font TTF files (symlinks to Nix store)

**Status:** ⏳ Pending

### Test 2: Font in fontconfig

**Steps:**

```bash
fc-list | grep -i "hack nerd"
```

**Expected Results:**

- Hack Nerd Font variants listed

**Status:** ⏳ Pending

### Test 3: Icons Render in Terminal

**Steps:**

1. Open WezTerm
2. Run:

```bash
echo "  󰊢       "
```

**Expected Results:**

- Icons display correctly (not boxes or question marks)
- Git icon, folder icon, etc. visible

**Status:** ⏳ Pending

### Test 4: Starship Icons

**Steps:**

1. Navigate to a git repository

```bash
cd ~/Code/nixcfg
```

2. Observe Starship prompt

**Expected Results:**

- Git branch icon displays
- Directory icons display
- No broken/missing glyphs

**Status:** ⏳ Pending

### Test 5: WezTerm Font Configuration

**Steps:**

1. Check WezTerm is using Hack Nerd Font

```bash
grep -i "hack" ~/.config/wezterm/wezterm.lua 2>/dev/null || echo "Check home-manager config"
```

**Expected Results:**

- Font configuration shows "Hack Nerd Font Mono"

**Status:** ⏳ Pending

## Summary

- Total Tests: 5
- Passed: 0
- Failed: 0
- Pending: 5

## Related

- Feature: [F08 - Nerd Fonts](../README.md#features)
- Automated: [T08-nerd-fonts.sh](./T08-nerd-fonts.sh)
