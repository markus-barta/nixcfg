# T18: Local /etc/hosts

**Feature ID**: F18  
**Status**: ✅ Implemented  
**Location**: Both jhw22 and ww87

## Overview

Tests that local `/etc/hosts` entries are properly configured for privacy-focused hostname resolution without relying on DNS. This provides fallback resolution when DNS is unavailable and uses cryptic/encoded hostnames to avoid revealing device details in git.

## Prerequisites

- SSH access to hsb8

## Manual Test Procedure

### Step 1: Verify /etc/hosts Contains hsb8

```bash
ssh mba@192.168.1.100
cat /etc/hosts | grep hsb8
```

**Expected**: Shows entries for `hsb8` and `hsb8.lan` pointing to `192.168.1.100`

### Step 2: Test Hostname Resolution

```bash
ssh mba@192.168.1.100
ping -c 1 hsb8
ping -c 1 hsb8.lan
```

**Expected**: Both resolve to `192.168.1.100` and respond

### Step 3: Verify in Configuration

```bash
ssh mba@192.168.1.100
grep -A 10 "networking.hosts" ~/nixcfg/hosts/hsb8/configuration.nix
```

**Expected**: Shows networking.hosts configuration with entries

### Step 4: Check Self-Resolution

```bash
ssh mba@192.168.1.100
hostname
hostname -f
```

**Expected**:

- First command: `hsb8`
- Second command: `hsb8.lan` or `hsb8`

## Automated Test

Run the automated test script:

```bash
./tests/T18-local-hosts.sh
```

## Success Criteria

- ✅ `/etc/hosts` contains entries for hsb8
- ✅ Hostname `hsb8` resolves to `192.168.1.100`
- ✅ Hostname `hsb8.lan` resolves to `192.168.1.100`
- ✅ Configuration has `networking.hosts` entries
- ✅ Self-resolution works (ping hsb8 works from hsb8)

## Troubleshooting

### Hostname Not Resolving

Check `/etc/hosts` directly:

```bash
ssh mba@192.168.1.100
sudo cat /etc/hosts
```

### Configuration Missing

```bash
ssh mba@192.168.1.100
grep -c "networking.hosts" ~/nixcfg/hosts/hsb8/configuration.nix
```

If returns 0, configuration is not applied.

## Test Log

| Date | Tester | Location | Result | Notes |
| ---- | ------ | -------- | ------ | ----- |
|      |        |          | ⏳     |       |

## Notes

- Local `/etc/hosts` provides fallback DNS resolution
- Works even when DNS server (AdGuard Home) is unavailable
- Uses privacy-focused hostnames (e.g., `vr-netgear-gs724` instead of "Netgear Switch Living Room")
- Prevents revealing device details in git repository
- Pattern inherited from hsb0 (DNS/DHCP server)
- Can be extended with additional infrastructure hosts as needed
- Format: `"IP.ADDRESS" = [ "short-name" "fqdn.lan" ];`
