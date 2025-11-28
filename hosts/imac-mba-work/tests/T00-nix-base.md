# T00: Nix Base System

Test the Nix installation and home-manager configuration.

## Prerequisites

- Nix installed
- home-manager configured via flake

## Manual Test Procedures

### Test 1: Nix Installation

**Steps:**

1. Verify Nix is installed and accessible

```bash
nix --version
```

**Expected Results:**

- Nix version displayed (e.g., `nix (Nix) 2.28.0`)

**Status:** ⏳ Pending

### Test 2: Flakes Support

**Steps:**

1. Verify flakes are enabled

```bash
nix flake --help
```

**Expected Results:**

- Help text displayed (not "experimental feature" error)

**Status:** ⏳ Pending

### Test 3: home-manager Installation

**Steps:**

1. Verify home-manager is installed

```bash
home-manager --version
```

**Expected Results:**

- Version displayed (e.g., `24.11`)

**Status:** ⏳ Pending

### Test 4: home-manager Profile

**Steps:**

1. Verify current generation

```bash
home-manager generations | head -3
```

**Expected Results:**

- At least one generation listed

**Status:** ⏳ Pending

### Test 5: Nix Profile Path

**Steps:**

1. Verify Nix profile is in PATH

```bash
echo $PATH | tr ':' '\n' | grep nix-profile
```

**Expected Results:**

- Shows `/Users/markus/.nix-profile/bin`

**Status:** ⏳ Pending

## Summary

- Total Tests: 5
- Passed: 0
- Failed: 0
- Pending: 5

## Related

- Feature: [F00 - Nix Base System](../README.md#features)
- Automated: [T00-nix-base.sh](./T00-nix-base.sh)
