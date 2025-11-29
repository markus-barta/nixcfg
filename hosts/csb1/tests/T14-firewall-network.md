# T14: Firewall & Network Test

**Feature ID**: F14  
**Status**: ⏳ Pending  
**Purpose**: Verify firewall rules and network configuration

## Overview

Tests that firewall rules are properly configured and required ports are accessible. Critical for migration - incorrect firewall rules can lock you out!

## Prerequisites

- SSH access to csb1 (port 2222)
- Network access from test machine

## Required Open Ports

| Port | Protocol | Service | Access |
| ---- | -------- | ------- | ------ |
| 2222 | TCP      | SSH     | Public |
| 80   | TCP      | HTTP    | Public |
| 443  | TCP      | HTTPS   | Public |

## Ports That Should Be Closed

| Port | Protocol | Service         | Reason             |
| ---- | -------- | --------------- | ------------------ |
| 22   | TCP      | SSH (default)   | Using 2222 instead |
| 3000 | TCP      | Grafana direct  | Behind Traefik     |
| 8086 | TCP      | InfluxDB direct | Internal only      |
| 5432 | TCP      | PostgreSQL      | Internal only      |

## Manual Verification

### Step 1: Check NixOS Firewall Status

```bash
ssh -p 2222 mba@cs1.barta.cm
sudo iptables -L -n | head -30
```

### Step 2: Check Open Ports from Server

```bash
# List listening ports
sudo ss -tlnp

# Check specific ports
sudo ss -tlnp | grep -E ':(22|80|443|2222|3000|8086)\s'
```

### Step 3: External Port Scan (from local machine)

```bash
# Check SSH port
nc -zv cs1.barta.cm 2222

# Check web ports
nc -zv cs1.barta.cm 80
nc -zv cs1.barta.cm 443

# These should be CLOSED/filtered
nc -zv cs1.barta.cm 22    # Should fail
nc -zv cs1.barta.cm 3000  # Should fail
```

## Automated Test

```bash
./tests/T14-firewall-network.sh
```

## Network Configuration

### Expected DNS Records

| Record             | Type    | Value         |
| ------------------ | ------- | ------------- |
| cs1.barta.cm       | A       | 152.53.64.166 |
| grafana.barta.cm   | CNAME/A | cs1.barta.cm  |
| docmost.barta.cm   | CNAME/A | cs1.barta.cm  |
| paperless.barta.cm | CNAME/A | cs1.barta.cm  |

### IPv6

- IPv6: `2a0a:4cc0:80:2d5:e8e8:c7ff:fe68:03c7`
- Should be accessible via SSH and HTTPS

## NixOS Firewall Configuration

Expected configuration in NixOS:

```nix
networking.firewall = {
  enable = true;
  allowedTCPPorts = [ 80 443 2222 ];
  # Port 22 NOT in allowedTCPPorts
};
```

## Success Criteria

- ✅ SSH port 2222 accessible
- ✅ HTTP port 80 accessible
- ✅ HTTPS port 443 accessible
- ✅ Default SSH port 22 blocked
- ✅ Internal ports (3000, 8086, etc.) not exposed
- ✅ Firewall enabled

## Warning Signs

- ❌ Port 22 open = Security risk (use 2222)
- ❌ Database ports open = Critical security issue
- ❌ Firewall disabled = All ports exposed!

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |
