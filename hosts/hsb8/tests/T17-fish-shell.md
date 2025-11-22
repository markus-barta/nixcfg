# T17: Fish Shell Utilities

**Feature ID**: F17  
**Status**: ✅ Implemented  
**Location**: Both jhw22 and ww87

## Overview

Tests that Fish shell utility functions and environment variables are properly configured, specifically the `sourcefish` function and `EDITOR` variable that were provided by the `serverMba` mixin.

## Prerequisites

- SSH access to hsb8
- Fish shell installed (default shell for hokage)

## Manual Test Procedure

### Step 1: Verify sourcefish Function Exists

```bash
ssh mba@192.168.1.100
type sourcefish
```

**Expected**: Shows function definition (not "not found")

### Step 2: Test sourcefish Function

```bash
ssh mba@192.168.1.100
# Create a test .env file
echo "TEST_VAR=hello_world" > /tmp/test.env
sourcefish /tmp/test.env
echo $TEST_VAR
```

**Expected**: Outputs `hello_world`

### Step 3: Verify EDITOR Variable

```bash
ssh mba@192.168.1.100
echo $EDITOR
```

**Expected**: `nano`

### Step 4: Verify in Configuration

```bash
ssh mba@192.168.1.100
grep -A 20 "programs.fish.interactiveShellInit" ~/nixcfg/hosts/hsb8/configuration.nix
```

**Expected**: Shows the sourcefish function definition and EDITOR export

## Automated Test

Run the automated test script:

```bash
./tests/T17-fish-shell.sh
```

## Success Criteria

- ✅ `sourcefish` function is defined and available
- ✅ `sourcefish` can load environment variables from .env files
- ✅ `EDITOR` variable is set to `nano`
- ✅ Configuration has `programs.fish.interactiveShellInit` block

## Troubleshooting

### sourcefish Not Found

Check configuration:

```bash
ssh mba@192.168.1.100
grep -c "function sourcefish" ~/nixcfg/hosts/hsb8/configuration.nix
```

If returns 0, the configuration is missing.

### EDITOR Not Set

```bash
ssh mba@192.168.1.100
env | grep EDITOR
```

Check if it's being set elsewhere.

## Test Log

| Date | Tester | Location | Result | Notes |
| ---- | ------ | -------- | ------ | ----- |
|      |        |          | ⏳     |       |

## Notes

- The `sourcefish` function loads environment variables from `.env` files into the current Fish session
- Useful for loading secrets or configuration without modifying shell config
- The `EDITOR=nano` ensures consistent editing experience
- These utilities were provided by `serverMba.enable` mixin in local hokage
- When migrating to external hokage, these must be added explicitly
- This is a convenience/quality-of-life feature, not critical for server operation
