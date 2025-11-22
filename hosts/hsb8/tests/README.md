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

| Test ID | Feature                  | Type            | Status |
| ------- | ------------------------ | --------------- | ------ |
| T00     | NixOS Base System        | Manual + Script | ✅     |
| T01     | DNS Server               | Manual + Script | ✅     |
| T02     | Ad Blocking              | Manual + Script | ⏳     |
| T03     | DNS Cache                | Manual + Script | ⏳     |
| T04     | DHCP Server              | Manual          | ⏳     |
| T05     | Static DHCP Leases       | Manual          | ⏳     |
| T06     | Web Management Interface | Manual          | ⏳     |
| T07     | DNS Query Logging        | Manual          | ⏳     |
| T08     | Custom DNS Rewrites      | Manual          | ⏳     |
| T09     | SSH Remote Access        | Manual + Script | ✅     |
| T10     | Multi-User Access        | Manual + Script | ⏳     |
| T11     | ZFS Storage              | Manual + Script | ✅     |
| T12     | ZFS Snapshots            | Manual + Script | ⏳     |
| T13     | Location-Based Config    | Manual + Script | ⏳     |
| T14     | One-Command Deployment   | Manual + Script | ⏳     |

## Notes

- Tests assume server is at target location (ww87) unless specified
- Some tests require physical access to the server
- DNS/DHCP tests require network isolation for accuracy
