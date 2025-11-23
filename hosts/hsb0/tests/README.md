# hsb0 Test Suite

This directory contains test procedures and automated scripts to verify that all DNS/DHCP server features are working correctly.

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
cd hosts/hsb0
for test in tests/T*.sh; do
  echo "Running $test..."
  bash "$test" || echo "❌ Failed: $test"
done
```

## Test Status Legend

- ✅ **Pass**: Feature working as expected
- ⏳ **Pending**: Feature not yet tested
- ❌ **Fail**: Feature not working, requires attention
- N/A: Test type not applicable for this feature

## Prerequisites

- SSH access to hsb0 (192.168.1.99 or hsb0.lan)
- Network connectivity to hsb0
- For DNS/DHCP tests: hsb0 must be the active network DNS/DHCP server

## Test List

| Test ID | Feature                      | 👇🏻 Manual Last Run | 🤖 Auto Last Run    | Notes                                              |
| ------- | ---------------------------- | ------------------ | ------------------- | -------------------------------------------------- |
| T00     | NixOS Base System            | ⏳ Not yet run     | ✅ 2025-11-23 16:30 | Foundation: version, config, generations, status   |
| T01     | DNS Server                   | ⏳ Not yet run     | ✅ 2025-11-23 16:35 | 5/5 tests passed, upstream DNS: 1.1.1.1, 1.0.0.1   |
| T02     | Ad Blocking                  | ⏳ Not yet run     | ✅ 2025-11-23 16:36 | 3/3 tests passed - protection & filtering enabled  |
| T03     | DNS Cache                    | ⏳ Not yet run     | ✅ 2025-11-23 16:37 | 3/3 tests passed - 4MB cache, optimistic, 9ms perf |
| T04     | DHCP Server                  | ⏳ Not yet run     | ❌ 2025-11-23 16:30 | DHCP not enabled - expected/by design?             |
| T05     | Static DHCP Leases           | ⏳ Not yet run     | ✅ 2025-11-23 16:30 | 4/4 tests passed - 107 static leases via agenix    |
| T06     | DNS Rewrites                 | ⏳ Not yet run     | ❌ 2025-11-23 16:30 | No rewrite rules configured - needs investigation  |
| T07     | Web Management Interface     | ⏳ Not yet run     | ⚠️ 2025-11-23 16:30 | 2/3 tests passed - firewall check failed           |
| T08     | DNS Query Logging            | ⏳ Not yet run     | ❌ 2025-11-23 16:30 | Query logging not enabled - needs investigation    |
| T09     | SSH Remote Access + Security | ⏳ Not yet run     | ⚠️ 2025-11-23 16:30 | 4/5 tests passed - user password not set           |
| T10     | ZFS Storage                  | ⏳ Not yet run     | ⚠️ 2025-11-23 16:30 | 3/4 tests passed - compression check failed        |
| T11     | ZFS Snapshots                | ⏳ Not yet run     | ✅ 2025-11-23 16:30 | 4/4 tests passed - list, create, verify, destroy   |

## Notes

- hsb0 is a production DNS/DHCP server - tests should be run carefully
- DNS/DHCP changes can affect the entire network
- Always have physical access available in case of issues
- Some tests may require temporary network reconfiguration
