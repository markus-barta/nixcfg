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

| Test ID | Feature                      | 👇🏻 Manual Last Run  | 🤖 Auto Last Run    | Notes                                              |
| ------- | ---------------------------- | ------------------- | ------------------- | -------------------------------------------------- |
| T00     | NixOS Base System            | ✅ 2025-12-02 18:59 | ✅ 2025-12-02 18:59 | 5/5 passed, 10 generations, Yarara 26.05 (hokage)  |
| T01     | DNS Server                   | ✅ 2025-12-02 18:59 | ✅ 2025-12-02 18:59 | 5/5 tests passed, upstream DNS: 1.1.1.1, 1.0.0.1   |
| T01     | Theme (starship/zellij/eza)  | ✅ 2025-12-02 18:59 | ✅ 2025-12-02 18:59 | 27/27 passed - yellow theme, Tokyo Night eza       |
| T02     | Ad Blocking                  | ✅ 2025-12-02 18:59 | ✅ 2025-12-02 18:59 | 3/3 tests passed - protection & filtering enabled  |
| T03     | DNS Cache                    | ✅ 2025-12-02 18:59 | ✅ 2025-12-02 18:59 | 3/3 tests passed - 4MB cache, optimistic, 9ms perf |
| T04     | DHCP Server                  | ✅ 2025-12-02 18:59 | ✅ 2025-12-02 18:59 | 5/5 tests passed - DHCP enabled, .201-.254, 24h    |
| T05     | Static DHCP Leases           | ✅ 2025-12-02 18:59 | ✅ 2025-12-02 18:59 | 4/4 tests passed - 107 static leases via agenix    |
| T06     | DNS Rewrites                 | ✅ 2025-12-02 18:59 | ✅ 2025-12-02 18:59 | 3/3 tests passed - csb0/csb1 → cs0/cs1.barta.cm    |
| T07     | Web Management Interface     | ✅ 2025-12-02 18:59 | ✅ 2025-12-02 18:59 | 3/3 tests passed - web UI accessible, port 3000    |
| T08     | DNS Query Logging            | ✅ 2025-12-02 18:59 | ✅ 2025-12-02 18:59 | 3/3 tests passed - 90 day retention, logging on    |
| T09     | SSH Remote Access + Security | ✅ 2025-12-02 18:59 | ✅ 2025-12-02 18:59 | 8/8 passed - 1 SSH key, hardened, hokage mkForce   |
| T10     | ZFS Storage                  | ✅ 2025-12-02 18:59 | ✅ 2025-12-02 18:59 | 5/5 tests passed - ONLINE, 4% used, zstd compress  |
| T11     | ZFS Snapshots                | ✅ 2025-12-02 18:59 | ✅ 2025-12-02 18:59 | 4/4 tests passed - list, create, verify, destroy   |

## Notes

- hsb0 is a production DNS/DHCP server - tests should be run carefully
- DNS/DHCP changes can affect the entire network
- Always have physical access available in case of issues
- Some tests may require temporary network reconfiguration
