# T08: DNS Query Logging

**Feature ID**: F08  
**Status**: ✅ Implemented

## Overview

Tests that DNS query logging is properly enabled with 90-day retention for troubleshooting and monitoring.

## Prerequisites

- SSH access to hsb0
- Web interface access

## Manual Test Procedure

### Step 1: Verify Query Logging Configuration

```bash
ssh mba@192.168.1.99
sudo systemctl cat adguardhome | grep -A 5 "querylog"
```

**Expected**: Shows `enabled: true` and `interval: 2160h` (90 days)

### Step 2: Check Query Log in Web Interface

```bash
open http://192.168.1.99:3000
# Navigate to Query Log
```

**Expected**: Shows recent DNS queries with timestamps, client IPs, and response status

### Step 3: Perform Test Query and Verify Logging

```bash
# Make a DNS query
nslookup test-$(date +%s).example.com 192.168.1.99

# Check if it appears in log (via web interface)
```

**Expected**: Query appears in the log within seconds

### Step 4: Verify Log Retention

```bash
open http://192.168.1.99:3000
# Check Query Log settings
```

**Expected**: Shows 90-day retention (2160 hours)

### Step 5: Test Log Filtering

In the web interface, try filtering by:

- Client IP
- Domain name
- Query type (A, AAAA, etc.)
- Response status (blocked, allowed)

**Expected**: Filtering works correctly

## Automated Test

Run the automated test script:

```bash
./tests/T08-dns-query-logging.sh
```

## Success Criteria

- ✅ Query logging enabled
- ✅ 90-day retention configured
- ✅ Queries appear in log
- ✅ Log accessible via web interface
- ✅ Filtering works

## Troubleshooting

### Queries Not Appearing in Log

1. Check if logging is enabled:

```bash
ssh mba@192.168.1.99
sudo systemctl cat adguardhome | grep querylog -A 5
```

2. Check AdGuard Home logs:

```bash
journalctl -u adguardhome | grep -i "query"
```

### Log Full or Not Rotating

Check disk space:

```bash
ssh mba@192.168.1.99
df -h /var/lib/private/AdGuardHome
```

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |

## Notes

- Query log retention: 2160 hours (90 days)
- Stores 1000 queries in memory for fast access
- Logs include: timestamp, client IP, query domain, query type, response status
- Useful for troubleshooting DNS issues and monitoring network activity
- Can be disabled for privacy if desired
