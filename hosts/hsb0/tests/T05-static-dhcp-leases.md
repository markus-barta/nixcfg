# T05: Static DHCP Leases

**Feature ID**: F05  
**Status**: ✅ Implemented

## Overview

Tests that static DHCP leases are properly managed via agenix-encrypted JSON and merged with dynamic leases in AdGuard Home.

## Prerequisites

- SSH access to hsb0
- Agenix secret `static-leases-hsb0.age` exists

## Manual Test Procedure

### Step 1: Verify Agenix Secret Exists

```bash
ssh mba@192.168.1.99
test -f /run/agenix/static-leases-hsb0 && echo "✅ Secret decrypted" || echo "❌ Secret missing"
```

**Expected**: Secret is decrypted at `/run/agenix/static-leases-hsb0`

### Step 2: Check Static Leases JSON Format

```bash
ssh mba@192.168.1.99
cat /run/agenix/static-leases-hsb0 | jq .
```

**Expected**: Valid JSON array with `mac`, `ip`, `hostname` fields

### Step 3: Verify Leases are Merged

```bash
ssh mba@192.168.1.99
sudo cat /var/lib/private/AdGuardHome/data/leases.json | jq '.leases[] | select(.static == true)'
```

**Expected**: Shows static leases with `static: true` flag

### Step 4: Count Static Leases

```bash
ssh mba@192.168.1.99
sudo cat /var/lib/private/AdGuardHome/data/leases.json | jq '[.leases[] | select(.static == true)] | length'
```

**Expected**: Matches number of leases in agenix secret

### Step 5: Verify in Web Interface

```bash
open http://192.168.1.99:3000
# Navigate to DHCP → Static Leases
```

**Expected**: Shows all static leases

## Automated Test

Run the automated test script:

```bash
./tests/T05-static-dhcp-leases.sh
```

## Success Criteria

- ✅ Agenix secret decrypted successfully
- ✅ Static leases JSON is valid
- ✅ Static leases merged into leases.json
- ✅ Lease count matches expected
- ✅ Visible in web interface

## Troubleshooting

### Secret Not Decrypted

Check agenix configuration:

```bash
ssh mba@192.168.1.99
ls -la /run/agenix/
```

### Invalid JSON

Edit and fix the secret:

```bash
cd ~/Code/nixcfg
agenix -e secrets/static-leases-hsb0.age
```

### Leases Not Merged

Check AdGuard Home logs:

```bash
ssh mba@192.168.1.99
journalctl -u adguardhome -n 100 | grep lease
```

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |

## Notes

- Static leases stored encrypted in git (`secrets/static-leases-hsb0.age`)
- Decrypted at boot by agenix to `/run/agenix/static-leases-hsb0`
- Merged with dynamic leases via preStart script using jq
- Format: `[{"mac": "AA:BB:CC:DD:EE:FF", "ip": "192.168.1.X", "hostname": "device"}]`
- Static leases have `static: true` and `expires: ""` in leases.json
