# T02: Git Dual Identity

Test Git dual identity configuration (work default, personal for specific paths).

## Prerequisites

- Git installed via Nix
- Git configured with conditional includes

## Manual Test Procedures

### Test 1: Git Installation

**Steps:**

1. Verify Git is installed from Nix

```bash
which git
git --version
```

**Expected Results:**

- Shows `/Users/markus/.nix-profile/bin/git`
- Version displayed

**Status:** ⏳ Pending

### Test 2: Default (Work) Identity

**Steps:**

1. Check default Git identity (in any directory)

```bash
cd /tmp
git config user.name
git config user.email
```

**Expected Results:**

- Name: `mba`
- Email: `markus.barta@bytepoets.com`

**Status:** ⏳ Pending

### Test 3: Personal Identity for nixcfg

**Steps:**

1. Check Git identity in nixcfg repository

```bash
cd ~/Code/nixcfg
git config user.name
git config user.email
```

**Expected Results:**

- Name: `Markus Barta`
- Email: `markus@barta.com`

**Status:** ⏳ Pending

### Test 4: Conditional Include Active

**Steps:**

1. Verify gitdir include is active

```bash
cd ~/Code/nixcfg
git config --show-origin user.email
```

**Expected Results:**

- Shows the includeIf conditional path

**Status:** ⏳ Pending

### Test 5: Work Identity for BYTEPOETS Projects

**Steps:**

1. If BYTEPOETS directory exists, check identity

```bash
mkdir -p ~/Code/BYTEPOETS/test-repo
cd ~/Code/BYTEPOETS/test-repo
git init
git config user.email
```

**Expected Results:**

- Email: `markus.barta@bytepoets.com` (work default)

**Status:** ⏳ Pending

## Summary

- Total Tests: 5
- Passed: 0
- Failed: 0
- Pending: 5

## Related

- Feature: [F02 - Git Dual Identity](../README.md#features)
- Automated: [T02-git-dual-identity.sh](./T02-git-dual-identity.sh)
