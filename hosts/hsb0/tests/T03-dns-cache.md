# T03: DNS Cache

**Feature ID**: F03  
**Status**: ✅ Implemented

## Overview

Tests that DNS caching is properly configured (4MB cache with optimistic caching) to improve DNS resolution speed.

## Prerequisites

- SSH access to hsb0
- AdGuard Home running

## Manual Test Procedure

### Step 1: Verify Cache Configuration

```bash
ssh mba@192.168.1.99
sudo systemctl cat adguardhome | grep -A 5 "cache"
```

**Expected**: Shows `cache_size: 4194304` (4MB) and `cache_optimistic: true`

### Step 2: Test Cache Performance

```bash
# First query (uncached)
time nslookup google.com 192.168.1.99

# Second query (should be cached)
time nslookup google.com 192.168.1.99
```

**Expected**: Second query is significantly faster

### Step 3: Check Cache Statistics

Open AdGuard Home web interface:

```bash
open http://192.168.1.99:3000
```

Navigate to Settings → DNS Settings → Cache

**Expected**: Shows cache configuration and hit rate

## Automated Test

Run the automated test script:

```bash
./tests/T03-dns-cache.sh
```

## Success Criteria

- ✅ DNS cache configured to 4MB
- ✅ Optimistic caching enabled
- ✅ Cache improves query performance
- ✅ Cache configuration visible in web interface

## Troubleshooting

### Cache Not Working

Check AdGuard Home logs for cache-related errors:

```bash
ssh mba@192.168.1.99
journalctl -u adguardhome | grep -i cache
```

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |

## Notes

- 4MB cache can hold thousands of DNS records
- Optimistic caching serves stale records while refreshing in background
- Significantly improves DNS resolution speed for frequently accessed domains
- Cache is in-memory (lost on restart, but quickly repopulated)
