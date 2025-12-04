# T00: Platform Detection

**Feature ID**: F00  
**Status**: ✅ Implemented

## Overview

Tests that StaSysMo correctly detects the platform (Linux/macOS) and configures appropriate paths and metric collection methods.

## Manual Test Procedure

### Step 1: Check Platform Detection

```bash
# Should output "Darwin" (macOS) or "Linux"
uname
```

**Expected**: Returns platform name

### Step 2: Verify Output Directory Path

```bash
# macOS
ls -la /tmp/stasysmo/

# Linux
ls -la /dev/shm/stasysmo/
```

**Expected**: Directory exists with metric files

### Step 3: Check Platform-Specific Commands

**macOS:**

```bash
vm_stat | head -5
sysctl vm.loadavg
sysctl vm.swapusage
```

**Linux:**

```bash
cat /proc/stat | head -5
cat /proc/meminfo | head -10
cat /proc/loadavg
```

**Expected**: Commands return metric data

## Automated Test

```bash
./tests/T00-platform.sh
```

## Success Criteria

- ✅ Platform correctly identified
- ✅ Output directory path matches platform
- ✅ Required commands/files available
- ✅ Platform-specific metric sources accessible

## Test Log

| Date | Tester | Platform | Result | Notes |
| ---- | ------ | -------- | ------ | ----- |
|      |        |          | ⏳     |       |
