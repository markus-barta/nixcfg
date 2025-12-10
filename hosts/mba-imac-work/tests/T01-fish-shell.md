# T01: Fish Shell

Test Fish shell configuration and functionality.

## Prerequisites

- Fish shell installed via Nix
- Fish configured as default shell

## Manual Test Procedures

### Test 1: Fish Installation

**Steps:**

1. Verify Fish is installed from Nix

```bash
which fish
```

**Expected Results:**

- Shows `/Users/markus/.nix-profile/bin/fish`

**Status:** ⏳ Pending

### Test 2: Fish is Default Shell

**Steps:**

1. Check current shell

```bash
echo $SHELL
```

**Expected Results:**

- Shows `/Users/markus/.nix-profile/bin/fish` or similar Nix path

**Status:** ⏳ Pending

### Test 3: Custom Aliases

**Steps:**

1. Check aliases are defined

```bash
alias | grep -E "^(ll|la|grep|cat)="
```

**Expected Results:**

- Shows aliases like `ll='ls -la'`, `cat='bat'`

**Status:** ⏳ Pending

### Test 4: Abbreviations

**Steps:**

1. List abbreviations

```bash
abbr
```

**Expected Results:**

- Shows abbreviations like `g=git`, `gst=git status`

**Status:** ⏳ Pending

### Test 5: Custom Functions

**Steps:**

1. Test sudo !! function

```bash
type sudo
```

**Expected Results:**

- Shows custom function with !! support

**Status:** ⏳ Pending

## Summary

- Total Tests: 5
- Passed: 0
- Failed: 0
- Pending: 5

## Related

- Feature: [F01 - Fish Shell](../README.md#features)
- Automated: [T01-fish-shell.sh](./T01-fish-shell.sh)
