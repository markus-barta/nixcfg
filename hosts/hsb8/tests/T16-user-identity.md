# T16: User Identity Configuration

**Feature ID**: F16  
**Status**: ✅ Implemented  
**Location**: Both jhw22 and ww87

## Overview

Tests that user identity is properly configured in the hokage module, ensuring git commits and system operations use the correct user information instead of defaults (Patrizio Bekerle).

## Prerequisites

- SSH access to hsb8
- Git installed (provided by hokage)

## Manual Test Procedure

### Step 1: Verify Git User Name

```bash
ssh mba@192.168.1.100
git config --get user.name
```

**Expected**: `Markus Barta`

### Step 2: Verify Git User Email

```bash
ssh mba@192.168.1.100
git config --get user.email
```

**Expected**: `markus@barta.com`

### Step 3: Verify in Configuration

```bash
ssh mba@192.168.1.100
grep -A 3 "userNameLong\|userNameShort\|userEmail" ~/nixcfg/hosts/hsb8/configuration.nix
```

**Expected**: Shows all three configured with Markus' information

### Step 4: Test Git Commit Authorship

```bash
ssh mba@192.168.1.100
cd /tmp
git init test-repo
cd test-repo
echo "test" > test.txt
git add test.txt
git commit -m "Test commit"
git log --format="%an <%ae>" -n 1
```

**Expected**: `Markus Barta <markus@barta.com>`

## Automated Test

Run the automated test script:

```bash
./tests/T16-user-identity.sh
```

## Success Criteria

- ✅ Git user.name is "Markus Barta" (not "Patrizio Bekerle")
- ✅ Git user.email is "markus@barta.com" (not "patrizio@bekerle.com")
- ✅ Configuration has userNameLong, userNameShort, userEmail set
- ✅ Git commits show correct authorship

## Troubleshooting

### Git Config Shows Wrong Name

Check hokage configuration:

```bash
ssh mba@192.168.1.100
grep "userNameLong\|userNameShort\|userEmail" ~/nixcfg/hosts/hsb8/configuration.nix
```

If missing, the hokage module will default to Patrizio's information.

### No Git Config Set

```bash
ssh mba@192.168.1.100
git config --list --show-origin | grep user
```

This shows where git config comes from.

## Test Log

| Date | Tester | Location | Result | Notes |
| ---- | ------ | -------- | ------ | ----- |
|      |        |          | ⏳     |       |

## Notes

- These hokage options default to "Patrizio Bekerle" and "patrizio@bekerle.com"
- Without explicit configuration, all git commits would be attributed to Patrizio
- This was provided by the `serverMba.enable` mixin in the local hokage module
- When migrating to external hokage, these must be set explicitly
- Not a security issue, but a correctness/attribution issue
