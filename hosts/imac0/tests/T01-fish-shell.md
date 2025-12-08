# T01: Fish Shell

Test Fish shell configuration and custom functions.

## Prerequisites

- Fish shell installed from Nix
- Custom functions configured

## Manual Test Procedures

### Test 1: Fish Installation

**Steps:**

1. Check Fish version: `fish --version`
2. Verify from Nix: `which fish`

**Expected:** Fish v4.1.2, from `~/.nix-profile/bin/fish`

**Status:** ⏳ Pending

### Test 2: Uzumaki Functions

**Steps:**

1. Check uzumaki functions: `fish -c "functions -q pingt sourcefish stress helpfish"`
2. Test pingt output: `pingt -c 1 127.0.0.1`
3. Test helpfish: `helpfish`

**Expected:**

- Functions: `pingt`, `sourcefish`, `stress`, `helpfish` (from uzumaki)
- `brewall` (optional, macOS-specific from home.nix)
- pingt shows timestamps
- helpfish shows Functions section

**Status:** ⏳ Pending

### Test 3: Abbreviations

**Steps:**

1. Type `flushdns` and check expansion
2. Check `qc0`, `qc1`, `qc24`, `qc99` abbreviations

**Expected:** All abbreviations expand correctly

**Status:** ⏳ Pending

## Summary

- Total Tests: 3
- Passed: 0
- Failed: 0
- Pending: 3

## Related

- Feature: [F01 - Fish Shell](../docs/README.md#features)
- Automated: [T01-fish-shell.sh](./T01-fish-shell.sh)
