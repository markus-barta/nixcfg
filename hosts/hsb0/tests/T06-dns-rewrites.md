# T06: DNS Rewrites

**Feature ID**: F06  
**Status**: ✅ Implemented

## Overview

Tests that DNS rewrites are properly configured to provide short names for cloud servers (csb0 → cs0.barta.cm, csb1 → cs1.barta.cm).

## Prerequisites

- SSH access to hsb0
- Cloud servers cs0.barta.cm and cs1.barta.cm are accessible

## Manual Test Procedure

### Step 1: Verify Rewrite Configuration

```bash
ssh mba@192.168.1.99
sudo systemctl cat adguardhome | grep -A 5 "user_rules"
```

**Expected**: Shows DNS rewrite rules for csb0 and csb1

### Step 2: Test csb0 Rewrite

```bash
nslookup csb0 192.168.1.99
```

**Expected**: Resolves to cs0.barta.cm

### Step 3: Test csb1 Rewrite

```bash
nslookup csb1 192.168.1.99
```

**Expected**: Resolves to cs1.barta.cm

### Step 4: Verify Direct Resolution Still Works

```bash
nslookup cs0.barta.cm 192.168.1.99
nslookup cs1.barta.cm 192.168.1.99
```

**Expected**: Both resolve to their respective IPs

## Automated Test

Run the automated test script:

```bash
./tests/T06-dns-rewrites.sh
```

## Success Criteria

- ✅ DNS rewrite rules configured
- ✅ csb0 resolves via rewrite
- ✅ csb1 resolves via rewrite
- ✅ Direct names still work

## Troubleshooting

### Rewrites Not Working

1. Check AdGuard Home configuration:

```bash
ssh mba@192.168.1.99
sudo systemctl cat adguardhome | grep -C 5 "csb"
```

2. Check query log in web interface to see how requests are being handled

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |

## Notes

- DNS rewrites use CNAME records
- Format: `||csb0^$dnsrewrite=NOERROR;CNAME;cs0.barta.cm`
- Allows short names for cloud servers without modifying /etc/hosts on every device
- Works network-wide for all devices using hsb0 as DNS
