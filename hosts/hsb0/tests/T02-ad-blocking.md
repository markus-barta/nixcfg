# T02: Ad Blocking

**Feature ID**: F02  
**Status**: ✅ Implemented

## Overview

Tests that AdGuard Home ad blocking is properly enabled and filtering ads/trackers across all network devices.

## Prerequisites

- SSH access to hsb0
- Ad blocking lists configured in AdGuard Home

## Manual Test Procedure

### Step 1: Verify Filtering is Enabled

```bash
ssh mba@192.168.1.99
sudo systemctl cat adguardhome | grep -A 5 "filtering"
```

**Expected**: Shows `protection_enabled: true` and `filtering_enabled: true`

### Step 2: Test Ad Domain (Should be Blocked)

```bash
nslookup ads.example.com 192.168.1.99
```

**Expected**: Returns NXDOMAIN or blocked response (if in blocklist)

### Step 3: Check Web Interface Filtering Status

```bash
# Open in browser
open http://192.168.1.99:3000
```

**Expected**: Dashboard shows "Protection is enabled"

### Step 4: Verify Query Log Shows Blocking

```bash
# In AdGuard Home UI
# Settings → Query Log
```

**Expected**: Can see blocked queries in red

## Automated Test

Run the automated test script:

```bash
./tests/T02-ad-blocking.sh
```

## Success Criteria

- ✅ Protection enabled in configuration
- ✅ Filtering enabled in configuration
- ✅ Ad domains are blocked (if in blocklists)
- ✅ Web interface shows filtering status

## Troubleshooting

### Ads Not Being Blocked

1. Check if filtering is enabled in configuration
2. Verify blocklists are loaded (AdGuard Home UI → Filters)
3. Check query log to see if requests are being blocked

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |

## Notes

- Ad blocking happens at the DNS level
- Blocks ads for all devices on the network
- Does not require per-device configuration
- Can be managed via web interface or declarative config
