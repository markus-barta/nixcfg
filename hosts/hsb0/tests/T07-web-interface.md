# T07: Web Management Interface

**Feature ID**: F07  
**Status**: ✅ Implemented

## Overview

Tests that the AdGuard Home web management interface is accessible on port 3000 for DNS/DHCP administration.

## Prerequisites

- Network connectivity to hsb0
- Admin credentials for AdGuard Home

## Manual Test Procedure

### Step 1: Verify Web Interface Port

```bash
ssh mba@192.168.1.99
sudo ss -tlpn | grep :3000
```

**Expected**: AdGuard Home listening on port 3000

### Step 2: Access Web Interface

```bash
open http://192.168.1.99:3000
```

**Expected**: AdGuard Home login page appears

### Step 3: Login to Interface

Use username `admin`; Markus holds the password in the Markus-only
`secrets/adguard-admin-password.age`. OPS uses the temporary status-only probe
in the RUNBOOK during cutover.

**Expected**: Successfully logs in to dashboard

### Step 4: Verify Dashboard Functionality

Check that dashboard shows:

- DNS queries statistics
- Top queried domains
- Top blocked domains
- Query log

**Expected**: All dashboard elements load correctly

### Step 5: Test Settings Access

Navigate to Settings → General Settings

**Expected**: Can access and view settings

## Automated Test

Run the automated test script:

```bash
./tests/T07-web-interface.sh
```

## Success Criteria

- ✅ Port 3000 is listening
- ✅ Web interface is accessible
- ✅ Login page loads
- ✅ Dashboard is functional
- ✅ Settings are accessible

## Troubleshooting

### Web Interface Not Accessible

1. Check if AdGuard Home is running:

```bash
ssh mba@192.168.1.99
systemctl status adguardhome
```

2. Check firewall:

```bash
sudo nft list ruleset | grep 3000
```

3. Check logs:

```bash
journalctl -u adguardhome -f
```

### Can't Login

- The admin users list comes from `/run/agenix/hsb0-adguard-users`, encrypted
  in `secrets/hsb0-adguard-users.age`; the password is encrypted separately
  in the Markus-only `secrets/adguard-admin-password.age`.
- Never display the runtime secret, verifier, login request body, or YAML.
- Follow the rotation procedure in [RUNBOOK](../docs/RUNBOOK.md#adguard-admin-rotation-ops-372).

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |

## Notes

- Web interface runs on port 3000 (not default 80/443)
- Admin username: `admin`
- Declarative configuration (`mutableSettings = false`) prevents UI changes from persisting
- All configuration must be done via NixOS configuration.nix
- With a valid users secret, accessible from devices on the network
- Missing or invalid users locks admin login and binds the UI to loopback;
  DNS/DHCP remain configured. Check `adguardhome-users-health.service`.
