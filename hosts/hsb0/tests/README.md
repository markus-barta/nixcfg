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

| Test ID | Feature                      | Manual Last Run | Auto Last Run  | Notes                                                |
| ------- | ---------------------------- | --------------- | -------------- | ---------------------------------------------------- |
| T00     | NixOS Base System            | ⏳ Not yet run  | ⏳ Not yet run | Foundation: version, config, generations, status     |
| T01     | DNS Server                   | ⏳ Not yet run  | ⏳ Not yet run | AdGuard Home DNS resolution with Cloudflare upstream |
| T02     | Ad Blocking                  | ⏳ Not yet run  | ⏳ Not yet run | Filtering enabled, protection working                |
| T03     | DNS Cache                    | ⏳ Not yet run  | ⏳ Not yet run | 4MB cache, optimistic caching                        |
| T04     | DHCP Server                  | ⏳ Not yet run  | ⏳ Not yet run | IP assignment 192.168.1.201-254, 24h lease           |
| T05     | Static DHCP Leases           | ⏳ Not yet run  | ⏳ Not yet run | agenix-encrypted, merged with dynamic leases         |
| T06     | DNS Rewrites                 | ⏳ Not yet run  | ⏳ Not yet run | csb0 → cs0.barta.cm, csb1 → cs1.barta.cm             |
| T07     | Web Management Interface     | ⏳ Not yet run  | ⏳ Not yet run | <http://192.168.1.99:3000>, admin access             |
| T08     | DNS Query Logging            | ⏳ Not yet run  | ⏳ Not yet run | 90-day retention, query history                      |
| T09     | SSH Remote Access + Security | ⏳ Not yet run  | ⏳ Not yet run | SSH keys, passwordless sudo, security hardening      |
| T10     | ZFS Storage                  | ⏳ Not yet run  | ⏳ Not yet run | Pool health, compression, fragmentation              |
| T11     | ZFS Snapshots                | ⏳ Not yet run  | ⏳ Not yet run | List, create, verify, destroy snapshots              |

## Notes

- hsb0 is a production DNS/DHCP server - tests should be run carefully
- DNS/DHCP changes can affect the entire network
- Always have physical access available in case of issues
- Some tests may require temporary network reconfiguration
