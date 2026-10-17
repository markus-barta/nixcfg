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

> 🔴 Do **not** print the decrypted file — it is the full MAC↔IP map of the home
> LAN. Validate its shape and size instead.

```bash
ssh mba@192.168.1.99
# Structure valid + how many leases (no lease contents printed)
sudo jq -e 'length' /run/agenix/static-leases-hsb0
# Required fields present on every entry -> prints true/false only
sudo jq -e 'all(has("mac") and has("ip") and has("hostname"))' /run/agenix/static-leases-hsb0
```

**Expected**: a lease count, then `true` — a valid JSON array whose entries all
carry `mac`, `ip` and `hostname`.

### Step 3: Verify Leases are Merged

```bash
ssh mba@192.168.1.99
sudo jq -e 'all(.leases[] | select(.static == true); has("mac") and has("ip") and has("hostname"))' /var/lib/private/AdGuardHome/data/leases.json
```

**Expected**: `true`; validates static lease fields without displaying MACs or lease contents.

### Step 4: Count Static Leases

```bash
ssh mba@192.168.1.99
sudo jq '[.leases[] | select(.static == true)] | length' /var/lib/private/AdGuardHome/data/leases.json
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
- Format: JSON array of objects with `mac`, `ip` and `hostname` fields; never print entries.
- Static leases have `static: true` and `expires: ""` in leases.json
