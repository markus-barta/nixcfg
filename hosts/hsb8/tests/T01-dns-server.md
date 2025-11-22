# T01: DNS Server (AdGuard Home)

**Feature ID**: F01  
**Status**: ✅ Implemented  
**Location**: ww87 (Parents' home)

## Overview

Tests that the AdGuard Home DNS server is running and resolving domain names correctly.

## Prerequisites

- Server deployed at ww87 location
- AdGuard Home enabled (`location = "ww87"` in configuration)
- Network connectivity to hsb8 (192.168.1.100)

## Manual Test Procedure

### Step 1: Verify AdGuard Home Service

```bash
ssh mba@192.168.1.100
systemctl status adguardhome
```

**Expected**: Service is `active (running)`

### Step 2: Test DNS Resolution Locally

```bash
ssh mba@192.168.1.100
nslookup google.com 127.0.0.1
```

**Expected**:

- Returns IP address for google.com
- Server: `127.0.0.1`
- No errors

### Step 3: Test DNS Resolution from Network

From another device on the network:

```bash
nslookup google.com 192.168.1.100
```

**Expected**:

- Returns IP address for google.com
- Server: `192.168.1.100`
- Response time < 500ms

### Step 4: Test External DNS

```bash
nslookup example.com 192.168.1.100
```

**Expected**: Resolves correctly (uses Cloudflare 1.1.1.1 upstream)

### Step 5: Check DNS Port Accessibility

```bash
nc -zvu 192.168.1.100 53
```

**Expected**: Port 53 UDP is open

## Automated Test

Run the automated test script:

```bash
./tests/T01-dns-server.sh
```

## Success Criteria

- ✅ AdGuard Home service is active
- ✅ DNS queries resolve correctly locally
- ✅ DNS queries resolve correctly from network
- ✅ Port 53 is accessible
- ✅ Response times are reasonable (< 500ms)

## Troubleshooting

### Service Not Running

```bash
ssh mba@192.168.1.100
sudo journalctl -u adguardhome -f
```

### DNS Not Resolving

1. Check location setting: `grep 'location =' ~/nixcfg/hosts/hsb8/configuration.nix`
2. Should be `location = "ww87"`
3. If `jhw22`, AdGuard Home is disabled by design

### Port Not Accessible

```bash
ssh mba@192.168.1.100
sudo iptables -L -n | grep 53
```

Check firewall rules allow port 53.

## Test Log

| Date       | Tester | Location | Result | Notes                     |
| ---------- | ------ | -------- | ------ | ------------------------- |
| 2025-11-22 | AI     | jhw22    | ⏳     | AdGuard disabled at jhw22 |
|            |        |          |        |                           |
