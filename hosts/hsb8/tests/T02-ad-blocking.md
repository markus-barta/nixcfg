# T02: Ad Blocking

**Feature ID**: F02  
**Status**: ✅ Implemented (via AdGuard Home)  
**Location**: ww87 (requires AdGuard Home to be active)

## Overview

Tests that ad blocking functionality is working correctly, protecting all devices on the network from ads and trackers.

## Prerequisites

- Server deployed at ww87 location (`location = "ww87"`)
- AdGuard Home enabled and running
- DNS configured to use hsb8 (192.168.1.100)

## Manual Test Procedure

### Step 1: Verify Ad Blocking Lists

```bash
ssh mba@192.168.1.100
curl -s http://127.0.0.1:3000/control/stats | jq '.num_blocked_filtering'
```

**Expected**: Shows number of blocked queries

### Step 2: Test Known Ad Domain

From a device using hsb8 as DNS:

```bash
nslookup ads.doubleclick.net 192.168.1.100
```

**Expected**: Should return blocked/NXDOMAIN

### Step 3: Check Blocking Statistics

Access AdGuard Home web UI: <http://192.168.1.100:3000>

**Expected**: Dashboard shows "Blocked by filters" counter increasing

### Step 4: Test Legitimate Domain

```bash
nslookup google.com 192.168.1.100
```

**Expected**: Resolves normally (not blocked)

### Step 5: Verify Filter Lists

In AdGuard Home UI → Filters → DNS blocklists

**Expected**: Shows active filter lists (AdGuard DNS filter, etc.)

## Automated Test

Script not yet implemented (requires ww87 deployment).

## Success Criteria

- ✅ Ad blocking is enabled in AdGuard Home
- ✅ Known ad domains are blocked
- ✅ Legitimate domains resolve normally
- ✅ Blocking statistics are tracked
- ✅ Filter lists are active and updating

## Analytical Check (jhw22 - Theoretical)

**Cannot physically test at jhw22** (AdGuard Home disabled), but configuration analysis shows:

✅ **Configuration Present**: AdGuard Home configuration includes:

```nix
filtering = {
  protection_enabled = true;
  filtering_enabled = true;
};
```

✅ **Expected Behavior**: When deployed to ww87:

- Filter lists will be activated
- DNS queries matching filter rules will be blocked
- Statistics will track blocked queries
- Web UI will show blocking dashboard

🔍 **Theoretical Result**: **PASS** - Configuration is correct for ad blocking

## Test Log

| Date       | Tester | Location | Result | Notes                                             |
| ---------- | ------ | -------- | ------ | ------------------------------------------------- |
| 2025-11-22 | AI     | jhw22    | 🔍     | Theoretical test - config verified, awaiting ww87 |
|            |        |          |        |                                                   |
