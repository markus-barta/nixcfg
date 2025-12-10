# T07: Karabiner-Elements

Test Karabiner-Elements keyboard remapping configuration.

## Prerequisites

- Karabiner-Elements installed via Homebrew
- Configuration linked via home-manager

## Manual Test Procedures

### Test 1: Karabiner-Elements Installed

**Steps:**

1. Check Karabiner is installed

```bash
ls /Applications/Karabiner-Elements.app
```

**Expected Results:**

- Application exists

**Status:** ⏳ Pending

### Test 2: Karabiner Running

**Steps:**

1. Check menu bar for Karabiner icon
2. Or check process

```bash
pgrep -l karabiner
```

**Expected Results:**

- karabiner_grabber and karabiner_observer running

**Status:** ⏳ Pending

### Test 3: Config File Linked

**Steps:**

```bash
ls -la ~/.config/karabiner/karabiner.json
```

**Expected Results:**

- File exists (symlink to config in hosts/mba-imac-work/config/)

**Status:** ⏳ Pending

### Test 4: Caps Lock → Hyper

**Steps:**

1. Open any text editor
2. Press Caps Lock + H

**Expected Results:**

- If Caps Lock is mapped to Hyper (Cmd+Ctrl+Opt+Shift), the key combination triggers
- Caps Lock alone does NOT toggle caps

**Status:** ⏳ Pending

### Test 5: F-Keys in Terminal

**Steps:**

1. Open WezTerm
2. Press F1, F2, etc.

**Expected Results:**

- F-keys work as function keys (not media keys) in terminal
- F1-F12 send actual function key codes

**Status:** ⏳ Pending

### Test 6: Input Monitoring Permissions

**Steps:**

1. System Preferences → Security & Privacy → Privacy → Input Monitoring
2. Check permissions

**Expected Results:**

- `karabiner_grabber` enabled
- `Karabiner-Elements` enabled

**Status:** ⏳ Pending

## Summary

- Total Tests: 6
- Passed: 0
- Failed: 0
- Pending: 6

## Related

- Feature: [F07 - Karabiner-Elements](../README.md#features)
- Automated: [T07-karabiner-elements.sh](./T07-karabiner-elements.sh)
