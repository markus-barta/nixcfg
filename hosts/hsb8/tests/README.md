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

| Test ID | Feature                  | Location | Manual Last Run     | Auto Last Run       | Notes                                                          |
| ------- | ------------------------ | -------- | ------------------- | ------------------- | -------------------------------------------------------------- |
| T00     | NixOS Base System        | both     | ✅ 2025-11-22 10:00 | ✅ 2025-11-22 11:30 | All 5 tests passed: version, config, generations, status, GRUB |
| T01     | DNS Server               | ww87     | 🔍 2025-11-22 10:00 | N/A                 | Theoretical: AdGuard disabled at jhw22                         |
| T02     | Ad Blocking              | ww87     | 🔍 2025-11-22 10:00 | N/A                 | Theoretical: config verified                                   |
| T03     | DNS Cache                | ww87     | 🔍 2025-11-22 10:00 | N/A                 | Theoretical: config verified                                   |
| T04     | DHCP Server              | ww87     | ⏳ Not yet run      | N/A                 | Not yet implemented (dhcp.enabled = false)                     |
| T05     | Static DHCP Leases       | ww87     | ⏳ Not yet run      | N/A                 | Depends on T04                                                 |
| T06     | Web Management Interface | ww87     | 🔍 2025-11-22 10:00 | N/A                 | Theoretical: port 3000 configured                              |
| T07     | DNS Query Logging        | ww87     | 🔍 2025-11-22 10:00 | N/A                 | Theoretical: 90-day retention configured                       |
| T08     | Custom DNS Rewrites      | ww87     | 🔍 2025-11-22 10:00 | N/A                 | Theoretical: feature available                                 |
| T09     | SSH Remote Access        | both     | ✅ 2025-11-22 12:00 | ✅ 2025-11-22 12:00 | All 11 tests passed: SSH + security (keys, sudo, password)     |
| T10     | Multi-User Access        | both     | ✅ 2025-11-22 12:15 | ✅ 2025-11-22 12:15 | All 5 tests passed: mba + gb keys configured, sudo working     |
| T11     | ZFS Storage              | both     | ✅ 2025-11-22 10:00 | ✅ 2025-11-22 11:15 | Pool healthy, 7% used, compression working                     |
| T12     | ZFS Snapshots            | both     | ✅ 2025-11-22 12:15 | ✅ 2025-11-22 12:15 | All 4 tests passed: list, create, verify, destroy              |
| T13     | Location-Based Config    | both     | ✅ 2025-11-22 10:00 | N/A                 | Manual: location=jhw22 verified                                |
| T14     | One-Command Deployment   | both     | ✅ 2025-11-22 10:00 | N/A                 | Manual: enable-ww87 script exists                              |
| T15     | Docker & Home Assistant  | both     | ⏳ Not yet run      | N/A                 | Docker infrastructure, Home Assistant for gb user              |
| T16     | User Identity Config     | both     | ⏳ Not yet run      | ⏳ Not yet run      | Git user.name, user.email, correct authorship                  |
| T17     | Fish Shell Utilities     | both     | ⏳ Not yet run      | ⏳ Not yet run      | sourcefish function, EDITOR=nano, shell functions              |
| T18     | Local /etc/hosts         | both     | ⏳ Not yet run      | ⏳ Not yet run      | Privacy-focused hostnames, fallback DNS resolution             |

**Location Legend:**

- `both`: Can be tested at jhw22 (current) or ww87 (target)
- `ww87`: Requires deployment to parents' home (AdGuard Home features)
- `jhw22`: Only testable at current location

**Status Legend:**

- ✅ **Pass**: Test executed and passed at the specified date/time
- ❌ **Fail**: Test executed and failed at the specified date/time
- ⚠️ **Warning**: Test passed with issues or partial success
- ⏳ **Pending**: Not yet run
- 🔍 **Theoretical**: Analytical check (cannot physically test at current location)
- N/A: Test type not applicable for this feature

## Notes

- Tests assume server is at target location (ww87) unless specified
- Some tests require physical access to the server
- DNS/DHCP tests require network isolation for accuracy
