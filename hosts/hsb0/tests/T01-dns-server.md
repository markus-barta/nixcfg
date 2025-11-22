# T01: DNS Server

**Feature ID**: F01  
**Status**: ✅ Implemented

## Overview

Tests that AdGuard Home DNS server is properly configured and resolving DNS queries using Cloudflare (1.1.1.1) as upstream DNS.

## Prerequisites

- SSH access to hsb0
- hsb0 is the active network DNS server

## Manual Test Procedure

### Step 1: Verify AdGuard Home Service

```bash
ssh mba@192.168.1.99
systemctl status adguardhome
```

**Expected**: Service is `active (running)`

### Step 2: Test DNS Resolution (External)

```bash
# From your local machine
nslookup google.com 192.168.1.99
```

**Expected**: Resolves to Google's IP addresses

### Step 3: Test DNS Resolution (Internal - /etc/hosts)

```bash
nslookup hsb0.lan 192.168.1.99
```

**Expected**: Resolves to `192.168.1.99`

### Step 4: Test DNS Port

```bash
nmap -p 53 192.168.1.99
```

**Expected**: Port 53/tcp and 53/udp OPEN

### Step 5: Verify Upstream DNS Configuration

```bash
ssh mba@192.168.1.99
sudo systemctl cat adguardhome | grep upstream_dns
```

**Expected**: Shows Cloudflare DNS (`1.1.1.1` and `1.0.0.1`)

## Automated Test

Run the automated test script:

```bash
./tests/T01-dns-server.sh
```

## Success Criteria

- ✅ AdGuard Home service is running
- ✅ DNS queries resolve correctly (external domains)
- ✅ DNS queries resolve correctly (internal hostnames)
- ✅ Port 53 is accessible
- ✅ Upstream DNS is configured to Cloudflare

## Troubleshooting

### DNS Not Resolving

```bash
ssh mba@192.168.1.99
journalctl -u adguardhome -f
```

Check for errors in the AdGuard Home log.

### Port 53 Already in Use

```bash
sudo ss -tulpn | grep :53
```

Another service might be using port 53.

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |

## Notes

- AdGuard Home runs on port 53 (DNS standard port)
- Uses Cloudflare DNS (1.1.1.1, 1.0.0.1) as upstream
- Local DNS resolution via /etc/hosts for critical infrastructure
- DNS resolution is fundamental - all other network features depend on it
