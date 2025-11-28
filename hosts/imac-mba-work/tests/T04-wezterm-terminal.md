# T04: WezTerm Terminal

Test WezTerm terminal emulator configuration.

## Prerequisites

- WezTerm installed via Nix
- WezTerm configuration linked

## Manual Test Procedures

### Test 1: WezTerm Installation

**Steps:**

1. Verify WezTerm is installed from Nix

```bash
which wezterm
wezterm --version
```

**Expected Results:**

- Shows path containing `.nix-profile`
- Version displayed

**Status:** ⏳ Pending

### Test 2: WezTerm App Available

**Steps:**

1. Check WezTerm app is in Applications

```bash
ls -la ~/Applications/ | grep -i wezterm
```

**Expected Results:**

- WezTerm.app symlinked

**Status:** ⏳ Pending

### Test 3: Config File Exists

**Steps:**

1. Check WezTerm config exists

```bash
ls -la ~/.config/wezterm/wezterm.lua
```

**Expected Results:**

- Config file exists

**Status:** ⏳ Pending

### Test 4: WezTerm Launches

**Steps:**

1. Launch WezTerm from Spotlight or Dock
2. Verify it opens correctly

**Expected Results:**

- Terminal opens
- Custom font displayed (Hack Nerd Font)
- Custom color scheme applied

**Status:** ⏳ Pending

### Test 5: Fish Shell Default

**Steps:**

1. Open WezTerm
2. Check shell

```bash
echo $SHELL
```

**Expected Results:**

- Fish shell is active (Starship prompt visible)

**Status:** ⏳ Pending

## Summary

- Total Tests: 5
- Passed: 0
- Failed: 0
- Pending: 5

## Related

- Feature: [F04 - WezTerm Terminal](../README.md#features)
- Automated: [T04-wezterm-terminal.sh](./T04-wezterm-terminal.sh)
