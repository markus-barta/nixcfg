# T00: Nix Base System

Test the Nix package manager and home-manager configuration.

## Prerequisites

- Nix installed (multi-user)
- home-manager configured
- Flakes enabled

## Manual Test Procedures

### Test 1: Nix Installation

**Steps:**

1. Check Nix version:
   ```bash
   nix --version
   ```
2. Verify daemon running:
   ```bash
   systemctl status nix-daemon   # Linux
   launchctl list | grep nix     # macOS
   ```

**Expected Results:**

- Nix version >= 2.18
- Nix daemon active

**Status:** ⏳ Pending

### Test 2: home-manager Functionality

**Steps:**

1. Check home-manager version:
   ```bash
   home-manager --version
   ```
2. Test switch (dry-run):
   ```bash
   cd ~/Code/nixcfg
   home-manager switch --flake .#markus@imac-mba-home --dry-run
   ```

**Expected Results:**

- home-manager version displayed
- Dry-run completes without errors

**Status:** ⏳ Pending

### Test 3: Flakes Support

**Steps:**

1. Check flake configuration:
   ```bash
   nix flake show ~/Code/nixcfg
   ```
2. Verify flake metadata:
   ```bash
   nix flake metadata ~/Code/nixcfg
   ```

**Expected Results:**

- Flake outputs listed
- homeConfigurations.markus@imac-mba-home present

**Status:** ⏳ Pending

### Test 4: Platform Detection

**Steps:**

1. Check system architecture:
   ```bash
   uname -m
   ```
2. Verify Nix recognizes platform:
   ```bash
   nix eval --impure --expr 'builtins.currentSystem'
   ```

**Expected Results:**

- Architecture: `x86_64` (Intel iMac)
- Platform: `x86_64-darwin`

**Status:** ⏳ Pending

### Test 5: PATH Priority

**Steps:**

1. Check PATH order:
   ```bash
   echo $PATH | tr ':' '\n' | head -5
   ```
2. Verify Nix paths first:
   ```bash
   which fish
   which node
   which python3
   ```

**Expected Results:**

- `$HOME/.nix-profile/bin` first in PATH
- All commands resolve to `~/.nix-profile/bin/`

**Status:** ⏳ Pending

## Summary

- Total Tests: 5
- Passed: 0
- Failed: 0
- Pending: 5

## Related

- Feature: [F00 - Nix Base System](../docs/README.md#features)
- Automated: [T00-nix-base.sh](./T00-nix-base.sh)
