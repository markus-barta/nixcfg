# hsb8 Test Suite

This directory contains test procedures and automated scripts to verify that all server features are working correctly.

## Test Format

Each feature has:

- **Test Documentation** (`Txx-feature-name.md`): Detailed manual test procedures
- **Test Script** (`Txx-feature-name.sh`): Automated test script (where applicable)

## Running Tests

### Individual Test

```bash
# Run manual test (follow instructions in markdown file)
cat tests/T01-dns-server.md

# Run automated test
./tests/T01-dns-server.sh
```

### All Automated Tests

```bash
# Run all tests
cd hosts/hsb8
for test in tests/T*.sh; do
  echo "Running $test..."
  bash "$test" || echo "❌ Failed: $test"
done
```

## Test Status Legend

- ✅ **Pass**: Feature working as expected
- ⏳ **Skip**: Feature not yet implemented or deployed
- ❌ **Fail**: Feature not working, requires attention

## Prerequisites

- SSH access to hsb8 (192.168.1.100 or hsb8.lan)
- Network connectivity
- For ww87 location tests: Server must be deployed at parents' home

## Test List

| Test ID | Feature                  | Location | Last Run   | Manual | Auto | Notes                                                 |
| ------- | ------------------------ | -------- | ---------- | ------ | ---- | ----------------------------------------------------- |
| T00     | NixOS Base System        | both     | 2025-11-22 | ✅     | ❌   | Manual: config verified, Auto: SSH issue              |
| T01     | DNS Server               | ww87     | 2025-11-22 | 🔍     | N/A  | Theoretical: AdGuard disabled at jhw22                |
| T02     | Ad Blocking              | ww87     | 2025-11-22 | 🔍     | N/A  | Theoretical: config verified                          |
| T03     | DNS Cache                | ww87     | 2025-11-22 | 🔍     | N/A  | Theoretical: config verified                          |
| T04     | DHCP Server              | ww87     | 2025-11-22 | ⏳     | N/A  | Not yet implemented (dhcp.enabled = false)            |
| T05     | Static DHCP Leases       | ww87     | 2025-11-22 | ⏳     | N/A  | Depends on T04                                        |
| T06     | Web Management Interface | ww87     | 2025-11-22 | 🔍     | N/A  | Theoretical: port 3000 configured                     |
| T07     | DNS Query Logging        | ww87     | 2025-11-22 | 🔍     | N/A  | Theoretical: 90-day retention configured              |
| T08     | Custom DNS Rewrites      | ww87     | 2025-11-22 | 🔍     | N/A  | Theoretical: feature available                        |
| T09     | SSH Remote Access        | both     | 2025-11-22 | ✅     | ❌   | Manual: deployed correctly, Auto: SSH key needed      |
| T10     | Multi-User Access        | both     | 2025-11-22 | ✅     | ❌   | Manual: both users configured, Auto: SSH key needed   |
| T11     | ZFS Storage              | both     | 2025-11-22 | ✅     | ❌   | Manual: zpool healthy (7% used), Auto: SSH key needed |
| T12     | ZFS Snapshots            | both     | 2025-11-22 | ✅     | ⏳   | Manual: snapshot capability verified, Auto: pending   |
| T13     | Location-Based Config    | both     | 2025-11-22 | ✅     | N/A  | Manual: location=jhw22 verified                       |
| T14     | One-Command Deployment   | both     | 2025-11-22 | ✅     | N/A  | Manual: enable-ww87 script exists                     |

**Location Legend:**

- `both`: Can be tested at jhw22 (current) or ww87 (target)
- `ww87`: Requires deployment to parents' home (AdGuard Home features)
- `jhw22`: Only testable at current location

**Status Legend:**

- ✅ **Pass**: Test executed and passed
- ❌ **Fail**: Test executed and failed
- ⏳ **Pending**: Not yet run
- 🔍 **Theoretical**: Analytical check (cannot physically test)
- N/A: Test type not applicable

## Notes

- Tests assume server is at target location (ww87) unless specified
- Some tests require physical access to the server
- DNS/DHCP tests require network isolation for accuracy
