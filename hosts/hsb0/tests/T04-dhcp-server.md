# T04: DHCP Server

**Feature ID**: F04  
**Status**: ✅ Implemented

## Overview

Tests that AdGuard Home DHCP server is properly configured to assign IP addresses in the range 192.168.1.201-254 with 24-hour leases.

## Prerequisites

- SSH access to hsb0
- Physical access to network for testing new device assignment

## Manual Test Procedure

### Step 1: Verify DHCP Service is Enabled

```bash
ssh mba@192.168.1.99
sudo systemctl cat adguardhome | grep -A 10 "dhcp"
```

**Expected**: Shows `enabled: true`, `range_start: 192.168.1.201`, `range_end: 192.168.1.254`

### Step 2: Check DHCP is Listening

```bash
ssh mba@192.168.1.99
sudo ss -ulpn | grep :67
```

**Expected**: Shows AdGuard Home listening on UDP port 67

### Step 3: Test DHCP Assignment (New Device)

Connect a new device to the network (e.g., phone in airplane mode, then enable WiFi)

**Expected**: Device gets IP in range 192.168.1.201-254

### Step 4: Verify Lease in Web Interface

```bash
open http://192.168.1.99:3000
# Navigate to DHCP settings
```

**Expected**: Shows active leases for connected devices

### Step 5: Check Gateway Assignment

On the newly connected device:

```bash
# Linux/Mac
ip route show default
# or
netstat -rn | grep default
```

**Expected**: Gateway is 192.168.1.5 (Fritz!Box)

## Automated Test

Run the automated test script:

```bash
./tests/T04-dhcp-server.sh
```

## Success Criteria

- ✅ DHCP enabled in configuration
- ✅ Correct IP range (192.168.1.201-254)
- ✅ 24-hour lease duration
- ✅ Listening on UDP port 67
- ✅ Gateway set to 192.168.1.5

## Troubleshooting

### DHCP Not Assigning IPs

1. Check if another DHCP server is running on the network:

```bash
sudo nmap --script broadcast-dhcp-discover
```

2. Verify interface is correct (enp2s0f0):

```bash
ssh mba@192.168.1.99
ip link show enp2s0f0
```

3. Check AdGuard Home logs:

```bash
journalctl -u adguardhome | grep -i dhcp
```

### IP Range Conflicts

Ensure no static IPs are assigned in the DHCP range (192.168.1.201-254)

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |

## Notes

- DHCP range: 192.168.1.201-254 (54 addresses)
- Lease duration: 86400 seconds (24 hours)
- Gateway: 192.168.1.5 (Fritz!Box router)
- DNS: 192.168.1.99 (hsb0 itself)
- Domain: lan (via DHCP Option 15)
- Static leases managed separately (see T05)
